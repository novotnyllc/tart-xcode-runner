#!/bin/zsh
set -eu

ROOT=${0:A:h:h}
RUNNER="$ROOT/skills/tart-xcode-runner/references/tart-runner"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tart-runner-safety.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/zdot"
export ZDOTDIR="$TMP/zdot"

fail() {
  print -u2 -- "FAIL: $*"
  exit 1
}

make_fake_tart() {
  local bin=$1 log=$2
  mkdir -p "$bin"
  cat >"$bin/tart" <<'EOF'
#!/bin/zsh
set -eu
print -r -- "$*" >>"$FAKE_TART_LOG"
case ${1:-} in
  --version) print 'test-tart 1.0' ;;
  list) print 'base' ;;
  *) exit 70 ;;
esac
EOF
  chmod +x "$bin/tart"
  : >"$log"
}

run_failing() {
  local output=$1
  shift
  set +e
  "$@" >"$output" 2>&1
  local exit_code=$?
  set -e
  (( exit_code != 0 )) || fail "command unexpectedly succeeded: $*"
}

test_repo_budget_refuses_before_tart_boot() {
  local case_root="$TMP/repo-budget" repo="$TMP/repo-budget/repo"
  local data="$case_root/data" bin="$case_root/bin" log="$case_root/tart.log"
  local output="$case_root/output.log"
  mkdir -p "$repo"
  print one >"$repo/one.swift"
  print two >"$repo/two.swift"
  make_fake_tart "$bin" "$log"

  run_failing "$output" env \
    PATH="$bin:$PATH" FAKE_TART_LOG="$log" \
    TART_XCUI_DATA_HOME="$data" TART_XCUI_BASE_VM=base \
    TART_XCUI_MAX_REPO_FILES=1 \
    "$RUNNER" run --repo "$repo" -- /usr/bin/true

  grep -Fq 'repository payload exceeds the safe file limit' "$output" ||
    fail "unsafe repository payload was not diagnosed"
  [[ ! -s $log ]] || fail "Tart was invoked before repository preflight refused"
}

test_generated_derived_data_is_outside_repo_budget() {
  local case_root="$TMP/derived-data" repo="$TMP/derived-data/repo"
  local data="$case_root/data" bin="$case_root/bin" log="$case_root/tart.log"
  local output="$case_root/output.log"
  mkdir -p "$repo/work/DerivedData-VoiceBroker"
  print source >"$repo/App.swift"
  for index in {1..5}; do
    print generated >"$repo/work/DerivedData-VoiceBroker/$index.o"
  done
  make_fake_tart "$bin" "$log"

  run_failing "$output" env \
    PATH="$bin:$PATH" FAKE_TART_LOG="$log" \
    TART_XCUI_DATA_HOME="$data" TART_XCUI_BASE_VM=base \
    TART_XCUI_MAX_REPO_FILES=1 \
    "$RUNNER" run --repo "$repo" -- /usr/bin/true

  grep -Fq 'cloning golden image' "$output" ||
    fail "DerivedData-prefixed cache incorrectly consumed the repo budget"
  grep -Fq 'clone base' "$log" || fail "safe payload never reached the clone boundary"
  local helper
  for helper in run-command.sh run-xcode.sh; do
    grep -Fq -- "--exclude 'DerivedData*'" \
      "$ROOT/skills/tart-xcode-runner/references/$helper" ||
      fail "$helper does not exclude DerivedData-prefixed caches"
  done
}

test_interrupted_run_after_host_panic_quarantines_future_runs() {
  local case_root="$TMP/host-panic" repo="$TMP/host-panic/repo"
  local data="$case_root/data" bin="$case_root/bin" log="$case_root/tart.log"
  local diagnostics="$case_root/DiagnosticReports" output="$case_root/output.log"
  mkdir -p "$repo" "$data/.state/runs" "$diagnostics/Retired"
  print source >"$repo/App.swift"
  print 999999 >"$data/.state/runs/20260811T234802Z-12193.pid"
  touch -t 202608111648 "$data/.state/runs/20260811T234802Z-12193.pid"
  print 'panic(cpu 1): initproc exited' >"$diagnostics/Retired/host.panic"
  touch -t 202608111653 "$diagnostics/Retired/host.panic"
  print 'diagnostic report bookkeeping' >"$diagnostics/.contents.panic"
  touch -t 202608111654 "$diagnostics/.contents.panic"
  make_fake_tart "$bin" "$log"

  run_failing "$output" env \
    PATH="$bin:$PATH" FAKE_TART_LOG="$log" \
    TART_XCUI_DATA_HOME="$data" TART_XCUI_BASE_VM=base \
    TART_XCUI_DIAGNOSTIC_REPORTS="$diagnostics" \
    "$RUNNER" run --repo "$repo" -- /usr/bin/true

  grep -Fq 'host crash quarantine' "$output" ||
    fail "host crash did not trip the quarantine"
  [[ -f "$data/.state/host-crash-quarantine" ]] ||
    fail "host crash quarantine was not persisted"
  grep -Fq 'panic=host.panic' "$data/.state/host-crash-quarantine" ||
    fail "quarantine selected hidden bookkeeping instead of the real panic"
  [[ ! -s $log ]] || fail "Tart was invoked after interrupted host crash evidence"

  rm -f "$data/.state/runs/20260811T234802Z-12193.pid"
  : >"$log"
  run_failing "$output" env \
    PATH="$bin:$PATH" FAKE_TART_LOG="$log" \
    TART_XCUI_DATA_HOME="$data" TART_XCUI_BASE_VM=base \
    TART_XCUI_DIAGNOSTIC_REPORTS="$diagnostics" \
    "$RUNNER" run --repo "$repo" -- /usr/bin/true
  grep -Fq 'host crash quarantine' "$output" ||
    fail "persisted host quarantine did not refuse the next run"
  [[ ! -s $log ]] || fail "Tart was invoked while host quarantine persisted"

  run_failing "$output" env \
    PATH="$bin:$PATH" FAKE_TART_LOG="$log" \
    TART_XCUI_DATA_HOME="$data" TART_XCUI_BASE_VM=base \
    "$RUNNER" reset
  grep -Fq -- 'reset --acknowledge-host-crash' "$output" ||
    fail "ordinary reset did not require explicit host-crash acknowledgment"

  env PATH="$bin:$PATH" FAKE_TART_LOG="$log" \
    TART_XCUI_DATA_HOME="$data" TART_XCUI_BASE_VM=base \
    "$RUNNER" reset --acknowledge-host-crash >"$output" 2>&1 ||
    fail "explicit host-crash recovery failed"
  [[ ! -e "$data/.state/host-crash-quarantine" ]] ||
    fail "explicit recovery did not clear host quarantine"
}

test_run_and_exec_share_private_control_socket_directory() {
  local case_root="$TMP/private-control-socket"
  local repo="$case_root/repo" data="$case_root/data" bin="$case_root/bin"
  local log="$case_root/tart.log" output="$case_root/output.log"
  local caller="$case_root/caller"
  mkdir -p "$repo" "$bin" "$caller"
  print source >"$repo/App.swift"
  cat >"$bin/tart" <<'EOF'
#!/bin/zsh
set -eu
print -r -- "$PWD|$*" >>"$FAKE_TART_LOG"
case ${1:-} in
  --version) print 'test-tart 1.0' ;;
  list) print 'base' ;;
  clone) ;;
  run)
    : >control.sock
    sleep 3
    rm -f control.sock
    ;;
  exec)
    [[ -e control.sock ]] || exit 71
    ;;
  stop|delete) ;;
  *) exit 70 ;;
esac
EOF
  chmod +x "$bin/tart"
  : >"$log"

  (
    cd "$caller"
    env PATH="$bin:$PATH" FAKE_TART_LOG="$log" \
      TART_XCUI_DATA_HOME="$data" TART_XCUI_RESULTS="$data/results" \
      TART_XCUI_BASE_VM=base TART_XCUI_RUN_TIMEOUT=30 \
      "$RUNNER" run --repo "$repo" -- /usr/bin/true >"$output" 2>&1
  ) || fail "private control-socket run failed"

  [[ ! -e "$caller/control.sock" ]] || fail "Tart control socket polluted caller directory"
  [[ ! -e "$repo/control.sock" ]] || fail "Tart control socket polluted repository"
  local run_cwd exec_cwd
  run_cwd=$(sed -n '/|run /{s/|.*//;p;q;}' "$log")
  exec_cwd=$(sed -n '/|exec /{s/|.*//;p;q;}' "$log")
  [[ -n $run_cwd && $run_cwd == "$exec_cwd" ]] ||
    fail "Tart run and exec did not share one control-socket directory"
  local normalized_data=${data:A}
  local normalized_run_cwd=${run_cwd:A}
  [[ $normalized_run_cwd == "$normalized_data/.state/boots"/* ]] ||
    fail "Tart control socket directory was not runner-owned"
  [[ ! -e $run_cwd ]] || fail "runner-owned control socket directory was not cleaned"
}

test_repo_budget_refuses_before_tart_boot
test_generated_derived_data_is_outside_repo_budget
test_interrupted_run_after_host_panic_quarantines_future_runs
test_run_and_exec_share_private_control_socket_directory
print 'tart runner safety tests passed'
