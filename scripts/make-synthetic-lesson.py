#!/usr/bin/env python3
"""Checks the lesson compiler and follow engine end to end, with no human.

Teach mode needs a person, a microphone and macOS permissions. This builds the
closest honest stand-in: a SYNTHETIC recording made from real windows.

  real:      Blender's own export of its window, at every state of the task
  real:      the compiler, the model calls, the OCR ground truth, the costs
  synthetic: a script made the changes instead of a person clicking
  synthetic: the narration is written below and spoken by `say`
  real:      if Speech Recognition is granted, the transcript comes from running
             that audio through teach mode's own recognition code
  absent:    accessibility info, because Blender doesn't expose any

The follower's setup differs on purpose: light theme, different window size and
position, different objects, different animation length. Everything comes out
labelled synthetic, including the lesson's own share card.

    scripts/make-synthetic-lesson.py [--output DIR] [--model MODEL] [--fly]

Takes the GUI lock around Blender. Needs Blender.app and a logged-in claude CLI.
"""

import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import wave

SCRIPTS_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
HEADLESS_SCRIPT = os.path.join(SCRIPTS_DIRECTORY, "headless.sh")
STATES_SCRIPT = os.path.join(SCRIPTS_DIRECTORY, "blender_lesson_states.py")
BLENDER_EXECUTABLE = "/Applications/Blender.app/Contents/MacOS/Blender"

GUI_LOCK_PATH = "/tmp/clicky-gui.lock"
GUI_LOCK_TIMEOUT_SECONDS = 900
BLENDER_TIMEOUT_SECONDS = 90

# Blender's own x,y,width,height, with a bottom-left origin.
TEACH_WINDOW_GEOMETRY = ("150", "120", "1100", "720")
FOLLOW_WINDOW_GEOMETRY = ("40", "60", "1400", "840")

STATE_NAMES = ["0-start", "1-animation-tab", "2-output-tab", "3-frame-end", "4-back-to-layout"]

TEACHER_NAME = "sean"

# Written for this test, in the voice of someone showing a friend. The "says"
# phrase plays first, then the action happens as it ends.
SYNTHETIC_NARRATION = [
    {
        "says": "okay so this is how you change how long your animation is, it took me ages to find this.",
        "action": None,
    },
    {
        "says": "first go up to the top and click animation, that's the tab with all the timing stuff.",
        "action": {"kind": "click", "stateIndex": 0, "text": "Animation"},
    },
    {
        "says": "then over on the right, see this little printer icon? i know it looks like a printer, trust me, that's output.",
        "action": {"kind": "click", "stateIndex": 1, "navigationIcon": True},
    },
    {
        "says": "now find frame range, click the end number, and type how long you want. i always do a hundred and twenty because that's five seconds at twenty four frames.",
        "action": {"kind": "typing", "stateIndex": 2, "text": "End", "digits": 3},
    },
    {
        "says": "then go back to layout and you're done.",
        "action": {"kind": "click", "stateIndex": 3, "text": "Layout"},
    },
    {"says": "that's it, nice and easy.", "action": None},
]

# Text each exported state must visibly contain, read back by OCR. Blender's
# framebuffer can lag its state, so a frame is only trusted once its pixels are
# seen to show what its file name claims. {frame_end} is that setup's own value.
EXPECTED_TEXT_BY_STATE = {
    "0-start": ["Transform"],
    "1-animation-tab": ["Dope Sheet"],
    "2-output-tab": ["Frame Range"],
    "3-frame-end": ["120"],
    "4-back-to-layout": ["Playback"],
}

# Which text proves the cursor landed right, per lesson step, on the follower's
# screen. None means the target has no words, so Blender's layout judges it.
# Step 3's target is the number in the field, not the "End" label beside it,
# so the follower's own value is what the point has to land on.
FOLLOW_GROUND_TRUTH_TEXT = ["Animation", None, "480", "Layout"]


def log(message):
    print(message, flush=True)


def take_gui_lock():
    deadline = time.time() + GUI_LOCK_TIMEOUT_SECONDS
    while time.time() < deadline:
        try:
            os.mkdir(GUI_LOCK_PATH)
            return
        except FileExistsError:
            time.sleep(3)
    raise RuntimeError(f"could not take {GUI_LOCK_PATH}")


def release_gui_lock():
    try:
        os.rmdir(GUI_LOCK_PATH)
    except FileNotFoundError:
        pass


def run_headless(*arguments):
    completed = subprocess.run([HEADLESS_SCRIPT, *arguments], capture_output=True, text=True)
    if not completed.stdout.strip():
        raise RuntimeError(f"headless produced no JSON: {completed.stderr}")
    return json.loads(completed.stdout)


def walk_blender_states(setup_name, window_geometry, frames_directory):
    """Runs one Blender session through every state. Returns the window's place
    on the display, read while it's open. Only ever quits the Blender it started."""
    blender_process = subprocess.Popen(
        [BLENDER_EXECUTABLE, "--factory-startup", "--window-geometry", *window_geometry,
         "--python", STATES_SCRIPT, "--", frames_directory, setup_name],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        done_path = os.path.join(frames_directory, f"{setup_name}-done")
        deadline = time.time() + BLENDER_TIMEOUT_SECONDS
        while not os.path.exists(done_path):
            if blender_process.poll() is not None:
                raise RuntimeError(f"Blender exited during the {setup_name} walk")
            if time.time() > deadline:
                raise RuntimeError(f"timed out on the {setup_name} walk")
            time.sleep(0.25)

        window_bounds = run_headless("--headless-window-bounds", "Blender")
        bounds = window_bounds["windowBoundsTopLeftOrigin"][0]

        with open(os.path.join(frames_directory, f"{setup_name}-{STATE_NAMES[0]}.json")) as layout_file:
            first_layout = json.load(layout_file)
        content_width = first_layout["windowInPoints"]["width"]
        content_height = first_layout["windowInPoints"]["height"]

        return {
            "x": bounds["x"],
            "y": bounds["y"] + bounds["height"] - content_height,
            "width": content_width,
            "height": content_height,
        }
    finally:
        with open(os.path.join(frames_directory, f"{setup_name}-quit"), "w") as quit_file:
            quit_file.write("quit")
        try:
            blender_process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            blender_process.terminate()


def assert_frames_show_their_states(setup_name, frames_directory):
    """Refuses to go on if an image doesn't show the state it's named after.
    A compile on stale frames would produce a result that means nothing."""
    for state_name, expected_texts in EXPECTED_TEXT_BY_STATE.items():
        image_path = os.path.join(frames_directory, f"{setup_name}-{state_name}.png")
        for expected_text in expected_texts:
            result = run_headless("--headless-find-text", image_path, "--text", expected_text)
            if result.get("status") != "ok":
                raise RuntimeError(f"{setup_name}-{state_name}.png doesn't show \"{expected_text}\"")
    log(f"  {setup_name}: every frame shows its state (read back by OCR)")


def synthesize_narration(recording_directory):
    """Speaks each phrase with `say` and joins them into one file, with gaps.
    Returns (audio file name, phrase timings). The timing is real: it's where
    each phrase sits in the audio."""
    sample_rate = 22050
    gap_seconds = 0.6
    joined_frames = bytearray()
    segments = []
    action_times = []

    with tempfile.TemporaryDirectory() as phrase_directory:
        for phrase_index, phrase in enumerate(SYNTHETIC_NARRATION):
            phrase_path = os.path.join(phrase_directory, f"phrase-{phrase_index}.wav")
            subprocess.run(
                ["say", "-v", "Samantha", "-o", phrase_path,
                 "--file-format=WAVE", f"--data-format=LEI16@{sample_rate}", phrase["says"]],
                check=True,
            )
            with wave.open(phrase_path, "rb") as phrase_file:
                phrase_frames = phrase_file.readframes(phrase_file.getnframes())

            start_seconds = len(joined_frames) / 2 / sample_rate
            joined_frames.extend(phrase_frames)
            end_seconds = len(joined_frames) / 2 / sample_rate
            segments.append({
                "text": phrase["says"],
                "startSeconds": round(start_seconds, 3),
                "endSeconds": round(end_seconds, 3),
            })
            action_times.append(round(end_seconds, 3))
            joined_frames.extend(b"\x00\x00" * int(gap_seconds * sample_rate))

    narration_file_name = "narration.wav"
    with wave.open(os.path.join(recording_directory, narration_file_name), "wb") as narration_file:
        narration_file.setnchannels(1)
        narration_file.setsampwidth(2)
        narration_file.setframerate(sample_rate)
        narration_file.writeframes(bytes(joined_frames))

    return narration_file_name, segments, action_times


def ocr_center_in_points(image_path, text, pixels_per_point):
    result = run_headless("--headless-find-text", image_path, "--text", text)
    box = result["boxesInPixels"][0]
    return {
        "x": (box["x"] + box["width"] / 2) / pixels_per_point,
        "y": (box["y"] + box["height"] / 2) / pixels_per_point,
    }


def navigation_bar_rect(layout):
    return layout["areas"]["PROPERTIES"][0]["regions"]["NAVIGATION_BAR"]


def output_tab_rect(frames_directory, setup_name):
    """Where the Output tab is, in window points. It has no text for OCR, and
    the navigation bar alone is hundreds of points tall, which proves little.
    Choosing a tab moves its highlight, so the rows that change across that
    state are the tabs involved. Output is the upper one, above the Object tab
    it replaced. This comes only from Blender's pixels, never from the model."""
    before_path = os.path.join(frames_directory, f"{setup_name}-{STATE_NAMES[1]}.png")
    after_path = os.path.join(frames_directory, f"{setup_name}-{STATE_NAMES[2]}.png")
    with open(os.path.join(frames_directory, f"{setup_name}-{STATE_NAMES[1]}.json")) as layout_file:
        layout = json.load(layout_file)

    pixels_per_point = layout["pixelsPerPoint"]
    navigation_bar = navigation_bar_rect(layout)
    result = run_headless(
        "--headless-changed-rows", before_path, "--after", after_path,
        "--column-start", str(int(navigation_bar["x"] * pixels_per_point)),
        "--column-end", str(int((navigation_bar["x"] + navigation_bar["width"]) * pixels_per_point)),
    )

    bar_top = navigation_bar["y"]
    bar_bottom = bar_top + navigation_bar["height"]
    tab_bands = [
        band for band in result["changedBandsInPixels"]
        if bar_top <= band["startRow"] / pixels_per_point <= bar_bottom
        and (band["endRow"] - band["startRow"]) / pixels_per_point >= 10
    ]
    if len(tab_bands) < 2:
        raise RuntimeError(f"expected two tabs to change in {setup_name}, found {tab_bands}")

    output_band = tab_bands[0]
    return {
        "x": navigation_bar["x"],
        "y": output_band["startRow"] / pixels_per_point,
        "width": navigation_bar["width"],
        "height": (output_band["endRow"] - output_band["startRow"]) / pixels_per_point,
    }


def build_recording(frames_directory, recording_directory, window_in_points):
    os.makedirs(os.path.join(recording_directory, "frames"))

    narration_file_name, segments, phrase_end_times = synthesize_narration(recording_directory)

    # Recognized text is rougher than the script, which is the honest input.
    narration_path = os.path.join(recording_directory, narration_file_name)
    narration_result = run_headless("--headless-narration-file", narration_path)
    narration_source = "the written script, because speech recognition isn't available"
    if narration_result.get("status") == "ok":
        segments = narration_result["segments"]
        narration_source = f"apple speech on-device recognition of that audio, {len(segments)} phrases"
    log(f"  narration from {narration_source}")

    actions = []
    for phrase_index, phrase in enumerate(SYNTHETIC_NARRATION):
        action = phrase["action"]
        if action is None:
            continue

        state_index = action["stateIndex"]
        action_number = len(actions)
        before_source = os.path.join(frames_directory, f"teach-{STATE_NAMES[state_index]}.png")
        after_source = os.path.join(frames_directory, f"teach-{STATE_NAMES[state_index + 1]}.png")
        before_name = f"action-{action_number}-before.png"
        after_name = f"action-{action_number}-after.png"
        shutil.copyfile(before_source, os.path.join(recording_directory, "frames", before_name))
        shutil.copyfile(after_source, os.path.join(recording_directory, "frames", after_name))

        with open(os.path.join(frames_directory, f"teach-{STATE_NAMES[state_index]}.json")) as layout_file:
            layout = json.load(layout_file)
        pixels_per_point = layout["pixelsPerPoint"]

        location = None
        if action.get("text"):
            location = ocr_center_in_points(before_source, action["text"], pixels_per_point)
        elif action.get("navigationIcon"):
            tab_rect = output_tab_rect(frames_directory, "teach")
            location = {"x": tab_rect["x"] + tab_rect["width"] / 2, "y": tab_rect["y"] + tab_rect["height"] / 2}

        keystroke_summary = None
        kind = action["kind"]
        if kind == "typing":
            keystroke_summary = {
                "letterCount": 0, "digitCount": action["digits"], "punctuationCount": 0, "spaceCount": 0,
                "returnCount": 1, "tabCount": 0, "deleteCount": 0, "arrowCount": 0, "escapeCount": 0,
                "shortcutNames": [],
            }

        actions.append({
            "secondsFromStart": phrase_end_times[phrase_index],
            "kind": kind,
            "applicationName": "Blender",
            "applicationBundleIdentifier": "org.blenderfoundation.blender",
            "locationInDisplayPoints": location,
            "keystrokeSummary": keystroke_summary,
            "beforeFrameFileName": before_name,
            "afterFrameFileName": after_name,
        })

    recording = {
        "formatVersion": 1,
        "recordingIdentifier": str(uuid.uuid4()),
        "provenance": {
            "kind": "syntheticRecording",
            "note": f"real blender window exports, scripted changes, written narration spoken by the say voice, transcript from {narration_source}.",
        },
        "teacherName": TEACHER_NAME,
        "startedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "durationInSeconds": phrase_end_times[-1],
        # The frame is the whole "display" here, because that's all that exists.
        "setup": {
            "displaySizeInPoints": {"x": 0, "y": 0, "width": window_in_points["width"], "height": window_in_points["height"]},
            "appearanceName": "dark",
        },
        "actions": actions,
        "narrationSegments": segments,
        "secureGaps": [],
        "narrationAudioFileName": narration_file_name,
    }

    with open(os.path.join(recording_directory, "recording.json"), "w") as recording_file:
        json.dump(recording, recording_file, indent=1)


def build_replay_manifest(frames_directory, follow_window_rect, manifest_path, step_count):
    """Pairs up follower screens with the compiled steps. The task has one step
    per state change, so a compile that split or merged steps can't be judged,
    and that's reported as a failure rather than guessed at."""
    if step_count != len(FOLLOW_GROUND_TRUTH_TEXT):
        raise RuntimeError(f"compiled {step_count} steps, but the follower walk has {len(FOLLOW_GROUND_TRUTH_TEXT)}")

    manifest_steps = []
    for step_index in range(step_count):
        ground_truth_rect = None
        if FOLLOW_GROUND_TRUTH_TEXT[step_index] is None:
            tab_rect = output_tab_rect(frames_directory, "follow")
            ground_truth_rect = {
                "x": follow_window_rect["x"] + tab_rect["x"],
                "y": follow_window_rect["y"] + tab_rect["y"],
                "width": tab_rect["width"],
                "height": tab_rect["height"],
            }

        manifest_steps.append({
            "beforeImagePath": os.path.join(frames_directory, f"follow-{STATE_NAMES[step_index]}.png"),
            "afterImagePath": os.path.join(frames_directory, f"follow-{STATE_NAMES[step_index + 1]}.png"),
            "imageRectInDisplayPoints": follow_window_rect,
            "groundTruthText": FOLLOW_GROUND_TRUTH_TEXT[step_index],
            "groundTruthRectInDisplayPoints": ground_truth_rect,
            # The screen changed, but not the way this step asks. Step 1 has no
            # earlier state, so it gets the last one, which is the same
            # workspace with a different value.
            "wrongChangeImagePath": os.path.join(
                frames_directory,
                f"follow-{STATE_NAMES[step_index - 1 if step_index > 0 else len(STATE_NAMES) - 1]}.png",
            ),
        })

    with open(manifest_path, "w") as manifest_file:
        json.dump({
            "setupDescription": (
                f"follower: {follow_window_rect['width']}x{follow_window_rect['height']} window, light theme, "
                "suzanne and a torus instead of the default cube, 480 frames instead of 250. "
                "teacher: 1100x720 window, dark theme, default cube."
            ),
            "steps": manifest_steps,
        }, manifest_file, indent=1)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", default=os.path.join(tempfile.gettempdir(), "clicky-synthetic-lesson"))
    parser.add_argument("--model", help="BrainModel value, defaults to the configured one")
    parser.add_argument("--fly", action="store_true", help="also fly the overlay to each point")
    parser.add_argument("--reuse-frames", action="store_true", help="keep the Blender frames from a previous run")
    arguments = parser.parse_args()

    output_directory = os.path.abspath(arguments.output)
    frames_directory = os.path.join(output_directory, "blender-frames")
    recording_directory = os.path.join(output_directory, "recording")
    lesson_path = os.path.join(output_directory, "synthetic-blender-lesson.clicky")
    manifest_path = os.path.join(output_directory, "replay-manifest.json")
    window_rects_path = os.path.join(output_directory, "window-rects.json")

    if not arguments.reuse_frames:
        shutil.rmtree(output_directory, ignore_errors=True)
        os.makedirs(frames_directory)

        log("taking the GUI lock for Blender...")
        take_gui_lock()
        try:
            log("walking the teacher's Blender (dark, 1100x720, default cube)...")
            teach_window = walk_blender_states("teach", TEACH_WINDOW_GEOMETRY, frames_directory)
            log(f"  window at {teach_window}")
            time.sleep(1)
            log("walking the follower's Blender (light, 1400x840, suzanne and a torus)...")
            follow_window = walk_blender_states("follow", FOLLOW_WINDOW_GEOMETRY, frames_directory)
            log(f"  window at {follow_window}")
        finally:
            release_gui_lock()

        with open(window_rects_path, "w") as window_rects_file:
            json.dump({"teach": teach_window, "follow": follow_window}, window_rects_file, indent=1)
    else:
        shutil.rmtree(recording_directory, ignore_errors=True)

    with open(window_rects_path) as window_rects_file:
        window_rects = json.load(window_rects_file)

    assert_frames_show_their_states("teach", frames_directory)
    assert_frames_show_their_states("follow", frames_directory)

    log("building the synthetic recording...")
    build_recording(frames_directory, recording_directory, window_rects["teach"])

    model_arguments = ["--model", arguments.model] if arguments.model else []

    log("compiling with the real model...")
    compile_result = run_headless(
        "--headless-compile-recording", recording_directory,
        "--lesson-output", lesson_path, *model_arguments,
    )
    with open(os.path.join(output_directory, "compile-result.json"), "w") as compile_result_file:
        json.dump(compile_result, compile_result_file, indent=1)
    log(json.dumps({key: compile_result.get(key) for key in ("status", "error", "stepCount", "archiveSizeInBytes", "compileSeconds")}))
    if compile_result.get("status") != "ok":
        sys.exit(1)

    build_replay_manifest(frames_directory, window_rects["follow"], manifest_path, compile_result["stepCount"])

    log("following on the different setup...")
    fly_arguments = ["--fly"] if arguments.fly else []
    replay_result = run_headless(
        "--headless-follow-replay", lesson_path,
        "--replay-manifest", manifest_path, "--save-replay-cost", *model_arguments, *fly_arguments,
    )
    with open(os.path.join(output_directory, "replay-result.json"), "w") as replay_result_file:
        json.dump(replay_result, replay_result_file, indent=1)

    log(json.dumps({key: replay_result.get(key) for key in (
        "status", "error", "failedStepCount", "unverifiedStepCount", "modelCallCount", "totalCostInUSDEstimated",
        "controlCallCount", "controlCostInUSDEstimatedExcludedFromTotal",
    )}))
    for step in replay_result.get("steps", []):
        log(
            f"  step {step.get('stepNumber')}: {step.get('intent')}\n"
            f"    landed: {step.get('landedOnTarget')}  check before: {step.get('checkBeforeAction', {}).get('passed')}"
            f" after: {step.get('checkAfterAction', {}).get('passed')} ({step.get('checkAfterAction', {}).get('method')})"
            f"  wrong change: {step.get('checkAfterWrongChange', {}).get('passed')}"
            f"  changed tiles: {step.get('changedTilesBeforeToAfter')}  adapted: {step.get('adaptedLine')}"
        )

    sys.exit(0 if replay_result.get("status") == "ok" else 1)


if __name__ == "__main__":
    main()
