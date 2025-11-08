#!/bin/sh
#
# NetDefense Agent Installer for OPNsense
# Usage: curl -sSL https://repo.netdefense.io/install.sh | sh
#

set -e

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

# Configuration
REPO_NAME="netdefense"
REPO_CONF_DIR="/usr/local/etc/pkg/repos"
REPO_CONF_FILE="${REPO_CONF_DIR}/${REPO_NAME}.conf"
REPO_URL="https://repo.netdefense.io/opnsense"
PACKAGE_NAME="os-netdefense"

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

    # Write repository configuration
    log_info "Writing repository configuration to ${REPO_CONF_FILE}..."
    cat > "${REPO_CONF_FILE}" <<EOF || error_exit "Failed to write repository configuration" 4
${REPO_NAME}: {
  url: "${REPO_URL}",
  priority: 5,
  enabled: yes
}
EOF

    log_success "Repository configuration created"
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

# Main installation flow
main() {
    echo ""
    log_info "Starting NetDefense Agent installation..."
    echo ""

    check_os
    check_root
    create_repo_dir
    configure_repo
    update_pkg_repo
    install_package
    verify_installation

    echo ""
    post_install_info

    exit 0
}

# Handle interruption
trap 'error_exit "Installation interrupted by user" 130' INT TERM

# Run main installation
main
