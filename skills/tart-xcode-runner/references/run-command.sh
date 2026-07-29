#!/bin/zsh
set -eu

run_id=$1
has_repo=$2
shift 2

artifact_dir="/Volumes/My Shared Files/artifacts"
work_dir="$HOME/tart-runner/$run_id"
export TART_ARTIFACTS="$artifact_dir"

if (( has_repo )); then
  source_dir="/Volumes/My Shared Files/source"
  export TART_SOURCE="$work_dir/src"
  mkdir -p "$TART_SOURCE"
  /usr/bin/rsync -a --delete \
    --exclude .build --exclude DerivedData --exclude results \
    "$source_dir/" "$TART_SOURCE/"
  cd "$TART_SOURCE"
else
  export TART_SOURCE=
  cd "$HOME"
fi

exec "$@"
