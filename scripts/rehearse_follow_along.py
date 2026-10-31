#!/usr/bin/env python3
"""TEST ONLY. Plays a whole Follow Along lesson against real Blender, with no
macOS permissions and no human.

Real: Blender 5.2, the saved lesson, every model call, the app's runner,
gating, mapping and cost figures. Not real: Blender exports its own window in
place of ScreenCaptureKit, nobody hears the voice when --mute is used, and a
script stands in for the student.

The student is deliberately dumb. It knows nothing about Blender and has no
coordinates of its own for the lesson. It does what each step's action says, at
exactly the point Clicky flew to. If Clicky points at the wrong thing, the
click misses and the lesson stalls, so a pass means the pointing really worked.
Blender's own state is read after each passed step as a ground truth that
doesn't come from any model.

Run it through the GUI lock:

    scripts/with-gui-lock.sh /usr/bin/python3 -I scripts/rehearse_follow_along.py \\
        --video _deRNqDcwRk --scenario full --evidence /abs/dir
"""

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

SCRIPTS_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
HEADLESS_SCRIPT = os.path.join(SCRIPTS_DIRECTORY, "headless.sh")
BRIDGE_SCRIPT = os.path.join(SCRIPTS_DIRECTORY, "follow_along_blender_bridge.py")
BLENDER_EXECUTABLE = "/Applications/Blender.app/Contents/MacOS/Blender"
FFMPEG_EXECUTABLE = "/opt/homebrew/bin/ffmpeg"

BLENDER_STARTUP_TIMEOUT_SECONDS = 60
STEP_STALL_TIMEOUT_SECONDS = 150
SECONDS_BEFORE_ACTING = 1.2

# Only used to make a deliberate mistake. Everything else the student does
# comes from Clicky. Window points, top-left origin.
LAYOUT_TAB_IN_WINDOW_POINTS = (279, 13)

DIGIT_KEY_NAMES = {
    "0": "ZERO", "1": "ONE", "2": "TWO", "3": "THREE", "4": "FOUR",
    "5": "FIVE", "6": "SIX", "7": "SEVEN", "8": "EIGHT", "9": "NINE",
    ".": "PERIOD", "-": "MINUS",
}

# Models name keys the way a person would. Blender's event names are shorter.
BLENDER_KEY_NAMES = {
    "ESCAPE": "ESC", "RETURN": "RET", "ENTER": "RET", "DELETE": "DEL",
    "BACKSPACE": "BACK_SPACE", "SPACEBAR": "SPACE",
}

# What goes wrong during a full run, by the step it happens on.
FULL_SCENARIO = {
    "mistake_on_step": "step-2",
    "question_on_step": "step-5",
    "question_text": "what does this do?",
    "go_back_on_step": "step-10",
    "go_back_text": "wait, go back",
    "done_text": "okay i did it",
}


class Rehearsal:
    def __init__(self, arguments, bridge_directory):
        self.arguments = arguments
        self.bridge_directory = bridge_directory
        self.scenario = FULL_SCENARIO if arguments.scenario == "full" else {}
        self.content_rect = None
        self.command_number = 0
        self.say_number = 0
        self.state_number = 0
        self.events_read = 0
        self.events = []
        self.step_states = {}
        self.pointed_frames = {}
        self.last_action_event = None
        self.current_step = None
        self.revisiting_step = None
        self.last_progress_time = time.time()
        self.notes = []
        self.mistake_made = False
        self.question_asked = False
        self.went_back = False

    # MARK: Talking to Blender

    def bridge_path(self, name):
        return os.path.join(self.bridge_directory, name)

    def wait_for_bridge_file(self, name, timeout_seconds=30):
        deadline = time.time() + timeout_seconds
        while time.time() < deadline:
            if os.path.exists(self.bridge_path(name)):
                return True
            time.sleep(0.05)
        return False

    def send_operations(self, operations):
        self.command_number += 1
        name = f"command-{self.command_number}"
        temporary_path = self.bridge_path(f"{name}.tmp")
        with open(temporary_path, "w") as command_file:
            json.dump(operations, command_file)
        os.rename(temporary_path, self.bridge_path(f"{name}.json"))
        if not self.wait_for_bridge_file(f"{name}.done"):
            self.notes.append(f"bridge did not finish {name}")

    def read_blender_state(self):
        self.state_number += 1
        name = f"state-{self.state_number}"
        open(self.bridge_path(f"{name}.request"), "w").close()
        if not self.wait_for_bridge_file(f"{name}.json"):
            return None
        time.sleep(0.05)
        with open(self.bridge_path(f"{name}.json")) as state_file:
            return json.load(state_file)

    def say(self, text):
        self.say_number += 1
        temporary_path = self.bridge_path(f"say-{self.say_number}.tmp")
        with open(temporary_path, "w") as say_file:
            say_file.write(text)
        os.rename(temporary_path, self.bridge_path(f"say-{self.say_number}.txt"))
        print(f"  student says: {text}")

    # MARK: The Student's Hands

    def to_window_points(self, display_point):
        return (
            display_point["x"] - self.content_rect["x"],
            display_point["y"] - self.content_rect["y"],
        )

    def click(self, display_point):
        x, y = self.to_window_points(display_point)
        self.click_window_point(x, y)

    @staticmethod
    def hover_operations(x, y):
        """Blender only arms a button when the mouse moves over it after the
        redraw from arriving, so a second small move is needed before a press.
        A real hand does this without trying."""
        return [
            {"op": "move", "x": x - 3, "y": y},
            {"op": "move", "x": x, "y": y},
            {"op": "wait", "seconds": 0.8},
            {"op": "move", "x": x + 1, "y": y},
            {"op": "wait", "seconds": 0.5},
        ]

    def click_window_point(self, x, y):
        self.send_operations(self.hover_operations(x, y) + [
            {"op": "button", "value": "PRESS", "x": x, "y": y},
            {"op": "wait", "seconds": 0.2},
            {"op": "button", "value": "RELEASE", "x": x, "y": y},
        ])

    def drag(self, start_point, end_point):
        start_x, start_y = self.to_window_points(start_point)
        end_x, end_y = self.to_window_points(end_point)
        path_steps = 8
        operations = self.hover_operations(start_x, start_y) + [
            {"op": "button", "value": "PRESS", "x": start_x, "y": start_y},
        ]
        for path_step in range(1, path_steps + 1):
            progress = path_step / path_steps
            operations.append({
                "op": "move",
                "x": start_x + (end_x - start_x) * progress,
                "y": start_y + (end_y - start_y) * progress,
            })
        operations.append({"op": "button", "value": "RELEASE", "x": end_x, "y": end_y})
        self.send_operations(operations)

    def type_value(self, display_point, value):
        x, y = self.to_window_points(display_point)
        operations = self.hover_operations(x, y) + [
            {"op": "button", "value": "PRESS", "x": x, "y": y},
            {"op": "button", "value": "RELEASE", "x": x, "y": y},
            {"op": "button", "value": "PRESS", "x": x, "y": y},
            {"op": "button", "value": "RELEASE", "x": x, "y": y},
            {"op": "wait", "seconds": 0.5},
            {"op": "key", "key": "A", "ctrl": True},
        ]
        for character in value:
            operations.append({"op": "key", "key": DIGIT_KEY_NAMES[character], "unicode": character})
        operations.append({"op": "key", "key": "RET"})
        self.send_operations(operations)

    def press_key(self, key_name):
        normalized_key_name = key_name.strip().upper()
        self.send_operations([{"op": "key", "key": BLENDER_KEY_NAMES.get(normalized_key_name, normalized_key_name)}])

    def perform(self, event):
        """Does what the step says, where Clicky pointed. Nothing else."""
        display_point = event.get("displayPoint")
        action_kind = event.get("actionKind")
        if not display_point:
            return

        time.sleep(SECONDS_BEFORE_ACTING)
        action_label = "prerequisite" if event.get("isPrerequisite") else action_kind
        print(f"  student acts: {action_label} at {display_point}")

        if event.get("isPrerequisite") and event.get("prerequisiteKey"):
            x, y = self.to_window_points(display_point)
            self.send_operations(self.hover_operations(x, y))
            self.press_key(event["prerequisiteKey"])
        elif event.get("isPrerequisite") or action_kind == "click":
            self.click(display_point)
        elif action_kind == "drag" and event.get("dragDestinationDisplayPoint"):
            self.drag(display_point, event["dragDestinationDisplayPoint"])
        elif action_kind == "type_value" and event.get("valueToType"):
            self.type_value(display_point, str(event["valueToType"]))
        elif action_kind == "press_key" and event.get("keyToPress"):
            self.press_key(event["keyToPress"])

    # MARK: Following the Lesson

    def read_new_events(self):
        events_path = self.bridge_path("events.jsonl")
        if not os.path.exists(events_path):
            return []
        with open(events_path) as events_file:
            lines = events_file.readlines()
        new_lines = lines[self.events_read:]
        complete_lines = [line for line in new_lines if line.endswith("\n")]
        self.events_read += len(complete_lines)
        new_events = [json.loads(line) for line in complete_lines]
        self.events.extend(new_events)
        return new_events

    def annotate_latest_frame(self, event, output_name):
        """Marks where the cursor landed on the frame the model actually saw."""
        if not self.arguments.evidence:
            return
        captures = sorted(
            glob.glob(self.bridge_path("capture-*.png")),
            key=lambda path: int(re.search(r"capture-(\d+)", path).group(1)),
        )
        if not captures:
            return

        x, y = self.to_window_points(event["displayPoint"])
        pixels_per_point = 2
        box_half_size = 16 * pixels_per_point
        center_x = int(x * pixels_per_point)
        center_y = int(y * pixels_per_point)

        output_path = os.path.join(self.arguments.evidence, "images", output_name)
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        filter_text = (
            f"drawbox=x={center_x - box_half_size}:y={center_y - box_half_size}"
            f":w={box_half_size * 2}:h={box_half_size * 2}:color=0x2F7BFF@0.95:t=5,"
            f"scale=1512:-2"
        )
        subprocess.run(
            [FFMPEG_EXECUTABLE, "-y", "-loglevel", "error", "-i", captures[-1], "-vf", filter_text, output_path],
            check=False,
        )

    def on_event(self, event):
        name = event["event"]
        self.last_progress_time = time.time()

        if name == "step_started":
            self.current_step = event["stepIdentifier"]
            self.revisiting_step = self.current_step if event.get("isRevisit") else None
            print(f"\n[{event['secondsIntoLesson']:>6}s] {event['stepIdentifier']}: {event['title']}" + (" (revisit)" if event.get("isRevisit") else ""))

        elif name == "step_announced":
            print(f"  clicky says: {event.get('spokenLine')}")
            if not event.get("pointed"):
                print("  clicky did not point")
                return
            print(f"  clicky points: {event.get('label')} at {event.get('displayPoint')}")
            self.annotate_latest_frame(event, f"{event['stepIdentifier']}-pointed.png")
            self.on_step_announced(event)

        elif name == "interface_adapted":
            print(f"  ** interface differs: {event['whatChanged']}")

        elif name == "success_checked":
            print(f"  check: {event['state']} ({event.get('evidence')}) ${event['usage'].get('costInUSD')}")

        elif name == "step_passed":
            print(f"  passed: {event.get('evidence')}")
            self.step_states[event["stepIdentifier"]] = self.read_blender_state()
            print(f"  blender says: {self.step_states[event['stepIdentifier']]}")

        elif name == "off_track":
            print(f"  off track ({event['evidence']}): {event['recoveryLine']}")

        elif name == "question_answered":
            print(f"  clicky answers: {event['answer']}")
            if self.last_action_event:
                self.perform(self.last_action_event)

        elif name == "location_reused":
            print(f"  location reused from cache: {event.get('label')}")

        elif name == "step_already_done":
            print(f"  already done, clicky says: {event.get('spokenLine')}")

        elif name in ("target_located", "screen_change_gated_through", "voice_command", "lesson_started", "lesson_finished"):
            pass

        else:
            print(f"  {name}: {event}")

    def on_step_announced(self, event):
        step_identifier = event["stepIdentifier"]

        if self.revisiting_step == step_identifier:
            # The work is already on screen. The student only confirms it.
            time.sleep(SECONDS_BEFORE_ACTING)
            self.say(self.scenario["done_text"])
            return

        self.last_action_event = event

        if self.scenario.get("mistake_on_step") == step_identifier and not self.mistake_made:
            self.mistake_made = True
            print("  student wanders off to the Layout workspace on purpose")
            self.click_window_point(*LAYOUT_TAB_IN_WINDOW_POINTS)
            return

        if self.scenario.get("question_on_step") == step_identifier and not self.question_asked:
            self.question_asked = True
            time.sleep(SECONDS_BEFORE_ACTING)
            self.say(self.scenario["question_text"])
            return

        if self.scenario.get("go_back_on_step") == step_identifier and not self.went_back:
            self.went_back = True
            time.sleep(SECONDS_BEFORE_ACTING)
            self.say(self.scenario["go_back_text"])
            return

        self.perform(event)

    def follow_until_finished(self, app_process):
        while True:
            for event in self.read_new_events():
                self.on_event(event)
                if event["event"] == "lesson_finished":
                    return True

            if app_process.poll() is not None:
                for event in self.read_new_events():
                    self.on_event(event)
                return False

            if time.time() - self.last_progress_time > STEP_STALL_TIMEOUT_SECONDS:
                self.notes.append(f"stalled on {self.current_step}")
                print(f"\nSTALLED on {self.current_step}: stopping the lesson")
                self.say("stop the lesson")
                self.last_progress_time = time.time() + 60

            time.sleep(0.2)


def find_content_rect(ground_truth):
    completed = subprocess.run(
        [HEADLESS_SCRIPT, "--headless-window-bounds", "Blender"], capture_output=True, text=True
    )
    bounds = json.loads(completed.stdout)["windowBoundsTopLeftOrigin"][0]
    content_height = ground_truth["windowInPoints"]["height"]
    return {
        "x": bounds["x"],
        "y": bounds["y"] + bounds["height"] - content_height,
        "width": ground_truth["windowInPoints"]["width"],
        "height": content_height,
    }


def write_transcript(rehearsal, evidence_directory, app_result, ground_truth):
    lines = [
        "# Follow Along rehearsal transcript",
        "",
        "Generated by `scripts/rehearse_follow_along.py` from the app's own event log.",
        f"Blender {ground_truth.get('blenderVersion')}. Capture source: rehearsal, Blender's own window export, **not ScreenCaptureKit**. The student is a script that clicks where Clicky pointed.",
        "",
    ]
    for event in rehearsal.events:
        name = event["event"]
        time_label = f"`{event.get('secondsIntoLesson', 0):>6.1f}s`"
        if name == "step_started":
            lines += ["", f"### {event['stepIdentifier']}: {event['title']}" + (" (going back)" if event.get("isRevisit") else "")]
        elif name == "step_announced":
            lines.append(f"- {time_label} **clicky says:** {event.get('spokenLine')}")
            if event.get("pointed"):
                lines.append(f"- {time_label} clicky points at *{event.get('label')}* at {event.get('displayPoint')}, action `{event.get('actionKind')}`")
        elif name == "interface_adapted":
            lines.append(f"- {time_label} **interface differs from the video:** {event['whatChanged']}")
        elif name == "voice_command":
            lines.append(f"- {time_label} **student says:** \"{event['transcript']}\" → `{event['command']}`")
        elif name == "question_answered":
            lines.append(f"- {time_label} **clicky answers:** {event['answer']}")
        elif name == "off_track":
            lines.append(f"- {time_label} **off track:** {event['evidence']}. **clicky says:** {event['recoveryLine']}")
        elif name == "success_checked":
            usage = event["usage"]
            lines.append(f"- {time_label} check by {usage.get('model')}: `{event['state']}`, {event.get('evidence')} (${usage.get('costInUSD')} est)")
        elif name == "location_reused":
            lines.append(f"- {time_label} location reused from cache, no model call")
        elif name == "step_already_done":
            lines.append(f"- {time_label} **already done, clicky says:** {event.get('spokenLine') or 'you have already got this one'}")
        elif name == "step_passed":
            lines.append(f"- {time_label} **passed.** Blender's own state: `{json.dumps(rehearsal.step_states.get(event['stepIdentifier']))}`")
    lines += ["", "## Result", "", "```json", json.dumps(app_result, indent=1), "```", ""]
    if rehearsal.notes:
        lines += ["## Notes", ""] + [f"- {note}" for note in rehearsal.notes]

    with open(os.path.join(evidence_directory, "run-transcript.md"), "w") as transcript_file:
        transcript_file.write("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--video", required=True)
    parser.add_argument("--scenario", choices=["clean", "full"], default="clean")
    parser.add_argument("--mute", action="store_true", help="skip the real voice")
    parser.add_argument("--evidence", help="absolute directory for the transcript and images")
    parser.add_argument("--window", default="0,0,1512,900", help="Blender window: x,y,width,height, bottom-left origin")
    arguments = parser.parse_args()

    bridge_directory = tempfile.mkdtemp(prefix="clicky-rehearsal-")
    print(f"bridge: {bridge_directory}", flush=True)

    # Blender's file browser opens on the home folder, and that browser is on
    # screen in the Shading workspace. An empty home keeps private folder names
    # out of the images sent to the model and saved as evidence.
    neutral_home_directory = tempfile.mkdtemp(prefix="clicky-neutral-home-")

    blender_process = subprocess.Popen(
        [
            BLENDER_EXECUTABLE, "--factory-startup", "--enable-event-simulate",
            "--window-geometry", *arguments.window.split(","),
            "--python", BRIDGE_SCRIPT, "--", bridge_directory,
        ],
        stdout=open(os.path.join(bridge_directory, "blender.log"), "w"),
        stderr=subprocess.STDOUT,
        env={**os.environ, "HOME": neutral_home_directory},
    )

    rehearsal = Rehearsal(arguments, bridge_directory)
    app_result = {"status": "not started"}
    ground_truth = {}

    try:
        if not rehearsal.wait_for_bridge_file("ground_truth.json", BLENDER_STARTUP_TIMEOUT_SECONDS):
            raise RuntimeError("Blender's bridge never started")
        with open(rehearsal.bridge_path("ground_truth.json")) as ground_truth_file:
            ground_truth = json.load(ground_truth_file)

        rehearsal.content_rect = find_content_rect(ground_truth)
        print(f"Blender {ground_truth['blenderVersion']}, content on display: {rehearsal.content_rect}")

        content_rect_text = ",".join(str(rehearsal.content_rect[key]) for key in ("x", "y", "width", "height"))
        app_arguments = [
            HEADLESS_SCRIPT, "--headless-follow-along-rehearsal", bridge_directory,
            "--video", arguments.video,
            "--content-rect", content_rect_text,
        ]
        if arguments.mute:
            app_arguments.append("--mute")

        app_process = subprocess.Popen(app_arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        finished = rehearsal.follow_until_finished(app_process)
        app_output, _ = app_process.communicate(timeout=60)

        try:
            app_result = json.loads(app_output)
        except json.JSONDecodeError:
            app_result = {"status": "unparseable", "output": app_output}

        if arguments.evidence:
            final_frames = sorted(
                glob.glob(rehearsal.bridge_path("capture-*.png")),
                key=lambda path: int(re.search(r"capture-(\d+)", path).group(1)),
            )
            if final_frames:
                images_directory = os.path.join(arguments.evidence, "images")
                os.makedirs(images_directory, exist_ok=True)
                subprocess.run(
                    [FFMPEG_EXECUTABLE, "-y", "-loglevel", "error", "-i", final_frames[-1], "-vf", "scale=1512:-2",
                     os.path.join(images_directory, "final-blender-window.png")],
                    check=False,
                )

        final_state = rehearsal.read_blender_state()
        print(f"\nfinal blender state: {final_state}")
        print(f"app result: {app_result}")
    finally:
        open(rehearsal.bridge_path("quit"), "w").close()
        try:
            blender_process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            blender_process.terminate()

    bridge_error_path = rehearsal.bridge_path("bridge-error.txt")
    if os.path.exists(bridge_error_path):
        with open(bridge_error_path) as bridge_error_file:
            print(f"BRIDGE ERRORS:\n{bridge_error_file.read()}")

    if arguments.evidence:
        os.makedirs(arguments.evidence, exist_ok=True)
        write_transcript(rehearsal, arguments.evidence, app_result, ground_truth)
        for file_name in ("events.jsonl", "summary.json"):
            source_path = rehearsal.bridge_path(file_name)
            if os.path.exists(source_path):
                shutil.copy(source_path, os.path.join(arguments.evidence, file_name))
        with open(os.path.join(arguments.evidence, "blender-state-after-each-step.json"), "w") as states_file:
            json.dump(rehearsal.step_states, states_file, indent=1)

    shutil.rmtree(bridge_directory, ignore_errors=True)
    shutil.rmtree(neutral_home_directory, ignore_errors=True)
    return 0 if finished and app_result.get("status") == "ok" and not rehearsal.notes else 1


if __name__ == "__main__":
    sys.exit(main())
