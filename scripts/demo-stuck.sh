#!/bin/bash
#
# One command to the Stuck demo: checks permissions, opens the Blender scene,
# and starts Clicky with Stuck on and the receipt showing. Detection then runs
# on your real input. This script can't trigger an offer and injects nothing.
#
#   scripts/demo-stuck.sh               full setup
#   scripts/demo-stuck.sh --local       answer with ollama, loaded in advance
#   scripts/demo-stuck.sh --consent-on-camera
#                                       leave Stuck off to flip it in the panel
#   scripts/demo-stuck.sh --no-build    skip the build
#   scripts/demo-stuck.sh --no-blender  leave any open Blender alone
#
# Run it again between takes: it resets what declining taught Clicky, and
# restarting clears the cooldown. It also sets Clicky's answer mode for the
# take, which replaces the panel's "answer on this mac" switch.

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${CLICKY_DERIVED_DATA_PATH:-$REPOSITORY_ROOT/build/DerivedData}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/Clicky.app"
# Resolved, because a process's path has symlinks like /tmp expanded.
APP_BINARY="$(cd -P "$APP_PATH/Contents/MacOS" 2>/dev/null && pwd)/Clicky"
HEADLESS="$REPOSITORY_ROOT/scripts/headless.sh"
BLENDER_EXECUTABLE="/Applications/Blender.app/Contents/MacOS/Blender"
SCENE_SCRIPT="$REPOSITORY_ROOT/scripts/blender_stuck_scene.py"

USE_LOCAL_BRAIN=false
CONSENT_ON_CAMERA=false
SHOULD_BUILD=true
SHOULD_OPEN_BLENDER=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --local) USE_LOCAL_BRAIN=true ;;
        --consent-on-camera) CONSENT_ON_CAMERA=true ;;
        --no-build) SHOULD_BUILD=false ;;
        --no-blender) SHOULD_OPEN_BLENDER=false ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [[ "$SHOULD_BUILD" == true ]]; then
    "$REPOSITORY_ROOT/scripts/build-and-run.sh" --build-only
fi

BUNDLE_IDENTIFIER="$(/usr/bin/defaults read "$APP_PATH/Contents/Info" CFBundleIdentifier)"

# Only this checkout's copy. Other apps and checkouts are left alone.
pkill -f "^$APP_BINARY" 2>/dev/null || true
/bin/sleep 0.5

echo
echo "== preflight =="
PREFLIGHT_DIRECTORY="$(mktemp -d -t clicky-demo-preflight)"
trap 'rm -rf "$PREFLIGHT_DIRECTORY"' EXIT
"$HEADLESS" --headless-permissions > "$PREFLIGHT_DIRECTORY/permissions.json" 2>/dev/null || true
"$HEADLESS" --headless-stuck-tap-check > "$PREFLIGHT_DIRECTORY/tap.json" 2>/dev/null || true

MISSING_REQUIRED="$(/usr/bin/python3 -I - "$PREFLIGHT_DIRECTORY" <<'PYTHON'
import json
import os
import sys

directory = sys.argv[1]
with open(os.path.join(directory, "permissions.json")) as permissions_file:
    permissions = json.load(permissions_file)
with open(os.path.join(directory, "tap.json")) as tap_file:
    tap = json.load(tap_file)

keys_reach_tap = tap.get("isReceivingKeyboardEvents") is True
capture_works = str(permissions.get("realCapture", "")).startswith("ok")
microphone = permissions.get("microphone") == "authorized"
speech = permissions.get("speechRecognition") == "authorized"

rows = [
    ("Input Monitoring or Accessibility, so undos can be seen", keys_reach_tap, True),
    ("Screen Recording, for the one screenshot on yes", capture_works, True),
    ("Microphone, for talking back with ctrl+option", microphone, False),
    ("Speech Recognition, for talking back", speech, False),
]
for label, granted, required in rows:
    state = "ok     " if granted else ("MISSING" if required else "absent ")
    print(f"  {state} {label}", file=sys.stderr)

print("yes" if not all(granted for _, granted, required in rows if required) else "no")
PYTHON
)"

if [[ "$MISSING_REQUIRED" == "yes" ]]; then
    echo >&2
    echo "A required permission is missing, and only you can grant it:" >&2
    echo "  System Settings > Privacy & Security > Input Monitoring: add Clicky" >&2
    echo "  System Settings > Privacy & Security > Screen & System Audio Recording: add Clicky" >&2
    echo "  $APP_PATH" >&2
    echo >&2
    echo "Then quit Clicky if it's running, and run this script again." >&2
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" || true
    exit 3
fi

LOCAL_MODEL_VALUE="$(/usr/bin/defaults read "$APP_PATH/Contents/Info" StuckLocalBrainModel)"
if [[ "$USE_LOCAL_BRAIN" == true ]]; then
    LOCAL_MODEL="${LOCAL_MODEL_VALUE#ollama:}"
    echo "  loading $LOCAL_MODEL so the first answer isn't a cold start..."
    curl -sf -m 180 http://127.0.0.1:11434/api/generate \
        -d "{\"model\":\"$LOCAL_MODEL\",\"keep_alive\":\"30m\"}" > /dev/null \
        || { echo "error: ollama isn't answering on 127.0.0.1:11434" >&2; exit 1; }
    /usr/bin/defaults write "$BUNDLE_IDENTIFIER" stuckUsesLocalBrain -bool true
else
    /usr/bin/defaults write "$BUNDLE_IDENTIFIER" stuckUsesLocalBrain -bool false
    command -v claude >/dev/null || [[ -x "$HOME/.local/bin/claude" ]] \
        || echo "  warning: the claude CLI wasn't found, so a yes will fail" >&2
fi

# A previous take's declines would make the next take refuse to offer.
/usr/bin/defaults delete "$BUNDLE_IDENTIFIER" stuckThresholdMultiplier 2>/dev/null || true

if [[ "$SHOULD_OPEN_BLENDER" == true ]]; then
    echo
    echo "== blender =="
    # Only a previous take. Any other Blender may hold someone's unsaved work.
    pkill -f "blender_stuck_scene.py" 2>/dev/null || true
    /bin/sleep 1
    if pgrep -f "^$BLENDER_EXECUTABLE" > /dev/null; then
        echo "  another Blender is open. Leaving it alone, but close it so it isn't on camera."
    fi
    "$BLENDER_EXECUTABLE" --factory-startup --window-geometry 0 70 1512 860 \
        --python "$SCENE_SCRIPT" > /dev/null 2>&1 &
    disown
    /bin/sleep 5
    open -a Blender || true
fi

echo
echo "== clicky =="
CLICKY_ARGUMENTS=(--show-stuck-receipt)
if [[ "$CONSENT_ON_CAMERA" == true ]]; then
    echo "stuck is OFF. flip it in the menu bar panel on camera."
else
    CLICKY_ARGUMENTS=(--enable-stuck --show-stuck-receipt)
    echo "turning stuck on for this launch, which is the same as agreeing to:"
    echo
    grep -o 'consentSentence = "[^"]*"' "$REPOSITORY_ROOT/leanring-buddy/StuckCompanion.swift" | sed 's/consentSentence = //'
fi
open -n "$APP_PATH" --args "${CLICKY_ARGUMENTS[@]}"

echo
echo "ready. in blender: click the grey cube, press g, move, click, cmd-z. repeat."
echo "the offer comes from your real input, usually after 4 or 5 undos."
echo "script and shot list: docs/demo/stuck/DEMO.md"
