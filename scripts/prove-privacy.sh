#!/bin/bash
#
# Shows that Stuck opens 0 network sockets and writes 0 files while detecting,
# using tools outside the app: lsof, nettop, the kernel's write counters, and
# fs_usage if you run it with sudo.
#
#   scripts/prove-privacy.sh                 measure the real app for 60s
#   scripts/prove-privacy.sh --seconds 30
#   sudo scripts/prove-privacy.sh            also records with fs_usage
#   scripts/prove-privacy.sh --replay        also measure the detector on a
#                                            synthetic replay, for when no one
#                                            is at the keyboard
#   scripts/prove-privacy.sh --out /abs/report.txt
#
# Move the mouse and press some keys while it runs. It reports how many events
# the detector handled, so an empty run can't pass itself off as a proof.
# Exits 1 if anything was opened or written.

set -uo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${CLICKY_DERIVED_DATA_PATH:-$REPOSITORY_ROOT/build/DerivedData}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/Clicky.app"
# Resolved, because a process's path has symlinks like /tmp expanded.
APP_BINARY="$(cd -P "$APP_PATH/Contents/MacOS" 2>/dev/null && pwd)/Clicky"
HEADLESS="$REPOSITORY_ROOT/scripts/headless.sh"
BUNDLE_IDENTIFIER="$(/usr/bin/defaults read "$APP_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "")"

SECONDS_TO_MEASURE=60
INCLUDE_REPLAY=false
REPORT_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --seconds) SECONDS_TO_MEASURE="$2"; shift 2 ;;
        --replay) INCLUDE_REPLAY=true; shift ;;
        --out) REPORT_PATH="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -x "$APP_PATH/Contents/MacOS/Clicky" ]]; then
    echo "error: $APP_PATH not found, run scripts/build-and-run.sh --build-only first" >&2
    exit 2
fi

WORK_DIRECTORY="$(mktemp -d -t clicky-privacy-proof)"
trap 'rm -rf "$WORK_DIRECTORY"' EXIT

if [[ -n "$REPORT_PATH" ]]; then
    exec > >(tee "$REPORT_PATH") 2>&1
fi

running_clicky_pid() {
    # By full path, so sibling checkouts and other apps never get measured.
    pgrep -f "^$APP_BINARY( --enable-stuck| --show-stuck-receipt|$)" | head -1
}

request_status() {
    "$HEADLESS" --headless-stuck-status 2>/dev/null
}

json_field() {
    /usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"
}

LAUNCHED_CLICKY=false
CLICKY_PID="$(running_clicky_pid || true)"
if [[ -z "$CLICKY_PID" ]]; then
    open -n "$APP_PATH" --args --enable-stuck --show-stuck-receipt
    LAUNCHED_CLICKY=true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        CLICKY_PID="$(running_clicky_pid || true)"
        [[ -n "$CLICKY_PID" ]] && break
        /bin/sleep 0.5
    done
    # Lets launch settle, so startup work isn't mistaken for detection.
    /bin/sleep 4
fi

if [[ -z "$CLICKY_PID" ]]; then
    echo "error: Clicky did not start" >&2
    exit 1
fi

echo "== clicky privacy proof =="
echo "date:     $(date)"
echo "app:      $APP_PATH"
echo "pid:      $CLICKY_PID"
echo

request_status > "$WORK_DIRECTORY/status-before.json" || true
EVENTS_BEFORE="$(json_field "$WORK_DIRECTORY/status-before.json" processedEventCount)"

if [[ "$(json_field "$WORK_DIRECTORY/status-before.json" isEnabled)" != "True" ]]; then
    echo "stuck is off in this Clicky. Turn it on, or quit Clicky and run this again."
    exit 2
fi
if [[ "$(json_field "$WORK_DIRECTORY/status-before.json" processIdentifier)" != "$CLICKY_PID" ]]; then
    echo "error: the Clicky that replied is not pid $CLICKY_PID. Quit other copies and run this again."
    exit 1
fi

/usr/bin/python3 -I "$REPOSITORY_ROOT/scripts/prove_privacy.py" \
    --pid "$CLICKY_PID" --seconds "$SECONDS_TO_MEASURE" \
    --label "the real app, Stuck on" --bundle-identifier "$BUNDLE_IDENTIFIER" \
    --json "$WORK_DIRECTORY/app.json"
MEASURE_STATUS=$?

request_status > "$WORK_DIRECTORY/status-after.json" || true

REPLAY_JSON=""
if [[ "$INCLUDE_REPLAY" == true ]]; then
    HARNESS_BINARY="$WORK_DIRECTORY/stuck-harness"
    CLICKY_STUCK_HARNESS_BINARY="$HARNESS_BINARY" "$REPOSITORY_ROOT/scripts/stuck-harness.sh" live-replay "$((SECONDS_TO_MEASURE + 8))" > "$WORK_DIRECTORY/replay-output.json" &
    REPLAY_SHELL_PID=$!
    for _ in $(seq 1 240); do
        REPLAY_PID="$(pgrep -f "^$HARNESS_BINARY live-replay" | head -1 || true)"
        [[ -n "$REPLAY_PID" ]] && break
        /bin/sleep 0.25
    done
    if [[ -n "${REPLAY_PID:-}" ]]; then
        /usr/bin/python3 -I "$REPOSITORY_ROOT/scripts/prove_privacy.py" \
            --pid "$REPLAY_PID" --seconds "$SECONDS_TO_MEASURE" \
            --label "the same detector source, synthetic replay" \
            --json "$WORK_DIRECTORY/replay.json"
        wait "$REPLAY_SHELL_PID"
        REPLAY_JSON="$WORK_DIRECTORY/replay.json"
    fi
fi

if [[ "$LAUNCHED_CLICKY" == true ]]; then
    kill "$CLICKY_PID" 2>/dev/null
fi

/usr/bin/python3 -I - "$WORK_DIRECTORY" "$APP_BINARY" "$REPOSITORY_ROOT" "$REPLAY_JSON" <<'PYTHON'
import json
import os
import re
import subprocess
import sys

work_directory, app_binary, repository_root, replay_json = sys.argv[1:5]


def load(name):
    path = os.path.join(work_directory, name)
    try:
        with open(path) as json_file:
            return json.load(json_file)
    except (OSError, ValueError):
        return {}


def report(measurement):
    print(f"\n-- {measurement['label']}, {measurement['seconds']:.0f}s, {measurement['lsofSamples']} lsof samples --")
    print(f"network sockets, peak (lsof -i):        {measurement['peakNetworkSockets']}")
    print(f"bytes in + out (nettop):                {measurement['nettopBytesInDelta'] + measurement['nettopBytesOutDelta']}")
    print(f"files newly opened for writing (lsof):  {len(measurement['newFilesOpenedForWriting'])}")
    print(f"logical writes (kernel rusage):         {measurement['logicalWritesDelta']}")
    print(f"disk bytes written (kernel rusage):     {measurement['diskBytesWrittenDelta']}")
    print(f"app files changed under ~/Library:      {len(measurement['bundleFilesChangedOnDisk'])}")
    fs_usage = measurement["fsUsage"]
    if "skipped" in fs_usage:
        print(f"fs_usage:                               skipped, {fs_usage['skipped']}")
    else:
        print(f"fs_usage write calls:                   {fs_usage['writeLines']} of {fs_usage['totalLines']} lines")
        for line in fs_usage["firstWriteLines"]:
            print(f"    {line}")
    for example in measurement["socketExamples"]:
        print(f"    socket: {example}")
    for path in measurement["newFilesOpenedForWriting"] + measurement["bundleFilesChangedOnDisk"]:
        print(f"    file: {path}")
    return (
        measurement["peakNetworkSockets"] == 0
        and measurement["nettopBytesInDelta"] + measurement["nettopBytesOutDelta"] == 0
        and not measurement["newFilesOpenedForWriting"]
        and measurement["logicalWritesDelta"] == 0
        and measurement["diskBytesWrittenDelta"] == 0
        and not measurement["bundleFilesChangedOnDisk"]
        and fs_usage.get("writeLines", 0) == 0
    )


app = load("app.json")
status_before = load("status-before.json")
status_after = load("status-after.json")

control = app["negativeControl"]
print("\n-- negative control: a child that really writes and connects --")
print(f"sockets seen:         {control['socketsSeen']}")
print(f"writable files seen:  {control['filesOpenForWritingSeen']}")
print(f"logical writes:       {control['logicalWritesDelta']}")
print(f"disk bytes written:   {control['diskBytesWrittenDelta']}")
print("instruments can see writes and sockets" if control["instrumentsWork"] else "INSTRUMENTS SAW NOTHING: this run proves nothing")

app_is_clean = report(app["measurement"])

events_during = None
if "processedEventCount" in status_before and "processedEventCount" in status_after:
    events_during = status_after["processedEventCount"] - status_before["processedEventCount"]

print("\n-- was detection really running? --")
print(f"tap reported by macOS:     {status_before.get('stuckTapCount')} tap, listen-only: {status_before.get('stuckTapIsListenOnly')}, enabled: {status_before.get('stuckTapIsEnabled')}")
print(f"keyboard events reach it:  {status_before.get('isReceivingKeyboardEvents')}")
print(f"events handled meanwhile:  {events_during}")
print(f"screenshots taken:         {status_after.get('screenshotsTakenCount')}")
if not events_during:
    print("NO EVENTS were handled. The app was idle, so this says nothing about detection.")
    print("Run it again and move the mouse and press keys while it measures.")

replay_is_clean = True
if replay_json:
    with open(replay_json) as replay_file:
        replay = json.load(replay_file)
    replay_is_clean = report(replay["measurement"])
    replay_output_path = os.path.join(work_directory, "replay-output.json")
    if os.path.exists(replay_output_path):
        with open(replay_output_path) as replay_output_file:
            print(f"replay did this work:      {replay_output_file.read().strip()}")

print("\n-- can test data or capture reach detection? --")
with open(app_binary, "rb") as binary_file:
    binary_contents = binary_file.read()
fixture_markers = [b"stuck: undo loop on one object", b"busy: coding, occasional undo", b"TraceBuilder"]
fixtures_in_binary = [marker.decode() for marker in fixture_markers if marker in binary_contents]
print(f"synthetic traces in the app binary:  {len(fixtures_in_binary)}")

sources = os.path.join(repository_root, "leanring-buddy")
detection_files = ["StuckDetector.swift", "StuckEventClassifier.swift", "StuckEventTapMonitor.swift", "StuckProcessProbe.swift"]
forbidden = re.compile(r"ScreenCaptureKit|SCScreenshotManager|URLSession|URLRequest|FileManager|FileHandle|\.write\(|print\(|NSLog|os_log|Logger\(|UserDefaults|kCGWindowName|AXUIElement")
violations = []
for file_name in detection_files:
    with open(os.path.join(sources, file_name)) as source_file:
        for line_number, line in enumerate(source_file, 1):
            code = line.split("//", 1)[0]
            if forbidden.search(code):
                violations.append(f"{file_name}:{line_number}: {line.strip()}")
print(f"capture, network, file or log calls in the detection sources:  {len(violations)}")
for violation in violations:
    print(f"    {violation}")

passed = control["instrumentsWork"] and app_is_clean and replay_is_clean and not violations and not fixtures_in_binary
print()
if passed and events_during:
    print(f"PASS  0 network sockets and 0 files written while detecting {events_during} real events.")
elif passed:
    print("PASS ON IDLE ONLY  nothing was written or opened, but no real events were handled.")
else:
    print("FAIL  see the numbers above.")
sys.exit(0 if passed else 1)
PYTHON
RESULT=$?
exit $(( MEASURE_STATUS != 0 ? 1 : RESULT ))
