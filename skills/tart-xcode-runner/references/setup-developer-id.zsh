#!/bin/zsh
set -eu
set -o pipefail

SCRIPT=${0:A}
ROOT=${SCRIPT:h:h:h:h}
KEYCHAIN=${TART_DEVELOPER_ID_KEYCHAIN:-"$HOME/Library/Keychains/login.keychain-db"}
APPLE_CERTIFICATES_URL=https://developer.apple.com/account/resources/certificates/add
if [[ -d "$ROOT/.git" ]]; then
  DATA_HOME=$ROOT
else
  DATA_HOME=${TART_XCUI_DATA_HOME:-"$HOME/Library/Application Support/Tart Xcode Runner"}
fi

WORK_DIR=
cleanup() {
  [[ -n ${WORK_DIR:-} && -d $WORK_DIR ]] || return
  rm -f -- "$WORK_DIR"/certificate.pem \
    "$WORK_DIR"/identity.p12 \
    "$WORK_DIR"/roundtrip.p12 \
    "$WORK_DIR"/signing-probe
  rmdir "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

usage() {
  cat <<'EOF'
Usage:
  setup-developer-id.zsh status
  setup-developer-id.zsh setup
  setup-developer-id.zsh enroll [CERTIFICATE.cer]
  setup-developer-id.zsh probe [CERTIFICATE_FINGERPRINT]
  setup-developer-id.zsh store-p12 IDENTITY.p12 --vault VAULT [--account ACCOUNT] [--title TITLE]
  setup-developer-id.zsh restore-p12 ITEM_ID --vault VAULT [--account ACCOUNT]

This helper manages a macOS Developer ID Application identity. Developer ID
does not sign iOS apps and is not needed for ordinary Tart builds or XCUITests.
Use it only for an approved macOS host-signing workflow.

setup, enroll, probe, store-p12, and restore-p12 require an attached terminal.
When an agent runs one of them, keep the whole command in one persistent PTY or
tmux session so macOS and 1Password authorization prompts remain available.
EOF
}

die() {
  print -u2 -- "error: $*"
  exit 1
}

require_tty() {
  [[ -t 0 && -t 1 ]] ||
    die "this command requires an attached terminal; run it directly or in one persistent PTY/tmux session"
}

resolve_path() {
  local path=$1
  case $path in
    '~') path=$HOME ;;
    '~/'*) path="$HOME/${path#\~/}" ;;
    '~'*) die "named-user tilde paths are unsupported; use an absolute path" ;;
  esac
  REPLY=${path:A}
}

ensure_work_dir() {
  [[ -n $WORK_DIR ]] && return
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tart-developer-id.XXXXXX")
  chmod 700 "$WORK_DIR"
}

require_keychain_access() {
  local output
  if ! output=$(security show-keychain-info "$KEYCHAIN" 2>&1); then
    print -u2 -- "$output"
    die "could not inspect the login Keychain; rerun with host authorization and do not create another certificate yet"
  fi
}

keychain_identity_output() {
  require_keychain_access
  local output
  if ! output=$(security find-identity -v -p codesigning "$KEYCHAIN" 2>&1); then
    print -u2 -- "$output"
    die "could not inspect signing identities; rerun with host authorization and do not create another certificate yet"
  fi
  [[ $output == *"valid identities found"* ]] ||
    die "security returned an indeterminate signing-identity result; do not create another certificate"
  print -r -- "$output"
}

developer_identities() {
  keychain_identity_output | sed -n '/"Developer ID Application:/p'
}

developer_id_fingerprints() {
  developer_identities | awk '{print $2}'
}

identity_line_for_fingerprint() {
  local fingerprint=${(U)${1//:/}}
  developer_identities |
    awk -v fingerprint="$fingerprint" '$2 == fingerprint { print; found=1 } END { exit !found }'
}

has_developer_identity() {
  local identities
  identities=$(developer_identities) ||
    die "could not determine whether a Developer ID identity is installed"
  [[ -n $identities ]]
}

one_password_app_installed() {
  [[ -d /Applications/1Password.app || -d "$HOME/Applications/1Password.app" ]]
}

status_command() {
  local identities
  identities=$(developer_identities)
  print "Developer ID: macOS only; not required for ordinary Tart builds or XCUITests"
  if [[ -n $identities ]]; then
    print "Keychain:     identity installed; signing access is not tested by status"
    print -r -- "$identities"
    print "              run 'setup-developer-id.zsh probe' before relying on it"
  else
    print "Keychain:     no valid Developer ID Application identity"
  fi

  if one_password_app_installed; then
    print "1Password:    app installed"
  else
    print "1Password:    app not found"
  fi

  if command -v op >/dev/null; then
    print "1Password CLI: $(op --version)"
  else
    print "1Password CLI: not found (optional; install from https://developer.1password.com/docs/cli/get-started/)"
  fi
}

certificate_metadata() {
  local certificate=$1 subject text fingerprint
  openssl x509 -in "$certificate" -checkend 0 -noout >/dev/null ||
    die "certificate is expired or not yet valid"
  security verify-cert -L -c "$certificate" -p codeSign -q ||
    die "certificate does not pass the local macOS code-signing trust policy"

  subject=$(openssl x509 -in "$certificate" -subject -nameopt 'sep_multiline,sname' -noout) ||
    die "could not read the certificate subject"
  CERT_COMMON_NAME=$(print -r -- "$subject" |
    sed -nE 's/^[[:space:]]*CN[[:space:]]*=[[:space:]]*(.*)$/\1/p' |
    head -n 1)
  CERT_TEAM_ID=$(print -r -- "$subject" |
    sed -nE 's/^[[:space:]]*OU[[:space:]]*=[[:space:]]*([[:alnum:]]+).*$/\1/p' |
    head -n 1)
  [[ $CERT_COMMON_NAME == "Developer ID Application: "* ]] ||
    die "archive certificate is not a Developer ID Application certificate"
  print -r -- "$CERT_TEAM_ID" | grep -Eq '^[[:alnum:]]{10}$' ||
    die "certificate does not contain a valid 10-character Apple Team ID"
  [[ $CERT_COMMON_NAME == *"($CERT_TEAM_ID)" ]] ||
    die "certificate common name and Apple Team ID do not match"

  text=$(openssl x509 -in "$certificate" -text -noout) ||
    die "could not inspect certificate extensions"
  print -r -- "$text" | grep -q '1\.2\.840\.113635\.100\.6\.1\.13' ||
    die "certificate is missing Apple's Developer ID Application extension"

  fingerprint=$(openssl x509 -in "$certificate" -fingerprint -sha1 -noout) ||
    die "could not fingerprint certificate"
  CERT_FINGERPRINT=${(U)${fingerprint#*=}}
  CERT_FINGERPRINT=${CERT_FINGERPRINT//:/}
  [[ -n $CERT_FINGERPRINT ]] || die "certificate fingerprint is empty"
}

prepare_certificate() {
  local source=$1
  ensure_work_dir
  if ! openssl x509 -in "$source" -out "$WORK_DIR/certificate.pem" 2>/dev/null; then
    openssl x509 -inform DER -in "$source" -out "$WORK_DIR/certificate.pem" 2>/dev/null ||
      die "file is not a readable X.509 certificate: $source"
  fi
  certificate_metadata "$WORK_DIR/certificate.pem"
}

validate_p12() {
  local p12=$1 password=$2 info certificate_hash private_hash leaf_count private_key_count
  [[ -n $password ]] || die "the .p12 export password must not be empty"
  ensure_work_dir

  if ! info=$(print -rn -- "$password" |
    openssl pkcs12 -in "$p12" -info -noout -passin stdin 2>&1); then
    die "could not decrypt and parse the .p12; check its export password"
  fi
  [[ ( $info == *"MAC:"* || $info == *"MAC Iteration"* || $info == *"MAC verified OK"* ) &&
    $info == *"Shrouded Keybag:"* ]] ||
    die "the .p12 private key is not password-encrypted"

  print -rn -- "$password" |
    openssl pkcs12 -in "$p12" -clcerts -nokeys -passin stdin \
      -out "$WORK_DIR/certificate.pem" 2>/dev/null ||
    die "the .p12 does not contain a readable leaf certificate"
  leaf_count=$(grep -c '^-----BEGIN CERTIFICATE-----$' "$WORK_DIR/certificate.pem" || true)
  (( leaf_count == 1 )) ||
    die "the .p12 must contain exactly one non-CA certificate"
  private_key_count=$(print -rn -- "$password" |
    openssl pkcs12 -in "$p12" -nocerts -nodes -passin stdin 2>/dev/null |
    grep -Ec '^-----BEGIN .*PRIVATE KEY-----$' || true)
  (( private_key_count == 1 )) ||
    die "the .p12 must contain exactly one private key"

  if ! certificate_hash=$(openssl x509 -in "$WORK_DIR/certificate.pem" -pubkey -noout |
    openssl pkey -pubin -outform DER 2>/dev/null |
    shasum -a 256 | awk '{print $1}'); then
    die "could not derive the certificate public key"
  fi
  if ! private_hash=$(print -rn -- "$password" |
    openssl pkcs12 -in "$p12" -nocerts -nodes -passin stdin 2>/dev/null |
    openssl pkey -pubout -outform DER 2>/dev/null |
    shasum -a 256 | awk '{print $1}'); then
    die "the .p12 does not contain a readable private key"
  fi
  [[ -n $certificate_hash && $certificate_hash == $private_hash ]] ||
    die "the .p12 certificate and private key do not match"

  certificate_metadata "$WORK_DIR/certificate.pem"
}

signing_probe() {
  local fingerprint=${(U)${1//:/}} probe
  identity_line_for_fingerprint "$fingerprint" >/dev/null ||
    die "exact Developer ID identity $fingerprint is not available in the login Keychain"
  ensure_work_dir
  probe="$WORK_DIR/signing-probe"
  cp /usr/bin/true "$probe"
  chmod 700 "$probe"
  print "Proving private-key access; macOS may ask you to approve codesign."
  codesign --force --sign "$fingerprint" --keychain "$KEYCHAIN" --timestamp=none "$probe" ||
    die "codesign could not use Developer ID identity $fingerprint"
  codesign --verify --strict --verbose=2 "$probe" ||
    die "the disposable Developer ID signature did not verify"
  print "Signing probe passed for Developer ID identity $fingerprint."
}

probe_command() {
  local requested=${1:-} output fingerprints
  if [[ -n $requested ]]; then
    signing_probe "$requested"
    return
  fi
  output=$(developer_id_fingerprints) ||
    die "could not enumerate Developer ID fingerprints"
  [[ -n $output ]] ||
    die "no Developer ID Application identity is installed"
  fingerprints=("${(@f)output}")
  if (( ${#fingerprints} == 1 )); then
    signing_probe "$fingerprints[1]"
    return
  fi
  print "Multiple Developer ID identities are installed:"
  developer_identities
  read -r "requested?Fingerprint to probe: "
  [[ -n $requested ]] || die "a fingerprint is required"
  signing_probe "$requested"
}

install_certificate() {
  resolve_path "$1"
  local certificate=$REPLY
  [[ -f $certificate ]] || die "certificate not found: $certificate"
  [[ ${certificate:e:l} == cer ]] || die "expected an Apple .cer file: $certificate"

  prepare_certificate "$certificate"
  print "Importing Developer ID Application certificate for team $CERT_TEAM_ID."
  security import "$WORK_DIR/certificate.pem" -k "$KEYCHAIN"
  identity_line_for_fingerprint "$CERT_FINGERPRINT" >/dev/null ||
    die "the imported certificate did not pair with its private key; use the Mac that created the CSR"
  signing_probe "$CERT_FINGERPRINT"
  print "Developer ID Application identity installed and verified:"
  identity_line_for_fingerprint "$CERT_FINGERPRINT"
}

enroll_command() {
  local certificate=${1:-}
  if [[ -n $certificate ]]; then
    install_certificate "$certificate"
    return
  fi

  if has_developer_identity; then
    print "A Developer ID Application identity is already installed. Run 'probe' to verify signing access."
    developer_identities
    return
  fi

  cat <<'EOF'
This creates a macOS team signing identity on this Mac. First confirm with the
team that a new Developer ID Application certificate should consume one of its
five slots. The Apple Account Holder must issue the certificate.

In Keychain Access:
  1. Choose Certificate Assistant > Request a Certificate From a Certificate Authority.
  2. Enter the Apple Developer account email and a descriptive common name.
  3. Leave CA Email Address empty, choose Saved to disk, and save the CSR.
EOF
  open -a "Keychain Access"
  read -r "?Press Return after the CSR is saved, or Ctrl-C to stop. "

  print "Opening Apple Certificates. Choose Developer ID > Developer ID Application,"
  print "upload the CSR, then download the resulting .cer file."
  open "$APPLE_CERTIFICATES_URL"

  local downloaded_certificate
  read -r "downloaded_certificate?Path to the downloaded .cer file (or leave blank to install it later): "
  if [[ -z $downloaded_certificate ]]; then
    print "Keep the CSR. Later run:"
    print "  ${(q)SCRIPT} enroll /path/to/downloaded.cer"
    return
  fi
  install_certificate "$downloaded_certificate"
}

parse_one_password_options() {
  OP_VAULT=
  OP_ACCOUNT_VALUE=${OP_ACCOUNT:-}
  OP_TITLE=

  while (( $# )); do
    case $1 in
      --vault)
        (( $# >= 2 )) || die "--vault needs a value"
        OP_VAULT=$2
        shift 2
        ;;
      --account)
        (( $# >= 2 )) || die "--account needs a value"
        OP_ACCOUNT_VALUE=$2
        shift 2
        ;;
      --title)
        (( $# >= 2 )) || die "--title needs a value"
        OP_TITLE=$2
        shift 2
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
  [[ -n $OP_VAULT ]] || die "--vault is required"
  [[ -n $OP_ACCOUNT_VALUE ]] || die "--account is required (or set OP_ACCOUNT)"
}

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\b'/\\b}
  value=${value//$'\f'/\\f}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  print -nr -- "$value"
}

password_item_json() {
  local title password notes
  title=$(json_escape "$1")
  password=$(json_escape "$2")
  notes=$(json_escape "$3")
  printf '%s' \
    "{\"title\":\"$title\",\"category\":\"PASSWORD\",\"fields\":[" \
    "{\"id\":\"password\",\"type\":\"CONCEALED\",\"purpose\":\"PASSWORD\",\"label\":\"password\",\"value\":\"$password\"}," \
    "{\"id\":\"notesPlain\",\"type\":\"STRING\",\"purpose\":\"NOTES\",\"label\":\"notesPlain\",\"value\":\"$notes\"}]}"
}

json_value() {
  local key=$1
  plutil -extract "$key" raw -o - -- -
}

one_password_sign_in() {
  command -v op >/dev/null ||
    die "1Password CLI is missing; install it from https://developer.1password.com/docs/cli/get-started/"

  local -a account_args
  local whoami session_token vault
  account_args=(--account "$OP_ACCOUNT_VALUE")
  if ! whoami=$(op whoami "${account_args[@]}" --format json 2>/dev/null); then
    if one_password_app_installed; then
      print "Unlock 1Password and approve CLI access if prompted."
    else
      print "1Password app not found; starting the CLI's manual sign-in flow."
      print "If this account is not configured yet, stop and run 'op account add' first."
    fi
    session_token=$(op signin "${account_args[@]}" --raw) ||
      die "1Password sign-in failed"
    [[ -n $session_token ]] ||
      die "1Password sign-in returned an empty session token"
    export OP_SESSION=$session_token
    unset session_token
    whoami=$(op whoami "${account_args[@]}" --format json) ||
      die "1Password authentication failed"
  fi

  OP_ACCOUNT_ID=$(print -r -- "$whoami" | json_value account_uuid) ||
    die "could not resolve the authenticated 1Password account ID"
  [[ -n $OP_ACCOUNT_ID ]] || die "authenticated 1Password account ID is empty"
  vault=$(op vault get "$OP_VAULT" --account "$OP_ACCOUNT_ID" --format json) ||
    die "could not resolve 1Password vault: $OP_VAULT"
  OP_VAULT_ID=$(print -r -- "$vault" | json_value id) ||
    die "could not resolve the 1Password vault ID"
  [[ -n $OP_VAULT_ID ]] || die "1Password vault ID is empty"
}

read_p12_password() {
  read -rs "P12_PASSWORD?Export password for the encrypted .p12: "
  print
  [[ -n $P12_PASSWORD ]] || die "the .p12 export password must not be empty"
}

store_p12_command() {
  (( $# >= 1 )) || die "store-p12 needs an encrypted .p12 file"
  resolve_path "$1"
  local p12=$REPLY
  shift
  parse_one_password_options "$@"

  [[ -f $p12 ]] || die "file not found: $p12"
  p12=${p12:P}
  [[ ${p12:e:l} == p12 ]] || die "expected an encrypted .p12 file: $p12"
  [[ $p12 != "$ROOT"/* ]] || die "move the .p12 outside the plugin or repository before storing it"
  [[ $p12 != "$DATA_HOME"/* ]] || die "move the .p12 outside Tart's VM, result, and state storage before storing it"

  read_p12_password
  validate_p12 "$p12" "$P12_PASSWORD"
  local source_fingerprint=$CERT_FINGERPRINT
  local source_digest
  source_digest=$(shasum -a 256 "$p12" | awk '{print $1}')
  [[ -n $OP_TITLE ]] ||
    OP_TITLE="Developer ID Application $CERT_TEAM_ID ${CERT_FINGERPRINT[1,12]}"

  cat <<EOF
About to store one recoverable 1Password item:
  file:        $p12
  account:     $OP_ACCOUNT_VALUE
  vault:       $OP_VAULT
  title:       $OP_TITLE
  team:        $CERT_TEAM_ID
  fingerprint: $CERT_FINGERPRINT

The item will contain the encrypted .p12 attachment and its concealed export
password. The restricted vault is therefore the custody boundary.
EOF
  read -q "?Continue? [y/N] " || {
    print
    die "cancelled"
  }
  print

  one_password_sign_in
  local notes created item_id reference downloaded_password downloaded_digest
  notes="macOS Developer ID Application certificate
Team ID: $CERT_TEAM_ID
SHA-1 fingerprint: $CERT_FINGERPRINT
Common name: $CERT_COMMON_NAME"
  created=$(password_item_json "$OP_TITLE" "$P12_PASSWORD" "$notes" |
    op item create \
      --account "$OP_ACCOUNT_ID" \
      --vault "$OP_VAULT_ID" \
      --tags "developer-id,code-signing" \
      --format json \
      - "identity[file]=$p12") ||
    die "1Password did not create the backup item"
  item_id=$(print -r -- "$created" | json_value id) ||
    die "1Password created an item but did not return its ID"
  [[ -n $item_id ]] || die "1Password returned an empty item ID"

  ensure_work_dir
  reference="op://$OP_VAULT_ID/$item_id/identity"
  op read "$reference" \
    --account "$OP_ACCOUNT_ID" \
    --out-file "$WORK_DIR/roundtrip.p12" \
    --file-mode 0600 \
    --force >/dev/null ||
    die "could not download the stored .p12 for verification"
  downloaded_password=$(op read "op://$OP_VAULT_ID/$item_id/password" \
    --account "$OP_ACCOUNT_ID" --no-newline) ||
    die "could not read the stored export password for verification"
  downloaded_digest=$(shasum -a 256 "$WORK_DIR/roundtrip.p12" | awk '{print $1}')
  [[ $source_digest == $downloaded_digest ]] ||
    die "the .p12 downloaded from 1Password does not match the source"
  validate_p12 "$WORK_DIR/roundtrip.p12" "$downloaded_password"
  [[ $CERT_FINGERPRINT == $source_fingerprint ]] ||
    die "the identity downloaded from 1Password does not match the source"
  unset P12_PASSWORD downloaded_password

  print "Stored and round-trip verified in 1Password."
  print "Item ID: $item_id"
  print "After confirming that item in 1Password, securely delete the local .p12."
}

restore_p12_command() {
  (( $# >= 1 )) || die "restore-p12 needs a 1Password item ID"
  local item_id=$1
  shift
  parse_one_password_options "$@"
  print -r -- "$item_id" | grep -Eq '^[a-z0-9]{26}$' ||
    die "restore-p12 requires the unambiguous 1Password item ID printed by store-p12"

  one_password_sign_in
  ensure_work_dir
  local reference password
  reference="op://$OP_VAULT_ID/$item_id/identity"
  op read "$reference" \
    --account "$OP_ACCOUNT_ID" \
    --out-file "$WORK_DIR/identity.p12" \
    --file-mode 0600 \
    --force >/dev/null ||
    die "could not download the identity attachment from 1Password"
  password=$(op read "op://$OP_VAULT_ID/$item_id/password" \
    --account "$OP_ACCOUNT_ID" --no-newline) ||
    die "could not read the identity export password from 1Password"
  validate_p12 "$WORK_DIR/identity.p12" "$password"

  cat <<EOF
Validated Developer ID Application identity:
  team:        $CERT_TEAM_ID
  fingerprint: $CERT_FINGERPRINT

Importing into the login Keychain. macOS will securely request the export
password; copy it from the same 1Password item. The script will not expose the
password in a process argument or clipboard.
EOF
  security import "$WORK_DIR/identity.p12" -k "$KEYCHAIN"
  unset password
  identity_line_for_fingerprint "$CERT_FINGERPRINT" >/dev/null ||
    die "the imported .p12 did not install its exact Developer ID private-key identity"
  signing_probe "$CERT_FINGERPRINT"
  print "Developer ID Application identity restored and verified:"
  identity_line_for_fingerprint "$CERT_FINGERPRINT"
}

offer_one_password_backup() {
  print
  if one_password_app_installed; then
    print "1Password app detected."
  else
    print "1Password app was not detected; the CLI can still use manual sign-in."
    print "Run 'op account add' first if the intended account is not configured."
  fi
  if ! command -v op >/dev/null; then
    print "Install 1Password CLI with: brew install 1password-cli"
    if one_password_app_installed; then
      print "Then enable 1Password > Settings > Developer > Integrate with 1Password CLI."
    else
      print "Then configure the intended account with: op account add"
    fi
    print "Guide: https://developer.1password.com/docs/cli/get-started/"
    print "Then export the identity and run this helper's store-p12 command."
    return
  fi

  read -q "?Back up the identity in 1Password now? [y/N] " || {
    print
    return
  }
  print
  cat <<'EOF'
In Keychain Access > My Certificates, export only the new Developer ID
Application identity as a strongly encrypted .p12 outside this repository.
EOF
  open -a "Keychain Access"
  local p12 vault account
  read -r "p12?Path to the exported .p12: "
  read -r "account?1Password account shorthand, ID, or sign-in address: "
  read -r "vault?Restricted 1Password vault: "
  store_p12_command "$p12" --account "$account" --vault "$vault"
}

setup_command() {
  status_command
  if has_developer_identity; then
    print
    print "Verifying that this process can use the private key."
    probe_command
    offer_one_password_backup
    return
  fi

  print
  read -q "?Create and install a new macOS Developer ID Application identity now? [y/N] " || {
    print
    print "Cancelled; no certificate was created."
    return
  }
  print
  enroll_command
  has_developer_identity || return
  offer_one_password_backup
}

command=${1:-setup}
(( $# == 0 )) || shift
case $command in
  status)
    (( $# == 0 )) || die "status takes no arguments"
    status_command
    ;;
  setup)
    (( $# == 0 )) || die "setup takes no arguments"
    require_tty
    setup_command
    ;;
  enroll)
    (( $# <= 1 )) || die "enroll accepts at most one .cer file"
    require_tty
    enroll_command "$@"
    ;;
  probe)
    (( $# <= 1 )) || die "probe accepts at most one fingerprint"
    require_tty
    probe_command "$@"
    ;;
  store-p12)
    require_tty
    store_p12_command "$@"
    ;;
  restore-p12)
    require_tty
    restore_p12_command "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    die "unknown command: $command"
    ;;
esac
