#!/bin/bash
#
# One command for the Follow Along demo: installs what's missing, checks macOS
# permissions, opens Blender, and starts the lesson.
#
#   scripts/demo-follow-along.sh               straight into the lesson
#   scripts/demo-follow-along.sh --paste       open the paste surface instead
#   scripts/demo-follow-along.sh --check       setup and preflight only, launch nothing
#   scripts/demo-follow-along.sh --setup-only  install yt-dlp and build, skip permissions
#   scripts/demo-follow-along.sh <youtube url> use a different tutorial
#
# This runs the real path: ScreenCaptureKit, the real voice, real push-to-talk.
# Nothing in it can reach the rehearsal code, so if permissions are missing it
# stops and says so rather than falling back to anything.
#
# Exit codes: 0 ready or running, 1 setup failed, 3 a permission is missing.

set -euo pipefail

DEFAULT_TUTORIAL_URL="https://www.youtube.com/watch?v=_deRNqDcwRk"

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLICKY_DERIVED_DATA="${CLICKY_DERIVED_DATA:-$REPOSITORY_ROOT/build/DerivedData}"
APP_PATH="$CLICKY_DERIVED_DATA/Build/Products/Debug/Clicky.app"

FOLLOW_ALONG_HOME="$HOME/Library/Application Support/Clicky/follow-along"
DOWNLOADER_ENVIRONMENT="$FOLLOW_ALONG_HOME/tools/ytdlp-venv"
BLENDER_EXECUTABLE="/Applications/Blender.app/Contents/MacOS/Blender"
# Blender's file browser is on screen in the Shading workspace and opens on the
# home folder. This keeps private folder names off camera and away from the model.
NEUTRAL_BLENDER_HOME="$FOLLOW_ALONG_HOME/neutral-blender-home"

LAUNCH_MODE="lesson"
SHOULD_CHECK_PERMISSIONS=true
TUTORIAL_URL="$DEFAULT_TUTORIAL_URL"

for argument in "$@"; do
    case "$argument" in
        --paste) LAUNCH_MODE="paste" ;;
        --check) LAUNCH_MODE="none" ;;
        --setup-only) LAUNCH_MODE="none"; SHOULD_CHECK_PERMISSIONS=false ;;
        --help|-h) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        http*|youtu*) TUTORIAL_URL="$argument" ;;
        *) echo "error: unknown argument: $argument" >&2; exit 1 ;;
    esac
done

# --- Tools ----------------------------------------------------------------

for required_path in /opt/homebrew/bin/ffmpeg "$BLENDER_EXECUTABLE"; do
    if [[ ! -x "$required_path" ]]; then
        echo "error: $required_path is missing" >&2
        exit 1
    fi
done

if [[ ! -x "$HOME/.local/bin/claude" && ! -x /opt/homebrew/bin/claude ]]; then
    echo "error: the claude CLI isn't installed, and it's what Clicky thinks with" >&2
    exit 1
fi

if [[ ! -x "$DOWNLOADER_ENVIRONMENT/bin/yt-dlp" ]]; then
    echo "Installing yt-dlp in a private environment..."
    mkdir -p "$(dirname "$DOWNLOADER_ENVIRONMENT")"
    /opt/homebrew/bin/python3 -m venv "$DOWNLOADER_ENVIRONMENT"
    "$DOWNLOADER_ENVIRONMENT/bin/pip" install --quiet --upgrade pip 'yt-dlp[default]'
fi

"$REPOSITORY_ROOT/scripts/build-and-run.sh" --build-only

if [[ "$SHOULD_CHECK_PERMISSIONS" == false ]]; then
    echo "Setup done."
    exit 0
fi

# --- Permissions ----------------------------------------------------------

echo "Checking permissions (a real test capture, not just the preflight flag)..."
permission_exit_code=0
permission_report="$("$REPOSITORY_ROOT/scripts/headless.sh" --headless-permissions 2>&1)" || permission_exit_code=$?

if [[ "$permission_exit_code" -ne 0 ]]; then
    echo
    echo "Clicky is missing permissions, and only you can grant them:"
    echo
    /usr/bin/python3 -I -c '
import json, sys
report = json.loads(sys.argv[1])
fixes = {
    "Screen & System Audio Recording": "System Settings > Privacy & Security > Screen & System Audio Recording. Add the app below if it is not listed, then rerun this script.",
    "Accessibility": "System Settings > Privacy & Security > Accessibility. Add the app below if it is not listed.",
    "Microphone": "Accept the prompt on the first hotkey press, or use the Grant button in the panel.",
    "Speech Recognition": "Accept the prompt on the first hotkey press, or System Settings > Privacy & Security > Speech Recognition.",
}
for permission in report.get("missingPermissions", []):
    print(f"  - {permission}: {fixes.get(permission, permission)}")
print(f"\n  App: {report.get(\"bundlePath\")}")
' "$permission_report" || echo "$permission_report"
    echo
    # --check only reports, so it can run without anyone at the machine.
    if [[ "$LAUNCH_MODE" != "none" ]]; then
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" || true
    fi
    exit 3
fi

echo "All four permissions are granted, and a real capture worked."

# HeyClicky listens on the same hotkey and draws its own cursor, which would
# answer over this build and appear in the recording.
if pgrep -x HeyClicky >/dev/null 2>&1; then
    echo
    echo "warning: the official HeyClicky app is running. Quit it first: it shares"
    echo "         the control+option hotkey and its cursor will show up on camera."
fi

if [[ "$LAUNCH_MODE" == "none" ]]; then
    echo "Ready. Nothing launched."
    exit 0
fi

# --- Launch ---------------------------------------------------------------

# Matches on the full path so other copies of Clicky are left alone.
pkill -f "$APP_PATH/Contents/MacOS/Clicky" 2>/dev/null || true

mkdir -p "$NEUTRAL_BLENDER_HOME"
if pgrep -f "$BLENDER_EXECUTABLE" >/dev/null 2>&1; then
    echo "Blender is already open, so that window will be used as it is."
else
    echo "Opening Blender with factory settings..."
    # The factory default cube is the starting point the lesson expects.
    HOME="$NEUTRAL_BLENDER_HOME" nohup "$BLENDER_EXECUTABLE" --factory-startup >/dev/null 2>&1 &
    disown
fi

BLENDER_WINDOW_WAIT_SECONDS=30
for (( waited_seconds = 0; waited_seconds < BLENDER_WINDOW_WAIT_SECONDS; waited_seconds++ )); do
    if "$REPOSITORY_ROOT/scripts/headless.sh" --headless-window-bounds Blender >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

OPEN_ARGUMENTS=()
if [[ -n "${CLICKY_BRAIN_MODEL:-}" ]]; then
    OPEN_ARGUMENTS+=(--env "CLICKY_BRAIN_MODEL=$CLICKY_BRAIN_MODEL")
fi

if [[ "$LAUNCH_MODE" == "paste" ]]; then
    open ${OPEN_ARGUMENTS[@]+"${OPEN_ARGUMENTS[@]}"} "$APP_PATH" --args --follow-along-paste
    echo "Clicky is up. Paste a link with command+V, then press return."
    echo "Reopen the surface any time with command+shift+Y."
else
    open ${OPEN_ARGUMENTS[@]+"${OPEN_ARGUMENTS[@]}"} "$APP_PATH" --args --follow-along "$TUTORIAL_URL"
    echo "Clicky is starting the lesson: $TUTORIAL_URL"
fi

echo "Run logs land in: $FOLLOW_ALONG_HOME/runs"
