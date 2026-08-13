#!/bin/zsh
set -eu
[[ ${TART_XCUI_TRACE:-0} == 1 ]] && set -x

SCRIPT=${0:A}
REFERENCES=${SCRIPT:h}
ROOT=${REFERENCES:h:h:h}
RUNNER="$REFERENCES/tart-runner"
if [[ -d "$ROOT/.git" ]]; then
  DEFAULT_DATA_HOME=$ROOT
else
  DEFAULT_DATA_HOME="$HOME/Library/Application Support/Tart Xcode Runner"
fi
DATA_HOME=${TART_XCUI_DATA_HOME:-$DEFAULT_DATA_HOME}
export TART_HOME=${TART_XCUI_TART_HOME:-"$DATA_HOME/.tart"}
STATE="$DATA_HOME/.state"
SHARE="$DATA_HOME/vm-share"
CACHE="$SHARE/cache"
IMAGE_BOOT_DIR="$STATE/boots/image-$$"
BASE_VM=${TART_XCUI_BASE_VM:-tart-xcui-base}
PACKED_VM=${TART_XCUI_PACKED_VM:-${BASE_VM}-packed}
DEFAULT_CONFIG=${TART_XCUI_IMAGE_CONFIG:-"$ROOT/config/image-26.5.json"}
PACKER_TART_COMMIT=c10d61142fdce6ca40c139a6575ce898e867b0f1
READY_TIMEOUT=${TART_XCUI_READY_TIMEOUT:-600}
UPGRADE_TIMEOUT=${TART_XCUI_UPGRADE_TIMEOUT:-7200}
PACKER_TIMEOUT=${TART_XCUI_PACKER_TIMEOUT:-3600}
UPGRADE_RUN_PID=

mkdir -p "$STATE" "$STATE/boots"
[[ $IMAGE_BOOT_DIR == "$STATE/boots/"* ]] || {
  print -u2 -- "error: refusing unsafe image boot directory: $IMAGE_BOOT_DIR"
  exit 1
}
rm -rf -- "$IMAGE_BOOT_DIR"
mkdir -p "$IMAGE_BOOT_DIR"

# Tart 2.34 resolves its control socket relative to the caller's working
# directory. Keep every image operation in one private, per-process directory
# so validation cannot collide with a stale socket or pollute the repository.
tart() {
  (cd "$IMAGE_BOOT_DIR" && command tart "$@")
}

cleanup_image_boot_dir() {
  rm -rf -- "$IMAGE_BOOT_DIR"
}

usage() {
  cat <<'EOF'
Usage:
  prepare-image.zsh rebuild [CONFIG_JSON]
  prepare-image.zsh download OCI_IMAGE [CONFIG_JSON]
  prepare-image.zsh packer --config CONFIG_JSON
  prepare-image.zsh packer --ipsw PATH_OR_URL --xcode-app PATH \
    --macos-version VERSION --macos-build BUILD \
    --xcode-version VERSION --xcode-build BUILD [--platform PLATFORM]...
  prepare-image.zsh add-platform PLATFORM...
  prepare-image.zsh add-component MetalToolchain
EOF
}

die() {
  print -u2 -- "error: $*"
  exit 1
}

zmodload zsh/system || die "zsh/system is required for image locking"
integer IMAGE_LOCK_FD
: >>"$STATE/image.lock"
zsystem flock -t 0 -f IMAGE_LOCK_FD "$STATE/image.lock" ||
  die "another image operation is already running"

# Booting the golden base (for validation) must not race a test run cloning
# it: hold the runner lock and drain active runs first, then release so the
# runner's own commands can take it again.
RUNNER_LOCK="$STATE/runner.lock"
integer RUNNER_LOCK_FD
runner_quiesce() {
  local deadline=$((SECONDS + ${TART_XCUI_RUNS_WAIT:-1800})) f pid active
  : >>"$RUNNER_LOCK"
  zsystem flock -t 600 -f RUNNER_LOCK_FD "$RUNNER_LOCK" ||
    die "the runner lock is busy; retry shortly"
  while true; do
    active=
    for f in "$STATE/runs"/*.pid(N); do
      pid=$(<"$f")
      if kill -0 "$pid" 2>/dev/null; then
        active=$pid
      else
        rm -f "$f"
      fi
    done
    [[ -n $active ]] || return 0
    (( SECONDS < deadline )) || die "a run (pid $active) is active; retry later"
    sleep 15
  done
}
runner_release() {
  zsystem flock -u "$RUNNER_LOCK_FD" 2>/dev/null || true
}

ensure_coordinate_plugin() {
  local patch_sha=$(/usr/bin/shasum -a 256 \
    "$REFERENCES/packer-plugin-tart-coordinate-click.patch" |
    /usr/bin/awk '{print substr($1, 1, 12)}')
  local source="$ROOT/.packer.d/src/packer-plugin-tart-$PACKER_TART_COMMIT-$patch_sha"
  local cached="$source/packer-plugin-tart"
  local installed="$ROOT/.packer.d/plugins/github.com/cirruslabs/tart/packer-plugin-tart_v1.21.0_x5.0_darwin_arm64"
  local checksum="${installed}_SHA256SUM"
  if [[ ! -x $cached ]]; then
    command -v go >/dev/null ||
      die "Go is required once to build the pinned unattended-setup Packer plugin"
    command -v git >/dev/null || die "Git is required to build the Packer plugin"

    if [[ ! -e $source ]]; then
      git clone https://github.com/cirruslabs/packer-plugin-tart.git "$source"
      git -C "$source" checkout "$PACKER_TART_COMMIT"
    fi
    if git -C "$source" apply --check \
        "$REFERENCES/packer-plugin-tart-coordinate-click.patch"; then
      git -C "$source" apply \
        "$REFERENCES/packer-plugin-tart-coordinate-click.patch"
    elif ! git -C "$source" apply --reverse --check \
        "$REFERENCES/packer-plugin-tart-coordinate-click.patch"; then
      die "the pinned Tart Packer patch does not apply cleanly"
    fi
    (
      cd "$source"
      go build \
        -ldflags="-X packer-plugin-tart/version.Version=1.21.0" \
        -o "$cached"
    )
  fi
  [[ -d ${installed:h} ]] || die "packer init did not create the Tart plugin directory"
  local staged="${installed}.new.$$"
  /bin/cp "$cached" "$staged"
  /bin/mv -f "$staged" "$installed"
  /usr/bin/codesign --verify "$installed"
  /usr/bin/shasum -a 256 "$installed" | /usr/bin/awk '{printf "%s", $1}' >"$checksum"
}

download_image() {
  [[ $# -ge 1 && $# -le 2 ]] || die "download requires OCI image and optional config"
  local image=$1 config=${2:-$DEFAULT_CONFIG}
  config=${config:A}
  stop_vm "$PACKED_VM"
  delete_vm "$PACKED_VM"
  tart clone "$image" "$PACKED_VM"
  validate_exact_vm "$PACKED_VM" "$config" ||
    die "$PACKED_VM failed exact image validation"
  "$RUNNER" prepare --replace "$PACKED_VM"
  delete_vm "$PACKED_VM"
}

vm_exists() {
  tart list --source local -q 2>/dev/null | /usr/bin/grep -Fqx -- "$1"
}

stop_vm() {
  vm_exists "$1" || return 0
  tart stop "$1" --timeout 30 >/dev/null 2>&1 || true
}

delete_vm() {
  vm_exists "$1" || return 0
  tart delete "$1"
}

wait_for_agent() {
  local vm=$1 run_pid=${2:-} deadline=$((SECONDS + READY_TIMEOUT))
  until tart exec "$vm" /usr/bin/true >/dev/null 2>&1; do
    [[ -z $run_pid ]] || kill -0 "$run_pid" 2>/dev/null || return 1
    (( SECONDS < deadline )) || return 1
    sleep 5
  done
}

start_upgrade_vm() {
  local vm=$1 attempt
  mkdir -p "$SHARE/references"
  /bin/cp "$REFERENCES/upgrade-macos.sh" \
    "$REFERENCES/provision-image.sh" \
    "$REFERENCES/automation-mode.expect" \
    "$REFERENCES/tart-guest-agent.plist" \
    "$REFERENCES/tart-guest-daemon.plist" \
    "$SHARE/references/"
  for attempt in 1 2 3 4 5; do
    tart run --no-graphics \
      --dir="${SHARE}:ro" \
      "$vm" >"$STATE/upgrade.log" 2>&1 &
    UPGRADE_RUN_PID=$!
    if wait_for_agent "$vm" "$UPGRADE_RUN_PID"; then
      return 0
    fi
    wait "$UPGRADE_RUN_PID" >/dev/null 2>&1 || true
    stop_vm "$vm"
    sleep 10
  done
  return 1
}

prime_vm() {
  local vm=$1 run_pid
  tart run --no-graphics "$vm" >"$STATE/prime.log" 2>&1 &
  run_pid=$!
  wait_for_agent "$vm" "$run_pid" ||
    die "candidate failed its initial boot; see $STATE/prime.log"
  stop_vm "$vm"
  wait "$run_pid" >/dev/null 2>&1 || true
  sleep 5
}

wait_for_build() {
  local vm=$1 expected=$2 run_pid=$3 deadline=$((SECONDS + UPGRADE_TIMEOUT))
  local actual
  while (( SECONDS < deadline )); do
    actual=$(tart exec "$vm" /usr/bin/sw_vers -buildVersion 2>/dev/null || true)
    [[ $actual == $expected ]] && return 0
    sleep 15
  done
  die "macOS upgrade did not reach build $expected within ${UPGRADE_TIMEOUT}s"
}

validate_exact_vm() {
  local vm=$1 config=$2 run_pid failed=0
  local macos_version macos_build xcode_version xcode_build
  macos_version=$(json_value "$config" macOSVersion 2>/dev/null || true)
  macos_build=$(json_value "$config" macOSBuild 2>/dev/null || true)
  xcode_version=$(json_value "$config" xcodeVersion 2>/dev/null || true)
  xcode_build=$(json_value "$config" xcodeBuild 2>/dev/null || true)
  stop_vm "$vm"
  tart run --no-graphics "$vm" >"$STATE/validate-image.log" 2>&1 &
  run_pid=$!
  wait_for_agent "$vm" "$run_pid" ||
    die "$vm failed to start; see $STATE/validate-image.log"
  # Version keys are optional: a config pins only what it declares.
  tart exec "$vm" /bin/zsh -lc "
    set -e
    [[ -z '$macos_version' ]] || test \"\$(/usr/bin/sw_vers -productVersion)\" = '$macos_version'
    [[ -z '$macos_build' ]] || test \"\$(/usr/bin/sw_vers -buildVersion)\" = '$macos_build'
    [[ -z '$xcode_version' ]] || test \"\$(/usr/bin/xcodebuild -version | /usr/bin/awk '/^Xcode/{print \$2}')\" = '$xcode_version'
    [[ -z '$xcode_build' ]] || test \"\$(/usr/bin/xcodebuild -version | /usr/bin/awk '/Build version/{print \$3}')\" = '$xcode_build'
    /usr/bin/xcodebuild -checkFirstLaunchStatus
    /usr/bin/xcrun -f clang >/dev/null
    /usr/bin/xcrun -f metal >/dev/null
    login_user=\$(/usr/bin/defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser)
    test -n \"\$login_user\"
    test \"\$login_user\" != root
    test \"\$(/usr/bin/defaults -currentHost read com.apple.screensaver idleTime)\" = 0
  " || failed=1
  local value
  for value in "${(@f)$(json_array "$config" sdks)}"; do
    [[ -n $value ]] || continue
    tart exec "$vm" /bin/zsh -lc \
      "/usr/bin/xcodebuild -showsdks | /usr/bin/grep -Fq -- '-sdk $value'" ||
      failed=1
  done
  for value in "${(@f)$(json_array "$config" platforms)}"; do
    [[ -n $value ]] || continue
    tart exec "$vm" /bin/zsh -lc \
      "/usr/bin/xcrun simctl list runtimes available | /usr/bin/grep -Fq '$value'" ||
      failed=1
  done
  stop_vm "$vm"
  wait "$run_pid" >/dev/null 2>&1 || true
  return "$failed"
}

# A promoted image supersedes older pinned downloads of the same kind; they
# are keyed by build and re-downloadable, so reclaim the space eagerly.
prune_stale_downloads() {
  local keep_installer=$1 keep_archive=$2 f
  if [[ -n $keep_installer ]]; then
    for f in "$CACHE"/InstallAssistant-*.pkg(N); do
      [[ $f == $keep_installer ]] || {
        rm -f "$f"
        print "pruned superseded installer: ${f:t}"
      }
    done
  fi
  for f in "$CACHE"/*.zip(N); do
    [[ $f == $keep_archive ]] || {
      rm -f "$f"
      print "pruned superseded Xcode archive: ${f:t}"
    }
  done
}

json_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1"
}

json_array() {
  local file=$1 key=$2 index=0 value
  while value=$(/usr/bin/plutil -extract "$key.$index" raw -o - "$file" 2>/dev/null); do
    print -r -- "$value"
    (( ++index ))
  done
}

rebuild_image() {
  local config=${1:-$DEFAULT_CONFIG}
  [[ $# -le 1 ]] || die "rebuild accepts at most one config path"
  config=${config:A}
  [[ -f $config ]] || die "image config does not exist: $config"
  /usr/bin/plutil -convert json -o - "$config" >/dev/null
  mkdir -p "$STATE" "$CACHE" "$TART_HOME"

  # Runtime validation is the authority: if the current golden image already
  # satisfies the config, a rebuild is a ~2 minute no-op instead of a full
  # build cycle.
  local strategy
  if vm_exists "$BASE_VM"; then
    runner_quiesce
    if validate_exact_vm "$BASE_VM" "$config"; then
      runner_release
      print "Golden image already matches $config"
      return 0
    fi
    runner_release
    print "Golden image does not satisfy $config; rebuilding"
  fi
  strategy=$(json_value "$config" buildStrategy 2>/dev/null || print upgrade)
  case $strategy in
    packer) packer_image --config "$config" ;;
    upgrade) upgrade_image "$config" ;;
    download) download_image "$(json_value "$config" seedImage)" "$config" ;;
    *) die "unsupported buildStrategy: $strategy" ;;
  esac
}

upgrade_image() {
  local config=$1 source run_pid value
  local macos_build installer_url installer_sha installer_file
  local xcode_app xcode_version xcode_build archive
  macos_build=$(json_value "$config" macOSBuild)
  installer_url=$(json_value "$config" installAssistant)
  installer_sha=$(json_value "$config" installAssistantSHA1)
  installer_file="$CACHE/InstallAssistant-$macos_build.pkg"
  xcode_app=$(json_value "$config" xcodeApp)
  xcode_version=$(json_value "$config" xcodeVersion)
  xcode_build=$(json_value "$config" xcodeBuild)
  archive="$CACHE/${xcode_app:t}-${xcode_build}.zip"

  [[ -d $xcode_app ]] || die "Xcode app does not exist: $xcode_app"
  if [[ ! -f $installer_file ]] ||
      [[ $(/usr/bin/shasum "$installer_file" | /usr/bin/awk '{print $1}') != $installer_sha ]]; then
    print "Downloading pinned macOS installer..."
    /usr/bin/curl -fL -C - "$installer_url" -o "$installer_file"
  fi
  print "$installer_sha  $installer_file" | /usr/bin/shasum -c -
  if [[ -f $archive ]] && ! /usr/bin/zipinfo -t "$archive" >/dev/null 2>&1; then
    /bin/mv "$archive" "${archive}.invalid"
  fi
  if [[ ! -f $archive ]]; then
    print "Archiving $xcode_app..."
    [[ ! -e ${archive}.partial ]] ||
      /bin/mv "${archive}.partial" "${archive}.partial.invalid"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent \
      "$xcode_app" "${archive}.partial"
    /bin/mv "${archive}.partial" "$archive"
  fi

  source=$(json_value "$config" seedImage)
  vm_exists "$BASE_VM" && source=$BASE_VM
  stop_vm "$PACKED_VM"
  delete_vm "$PACKED_VM"
  print "Cloning update candidate from $source"
  tart clone "$source" "$PACKED_VM"
  local needs_prime=1
  [[ $source != $BASE_VM ]] || needs_prime=0
  tart set "$PACKED_VM" \
    --cpu "$(json_value "$config" cpu)" \
    --memory "$(( $(json_value "$config" memoryGB) * 1024 ))" \
    --disk-size "$(json_value "$config" diskGB)"
  sleep 10
  trap 'stop_vm "$PACKED_VM"' EXIT
  trap 'stop_vm "$PACKED_VM"; exit 130' INT TERM HUP
  # A clone of the existing base is already primed; only fresh OCI seeds
  # need the first-boot migration pass.
  (( ! needs_prime )) || prime_vm "$PACKED_VM"
  start_upgrade_vm "$PACKED_VM" ||
    die "candidate failed to start; see $STATE/upgrade.log"
  run_pid=$UPGRADE_RUN_PID

  if [[ $(tart exec "$PACKED_VM" /usr/bin/sw_vers -buildVersion) != $macos_build ]]; then
    print "Upgrading macOS to $macos_build; the VM will reboot..."
    tart exec "$PACKED_VM" /bin/zsh \
      "/Volumes/My Shared Files/references/upgrade-macos.sh" \
      "${installer_file:t}" "$macos_build" || true
    wait_for_build "$PACKED_VM" "$macos_build" "$run_pid"
  fi

  local -a provision_args=(
    "${archive:t}" "${xcode_app:t}" "$xcode_version" "$xcode_build"
  )
  for value in "${(@f)$(json_array "$config" platforms)}"; do
    provision_args+=(--platform "$value")
  done
  for value in "${(@f)$(json_array "$config" components)}"; do
    provision_args+=(--component "$value")
  done
  for value in "${(@f)$(json_array "$config" sdks)}"; do
    provision_args+=(--sdk "$value")
  done
  print "Provisioning Xcode $xcode_version ($xcode_build)..."
  tart exec "$PACKED_VM" /bin/zsh \
    "/Volumes/My Shared Files/references/provision-image.sh" \
    "${provision_args[@]}"
  stop_vm "$PACKED_VM"
  wait "$run_pid" >/dev/null 2>&1 || true
  trap - EXIT INT TERM HUP

  validate_exact_vm "$PACKED_VM" "$config" ||
    die "$PACKED_VM failed exact image validation"
  "$RUNNER" prepare --replace "$PACKED_VM"
  runner_quiesce
  validate_exact_vm "$BASE_VM" "$config" ||
    die "$BASE_VM failed post-promotion validation"
  runner_release
  delete_vm "$PACKED_VM"
  prune_stale_downloads "$installer_file" "$archive"
  print "Exact image promoted to $BASE_VM"
}

packer_image() {
  local config= ipsw= xcode_app= macos_version= macos_build=
  local xcode_version= xcode_build= cpu=8 memory_gb=16 disk_gb=150
  local build_vm="${PACKED_VM}-$$"
  local -a platforms=() components=() sdks=()
  local -a original=("$@")
  local index
  for (( index = 1; index <= ${#original}; ++index )); do
    if [[ ${original[$index]} == --config ]]; then
      (( index < ${#original} )) || die "--config requires a path"
      config=${original[$(( index + 1 ))]}
      config=${config:A}
      [[ -f $config ]] || die "image config does not exist: $config"
      ipsw=$(json_value "$config" ipsw)
      xcode_app=$(json_value "$config" xcodeApp)
      macos_version=$(json_value "$config" macOSVersion)
      macos_build=$(json_value "$config" macOSBuild)
      xcode_version=$(json_value "$config" xcodeVersion)
      xcode_build=$(json_value "$config" xcodeBuild)
      cpu=$(json_value "$config" cpu)
      memory_gb=$(json_value "$config" memoryGB)
      disk_gb=$(json_value "$config" diskGB)
      platforms=("${(@f)$(json_array "$config" platforms)}")
      components=("${(@f)$(json_array "$config" components)}")
      sdks=("${(@f)$(json_array "$config" sdks)}")
      break
    fi
  done
  while (( $# )); do
    case $1 in
      --config) shift 2 ;;
      --ipsw) ipsw=$2; shift 2 ;;
      --xcode-app) xcode_app=${2:A}; shift 2 ;;
      --macos-version) macos_version=$2; shift 2 ;;
      --macos-build) macos_build=$2; shift 2 ;;
      --xcode-version) xcode_version=$2; shift 2 ;;
      --xcode-build) xcode_build=$2; shift 2 ;;
      --platform) platforms+=("$2"); shift 2 ;;
      --component) components+=("$2"); shift 2 ;;
      --sdk) sdks+=("$2"); shift 2 ;;
      --cpu) cpu=$2; shift 2 ;;
      --memory-gb) memory_gb=$2; shift 2 ;;
      --disk-gb) disk_gb=$2; shift 2 ;;
      *) die "unknown packer argument: $1" ;;
    esac
  done
  [[ -n $ipsw && -n $xcode_app && -n $macos_version && -n $macos_build &&
      -n $xcode_version && -n $xcode_build ]] ||
    die "packer requires IPSW, Xcode app, and exact macOS/Xcode versions and builds"
  [[ -d $xcode_app ]] || die "Xcode app does not exist: $xcode_app"
  (( ${#platforms} > 0 )) || platforms=(iOS)
  (( ${#components} > 0 )) || components=(MetalToolchain)
  (( ${#sdks} > 0 )) || sdks=(iphoneos27.0 iphonesimulator27.0 macosx27.0)
  local value platforms_hcl="[" components_hcl="[" sdks_hcl="["
  for value in "${platforms[@]}"; do
    [[ $value == iOS || $value == tvOS || $value == watchOS || $value == visionOS ]] ||
      die "unsupported platform: $value"
    [[ $platforms_hcl == "[" ]] || platforms_hcl+=","
    platforms_hcl+="\"$value\""
  done
  for value in "${components[@]}"; do
    [[ $value == MetalToolchain ]] || die "unsupported component: $value"
    [[ $components_hcl == "[" ]] || components_hcl+=","
    components_hcl+="\"$value\""
  done
  for value in "${sdks[@]}"; do
    [[ $value != *[^A-Za-z0-9.-]* ]] || die "invalid SDK identifier: $value"
    [[ $sdks_hcl == "[" ]] || sdks_hcl+=","
    sdks_hcl+="\"$value\""
  done
  platforms_hcl+="]"
  components_hcl+="]"
  sdks_hcl+="]"
  command -v packer >/dev/null ||
    die "Packer is missing; run: brew tap hashicorp/tap && brew install hashicorp/tap/packer"
  command -v tart >/dev/null || die "Tart is missing; follow the skill Setup section"

  mkdir -p "$STATE" "$CACHE" "$TART_HOME" "$ROOT/.packer.d/plugins"
  local archive="$CACHE/${xcode_app:t}-${xcode_build}.zip"
  local agent_archive="$CACHE/tart-guest-agent-0.11.0.tar.gz"
  local actual_xcode_version actual_xcode_build
  actual_xcode_version=$(/usr/bin/env DEVELOPER_DIR="$xcode_app/Contents/Developer" \
    /usr/bin/xcodebuild -version | /usr/bin/awk '/^Xcode/{print $2}')
  actual_xcode_build=$(/usr/bin/env DEVELOPER_DIR="$xcode_app/Contents/Developer" \
    /usr/bin/xcodebuild -version | /usr/bin/awk '/Build version/{print $3}')
  [[ $actual_xcode_version == $xcode_version ]] ||
    die "Xcode version is $actual_xcode_version, expected $xcode_version"
  [[ $actual_xcode_build == $xcode_build ]] ||
    die "Xcode build is $actual_xcode_build, expected $xcode_build"
  if [[ ! -f $archive ]]; then
    print "Archiving $xcode_app..."
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$xcode_app" "$archive"
  fi
  if [[ ! -f $agent_archive ]]; then
    /usr/bin/curl -fL \
      https://github.com/openai/tart-guest-agent/releases/download/v0.11.0/tart-guest-agent-darwin-all.tar.gz \
      -o "$agent_archive"
    print "28e1b698c726c5f1d0f8c9d086b3390f6407d47e3f4b83081d9b2a9a2a1f0bc7  $agent_archive" |
      /usr/bin/shasum -a 256 -c -
  fi

  tart stop "$build_vm" --timeout 30 >/dev/null 2>&1 || true
  tart delete "$build_vm" >/dev/null 2>&1 || true
  (
    cd "$REFERENCES"
    PACKER_PLUGIN_PATH="$ROOT/.packer.d/plugins" packer init macos-beta.pkr.hcl
    ensure_coordinate_plugin
    PACKER_PLUGIN_PATH="$ROOT/.packer.d/plugins" packer build -force \
      -var "ipsw=$ipsw" \
      -var "vm_name=$build_vm" \
      -var "xcode_archive=$archive" \
      -var "xcode_app_name=${xcode_app:t}" \
      -var "guest_agent_archive=$agent_archive" \
      -var "macos_version=$macos_version" \
      -var "macos_build=$macos_build" \
      -var "xcode_version=$xcode_version" \
      -var "xcode_build=$xcode_build" \
      -var "platforms=$platforms_hcl" \
      -var "components=$components_hcl" \
      -var "sdks=$sdks_hcl" \
      -var "cpu=$cpu" \
      -var "memory_gb=$memory_gb" \
      -var "disk_gb=$disk_gb" \
      macos-beta.pkr.hcl &
    local packer_pid=$!
    (
      sleep "$PACKER_TIMEOUT"
      print -u2 -- "Packer timed out after ${PACKER_TIMEOUT}s"
      kill -TERM "$packer_pid" >/dev/null 2>&1 || true
    ) &
    local watchdog=$!
    set +e
    wait "$packer_pid"
    local packer_status=$?
    set -e
    kill "$watchdog" >/dev/null 2>&1 || true
    wait "$watchdog" >/dev/null 2>&1 || true
    (( packer_status == 0 )) || exit "$packer_status"
  )

  [[ -z $config ]] ||
    validate_exact_vm "$build_vm" "$config" ||
    die "$build_vm failed exact config validation"
  "$RUNNER" prepare --replace "$build_vm"
  tart delete "$build_vm"
  prune_stale_downloads "" "$archive"
  print "Exact image promoted to $BASE_VM"
}

case ${1:-help} in
  rebuild) shift; rebuild_image "$@" ;;
  download) shift; download_image "$@" ;;
  packer) shift; packer_image "$@" ;;
  add-platform) shift; "$RUNNER" add-platform "$@" ;;
  add-component) shift; "$RUNNER" add-component "$@" ;;
  help|-h|--help) usage ;;
  *) usage; die "unknown command: ${1:-}" ;;
esac
cleanup_image_boot_dir
