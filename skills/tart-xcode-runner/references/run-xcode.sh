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
  --exclude .build --exclude DerivedData --exclude results \
  "$source_dir/" "$checkout/"

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
