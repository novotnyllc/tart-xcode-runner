#!/bin/zsh
set -eu

ROOT=${0:A:h:h}
HELPER=$ROOT/skills/tart-xcode-runner/references/setup-developer-id.zsh
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-developer-id.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/state" "$TEST_DIR/fixtures" "$TEST_DIR/helper-tmp"

export TEST_STATE=$TEST_DIR/state
export P12_FIXTURE=$TEST_DIR/fixtures/identity.p12
export TMPDIR=$TEST_DIR/helper-tmp
export TART_DEVELOPER_ID_KEYCHAIN=$TEST_DIR/login.keychain-db
export TART_XCUI_DATA_HOME=$TEST_DIR/data
export TEST_FINGERPRINT=0123456789ABCDEF0123456789ABCDEF01234567
print -n -- "encrypted identity fixture" >"$P12_FIXTURE"
print -n -- "certificate fixture" >"$TEST_DIR/fixtures/identity.cer"
export P12_FIXTURE=${P12_FIXTURE:P}

cat >"$TEST_DIR/bin/security" <<'EOF'
#!/bin/zsh
set -eu
print -r -- "$*" >>"$TEST_STATE/security.log"
case $1 in
  show-keychain-info)
    if [[ ${SECURITY_MODE:-ok} == denied ]]; then
      print -u2 -- "stub: Keychain access denied"
      exit 1
    fi
    ;;
  find-identity)
    if [[ ${SECURITY_MODE:-ok} == identity || -f "$TEST_STATE/identity-installed" ]]; then
      print -- '  1) FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF "Developer ID Application: Other User (ZZZZZZZZZZ)"'
      print -- "  2) $TEST_FINGERPRINT \"Developer ID Application: Test User (ABCDEFGHIJ)\""
      print -- "     2 valid identities found"
    elif [[ ${SECURITY_MODE:-ok} == unrelated ]]; then
      print -- '  1) FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF "Developer ID Application: Other User (ZZZZZZZZZZ)"'
      print -- "     1 valid identities found"
    else
      print -- "     0 valid identities found"
    fi
    ;;
  verify-cert)
    [[ ${CERT_TRUST_MODE:-valid} == valid ]]
    ;;
  import)
    [[ ${SECURITY_IMPORT_WRONG:-0} == 1 ]] ||
      : >"$TEST_STATE/identity-installed"
    ;;
  *)
    print -u2 -- "unexpected security command: $*"
    exit 2
    ;;
esac
EOF

cat >"$TEST_DIR/bin/openssl" <<'EOF'
#!/bin/zsh
set -eu
command=$1
shift
case $command in
  x509)
    if [[ " $* " == *" -checkend "* ]]; then
      exit 0
    elif [[ " $* " == *" -subject "* ]]; then
      print -- "subject="
      print -- "    CN=Developer ID Application: Test User (ABCDEFGHIJ)"
      print -- "    OU=ABCDEFGHIJ"
    elif [[ " $* " == *" -text "* ]]; then
      print -- "1.2.840.113635.100.6.1.13"
    elif [[ " $* " == *" -fingerprint "* ]]; then
      print -- "sha1 Fingerprint=01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67"
    elif [[ " $* " == *" -pubkey "* ]]; then
      print -- "PUBLIC KEY"
    else
      output=
      while (( $# )); do
        if [[ $1 == -out ]]; then
          output=$2
          break
        fi
        shift
      done
      [[ -n $output ]] || exit 2
      print -- "-----BEGIN CERTIFICATE-----" >"$output"
      print -- "fixture" >>"$output"
      print -- "-----END CERTIFICATE-----" >>"$output"
    fi
    ;;
  pkcs12)
    if [[ " $* " == *" -info "* ]]; then
      [[ ${P12_MODE:-encrypted} != bad-password ]] || exit 1
      print -u2 -- "MAC verified OK"
      if [[ ${P12_MODE:-encrypted} == unencrypted ]]; then
        print -u2 -- "Key bag"
      else
        print -u2 -- "Shrouded Keybag: fixture"
      fi
    elif [[ " $* " == *" -clcerts "* ]]; then
      output=
      while (( $# )); do
        if [[ $1 == -out ]]; then
          output=$2
          break
        fi
        shift
      done
      [[ -n $output ]] || exit 2
      print -- "-----BEGIN CERTIFICATE-----" >"$output"
      print -- "fixture" >>"$output"
      print -- "-----END CERTIFICATE-----" >>"$output"
      if [[ ${P12_MODE:-encrypted} == multiple-certificates ]]; then
        print -- "-----BEGIN CERTIFICATE-----" >>"$output"
        print -- "extra" >>"$output"
        print -- "-----END CERTIFICATE-----" >>"$output"
      fi
    elif [[ " $* " == *" -nocerts "* ]]; then
      [[ ${P12_MODE:-encrypted} != no-private-key ]] || exit 0
      print -- "-----BEGIN PRIVATE KEY-----"
      print -- "fixture"
      print -- "-----END PRIVATE KEY-----"
      if [[ ${P12_MODE:-encrypted} == multiple-private-keys ]]; then
        print -- "-----BEGIN PRIVATE KEY-----"
        print -- "extra"
        print -- "-----END PRIVATE KEY-----"
      fi
    else
      exit 2
    fi
    ;;
  pkey)
    cat >/dev/null
    if [[ ${P12_MODE:-encrypted} == mismatched-key && " $* " == *" -pubout "* ]]; then
      print -n -- "PRIVATE-DER"
    else
      print -n -- "MATCHED-DER"
    fi
    ;;
  *)
    print -u2 -- "unexpected openssl command: $command $*"
    exit 2
    ;;
esac
EOF

cat >"$TEST_DIR/bin/codesign" <<'EOF'
#!/bin/zsh
set -eu
print -r -- "$*" >>"$TEST_STATE/codesign.log"
if [[ ${CODESIGN_FAIL:-0} == 1 && " $* " == *" --force "* ]]; then
  exit 1
fi
EOF

cat >"$TEST_DIR/bin/op" <<'EOF'
#!/bin/zsh
set -eu
print -r -- "$*" >>"$TEST_STATE/op.log"
case $1 in
  --version)
    print -- "2.35.0-stub"
    ;;
  whoami)
    [[ ${OP_SESSION:-} == test-session-token ]] || exit 1
    print -- '{"account_uuid":"accountuuid"}'
    ;;
  signin)
    [[ " $* " == *" --raw"* ]] || {
      print -u2 -- "signin did not request raw output"
      exit 2
    }
    print -n -- "test-session-token"
    ;;
  vault)
    [[ $2 == get && " $* " == *" --account accountuuid"* ]] || exit 2
    print -- '{"id":"vaultuuid"}'
    ;;
  item)
    [[ $2 == create && " $* " == *" --account accountuuid"* ]] || exit 2
    [[ "$*" != *testpass* ]] || {
      print -u2 -- "password leaked in item-create arguments"
      exit 2
    }
    payload=$(cat)
    [[ $payload == *'"value":"testpass"'* ]] || {
      print -u2 -- "concealed password missing from stdin JSON"
      exit 2
    }
    [[ " $* " == *"identity[file]=$P12_FIXTURE"* ]] || exit 2
    print -- '{"id":"abcdefghijklmnopqrstuvwxyz"}'
    ;;
  read)
    reference=$2
    shift 2
    [[ " $* " == *" --account accountuuid"* ]] || exit 2
    case $reference in
      */identity)
        output=
        while (( $# )); do
          if [[ $1 == --out-file ]]; then
            output=$2
            break
          fi
          shift
        done
        [[ -n $output ]] || exit 2
        cp "$P12_FIXTURE" "$output"
        [[ ${OP_READ_MODE:-matching} != altered ]] ||
          print -n -- "altered" >>"$output"
        print -r -- "output:$output" >>"$TEST_STATE/op-output.log"
        ;;
      */password)
        print -n -- "testpass"
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  *)
    print -u2 -- "unexpected op command: $*"
    exit 2
    ;;
esac
EOF

chmod +x "$TEST_DIR/bin/security" \
  "$TEST_DIR/bin/openssl" \
  "$TEST_DIR/bin/codesign" \
  "$TEST_DIR/bin/op"
export PATH="$TEST_DIR/bin:/usr/bin:/bin"

fail() {
  print -u2 -- "FAIL: $*"
  exit 1
}

assert_no_helper_temps() {
  local -a leftovers
  leftovers=("$TMPDIR"/tart-developer-id.*(N))
  (( ${#leftovers} == 0 )) ||
    fail "helper left temporary identity material behind: ${leftovers[*]}"
}

reset_state() {
  assert_no_helper_temps
  rm -f "$TEST_STATE/identity-installed" \
    "$TEST_STATE/codesign.log" \
    "$TEST_STATE/op.log" \
    "$TEST_STATE/op-output.log" \
    "$TEST_STATE/security.log"
  unset OP_SESSION
  unset OP_READ_MODE
  export P12_MODE=encrypted
}

expect_store() {
  /usr/bin/expect <<'EOF'
set timeout 10
log_user 1
spawn -noecho $env(HELPER) store-p12 $env(P12_FIXTURE) --account example --vault example
expect "Export password for the encrypted .p12:"
send -- "testpass\r"
expect {
  "Continue?*" {
    send -- "y\r"
    expect eof
  }
  eof {}
}
set result [wait]
exit [lindex $result 3]
EOF
}

assert_p12_rejected() {
  local mode=$1 expected=$2 output
  reset_state
  export P12_MODE=$mode
  output=$(expect_store 2>&1 || true)
  [[ $output == *"$expected"* ]] ||
    fail "$mode .p12 was not rejected with the expected error"
  [[ ! -f "$TEST_STATE/op.log" ]] ||
    fail "1Password was contacted before $mode archive validation"
}

export HELPER

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

reset_state
certificate_output=$(/usr/bin/script -q /dev/null \
  "$HELPER" enroll "$TEST_DIR/fixtures/identity.cer" 2>&1)
[[ $certificate_output == *"identity installed and verified"* ]] ||
  fail "validated certificate did not complete exact-fingerprint installation"
grep -q -- "--sign $TEST_FINGERPRINT" "$TEST_STATE/codesign.log" ||
  fail "certificate installation did not probe the exact fingerprint"
grep -q -- "--verify --strict --verbose=2" "$TEST_STATE/codesign.log" ||
  fail "certificate installation did not strictly verify the disposable signature"
grep -Eq '^import .*/tart-developer-id\..*/certificate\.pem -k ' "$TEST_STATE/security.log" ||
  fail "certificate installation did not import the normalized certificate"

reset_state
trust_output=$(CERT_TRUST_MODE=invalid /usr/bin/script -q /dev/null \
  "$HELPER" enroll "$TEST_DIR/fixtures/identity.cer" 2>&1 || true)
[[ $trust_output == *"does not pass the local macOS code-signing trust policy"* ]] ||
  fail "untrusted certificate was not rejected"
grep -q -- "verify-cert -L" "$TEST_STATE/security.log" ||
  fail "certificate trust policy was not evaluated"
grep -q '^import ' "$TEST_STATE/security.log" &&
  fail "untrusted certificate reached Keychain import"

reset_state
mismatch_output=$(SECURITY_IMPORT_WRONG=1 /usr/bin/script -q /dev/null \
  "$HELPER" enroll "$TEST_DIR/fixtures/identity.cer" 2>&1 || true)
[[ $mismatch_output == *"did not pair with its private key"* ]] ||
  fail "an unrelated identity satisfied certificate import verification"
[[ ! -f "$TEST_STATE/codesign.log" ]] ||
  fail "codesign ran after exact-fingerprint verification failed"

reset_state
probe_failure=$(SECURITY_MODE=identity CODESIGN_FAIL=1 /usr/bin/script -q /dev/null \
  "$HELPER" probe "$TEST_FINGERPRINT" 2>&1 || true)
[[ $probe_failure == *"codesign could not use Developer ID identity"* ]] ||
  fail "codesign failure was not reported"
[[ $probe_failure != *"Signing probe passed"* ]] ||
  fail "codesign failure was reported as success"
assert_no_helper_temps

assert_p12_rejected unencrypted ".p12 private key is not password-encrypted"
assert_p12_rejected bad-password "could not decrypt and parse the .p12"
assert_p12_rejected no-private-key ".p12 must contain exactly one private key"
assert_p12_rejected mismatched-key ".p12 certificate and private key do not match"
assert_p12_rejected multiple-private-keys ".p12 must contain exactly one private key"
assert_p12_rejected multiple-certificates ".p12 must contain exactly one non-CA certificate"

reset_state
export OP_READ_MODE=altered
altered_output=$(expect_store 2>&1 || true)
[[ $altered_output == *"downloaded from 1Password does not match the source"* ]] ||
  fail "altered 1Password attachment passed round-trip verification"
[[ $altered_output != *"Stored and round-trip verified"* ]] ||
  fail "altered 1Password attachment was reported as verified"
assert_no_helper_temps

reset_state
store_output=$(expect_store 2>&1) ||
  fail "valid 1Password backup flow failed: $store_output"
[[ $store_output == *"Stored and round-trip verified in 1Password"* ]] ||
  fail "1Password backup did not report round-trip verification"
[[ $store_output == *"Item ID: abcdefghijklmnopqrstuvwxyz"* ]] ||
  fail "1Password backup did not retain the item ID"
grep -q -- "signin --account example --raw" "$TEST_STATE/op.log" ||
  fail "manual 1Password sign-in did not request a raw session token"
grep -q -- "item create --account accountuuid --vault vaultuuid" "$TEST_STATE/op.log" ||
  fail "1Password item creation did not use resolved account and vault IDs"
store_output_path=$(sed -n 's/^output://p' "$TEST_STATE/op-output.log" | tail -n 1)
[[ -n $store_output_path && ! -e ${store_output_path:h} ]] ||
  fail "1Password round-trip temporary files were not removed"
assert_no_helper_temps

reset_state
restore_output=$(/usr/bin/script -q /dev/null \
  "$HELPER" restore-p12 abcdefghijklmnopqrstuvwxyz --account example --vault example 2>&1)
[[ $restore_output == *"identity restored and verified"* ]] ||
  fail "1Password restore did not verify the exact identity"
grep -q -- "signin --account example --raw" "$TEST_STATE/op.log" ||
  fail "restore did not use raw CLI-only sign-in"
grep -q -- "--sign $TEST_FINGERPRINT" "$TEST_STATE/codesign.log" ||
  fail "restore did not probe the downloaded identity's exact fingerprint"
restore_output_path=$(sed -n 's/^output://p' "$TEST_STATE/op-output.log" | tail -n 1)
[[ -n $restore_output_path && ! -e ${restore_output_path:h} ]] ||
  fail "restore temporary identity material was not removed"
assert_no_helper_temps

grep -q "guided macOS Developer ID signing setup" "$ROOT/.claude-plugin/marketplace.json" ||
  fail "Claude marketplace metadata is stale"
grep -q "desktop app is optional" "$ROOT/skills/tart-xcode-runner/SKILL.md" ||
  fail "skill guidance incorrectly requires the 1Password desktop app"
grep -q "op account add" "$ROOT/skills/tart-xcode-runner/SKILL.md" ||
  fail "skill guidance omits CLI-only account onboarding"
grep -q "give its path to the still-running helper" "$ROOT/README.md" ||
  fail "README bypasses the helper's hardened certificate import"

print "setup-developer-id checks passed"
