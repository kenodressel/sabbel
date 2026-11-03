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
BUNDLE_ID="com.sabbel.app"

# ---------------------------------------------------------------------------
# Permissions (TCC) across an update
#
# macOS ties the Accessibility and Microphone grants to the app's designated
# requirement. A release signed by the stable "Sabbel Release" certificate has
# the same one as the release before it, so its grants carry over and must be
# kept. When the installed app is ad hoc signed (every build is a new
# identity, e.g. a 0.5.x Python build) or its requirement differs from the new
# app's, the old grant no longer matches: macOS shows the switch as on while
# denying the app. Only then are the grants reset, so macOS asks again.
#
# Shared with `make install-app`, which sources this file with
# SABBEL_INSTALL_LIB=1 (as does scripts/test_install_tcc.sh).
# ---------------------------------------------------------------------------

# Exit 0 when the grants must be reset, 1 when they can be kept. Decided on
# the designated requirement alone (`codesign -d -r-`): it is what TCC
# matches, and an ad-hoc app's is always a `cdhash` (new with every build).
# Reset when the installed app's requirement is missing (unsigned or
# unreadable), is a cdhash, or differs from the new app's.
#   $1  `codesign -d -r-` output of the installed app
#   $2  `codesign -d -r-` output of the new app
sabbel_needs_tcc_reset() {
  # Compare only the requirement: the Executable= line names each app's path.
  # Ad-hoc output prints it as a comment ("# designated => cdhash ...").
  _sabbel_old_dr="$(printf '%s\n' "$1" | sed -n 's/^#* *designated => //p')"
  _sabbel_new_dr="$(printf '%s\n' "$2" | sed -n 's/^#* *designated => //p')"
  case "${_sabbel_old_dr}" in
    ''|cdhash*) return 0 ;;
  esac
  if [ "${_sabbel_old_dr}" = "${_sabbel_new_dr}" ]; then
    return 1
  fi
  return 0
}

# Exit 0 when replacing the installed app $1 with the new app $2 needs a reset.
sabbel_tcc_reset_needed() {
  sabbel_needs_tcc_reset \
    "$(codesign -d -r- "$1" 2>&1 || true)" \
    "$(codesign -d -r- "$2" 2>&1 || true)"
}

sabbel_reset_tcc() {
  tccutil reset Accessibility "${BUNDLE_ID}" >/dev/null 2>&1 || true
  tccutil reset Microphone "${BUNDLE_ID}" >/dev/null 2>&1 || true
}

# Sourced for the functions above only: stop before installing anything.
if [ "${SABBEL_INSTALL_LIB:-}" = 1 ]; then return 0; fi

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
IS_UPDATE=false
TCC_RESET=false

if [ -d "${DEST}" ]; then
  IS_UPDATE=true
  info "Updating existing installation..."

  # Stop running Sabbel
  pkill -x "Sabbel" 2>/dev/null || true
  DOMAIN="gui/$(id -u)"
  launchctl bootout "${DOMAIN}/${PLIST_LABEL}" 2>/dev/null || true
  sleep 1

  if sabbel_tcc_reset_needed "${DEST}" "${TMPDIR}/${APP_NAME}"; then
    info "The app's signature changed; resetting its Accessibility and Microphone permissions..."
    sabbel_reset_tcc
    TCC_RESET=true
  fi

  rm -rf "${DEST}"
fi

info "Installing to ${DEST}..."
ditto "${TMPDIR}/${APP_NAME}" "${DEST}"

# ---------------------------------------------------------------------------
# Launch (macOS focuses it if it's already running via autostart below)
# ---------------------------------------------------------------------------

open "${DEST}"

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

# Parse flags
AUTOSTART=true
for arg in "$@"; do
  case "${arg}" in
    --no-autostart) AUTOSTART=false ;;
  esac
done

if [ -t 0 ]; then
  # Interactive — ask the user
  printf "\n"
  printf "%sStart Sabbel on login?%s [Y/n] " "${BOLD}" "${RESET}"
  read -r REPLY
  case "${REPLY}" in
    [nN]*) AUTOSTART=false ;;
  esac
fi

if [ "${AUTOSTART}" = true ]; then
  setup_autostart
fi

# ---------------------------------------------------------------------------
# Success
# ---------------------------------------------------------------------------

printf "\n"
if [ "${IS_UPDATE}" = true ]; then
  success "Sabbel has been updated and launched."
  printf "\n"
  if [ "${TCC_RESET}" = true ]; then
    printf "  The app's signature changed (expected once, when updating from a\n"
    printf "  0.5.x build), so its Accessibility and Microphone permissions were\n"
    printf "  reset. Grant them again when macOS asks; the Sabbel menu shows what\n"
    printf "  is still missing. Later updates keep your permissions.\n"
  else
    printf "  Same signature as before: your Accessibility and Microphone\n"
    printf "  permissions were kept.\n"
  fi
else
  success "Sabbel has been installed to ${BOLD}${DEST}${RESET} and launched."
  printf "\n"
  printf "  Sabbel lives in the menu bar. Open its menu to see its status and\n"
  printf "  which permissions it still needs.\n"
fi
printf "\n"
