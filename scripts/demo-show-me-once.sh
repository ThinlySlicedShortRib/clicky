#!/bin/bash
#
# One command to get the Show Me Once demo ready to film.
#
#   scripts/demo-show-me-once.sh            build, set up documents, check everything
#   scripts/demo-show-me-once.sh --teach    also launch Clicky and open the teacher's document
#   scripts/demo-show-me-once.sh --follow <lesson.clicky>
#                                           open the follower's document, then the lesson
#   scripts/demo-show-me-once.sh --check-pointing
#                                           with Numbers in front, check pointing on real capture
#
# Only a person can grant macOS permissions. When any are missing this says
# exactly which, puts up the system prompts it can, and stops with exit code 3.
# There's no fallback to saved images anywhere on this path.
#
# CLICKY_TEACHER_NAME sets the name on the share card.

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${CLICKY_DERIVED_DATA_PATH:-$REPOSITORY_ROOT/build/DerivedData}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/Clicky.app"
NUMBERS_APP_PATH="/Applications/Numbers Creator Studio.app"
LAUNCH_SERVICES_REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
DEMO_DOCUMENTS_SOURCE="$REPOSITORY_ROOT/docs/demo/show-me-once/documents"
DEMO_DOCUMENTS_PATH="$HOME/Library/Application Support/Clicky/Demo"
TEACHER_DOCUMENT="$DEMO_DOCUMENTS_PATH/teacher-october-spending.csv"
FOLLOWER_DOCUMENT="$DEMO_DOCUMENTS_PATH/follower-household-bills.csv"

MODE="${1:-setup}"
LESSON_PATH="${2:-}"

fail() {
    echo "error: $1" >&2
    exit "${2:-1}"
}

launch_clicky() {
    # Matches the full path, so other copies of Clicky are left alone.
    pkill -f "$APP_PATH/Contents/MacOS/Clicky" 2>/dev/null || true
    sleep 0.5
    OPEN_ARGUMENTS=()
    if [[ -n "${CLICKY_TEACHER_NAME:-}" ]]; then
        OPEN_ARGUMENTS+=(--env "CLICKY_TEACHER_NAME=$CLICKY_TEACHER_NAME")
    fi
    if [[ -n "${CLICKY_BRAIN_MODEL:-}" ]]; then
        OPEN_ARGUMENTS+=(--env "CLICKY_BRAIN_MODEL=$CLICKY_BRAIN_MODEL")
    fi
    open ${OPEN_ARGUMENTS[@]+"${OPEN_ARGUMENTS[@]}"} "$APP_PATH" "$@"
}

[[ -d "$NUMBERS_APP_PATH" ]] || fail "Numbers Creator Studio isn't installed at $NUMBERS_APP_PATH"
command -v claude >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/claude" ]] || fail "the claude CLI isn't installed, and it's what compiles and follows lessons"

"$REPOSITORY_ROOT/scripts/build-and-run.sh" --build-only

# So double-clicking a .clicky opens this build, not another checkout's.
"$LAUNCH_SERVICES_REGISTER" -f "$APP_PATH"

# Copies, so the demo can never change the originals in the repository.
mkdir -p "$DEMO_DOCUMENTS_PATH"
cp "$DEMO_DOCUMENTS_SOURCE"/*.csv "$DEMO_DOCUMENTS_PATH/"
echo "Demo documents: $DEMO_DOCUMENTS_PATH"

PREFLIGHT_ARGUMENTS=(--headless-lesson-preflight)
if [[ -t 0 ]] && [[ "$MODE" != "--no-prompts" ]]; then
    # A person is here to answer, so ask for everything at once.
    PREFLIGHT_ARGUMENTS+=(--request-permissions)
fi

PREFLIGHT_RESULT="$(mktemp -t clicky-preflight)"
trap 'rm -f "$PREFLIGHT_RESULT"' EXIT
PREFLIGHT_STATUS=0
"$REPOSITORY_ROOT/scripts/headless.sh" "${PREFLIGHT_ARGUMENTS[@]}" >"$PREFLIGHT_RESULT" || PREFLIGHT_STATUS=$?
cat "$PREFLIGHT_RESULT"

if grep -q '"lessonFilesOpenInThisBuild" : false' "$PREFLIGHT_RESULT"; then
    cat >&2 <<HELP

Warning: double-clicking a .clicky file won't open this build. Usually that's
other copies of Clicky built on this Mac, which share its bundle id. Either:
  - remove them: $LAUNCH_SERVICES_REGISTER -u <path to the other Clicky.app>
  - or drop the file on the panel, use its "open lesson" button, or --follow
HELP
fi

if [[ "$PREFLIGHT_STATUS" -eq 3 ]]; then
    cat >&2 <<HELP

Not ready. Permissions are missing, and only you can grant them, for this app:

    $APP_PATH

  System Settings > Privacy & Security, then each of:
    Screen & System Audio Recording   add the app if it isn't listed, then quit and relaunch it
    Accessibility                     add the app if it isn't listed
    Microphone                        allow when prompted
    Speech Recognition                allow when prompted

Then run this script again.
HELP
    exit 3
elif [[ "$PREFLIGHT_STATUS" -ne 0 ]]; then
    fail "preflight failed" "$PREFLIGHT_STATUS"
fi

case "$MODE" in
    setup|--no-prompts)
        echo "Ready. Next: scripts/demo-show-me-once.sh --teach"
        ;;
    --teach)
        open -a "$NUMBERS_APP_PATH" "$TEACHER_DOCUMENT"
        launch_clicky
        echo "Clicky is running. Press control + shift + t, do the task while talking, then press it again."
        ;;
    --follow)
        [[ -f "$LESSON_PATH" ]] || fail "--follow needs the path of a .clicky file"
        open -a "$NUMBERS_APP_PATH" "$FOLLOWER_DOCUMENT"
        sleep 2
        launch_clicky "$LESSON_PATH"
        echo "Lesson opened. Hold control + option to ask a question."
        ;;
    --check-pointing)
        # Real capture only: --image isn't passed, so a blocked capture fails.
        "$REPOSITORY_ROOT/scripts/headless.sh" --headless-point \
            --prompt "where's the button that adds a chart? point at it." --verify-text "Chart"
        ;;
    *)
        fail "unknown option $MODE" 2
        ;;
esac
