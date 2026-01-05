#!/bin/bash
# Labelle CLI Installer
# Usage: curl -fsSL https://labelle-toolkit.github.io/labelle-cli/install.sh | bash

set -e

REPO="labelle-toolkit/labelle-cli"
INSTALL_DIR="/usr/local/bin"
BINARY_NAME="labelle"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() {
    echo -e "${BLUE}==>${NC} $1"
}

success() {
    echo -e "${GREEN}==>${NC} $1"
}

error() {
    echo -e "${RED}Error:${NC} $1" >&2
    exit 1
}

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "darwin" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *) error "Unsupported operating system: $(uname -s)" ;;
    esac
}

# Detect architecture
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64" ;;
        arm64|aarch64) echo "arm64" ;;
        *) error "Unsupported architecture: $(uname -m)" ;;
    esac
}

# Get latest version from GitHub
get_latest_version() {
    curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | \
        grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

# Main installation
main() {
    echo ""
    echo "  _       _          _ _      "
    echo " | | __ _| |__   ___| | | ___ "
    echo " | |/ _\` | '_ \\ / _ \\ | |/ _ \\"
    echo " | | (_| | |_) |  __/ | |  __/"
    echo " |_|\\__,_|_.__/ \\___|_|_|\\___|"
    echo ""
    echo " CLI Installer"
    echo ""

    OS=$(detect_os)
    ARCH=$(detect_arch)
    VERSION=$(get_latest_version)

    if [ -z "$VERSION" ]; then
        error "Could not determine latest version"
    fi

    info "Detected: ${OS}-${ARCH}"
    info "Latest version: ${VERSION}"

    # Determine download URL and extension
    if [ "$OS" = "windows" ]; then
        ARCHIVE="labelle-windows-x86_64.zip"
        EXT="zip"
    else
        ARCHIVE="labelle-${OS}-${ARCH}.tar.gz"
        EXT="tar.gz"
    fi

    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ARCHIVE}"

    info "Downloading ${ARCHIVE}..."

    # Create temp directory
    TMP_DIR=$(mktemp -d)
    trap "rm -rf ${TMP_DIR}" EXIT

    # Download
    curl -fsSL "$DOWNLOAD_URL" -o "${TMP_DIR}/${ARCHIVE}"

    # Extract
    info "Extracting..."
    cd "$TMP_DIR"
    if [ "$EXT" = "zip" ]; then
        unzip -q "$ARCHIVE"
    else
        tar -xzf "$ARCHIVE"
    fi

    # Install
    info "Installing to ${INSTALL_DIR}..."

    if [ -w "$INSTALL_DIR" ]; then
        mv "${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
    else
        info "Requesting sudo access to install to ${INSTALL_DIR}"
        sudo mv "${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"
    fi

    chmod +x "${INSTALL_DIR}/${BINARY_NAME}"

    success "Installed labelle ${VERSION} to ${INSTALL_DIR}/${BINARY_NAME}"
    echo ""

    # Verify installation
    if command -v labelle &> /dev/null; then
        echo "Verify installation:"
        labelle version
        echo ""
        echo "Get started:"
        echo "  labelle init my-game"
        echo "  cd my-game"
        echo "  labelle run"
    else
        echo "Note: ${INSTALL_DIR} may not be in your PATH"
        echo "Add it with: export PATH=\"\$PATH:${INSTALL_DIR}\""
    fi
}

main "$@"
