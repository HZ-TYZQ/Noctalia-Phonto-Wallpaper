#!/usr/bin/env bash
# Checks the phonto behaviors phonto_service.luau relies on, against the real
# phonto binary in the running Wayland session. One monitor is enough: the second
# pinned output is a name that does not exist. phonto draws a test pattern on the
# first output at the background layer for a few seconds (normally hidden under
# Noctalia's own wallpaper).
#
# Usage: phonto_contract.sh <tmpdir containing videos/a.mp4 and videos/b.mp4>

set -u
root=$1
a=$root/videos/a.mp4
b=$root/videos/b.mp4
log=$root/phonto.log
pass=0 fail=0 pids=()

check() { # label, then a command that must succeed
  local label=$1
  shift
  if "$@"; then
    echo "PASS $label"
    pass=$((pass + 1))
  else
    echo "FAIL $label"
    fail=$((fail + 1))
  fi
}
start() { # starts phonto with the given arguments; sets $pid
  phonto "$@" >>"$log" 2>&1 &
  pid=$!
  pids+=("$pid")
}
state() { awk '{ sub(/^.*\) /, ""); print $1 }' "/proc/$1/stat" 2>/dev/null; }
alive() { [[ -e /proc/$1 && $(state "$1") != Z ]]; }
dead_soon() {
  for _ in $(seq 50); do
    alive "$1" || return 0
    sleep 0.1
  done
  return 1
}
# Waits until the process has really stopped: a signal that arrives while a
# SIGSTOP is still being delivered is handled as if the process were running.
stopped_soon() {
  for _ in $(seq 50); do
    [[ $(state "$1") == T ]] && return 0
    sleep 0.1
  done
  return 1
}
decoders() { grep -l '^decoder:' /proc/"$1"/task/*/comm 2>/dev/null | wc -l; }
pss_kib() { awk '/^Pss:/ { print $2 }' "/proc/$1/smaps_rollup"; }
cleanup() {
  for p in "${pids[@]}"; do
    kill -CONT "$p" 2>/dev/null
    kill -KILL "$p" 2>/dev/null
  done
}
trap cleanup EXIT

out=$(phonto displays 2>/dev/null | awk 'NR > 1 && NF >= 2 { print $1; exit }')
if [[ -z $out ]]; then
  echo "FAIL phonto lists no display (is a Wayland session running?)"
  exit 1
fi
echo "using display $out"

timeout 15 phonto --display NOPE-1 "$a" >>"$log" 2>&1
rc=$?
check "exits when none of its pinned outputs exist" test "$rc" -ne 0 -a "$rc" -ne 124

start --display "$out" "$a" --display NOPE-1 "$b"
sleep 3
check "one process renders a pinned output while another pinned one is absent" alive "$pid"
check "each pinned video gets its own decoder" test "$(decoders "$pid")" -eq 2
pss_two=$(pss_kib "$pid")
kill "$pid"
check "SIGTERM ends it" dead_soon "$pid"

start "$a"
sleep 3
check "mirror mode runs" alive "$pid"
check "mirror mode uses a single decoder" test "$(decoders "$pid")" -eq 1
pss_one=$(pss_kib "$pid")

kill -STOP "$pid"
check "SIGSTOP pauses it" stopped_soon "$pid"
kill -CONT "$pid"
sleep 1
check "SIGCONT resumes it" test "$(state "$pid")" != T -a -e "/proc/$pid"
kill -STOP "$pid"
stopped_soon "$pid"
kill -TERM "$pid"
sleep 1
check "a stopped phonto ignores SIGTERM until continued (why stopping sends SIGCONT first)" alive "$pid"
kill -CONT "$pid" 2>/dev/null
check "SIGCONT then lets the pending SIGTERM end it" dead_soon "$pid"

if [[ -n $pss_one && -n $pss_two ]]; then
  echo "INFO memory (PSS, system RAM only): one video $((pss_one / 1024)) MiB, two pinned videos in one process $((pss_two / 1024)) MiB"
  echo "INFO so another output costs ~$(((pss_two - pss_one) / 1024)) MiB in the same process, vs ~$((pss_one / 1024)) MiB as a separate process"
fi

echo "phonto contract: $pass passed, $fail failed"
((fail == 0))
