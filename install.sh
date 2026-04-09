#!/bin/sh
set -euo pipefail

# Sabbel installer
# Usage: curl -fsSL https://raw.githubusercontent.com/kenodressel/sabbel/main/install.sh | sh

REPO="kenodressel/sabbel"
APP_NAME="Sabbel.app"
ZIP_NAME="Sabbel.zip"
INSTALL_DIR="${HOME}/Applications"
DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/${ZIP_NAME}"

PLIST_LABEL="com.sabbel.agent"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/${PLIST_LABEL}.plist"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"
  RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  CYAN="$(printf '\033[36m')"
  RESET="$(printf '\033[0m')"
else
  BOLD=""
  RED=""
  GREEN=""
  YELLOW=""
  CYAN=""
  RESET=""
fi

info() {
  printf "%s==>%s %s%s\n" "${CYAN}${BOLD}" "${RESET}" "$*" "${RESET}"
}

success() {
  printf "%s==>%s %s%s\n" "${GREEN}${BOLD}" "${RESET}" "$*" "${RESET}"
}

warn() {
  printf "%sWarning:%s %s%s\n" "${YELLOW}${BOLD}" "${RESET}" "$*" "${RESET}" >&2
}

error() {
  printf "%sError:%s %s%s\n" "${RED}${BOLD}" "${RESET}" "$*" "${RESET}" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# System checks
# ---------------------------------------------------------------------------

OS="$(uname -s)"
ARCH="$(uname -m)"

if [ "${OS}" != "Darwin" ]; then
  error "Sabbel requires macOS. Detected OS: ${OS}"
fi

if [ "${ARCH}" != "arm64" ]; then
  error "Sabbel requires Apple Silicon (arm64). Detected architecture: ${ARCH}"
fi

# ---------------------------------------------------------------------------
# Temp directory with automatic cleanup
# ---------------------------------------------------------------------------

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

info "Downloading Sabbel..."
if command -v curl > /dev/null 2>&1; then
  curl --fail --silent --show-error --location --output "${TMPDIR}/${ZIP_NAME}" "${DOWNLOAD_URL}"
else
  error "curl is required but was not found."
fi

# ---------------------------------------------------------------------------
# Extract
# ---------------------------------------------------------------------------

info "Extracting ${ZIP_NAME}..."
ditto -xk "${TMPDIR}/${ZIP_NAME}" "${TMPDIR}/"

if [ ! -d "${TMPDIR}/${APP_NAME}" ]; then
  error "Expected ${APP_NAME} inside ${ZIP_NAME}, but it was not found."
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

mkdir -p "${INSTALL_DIR}"

DEST="${INSTALL_DIR}/${APP_NAME}"

if [ -d "${DEST}" ]; then
  warn "Replacing existing installation at ${DEST}"
  rm -rf "${DEST}"
fi

info "Installing to ${DEST}..."
ditto "${TMPDIR}/${APP_NAME}" "${DEST}"

# ---------------------------------------------------------------------------
# Autostart prompt
# ---------------------------------------------------------------------------

setup_autostart() {
  mkdir -p "${PLIST_DIR}"
  cat > "${PLIST_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>${DEST}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/sabbel.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/sabbel.log</string>
</dict>
</plist>
PLIST

  DOMAIN="gui/$(id -u)"
  launchctl bootout "${DOMAIN}/${PLIST_LABEL}" 2>/dev/null || true
  launchctl bootstrap "${DOMAIN}" "${PLIST_PATH}"
  success "Sabbel will start automatically on login."
}

if [ -t 0 ]; then
  # Interactive — ask the user
  printf "\n"
  printf "%sStart Sabbel on login?%s [Y/n] " "${BOLD}" "${RESET}"
  read -r REPLY
  case "${REPLY}" in
    [nN]*) ;;
    *)     setup_autostart ;;
  esac
else
  # Non-interactive (piped) — skip autostart
  printf "\n"
  info "To start Sabbel on login, run:"
  printf "  launchctl load ~/Library/LaunchAgents/com.sabbel.agent.plist\n"
fi

# ---------------------------------------------------------------------------
# Success
# ---------------------------------------------------------------------------

printf "\n"
success "Sabbel has been installed to ${BOLD}${DEST}${RESET}"
printf "\n"
printf "%sNext steps:%s\n" "${BOLD}" "${RESET}"
printf "  1. Open Sabbel from ~/Applications or Spotlight (press Cmd+Space, type Sabbel)\n"
printf "  2. On first launch, macOS may ask you to confirm opening an app from the internet — click Open\n"
printf "  3. Grant Accessibility and Microphone permissions when prompted\n"
printf "\n"
