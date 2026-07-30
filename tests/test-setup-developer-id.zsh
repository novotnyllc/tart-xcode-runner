#!/bin/zsh
set -eu

ROOT=${0:A:h:h}
HELPER=$ROOT/skills/tart-xcode-runner/references/setup-developer-id.zsh
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-developer-id.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
mkdir "$TEST_DIR/bin"

cat >"$TEST_DIR/bin/security" <<'EOF'
#!/bin/zsh
case $1 in
  show-keychain-info)
    if [[ ${SECURITY_MODE:-ok} == denied ]]; then
      print -u2 -- "stub: Keychain access denied"
      exit 1
    fi
    ;;
  find-identity)
    print -- "     0 valid identities found"
    ;;
  *)
    print -u2 -- "unexpected security command: $*"
    exit 2
    ;;
esac
EOF
chmod +x "$TEST_DIR/bin/security"
export PATH="$TEST_DIR/bin:/usr/bin:/bin"

fail() {
  print -u2 -- "FAIL: $*"
  exit 1
}

if "$HELPER" setup </dev/null >"$TEST_DIR/nonpty.out" 2>&1; then
  fail "setup succeeded without an attached terminal"
fi
grep -q "requires an attached terminal" "$TEST_DIR/nonpty.out" ||
  fail "setup did not explain its terminal requirement"

if SECURITY_MODE=denied "$HELPER" status >"$TEST_DIR/denied.out" 2>&1; then
  fail "status treated denied Keychain access as no identity"
fi
grep -q "do not create another certificate yet" "$TEST_DIR/denied.out" ||
  fail "status did not fail closed on denied Keychain access"

enroll_output=$(SECURITY_MODE=denied /usr/bin/script -q /dev/null "$HELPER" enroll 2>&1 || true)
[[ $enroll_output == *"do not create another certificate yet"* ]] ||
  fail "guided enrollment did not fail closed on denied Keychain access"
[[ $enroll_output != *"Request a Certificate"* ]] ||
  fail "guided enrollment offered a CSR after denied Keychain access"

"$HELPER" status >"$TEST_DIR/empty.out"
grep -q "no valid Developer ID Application identity" "$TEST_DIR/empty.out" ||
  fail "status did not distinguish a genuinely empty Keychain"

probe_output=$(/usr/bin/script -q /dev/null "$HELPER" probe 2>&1 || true)
[[ $probe_output == *"no Developer ID Application identity is installed"* ]] ||
  fail "probe did not handle an empty identity list"

path_output=$(/usr/bin/script -q /dev/null "$HELPER" enroll '~/Downloads/missing.cer' 2>&1 || true)
[[ $path_output == *"$HOME/Downloads/missing.cer"* ]] ||
  fail "a leading ~/ path was not expanded against HOME"
[[ $path_output != *"$ROOT/~/Downloads/missing.cer"* ]] ||
  fail "a leading ~/ path was expanded relative to the repository"

print "setup-developer-id checks passed"
