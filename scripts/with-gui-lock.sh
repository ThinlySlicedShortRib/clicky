#!/bin/bash
#
# Runs a command while holding the machine-wide GUI lock, so parallel checkouts
# don't fight over Blender windows or Clicky launches. Waits for the lock, and
# always releases it, including on Ctrl-C.
#
#   scripts/with-gui-lock.sh scripts/headless.sh --headless-self-test

set -uo pipefail

LOCK_PATH="/tmp/clicky-gui.lock"
POLL_INTERVAL_SECONDS=5
MAXIMUM_WAIT_SECONDS="${CLICKY_GUI_LOCK_WAIT_SECONDS:-1800}"

waited_seconds=0
until mkdir "$LOCK_PATH" 2>/dev/null; do
    if (( waited_seconds >= MAXIMUM_WAIT_SECONDS )); then
        echo "error: gave up waiting for $LOCK_PATH after ${waited_seconds}s" >&2
        exit 75
    fi
    sleep "$POLL_INTERVAL_SECONDS"
    waited_seconds=$(( waited_seconds + POLL_INTERVAL_SECONDS ))
done
trap 'rmdir "$LOCK_PATH" 2>/dev/null' EXIT INT TERM

"$@"
exit $?
