#!/usr/bin/env bash
# Runs the phonto-wallpaper tests.
#
#   tests/run.sh            service logic (simulated outputs) + real-process tests
#   tests/run.sh --phonto   also checks the real phonto binary in this session
#
# Needs luajit, ffmpeg, gcc and procps (pgrep/pkill). The systemd checks run when
# `systemd-run --user --scope` works. TEST_VERBOSE=1 also prints passing checks
# and every shell command of the real-process tests.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
service=$here/../phonto-wallpaper/phonto_service.luau
with_phonto=0
[[ ${1:-} == --phonto ]] && with_phonto=1

for tool in luajit ffmpeg gcc pgrep pkill; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }
done
if ((with_phonto)) && ! command -v phonto >/dev/null; then
  echo "phonto is not installed" >&2
  exit 2
fi

root=$(mktemp -d "${TMPDIR:-/tmp}/phonto-tests.XXXXXX")
export TEST_UNIT="phonto-test-$$.scope"

cleanup() {
  # Safety net in case a suite died before its own cleanup.
  for pid in $(pgrep -x 'phonto|xphonto'); do
    if [[ $(readlink "/proc/$pid/exe" 2>/dev/null) == "$root"/* ]]; then
      kill -CONT "$pid" 2>/dev/null
      kill -KILL "$pid" 2>/dev/null
    fi
  done
  for unit in "$TEST_UNIT" phonto-TEST-1.scope phonto-TEST-2.scope; do
    systemctl --user thaw "$unit" >/dev/null 2>&1
    systemctl --user stop "$unit" >/dev/null 2>&1
  done
  rm -rf "$root"
}
trap cleanup EXIT

mkdir -p "$root/videos" "$root/bin"
ffmpeg -loglevel error -f lavfi -i "testsrc=size=320x240:rate=10" -t 10 -pix_fmt yuv420p "$root/videos/a.mp4" &&
  ffmpeg -loglevel error -f lavfi -i "smptebars=size=320x240:rate=10" -t 10 -pix_fmt yuv420p "$root/videos/b.mp4" &&
  ffmpeg -loglevel error -f lavfi -i "testsrc=size=320x240:rate=10" -t 0.4 -pix_fmt yuv420p "$root/videos/short.mp4" ||
  { echo "could not generate test videos" >&2; exit 2; }
gcc -O2 -o "$root/bin/phonto" "$here/fake_phonto.c" || { echo "could not build fake_phonto" >&2; exit 2; }

status=0
echo "== service logic (simulated outputs and processes)"
luajit "$here/service_sim.lua" "$service" "$root" || status=1
echo
echo "== service against real processes (stand-in phonto binary)"
PATH="$root/bin:$PATH" luajit "$here/service_shell.lua" "$service" "$root" || status=1
if ((with_phonto)); then
  echo
  echo "== phonto contract (real phonto in this session)"
  bash "$here/phonto_contract.sh" "$root" || status=1
fi
exit $status
