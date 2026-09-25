#!/usr/bin/env bash
# Superduino testbench runner.
#
# Builds Superduino, installs it into a temporary folder and runs every test
# case in tests/cases (or those whose name contains PATTERN) in a fresh,
# isolated environment: its own HOME, user directory, fake arduino-cli and
# fake pkexec. Nothing in your real home directory is touched.
#
# Usage: tests/run.sh [--visible] [--keep] [PATTERN]
#   --visible  show the editor windows (default: SDL offscreen driver) and
#              save screenshots taken with T.shot() into each case folder
#   --keep     keep the temporary folder for inspection
#
# A case may set environment variables with lines like:
#   --! TIMEOUT=90
#   --! FAKE_CLI_ON_PATH=0     (default 1: tests/fixtures/bin is on PATH)
#
# Cases named real_* use the network and the real arduino-cli; they only run
# when SUPERDUINO_REAL_TESTS=1 is set.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VISIBLE=0
KEEP=0
PATTERN=""
for arg in "$@"; do
  case "$arg" in
    --visible) VISIBLE=1 ;;
    --keep) KEEP=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) PATTERN="$arg" ;;
  esac
done

WORK=$(mktemp -d -t superduino-tests.XXXXXX)
cleanup() { if [ "$KEEP" = 1 ]; then echo "Kept: $WORK"; else rm -rf "$WORK"; fi; }
trap cleanup EXIT

echo "Building..."
if ! meson compile -C "$ROOT/build" >"$WORK/build.log" 2>&1; then
  cat "$WORK/build.log"; echo "Build failed"; exit 1
fi
meson install -C "$ROOT/build" --destdir "$WORK/install" --skip-subprojects >"$WORK/install.log" 2>&1 || {
  cat "$WORK/install.log"; echo "Install failed"; exit 1
}
BIN=$(find "$WORK/install" -type f -name superduino -perm -u+x | head -1)

passed=0
failed=0
failed_cases=()
for case_file in "$ROOT"/tests/cases/*.lua; do
  name=$(basename "$case_file" .lua)
  if [ -n "$PATTERN" ] && [[ "$name" != *"$PATTERN"* ]]; then continue; fi

  dir="$WORK/cases/$name"
  mkdir -p "$dir/home" "$dir/user"
  cp "$ROOT/tests/harness.lua" "$dir/user/init.lua"

  # per-case settings
  TIMEOUT=60
  FAKE_CLI_ON_PATH=1
  extra_env=()
  while IFS= read -r line; do
    setting=${line#--! }
    case "$setting" in
      TIMEOUT=*) TIMEOUT=${setting#TIMEOUT=} ;;
      FAKE_CLI_ON_PATH=*) FAKE_CLI_ON_PATH=${setting#FAKE_CLI_ON_PATH=} ;;
      *=*) extra_env+=("$setting") ;;
    esac
  done < <(grep '^--! ' "$case_file")

  path="/usr/bin:/bin"
  [ "$FAKE_CLI_ON_PATH" = 1 ] && path="$ROOT/tests/fixtures/bin:$path"
  driver=offscreen
  [ "$VISIBLE" = 1 ] && driver=""

  start=$(date +%s.%N)
  (cd "$dir/home" && env -i \
    HOME="$dir/home" PATH="$path" DISPLAY="${DISPLAY:-}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" SDL_VIDEO_DRIVER="$driver" \
    LITE_USERDIR="$dir/user" SUPERDUINO_TEST_DIR="$dir" SUPERDUINO_TEST_CASE="$case_file" \
    SUPERDUINO_TEST_FIXTURES="$ROOT/tests/fixtures" SUPERDUINO_TEST_VISIBLE="$VISIBLE" \
    SUPERDUINO_REAL_TESTS="${SUPERDUINO_REAL_TESTS:-0}" \
    "${extra_env[@]}" \
    timeout -s KILL "$TIMEOUT" "$BIN" >"$dir/stdout.log" 2>&1) 2>/dev/null
  seconds=$(printf "%.1f" "$(echo "$(date +%s.%N) - $start" | bc)")

  results="$dir/results.txt"
  touch "$results"
  n_ok=$(grep -c '^ok ' "$results")
  n_fail=$(grep -c '^not ok ' "$results")
  if [ ! -f "$dir/done" ]; then
    echo "not ok did not finish within ${TIMEOUT}s (crash or hang); see $dir/stdout.log" >>"$results"
    n_fail=$((n_fail + 1))
  fi

  if [ "$n_fail" -eq 0 ] && [ "$n_ok" -gt 0 ]; then
    printf "PASS  %-40s %3d checks  %5ss\n" "$name" "$n_ok" "$seconds"
    passed=$((passed + 1))
  else
    printf "FAIL  %-40s %3d ok, %d failed  %5ss\n" "$name" "$n_ok" "$n_fail" "$seconds"
    grep '^not ok ' "$results" | sed 's/^/        /'
    [ "$n_ok" -eq 0 ] && [ "$n_fail" -eq 0 ] && echo "        no checks were run"
    failed=$((failed + 1))
    failed_cases+=("$name")
    KEEP=1
  fi
done

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
