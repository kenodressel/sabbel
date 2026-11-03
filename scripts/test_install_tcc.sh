#!/bin/sh
# Tests install.sh's decision to reset the TCC grants (Accessibility,
# Microphone) on an update, with canned `codesign` output. Run by
# `make native-test`.
#
# It never touches the real TCC database: `codesign` and `tccutil` are stubs
# first on PATH, and the test refuses to run when they are not.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILS=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; FAILS=$((FAILS + 1)); }

# Syntax, as both the POSIX sh that `curl | sh` runs and bash.
sh -n "$ROOT/install.sh" && pass "install.sh parses with sh -n" || fail "install.sh parses with sh -n"
bash -n "$ROOT/install.sh" && pass "install.sh parses with bash -n" || fail "install.sh parses with bash -n"

STUBS="$(mktemp -d)"
trap 'rm -rf "$STUBS"' EXIT

# tccutil only records its arguments.
cat > "$STUBS/tccutil" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$STUBS/tccutil.calls"
EOF
# codesign prints the canned output stored in the fake app directory:
# <app>/dv for `codesign -dv <app>`, <app>/dr for `codesign -d -r- <app>`.
cat > "$STUBS/codesign" <<'EOF'
#!/bin/sh
case "$1" in
  -dv) cat "$2/dv" >&2 ;;
  -d) cat "$3/dr" ;;
  *) echo "unexpected codesign call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$STUBS/tccutil" "$STUBS/codesign"
# Everything else the installer runs must never be reached when it is sourced.
for cmd in curl ditto pkill launchctl open; do
  printf '#!/bin/sh\necho "%s must not run in this test" >&2\nexit 99\n' "$cmd" > "$STUBS/$cmd"
  chmod +x "$STUBS/$cmd"
done
PATH="$STUBS:$PATH"
export PATH
if [ "$(command -v tccutil)" != "$STUBS/tccutil" ] || [ "$(command -v codesign)" != "$STUBS/codesign" ]; then
  echo "FAIL - the codesign/tccutil stubs are not first on PATH; refusing to run" >&2
  exit 1
fi

# Sourcing install.sh without its library guard would run the installer.
if ! grep -q '^if \[ "${SABBEL_INSTALL_LIB:-}" = 1 \]; then return 0; fi$' "$ROOT/install.sh"; then
  echo "FAIL - install.sh has no SABBEL_INSTALL_LIB guard; refusing to source it" >&2
  exit 1
fi
SABBEL_INSTALL_LIB=1
export SABBEL_INSTALL_LIB
# shellcheck source=../install.sh
. "$ROOT/install.sh"

# Canned codesign output.
DV_RELEASE='Executable=/x/Sabbel.app/Contents/MacOS/Sabbel
Identifier=com.sabbel.app
Signature size=1234
Authority=Sabbel Release
TeamIdentifier=not set'
DV_ADHOC='Executable=/x/Sabbel.app/Contents/MacOS/Sabbel
Identifier=com.sabbel.app
CodeDirectory v=20400 size=40871 flags=0x2(adhoc) hashes=1271+3 location=embedded
Signature=adhoc
TeamIdentifier=not set'
DV_UNSIGNED='/x/Sabbel.app: code object is not signed at all'
DR_RELEASE='Executable=/old/path/Sabbel.app/Contents/MacOS/Sabbel
designated => identifier "com.sabbel.app" and certificate leaf = H"1111111111111111111111111111111111111111"'
DR_RELEASE_NEW_PATH='Executable=/tmp/new/Sabbel.app/Contents/MacOS/Sabbel
designated => identifier "com.sabbel.app" and certificate leaf = H"1111111111111111111111111111111111111111"'
DR_OTHER_CERT='Executable=/tmp/new/Sabbel.app/Contents/MacOS/Sabbel
designated => identifier "com.sabbel.app" and certificate leaf = H"2222222222222222222222222222222222222222"'
DR_ADHOC='Executable=/tmp/new/Sabbel.app/Contents/MacOS/Sabbel
# designated => cdhash H"f776e056d453cfa7c0896ffd638fc090d44f77df"'

# expect_reset DESCRIPTION 0|1 OLD_DV OLD_DR NEW_DR   (0: reset, 1: keep)
expect() {
  desc="$1"; want="$2"; shift 2
  if sabbel_needs_tcc_reset "$@"; then got=0; else got=1; fi
  [ "$got" = "$want" ] && pass "$desc" || fail "$desc (got $got, want $want)"
}

expect "Sabbel Release -> Sabbel Release keeps the grants" 1 "$DV_RELEASE" "$DR_RELEASE" "$DR_RELEASE_NEW_PATH"
expect "an ad-hoc installed app is reset" 0 "$DV_ADHOC" "$DR_ADHOC" "$DR_RELEASE"
expect "an unsigned installed app is reset" 0 "$DV_UNSIGNED" "" "$DR_RELEASE"
expect "a different certificate is reset" 0 "$DV_RELEASE" "$DR_RELEASE" "$DR_OTHER_CERT"
expect "a signed app replaced by an ad-hoc build is reset" 0 "$DV_RELEASE" "$DR_RELEASE" "$DR_ADHOC"
expect "an unreadable designated requirement is reset" 0 "$DV_RELEASE" "" "$DR_RELEASE"

# The wrapper reads both apps through codesign and resets through tccutil.
OLD="$STUBS/old.app"; NEW="$STUBS/new.app"
mkdir -p "$OLD" "$NEW"
printf '%s\n' "$DV_RELEASE" > "$OLD/dv"; printf '%s\n' "$DR_RELEASE" > "$OLD/dr"
printf '%s\n' "$DR_RELEASE_NEW_PATH" > "$NEW/dr"
if sabbel_tcc_reset_needed "$OLD" "$NEW"; then fail "wrapper keeps the grants for the same signature"; else pass "wrapper keeps the grants for the same signature"; fi
printf '%s\n' "$DR_OTHER_CERT" > "$NEW/dr"
if sabbel_tcc_reset_needed "$OLD" "$NEW"; then pass "wrapper resets for another certificate"; else fail "wrapper resets for another certificate"; fi

sabbel_reset_tcc
EXPECTED='reset Accessibility com.sabbel.app
reset Microphone com.sabbel.app'
[ "$(cat "$STUBS/tccutil.calls")" = "$EXPECTED" ] \
  && pass "the reset covers Accessibility and Microphone for com.sabbel.app" \
  || fail "the reset covers Accessibility and Microphone for com.sabbel.app (got: $(cat "$STUBS/tccutil.calls"))"

if [ "$FAILS" -ne 0 ]; then
  echo "$FAILS install TCC test(s) failed" >&2
  exit 1
fi
echo "install TCC tests passed"
