#!/usr/bin/env bash
# Builds Superduino, installs it into ./dist and starts it.
#
# Usage: ./run.sh [ARGS...]
#   ARGS are passed to Superduino, e.g. ./run.sh ~/Arduino/Blink
#
# This runs with your real settings (~/.config/superduino), your real
# arduino-cli and your real sketchbook. For isolated automated tests use
# tests/run.sh instead.
set -e

ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

if [ ! -d build ]; then
  echo "Setting up the build folder..."
  meson setup build
fi

echo "Building..."
meson compile -C build >/dev/null
meson install -C build --destdir ../dist --skip-subprojects >/dev/null

echo "Starting Superduino..."
exec "$ROOT/dist/usr/local/bin/superduino" "$@"
