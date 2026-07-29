#!/bin/zsh
set -eu

run_id=$1
mode=$2
shift 2

source_dir="/Volumes/My Shared Files/source"
artifact_dir="/Volumes/My Shared Files/artifacts"
work_dir="$HOME/tart-runner/$run_id"
checkout="$work_dir/src"
derived_data="$work_dir/DerivedData"
result_bundle="$work_dir/Result.xcresult"
xcode_args=("$@")

mkdir -p "$checkout" "$derived_data"
/usr/bin/rsync -a --delete \
  --exclude .git --exclude .build --exclude DerivedData --exclude results \
  "$source_dir/" "$checkout/"

# The VM has no signing identities; unless the caller overrides signing
# explicitly, ad-hoc signing (entitlements dropped) is the only recipe that
# can work here. CODE_SIGNING_ALLOWED=NO is NOT equivalent: it hangs UI test
# runners before they connect.
has_signing=0
for arg in "${xcode_args[@]}"; do
  [[ $arg == CODE_SIGN*=* || $arg == DEVELOPMENT_TEAM=* ||
     $arg == PROVISIONING_PROFILE*=* ]] && has_signing=1
done
if (( ! has_signing )); then
  xcode_args+=(
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
    PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_ENTITLEMENTS=
    AD_HOC_CODE_SIGNING_ALLOWED=YES
  )
fi

if [[ $mode == xcui-test ]]; then
  has_destination=0
  has_parallel_setting=0
  for arg in "${xcode_args[@]}"; do
    [[ $arg == -destination || $arg == -destination=* ]] && has_destination=1
    [[ $arg == -parallel-testing-enabled || $arg == -parallel-testing-enabled=* ]] &&
      has_parallel_setting=1
  done
  (( has_parallel_setting )) || xcode_args+=(-parallel-testing-enabled NO)
  if (( ! has_destination )); then
    device_id=$(/usr/bin/xcrun simctl list devices available |
      /usr/bin/sed -nE '/iPhone/{s/.*\(([0-9A-Fa-f-]{36})\).*/\1/p;q;}')
    [[ -n $device_id ]] || {
      print -u2 -- "error: no available iPhone simulator"
      exit 1
    }
    /usr/bin/xcrun simctl boot "$device_id" >/dev/null 2>&1 || true
    /usr/bin/xcrun simctl bootstatus "$device_id" -b
    xcode_args+=(-destination "id=$device_id")
  fi
fi

cd "$checkout"
set +e
NSUnbufferedIO=YES /usr/bin/xcodebuild \
  "${xcode_args[@]}" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle"
exit_code=$?
set -e

if [[ -d $result_bundle ]]; then
  /usr/bin/ditto "$result_bundle" "$artifact_dir/Result.xcresult" ||
    exit_code=$?
fi
print "$exit_code" >"$artifact_dir/guest-exit-status" || exit_code=$?
exit "$exit_code"
