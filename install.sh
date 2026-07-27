#!/bin/sh
#
# NetDefense Agent Installer for OPNsense
#
# Usage:
#   Default (prod channel):
#     curl -sSL https://repo.netdefense.io/install.sh | sh
#   Other channels (operator-only):
#     curl -sSL https://repo.netdefense.io/install.sh | sh -s -- --env=qa
#     curl -sSL https://repo.netdefense.io/install.sh | sh -s -- --env=dev
#
#   Unattended install (registration token + API auto-setup + enable):
#     curl -sSL https://repo.netdefense.io/install.sh | \
#       sh -s -- --auto-setup=<org-registration-token-uuid>
#
#   Add --non-interactive for CI/IaC consumers — replaces the trailing
#   prose summary with a parseable KEY=value status block.
#

set -e

# Parse args
TARGET_ENV="prod"
AUTO_SETUP_TOKEN=""
NON_INTERACTIVE=0
for arg in "$@"; do
    case "$arg" in
        --env=*)
            TARGET_ENV="${arg#--env=}"
            ;;
        --auto-setup=*)
            AUTO_SETUP_TOKEN="${arg#--auto-setup=}"
            ;;
        --non-interactive)
            NON_INTERACTIVE=1
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $0 [--env=prod|qa|dev] [--auto-setup=<uuid>] [--non-interactive]" >&2
            exit 1
            ;;
    esac
done

# Validate --auto-setup token format up-front so we fail before any side
# effects on the system. The OPNsense Settings model enforces the same
# regex (Settings.xml: token mask) — pre-validating here gives a clear
# error from the shell instead of a vague PHP rejection later.
if [ -n "${AUTO_SETUP_TOKEN}" ]; then
    case "${AUTO_SETUP_TOKEN}" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
            ;;
        *)
            echo "Invalid --auto-setup value: must be a lowercase UUID (8-4-4-4-12 hex)" >&2
            exit 10
            ;;
    esac
fi

case "$TARGET_ENV" in
    prod)
        PACKAGE_NAME="os-netdefense"
        ;;
    qa)
        PACKAGE_NAME="os-netdefense-qa"
        ;;
    dev)
        PACKAGE_NAME="os-netdefense-dev"
        ;;
    *)
        echo "Invalid --env=${TARGET_ENV} (must be prod, qa, or dev)" >&2
        exit 1
        ;;
esac

# Colors for output (if terminal supports it)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Configuration. URLs route to the per-env channel under the same domain;
# fingerprints live alongside each channel's pkg metadata so the same
# signing key serves all three (only the metadata index differs per env).
#
# REPO_NAME is the dictionary key written into the .conf file and is what
# OPNsense renders in System → Firmware → Plugins as the originating repo
# (mirrors how OPNsense itself shows up as "OPNsense"). Server-side
# fingerprint paths stay lowercase; only the client-side label changes.
REPO_NAME="NetDefense"
LEGACY_REPO_NAME="netdefense"
REPO_CONF_DIR="/usr/local/etc/pkg/repos"
REPO_CONF_FILE="${REPO_CONF_DIR}/${REPO_NAME}.conf"
LEGACY_REPO_CONF_FILE="${REPO_CONF_DIR}/${LEGACY_REPO_NAME}.conf"

# Channel root (no ABI segment). Dual-ABI layout: each channel serves both
# FreeBSD ABIs (FreeBSD:14:amd64 / FreeBSD:15:amd64 — OPNsense 26.7+ moved
# to FreeBSD 15) as independent, self-contained pkg(8) repo mirrors under
# ${channel}/opnsense/${ABI}/, mirroring how OPNsense's own repo and
# pkg.freebsd.org lay out ${ABI}-nested mirrors.
CHANNEL_ROOT="https://repo.netdefense.io/${TARGET_ENV}/opnsense"

# Repo conf URL written into NetDefense.conf's url: field. The `${ABI}`
# here is pkg(8)'s own substitution variable, NOT a shell variable — it
# must land in the file UNEXPANDED (escaped below) so pkg resolves it at
# every `pkg update`/`pkg install` from the installing box's own live ABI.
# This is deliberately different from FINGERPRINT_URL below: that fetch is
# performed by THIS script via `fetch`, which has no notion of pkg's
# ${ABI} substitution, so it needs a concretely resolved ABI instead (see
# install_fingerprint(), which resolves it via `pkg config ABI`).
REPO_URL="${CHANNEL_ROOT}/\${ABI}"

FINGERPRINT_DIR="/usr/local/etc/pkg/fingerprints/${REPO_NAME}/trusted"
LEGACY_FINGERPRINT_DIR="/usr/local/etc/pkg/fingerprints/${LEGACY_REPO_NAME}"

# Logging functions
log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

log_success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
}

log_warning() {
    printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
}

# Error handler
error_exit() {
    log_error "$1"
    exit "${2:-1}"
}

# Check if running on FreeBSD/OPNsense
check_os() {
    log_info "Checking operating system..."
    if [ "$(uname -s)" != "FreeBSD" ]; then
        error_exit "This script is designed for FreeBSD/OPNsense systems only." 1
    fi
    log_success "Running on FreeBSD"
}

# Check root privileges
check_root() {
    log_info "Checking root privileges..."
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "This script must be run as root. Please use 'su' or 'sudo'." 1
    fi
    log_success "Running with root privileges"
}

# Create repository configuration directory if needed
create_repo_dir() {
    log_info "Checking repository configuration directory..."
    if [ ! -d "${REPO_CONF_DIR}" ]; then
        log_info "Creating ${REPO_CONF_DIR}..."
        mkdir -p "${REPO_CONF_DIR}" || error_exit "Failed to create repository directory" 2
        log_success "Repository directory created"
    else
        log_success "Repository directory exists"
    fi
}

# Install repository fingerprint for package verification
install_fingerprint() {
    log_info "Installing repository fingerprint for signature verification..."

    # Create fingerprint directory
    if [ ! -d "${FINGERPRINT_DIR}" ]; then
        log_info "Creating ${FINGERPRINT_DIR}..."
        mkdir -p "${FINGERPRINT_DIR}" || error_exit "Failed to create fingerprint directory" 2
    fi

    # Resolve this box's concrete pkg ABI. Each ABI has its own
    # self-contained repo mirror (own fingerprints/ dir too), and unlike
    # NetDefense.conf's url: (pkg-substituted, see REPO_URL above), this
    # script downloads the fingerprint itself via `fetch`, which cannot
    # expand pkg's ${ABI} variable — it needs a real, resolved URL.
    LOCAL_PKG_ABI="$(pkg config ABI 2>/dev/null)"
    if [ -z "${LOCAL_PKG_ABI}" ]; then
        error_exit "Could not determine local pkg ABI ('pkg config ABI' returned empty). Is pkg bootstrapped?" 2
    fi
    log_info "Detected local pkg ABI: ${LOCAL_PKG_ABI}"

    FINGERPRINT_URL="${CHANNEL_ROOT}/${LOCAL_PKG_ABI}/fingerprints/netdefense/trusted/netdefense"

    # Download fingerprint
    log_info "Downloading fingerprint from ${FINGERPRINT_URL}..."
    if fetch -o "${FINGERPRINT_DIR}/netdefense" "${FINGERPRINT_URL}"; then
        log_success "Fingerprint installed successfully"
    else
        error_exit "Failed to download repository fingerprint" 3
    fi
}

# Remove the legacy lowercase repo registration so we don't end up with
# two parallel repos pointing at the same packages. Older installs of
# this script registered the repo as "netdefense"; the dictionary key is
# what OPNsense displays, so we switched to "NetDefense".
remove_legacy_repo() {
    if [ -f "${LEGACY_REPO_CONF_FILE}" ]; then
        log_info "Removing legacy lowercase repo: ${LEGACY_REPO_CONF_FILE}"
        rm -f "${LEGACY_REPO_CONF_FILE}" || log_warning "Failed to remove ${LEGACY_REPO_CONF_FILE}"
    fi
    if [ -d "${LEGACY_FINGERPRINT_DIR}" ]; then
        log_info "Removing legacy fingerprint dir: ${LEGACY_FINGERPRINT_DIR}"
        rm -rf "${LEGACY_FINGERPRINT_DIR}" || log_warning "Failed to remove ${LEGACY_FINGERPRINT_DIR}"
    fi
}

# Configure NetDefense repository
configure_repo() {
    log_info "Configuring NetDefense package repository..."

    # Backup existing config if present
    if [ -f "${REPO_CONF_FILE}" ]; then
        log_warning "Repository configuration already exists"
        BACKUP_FILE="${REPO_CONF_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "Creating backup: ${BACKUP_FILE}"
        cp "${REPO_CONF_FILE}" "${BACKUP_FILE}" || error_exit "Failed to backup existing configuration" 3
    fi

    # Write repository configuration with signature verification
    log_info "Writing repository configuration to ${REPO_CONF_FILE}..."
    cat > "${REPO_CONF_FILE}" <<EOF || error_exit "Failed to write repository configuration" 4
${REPO_NAME}: {
  url: "${REPO_URL}",
  priority: 5,
  enabled: yes,
  signature_type: "fingerprints",
  fingerprints: "/usr/local/etc/pkg/fingerprints/${REPO_NAME}"
}
EOF

    log_success "Repository configuration created with signature verification"
}

# Update package repository
update_pkg_repo() {
    log_info "Updating package repository information..."
    if pkg update; then
        log_success "Package repository updated successfully"
    else
        error_exit "Failed to update package repository. Check your internet connection and repository URL." 5
    fi
}

# Install NetDefense package
install_package() {
    log_info "Installing ${PACKAGE_NAME} package..."

    # Check if already installed
    if pkg info "${PACKAGE_NAME}" >/dev/null 2>&1; then
        log_warning "${PACKAGE_NAME} is already installed"
        log_info "Attempting to upgrade to latest version..."
        if pkg upgrade -y "${PACKAGE_NAME}"; then
            log_success "Package upgraded successfully"
        else
            error_exit "Failed to upgrade ${PACKAGE_NAME}" 6
        fi
    else
        # Install the package
        if pkg install -y "${PACKAGE_NAME}"; then
            log_success "${PACKAGE_NAME} installed successfully"
        else
            error_exit "Failed to install ${PACKAGE_NAME}. Check repository availability." 7
        fi
    fi
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."

    if pkg info "${PACKAGE_NAME}" >/dev/null 2>&1; then
        VERSION=$(pkg info "${PACKAGE_NAME}" | grep "^Version" | awk '{print $3}')
        log_success "Verification complete: ${PACKAGE_NAME} version ${VERSION} is installed"
        return 0
    else
        error_exit "Installation verification failed: ${PACKAGE_NAME} not found" 8
    fi
}

# Apply unattended settings via the plugin's CLI helper. Runs only when
# --auto-setup=<token> was passed. Generates a fresh device UUID locally,
# then asks configure.php to persist token + deviceId, provision the
# OPNsense API user/key, and enable the agent — all in one Config save.
#
# Sets the following globals so post_install_info_unattended can render
# the summary:
#   APPLIED_DEVICE_UUID, APPLIED_RESULT, APPLIED_API_SETUP
#
# The OPNsense API key + secret are deliberately not surfaced here. They
# live only in /conf/config.xml and the rendered ndagent.conf — both
# root-readable on the box. install.sh stdout flows into operator
# terminals, CI logs, and screenshots; the credential must not appear on
# any of those surfaces.
apply_unattended_settings() {
    log_info "Applying unattended configuration..."

    CONFIGURE_PHP="/usr/local/opnsense/scripts/OPNsense/NetDefense/configure.php"
    if [ ! -x "${CONFIGURE_PHP}" ]; then
        log_error "Plugin helper not found at ${CONFIGURE_PHP}"
        log_error "The package may be too old (pre-1.5.0) or corrupted."
        exit 20
    fi

    APPLIED_DEVICE_UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    log_info "Generated device UUID: ${APPLIED_DEVICE_UUID}"
    log_info "Provisioning OPNsense API user + key..."

    # Capture stdout (JSON) and exit code separately. configure.php's
    # --json output omits the api_key/api_secret by design, so HELPER_OUT
    # is safe to log. stderr passes through to the operator.
    HELPER_OUT="$(${CONFIGURE_PHP} \
        --token="${AUTO_SETUP_TOKEN}" \
        --device-id="${APPLIED_DEVICE_UUID}" \
        --setup-api \
        --enable \
        --json)" || HELPER_RC=$?
    HELPER_RC="${HELPER_RC:-0}"

    APPLIED_RESULT="$(printf '%s' "${HELPER_OUT}" \
        | awk -F'"result":"' 'NF>1{sub(/".*/,"",$2);print $2}')"
    APPLIED_API_SETUP="$(printf '%s' "${HELPER_OUT}" \
        | awk -F'"api_setup":"' 'NF>1{sub(/".*/,"",$2);print $2}')"

    case "${HELPER_RC}" in
        0)
            log_success "Unattended configuration applied"
            ;;
        21)
            log_warning "Token saved, but API auto-setup failed."
            log_warning "Finish API setup from Services > NetDefense > Setup API Credentials."
            log_info "Helper output: ${HELPER_OUT}"
            # Don't `exit` — the agent is otherwise viable for non-API tasks.
            ;;
        *)
            log_error "Unattended configuration failed (exit ${HELPER_RC})"
            log_error "Helper output: ${HELPER_OUT}"
            exit "${HELPER_RC}"
            ;;
    esac
}

# Display post-installation information
post_install_info() {
    cat <<'EOF'

========================================
NetDefense Agent Installation Complete
========================================

Configuration:
  Navigate to Services > NetDefense in the OPNsense web interface
  to configure and manage the NetDefense agent.

EOF
}

# Post-install summary for the unattended path. Format mirrors a key=value
# block that CI consumers can grep; the prose echo is suppressed under
# --non-interactive.
post_install_info_unattended() {
    # APPLIED_API_SETUP values: "ok" (provisioned just now), "skipped"
    # (already configured), "failed" (recoverable; operator finishes via
    # web UI). Never echo the key itself.
    case "${APPLIED_API_SETUP}" in
        ok|skipped) API_STATUS="APPLIED" ;;
        failed)     API_STATUS="FAILED — finish via web UI" ;;
        *)          API_STATUS="not configured" ;;
    esac

    if [ "${NON_INTERACTIVE}" -eq 1 ]; then
        cat <<EOF
STATUS=${APPLIED_RESULT:-unknown}
DEVICE_UUID=${APPLIED_DEVICE_UUID}
API_SETUP=${APPLIED_API_SETUP:-unknown}
ENV=${TARGET_ENV}
EOF
        return
    fi

    cat <<EOF

========================================
NetDefense Agent Installation Complete
========================================

Registration token: APPLIED
Device UUID:        ${APPLIED_DEVICE_UUID}
API credentials:    ${API_STATUS}
Service enabled:    YES (${TARGET_ENV} channel)

Next step:
  Approve this device in NetDefense (it will appear pending).
EOF
}

# Main installation flow
main() {
    echo ""
    log_info "Starting NetDefense Agent installation..."
    log_info "Channel: ${TARGET_ENV}"
    log_info "Package: ${PACKAGE_NAME}"
    log_info "Repo:    ${CHANNEL_ROOT}/<your ABI> (pkg resolves \${ABI} from this box's own FreeBSD ABI)"
    echo ""

    check_os
    check_root
    create_repo_dir
    remove_legacy_repo
    install_fingerprint
    configure_repo
    update_pkg_repo
    install_package
    verify_installation

    echo ""
    if [ -n "${AUTO_SETUP_TOKEN}" ]; then
        apply_unattended_settings
        post_install_info_unattended
    else
        post_install_info
    fi

    exit 0
}

# Handle interruption
trap 'error_exit "Installation interrupted by user" 130' INT TERM

# Run main installation
main
