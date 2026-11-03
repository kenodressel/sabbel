#!/bin/sh
# Tests install.sh's decision to reset the TCC grants (Accessibility,
# Microphone) on an update, against verbatim `codesign` output captured on a
# Mac (scripts/fixtures/codesign/, only paths changed). Run by
# `make test`.
#
# It never touches the real TCC database: `codesign` and `tccutil` are stubs
# first on PATH, and the test refuses to run when they are not.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$ROOT/scripts/fixtures/codesign"
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
# codesign replays a capture: an "app" is a fixture directory holding the
# output of `-dv` (dv), `-dvv` (dvv) and `-d -r-` (dr), and the exit status (rc).
# Like codesign, it writes to stderr.
cat > "$STUBS/codesign" <<'EOF'
#!/bin/sh
case "$1" in
  -dv) app="$2"; out=dv ;;
  -dvv) app="$2"; out=dvv ;;
  -d) app="$3"; out=dr ;;
  *) echo "unexpected codesign call: $*" >&2; exit 2 ;;
esac
cat "$app/$out" >&2
exit "$(cat "$app/rc")"
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

# Fixtures (see scripts/fixtures/codesign/):
#   adhoc     dist/Sabbel.app from `make build-app` without the certificate
#   signed    a certificate-signed app (Developer ID; a "Sabbel Release" app
#             has the same shape, with `certificate leaf = H"..."`)
#   other     an app signed by another certificate
#   unsigned  an app with no signature
# signed-new is "signed" unpacked elsewhere (the installer's temp dir): same
# signature, different Executable= path.
cp -R "$FIXTURES/signed" "$STUBS/signed-new"
sed 's|^Executable=/Applications/|Executable=/tmp/tmp.XXXX/|' "$FIXTURES/signed/dr" > "$STUBS/signed-new/dr"
app() { [ "$1" = signed-new ] && echo "$STUBS/signed-new" || echo "$FIXTURES/$1"; }

# expect DESCRIPTION reset|keep INSTALLED NEW
expect() {
  if sabbel_tcc_reset_needed "$(app "$3")" "$(app "$4")"; then got=reset; else got=keep; fi
  [ "$got" = "$2" ] && pass "$1" || fail "$1 (got $got, want $2)"
}

expect "the same certificate signature keeps the grants" keep signed signed-new
expect "an ad-hoc installed app is reset" reset adhoc signed-new
expect "an ad-hoc app replaced by the same ad-hoc build is still reset" reset adhoc adhoc
expect "an unsigned installed app is reset" reset unsigned signed-new
expect "a different certificate is reset" reset signed other
expect "a signed app replaced by an ad-hoc build is reset" reset signed adhoc
expect "an unreadable new app is reset" reset signed unsigned

# The release workflow's ad-hoc refusal must read -dvv: real -dv output has no
# Authority= lines at all.
grep -q '^Authority=' "$FIXTURES/signed/dv" \
  && fail "-dv capture unexpectedly has Authority= lines" \
  || pass "-dv prints no Authority= line"
grep -q '^Authority=Developer ID Application: ' "$FIXTURES/signed/dvv" \
  && pass "-dvv prints the leaf certificate as an Authority= line" \
  || fail "-dvv prints the leaf certificate as an Authority= line"
grep -q 'codesign -dvv dist/Sabbel.app 2>&1 | grep -q "Authority=Sabbel Release"' "$ROOT/.github/workflows/release.yml" \
  && pass "release.yml reads the signing authority with -dvv" \
  || fail "release.yml reads the signing authority with -dvv"

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
