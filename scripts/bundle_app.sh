#!/bin/bash
# Assemble and sign dist/Sabbel.app from the release build of the Swift package.
# Usage: scripts/bundle_app.sh [VERSION]    (VERSION: "dev" or a tag without its "v")
# Env:   SABBEL_SIGN_IDENTITY  codesign identity; unset -> "Sabbel Release" if the
#                              keychain has it, else ad hoc (with a warning).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-dev}"
APP="$ROOT/dist/Sabbel.app"
BIN_DIR="$(swift build --package-path "$ROOT/native" -c release --show-bin-path)"

# The bundle version must be numeric; "dev" builds report 0.0.0. A prerelease
# tag like 1.0.0-rc.1 keeps its numeric core for CFBundleShortVersionString.
if [ "$VERSION" = "dev" ]; then BUNDLE_VERSION="0.0.0"; else BUNDLE_VERSION="${VERSION%%-*}"; fi

IDENTITY="${SABBEL_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Sabbel Release"'; then
    IDENTITY="Sabbel Release"
  else
    IDENTITY="-"
    echo "warning: signing ad hoc; Accessibility/Microphone grants will not survive a rebuild" >&2
  fi
fi

[ -f "$BIN_DIR/Sabbel" ] || { echo "error: $BIN_DIR/Sabbel not built" >&2; exit 1; }
[ -f "$ROOT/icons/Sabbel.icns" ] || { echo "error: icons/Sabbel.icns missing (make icons/Sabbel.icns)" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Sabbel" "$APP/Contents/MacOS/Sabbel"
cp "$ROOT/icons/Sabbel.icns" "$APP/Contents/Resources/Sabbel.icns"
sed "s|__BUNDLE_VERSION__|$BUNDLE_VERSION|g; s|__SABBEL_VERSION__|$VERSION|g" \
  "$ROOT/native/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# SwiftPM resource bundles: Bundle.module looks in Bundle.main.resourceURL.
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] || continue
  cp -R "$b" "$APP/Contents/Resources/"
  echo "bundled resource bundle $(basename "$b")"
done

# Dynamic frameworks (e.g. from binary targets): found through @rpath.
shopt -s nullglob
for f in "$BIN_DIR"/*.framework; do
  cp -R "$f" "$APP/Contents/Frameworks/"
  echo "bundled framework $(basename "$f")"
done
shopt -u nullglob
if [ -n "$(ls -A "$APP/Contents/Frameworks")" ]; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Sabbel" 2>/dev/null || true
else
  rmdir "$APP/Contents/Frameworks"
fi

codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (version $VERSION, signed: $IDENTITY)"
