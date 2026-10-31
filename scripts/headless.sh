#!/bin/bash
#
# Runs one of Clicky's headless commands and prints its JSON result.
# The commands are documented in docs/FOUNDATION.md.
#
#   scripts/headless.sh --headless-permissions
#   scripts/headless.sh --headless-self-test
#   scripts/headless.sh --headless-point --prompt "where is the file menu?"
#   scripts/headless.sh --headless-fly-to 400,300 --label "here"
#
# The app is launched through `open` on purpose. Running the binary directly
# would make macOS attribute permissions to this shell's host app rather than
# to Clicky, so a capture check could pass or fail for the wrong reason.

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$REPOSITORY_ROOT/build/DerivedData/Build/Products/Debug/Clicky.app"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: $APP_PATH not found, run scripts/build-and-run.sh --build-only first" >&2
    exit 2
fi

RESULT_DIRECTORY="$(mktemp -d -t clicky-headless)"
trap 'rm -rf "$RESULT_DIRECTORY"' EXIT
RESULT_PATH="$RESULT_DIRECTORY/result.json"
LOG_PATH="$RESULT_DIRECTORY/output.log"

OPEN_ARGUMENTS=()
if [[ -n "${CLICKY_BRAIN_MODEL:-}" ]]; then
    OPEN_ARGUMENTS+=(--env "CLICKY_BRAIN_MODEL=$CLICKY_BRAIN_MODEL")
fi

# -n starts a separate instance, so a menu bar copy that's already running
# doesn't swallow the command. -W waits for it to exit. `open` doesn't pass the
# app's exit code back, so the status comes from the JSON instead.
open -n -W ${OPEN_ARGUMENTS[@]+"${OPEN_ARGUMENTS[@]}"} \
    --stdout "$LOG_PATH" --stderr "$LOG_PATH" \
    "$APP_PATH" --args "$@" --output "$RESULT_PATH"

if [[ ! -s "$RESULT_PATH" ]]; then
    echo "error: Clicky produced no result. Output was:" >&2
    cat "$LOG_PATH" >&2 2>/dev/null || true
    exit 1
fi

cat "$RESULT_PATH"
echo

STATUS="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$RESULT_PATH")"
case "$STATUS" in
    ok) exit 0 ;;
    usage_error) exit 2 ;;
    permission_missing|permissions_missing) exit 3 ;;
    *) exit 1 ;;
esac
