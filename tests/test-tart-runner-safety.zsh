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
  grep -Fq 'diagnostic=host.panic' "$data/.state/host-crash-quarantine" ||
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

test_interrupted_run_after_login_session_file_exhaustion_quarantines() {
  local case_root="$TMP/login-session-crash"
  local repo="$case_root/repo" data="$case_root/data" bin="$case_root/bin"
  local log="$case_root/tart.log" diagnostics="$case_root/DiagnosticReports"
  local output="$case_root/output.log"
  mkdir -p "$repo" "$data/.state/runs" "$diagnostics"
  print source >"$repo/App.swift"
  print 999999 >"$data/.state/runs/20260813T185416Z-16795.pid"
  touch -t 202608131154 "$data/.state/runs/20260813T185416Z-16795.pid"
  cat >"$diagnostics/loginwindow-2026-08-13-115955.ips" <<'EOF'
{"app_name":"loginwindow","timestamp":"2026-08-13 11:59:55.00 -0700","bug_type":"309"}
{"exception":{"type":"EXC_BAD_ACCESS","subtype":" FS pagein error: 23 Too many open files in system"}}
EOF
  touch -t 202608131159 "$diagnostics/loginwindow-2026-08-13-115955.ips"
  make_fake_tart "$bin" "$log"

  run_failing "$output" env \
    PATH="$bin:$PATH" FAKE_TART_LOG="$log" \
    TART_XCUI_DATA_HOME="$data" TART_XCUI_BASE_VM=base \
    TART_XCUI_DIAGNOSTIC_REPORTS="$diagnostics" \
    "$RUNNER" run --repo "$repo" -- /usr/bin/true

  grep -Fq 'host crash quarantine' "$output" ||
    fail "login-session file exhaustion did not trip the quarantine"
  grep -Fq 'diagnostic=loginwindow-2026-08-13-115955.ips' \
    "$data/.state/host-crash-quarantine" ||
    fail "login-session crash diagnostic was not persisted"
  [[ ! -s $log ]] || fail "Tart was invoked after login-session crash evidence"
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

test_image_validation_uses_private_control_socket_directory() {
  local case_root="$TMP/image-private-control-socket"
  local data="$case_root/data" bin="$case_root/bin" log="$case_root/tart.log"
  local caller="$case_root/caller" output="$case_root/output.log"
  local config="$case_root/image.json"
  mkdir -p "$bin" "$caller"
  cat >"$config" <<'EOF'
{
  "name": "safety-test",
  "buildStrategy": "download",
  "platforms": []
}
EOF
  cat >"$bin/tart" <<'EOF'
#!/bin/zsh
set -eu
print -r -- "$PWD|$*" >>"$FAKE_TART_LOG"
case ${1:-} in
  list) print 'base' ;;
  run)
    : >control.sock
    sleep 10
    rm -f control.sock
    ;;
  exec) [[ -e control.sock ]] || exit 71 ;;
  stop|delete) ;;
  *) exit 70 ;;
esac
EOF
  chmod +x "$bin/tart"
  : >"$log"

  (
    cd "$caller"
    env PATH="$bin:$PATH" FAKE_TART_LOG="$log" \
      TART_XCUI_DATA_HOME="$data" TART_XCUI_BASE_VM=base \
      "$ROOT/skills/tart-xcode-runner/references/prepare-image.zsh" \
      rebuild "$config" >"$output" 2>&1
  ) || fail "private image-validation control-socket run failed: $(<"$output"); $(<"$data/.state/validate-image.log")"

  grep -Fq 'Golden image already matches' "$output" ||
    fail "image validation did not complete"
  [[ ! -e "$caller/control.sock" ]] ||
    fail "image validation polluted the caller directory"
  local run_cwd exec_cwd
  run_cwd=$(sed -n '/|run /{s/|.*//;p;q;}' "$log")
  exec_cwd=$(sed -n '/|exec /{s/|.*//;p;q;}' "$log")
  [[ -n $run_cwd && $run_cwd == "$exec_cwd" ]] ||
    fail "image validation run and exec did not share a private directory"
  local normalized_data=${data:A}
  local normalized_run_cwd=${run_cwd:A}
  [[ $normalized_run_cwd == "$normalized_data/.state/boots"/* ]] ||
    fail "image validation did not use a runner-owned socket directory"
  [[ ! -e $run_cwd ]] ||
    fail "image validation did not clean its private socket directory"
}

test_doctor_recognizes_live_runner_started_in_pipeline() {
  local case_root="$TMP/live-pipeline-runner"
  local repo="$case_root/repo" data="$case_root/data" bin="$case_root/bin"
  local log="$case_root/tart.log" output="$case_root/output.log"
  local doctor_output="$case_root/doctor.log" pipeline_pid marker
  mkdir -p "$repo" "$bin"
  print source >"$repo/App.swift"
  cat >"$bin/tart" <<'EOF'
#!/bin/zsh
set -eu
print -r -- "$*" >>"$FAKE_TART_LOG"
case ${1:-} in
  --version) print 'test-tart 1.0' ;;
  list) print 'base' ;;
  clone) sleep 5 ;;
  *) exit 70 ;;
esac
EOF
  chmod +x "$bin/tart"
  : >"$log"

  (
    env PATH="$bin:$PATH" FAKE_TART_LOG="$log" \
      TART_XCUI_DATA_HOME="$data" TART_XCUI_RESULTS="$data/results" \
      TART_XCUI_BASE_VM=base TART_XCUI_RUN_TIMEOUT=30 \
      "$RUNNER" run --repo "$repo" -- /usr/bin/true 2>&1 | tee "$output"
  ) >/dev/null &
  pipeline_pid=$!

  for _ in {1..50}; do
    marker=($data/.state/runs/*.pid(N))
    (( ${#marker[@]} == 1 )) && break
    sleep 0.1
  done
  (( ${#marker[@]} == 1 )) || fail "pipelined runner did not register its PID receipt"
  local marker_pid marker_command
  marker_pid=$(<"$marker[1]")
  marker_command=$(ps -p "$marker_pid" -o command= 2>/dev/null || true)

  env PATH="$bin:$PATH" FAKE_TART_LOG="$log" \
    TART_XCUI_DATA_HOME="$data" TART_XCUI_BASE_VM=base \
    "$RUNNER" doctor >"$doctor_output" 2>&1 ||
    fail "doctor failed during live pipelined run (pid=$marker_pid command=$marker_command): $(<"$doctor_output")"
  grep -Fq 'active runs: 1' "$doctor_output" ||
    fail "doctor did not recognize the live pipelined runner"
  grep -Fq 'interrupted runs: 0' "$doctor_output" ||
    fail "doctor misclassified the live pipelined runner as interrupted"

  wait "$pipeline_pid" 2>/dev/null || true
}

# Issue #5: a stale control socket from an interrupted run cost the whole
# readiness timeout and looked like a VM boot failure. Blindly rm -rf'ing the
# boot directory would fix that and introduce a worse bug: deleting a socket a
# LIVE tart still owns. Both halves are pinned here.
test_stale_boot_socket_is_quarantined_but_live_one_fails_closed() {
  local case_root="$TMP/boot-socket"
  local state="$case_root/state"
  mkdir -p "$state/boots/stale-run"
  : >"$state/boots/stale-run/control.sock"

  local harness="$case_root/harness.zsh"
  cat >"$harness" <<'EOF'
#!/bin/zsh
set -eu
STATE=$1
die() { print -u2 -- "error: $*"; exit 1; }
eval "$(sed -n '/^fresh_boot_dir() {/,/^}/p' "$RUNNER")"
fresh_boot_dir "$2"
EOF
  chmod +x "$harness"

  # Unowned: quarantined, and the run gets a fresh directory.
  RUNNER="$RUNNER" zsh "$harness" "$state" stale-run >/dev/null 2>&1 ||
    fail 'a stale unowned boot socket must not block the run'
  [[ -d "$state/boots/stale-run" ]] ||
    fail 'a fresh boot directory must exist after quarantining a stale one'
  local -a quarantined
  quarantined=(${(f)"$(find "$state/quarantine/boots" -mindepth 1 -maxdepth 1 2>/dev/null)"})
  (( ${#quarantined} == 1 )) ||
    fail 'the stale boot directory must be quarantined, not deleted'
  [[ -e "${quarantined[1]}/control.sock" ]] ||
    fail 'the stale control socket must move into quarantine'

  # Owned by a live process: must refuse rather than delete it.
  mkdir -p "$state/boots/live-run"
  # A held-open regular file, not a real AF_UNIX socket: the suite's temp root
  # pushes the path past the ~104-byte sun_path limit, so a bind would silently
  # fail and the test would assert against an empty directory. The check under
  # test asks lsof whether ANY entry has a live owner, so this exercises the
  # same path without the length limit.
  python3 -c "
import time
f = open('$state/boots/live-run/control.sock', 'w')
time.sleep(30)" >/dev/null 2>&1 &
  local holder=$!
  # Wait for the bind rather than guessing. A sleep that is too short leaves no
  # socket, the check finds no owner, and the test passes for the wrong reason —
  # it would be asserting against an empty directory.
  local waited=0
  while [[ ! -e "$state/boots/live-run/control.sock" ]] && (( waited < 50 )); do
    sleep 0.1
    (( waited += 1 ))
  done
  [[ -e "$state/boots/live-run/control.sock" ]] ||
    fail 'test setup: the live holder never bound its socket'
  local out="$case_root/live.err"
  if RUNNER="$RUNNER" zsh "$harness" "$state" live-run >/dev/null 2>"$out"; then
    kill $holder 2>/dev/null || true
    fail 'a boot directory owned by a live process must fail closed'
  fi
  kill $holder 2>/dev/null || true
  grep -q 'live pid' "$out" ||
    fail "refusal must name the live owner; got: $(head -1 "$out")"
  [[ -e "$state/boots/live-run/control.sock" ]] ||
    fail 'the live socket must be left alone, not deleted'

  # An lsof that cannot answer at all (not even a failed search) must fail
  # closed. A stub that exits 127 simulates a missing/broken lsof binary; the
  # guard under test must treat that as "cannot determine ownership", never as
  # "unowned".
  mkdir -p "$state/boots/error-run" "$case_root/bin"
  : >"$state/boots/error-run/control.sock"
  printf '#!/bin/sh\nexit 127\n' >"$case_root/bin/lsof"
  chmod +x "$case_root/bin/lsof"
  local out2="$case_root/error.err"
  if PATH="$case_root/bin:$PATH" RUNNER="$RUNNER" zsh "$harness" "$state" error-run >/dev/null 2>"$out2"; then
    fail 'a boot directory lsof cannot inspect must fail closed, not quarantine'
  fi
  grep -qE 'lsof( -V)? exited 127' "$out2" ||
    fail "refusal must name the inspection failure; got: $(head -1 "$out2")"
}

test_repo_budget_refuses_before_tart_boot
test_generated_derived_data_is_outside_repo_budget
test_interrupted_run_after_host_panic_quarantines_future_runs
test_interrupted_run_after_login_session_file_exhaustion_quarantines
test_run_and_exec_share_private_control_socket_directory
test_image_validation_uses_private_control_socket_directory
test_doctor_recognizes_live_runner_started_in_pipeline
test_stale_boot_socket_is_quarantined_but_live_one_fails_closed
print 'tart runner safety tests passed'
