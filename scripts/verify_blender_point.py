#!/usr/bin/env python3
"""Checks that [POINT:...] lands on real elements of a live Blender window.

For each target this asks the Brain through the app's headless path, then
judges the answer against ground truth that doesn't come from the model:
Vision OCR of the screenshot for text, and Blender's own layout for editors.

If Clicky has Screen Recording, the app's real ScreenCaptureKit path supplies
the image. If not, Blender's export of its own window is placed where the
window server says the window is, and the result records `captureSource:
fixture` so nobody mistakes that run for a real capture.

    scripts/verify_blender_point.py                 maximized window, all targets
    scripts/verify_blender_point.py --window 150,120,1100,720
    scripts/verify_blender_point.py --only Modeling --model codex --runs 3
"""

import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

SCRIPTS_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
HEADLESS_SCRIPT = os.path.join(SCRIPTS_DIRECTORY, "headless.sh")
GROUND_TRUTH_SCRIPT = os.path.join(SCRIPTS_DIRECTORY, "blender_ground_truth.py")
BLENDER_EXECUTABLE = "/Applications/Blender.app/Contents/MacOS/Blender"
BLENDER_STARTUP_TIMEOUT_SECONDS = 40

# Each target is judged on text position, or on an editor's rectangle.
TEXT_TARGETS = [
    ("how do i switch to the modeling workspace? point at it.", "Modeling"),
    ("where do i open the scripting workspace? point at it.", "Scripting"),
    ("where is the file menu? point at it.", "File"),
    ("which menu in the 3d viewport header adds a new object? point at it.", "Add"),
    ("point at the camera in the outliner list.", "Camera"),
    ("where are the scale values for this object? point at the scale x label.", "Scale"),
    ("where do i set the last frame of the animation? point at the end frame label.", "End"),
]
EDITOR_TARGETS = [
    ("point at the timeline editor at the bottom of the window.", "DOPESHEET_EDITOR", None),
    ("point at the outliner panel.", "OUTLINER", None),
    ("point at the column of property tab icons.", "PROPERTIES", "NAVIGATION_BAR"),
]


def run_headless(*arguments):
    completed = subprocess.run(
        [HEADLESS_SCRIPT, *arguments], capture_output=True, text=True
    )
    if not completed.stdout.strip():
        raise RuntimeError(f"headless produced no JSON: {completed.stderr}")
    return json.loads(completed.stdout)


def wait_for_file(path, blender_process):
    deadline = time.time() + BLENDER_STARTUP_TIMEOUT_SECONDS
    while time.time() < deadline:
        if os.path.exists(path):
            return
        if blender_process.poll() is not None:
            raise RuntimeError("Blender exited before exporting its ground truth")
        time.sleep(0.25)
    raise RuntimeError("timed out waiting for Blender to export its ground truth")


def blender_content_rect(ground_truth):
    """Where Blender's content sits on the display. The window server's bounds
    include the title bar, so the content is the bottom part of that frame."""
    window_bounds = run_headless("--headless-window-bounds", "Blender")
    bounds = window_bounds["windowBoundsTopLeftOrigin"][0]
    content_width = ground_truth["windowInPoints"]["width"]
    content_height = ground_truth["windowInPoints"]["height"]
    return {
        "x": bounds["x"],
        "y": bounds["y"] + bounds["height"] - content_height,
        "width": content_width,
        "height": content_height,
    }


def to_display_rect(window_rect, content_rect):
    return ",".join(str(value) for value in (
        content_rect["x"] + window_rect["x"],
        content_rect["y"] + window_rect["y"],
        window_rect["width"],
        window_rect["height"],
    ))


def build_targets(ground_truth, content_rect, only_filter):
    targets = [
        {"name": text, "prompt": prompt, "verifyArguments": ["--verify-text", text]}
        for prompt, text in TEXT_TARGETS
    ]
    for prompt, area_type, region_type in EDITOR_TARGETS:
        area = ground_truth["areas"][area_type]
        rect = area["regions"][region_type] if region_type else area["rect"]
        targets.append({
            "name": region_type or area_type,
            "prompt": prompt,
            "verifyArguments": ["--verify-rect", to_display_rect(rect, content_rect)],
        })
    if only_filter:
        targets = [target for target in targets if only_filter.lower() in target["name"].lower()]
    return targets


def describe_miss(result):
    verification = result.get("textVerification") or result.get("rectVerification") or {}
    return verification.get("error") or f"pointed at {result.get('pointInDisplayPoints')}, expected {verification}"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--window", help="Blender window as x,y,width,height (Blender's bottom-left origin)")
    parser.add_argument("--model", help="BrainModel value, defaults to the configured one")
    parser.add_argument("--only", help="only targets whose name contains this")
    parser.add_argument("--runs", type=int, default=1, help="repeat each target this many times")
    parser.add_argument("--max-dimension", help="fixture image size, for comparing resolutions")
    parser.add_argument("--fly", action="store_true", help="also fly the overlay to each point")
    parser.add_argument("--keep", action="store_true", help="keep the output directory")
    arguments = parser.parse_args()

    output_directory = tempfile.mkdtemp(prefix="clicky-blender-")
    blender_command = [BLENDER_EXECUTABLE, "--factory-startup"]
    if arguments.window:
        blender_command += ["--window-geometry", *arguments.window.split(",")]
    blender_command += ["--python", GROUND_TRUTH_SCRIPT, "--", output_directory]

    blender_process = subprocess.Popen(
        blender_command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

    results = []
    try:
        ground_truth_path = os.path.join(output_directory, "ground_truth.json")
        wait_for_file(ground_truth_path, blender_process)
        with open(ground_truth_path) as ground_truth_file:
            ground_truth = json.load(ground_truth_file)

        content_rect = blender_content_rect(ground_truth)
        print(f"Blender content on display: {content_rect}")

        fixture_arguments = [
            "--image", os.path.join(output_directory, "blender_window.png"),
            "--image-rect", to_display_rect({"x": 0, "y": 0, "width": content_rect["width"], "height": content_rect["height"]}, content_rect),
        ]
        if arguments.model:
            fixture_arguments += ["--model", arguments.model]
        if arguments.max_dimension:
            fixture_arguments += ["--image-only", "--max-dimension", arguments.max_dimension]
        if arguments.fly:
            fixture_arguments.append("--fly")

        for target in build_targets(ground_truth, content_rect, arguments.only):
            for _ in range(arguments.runs):
                result = run_headless(
                    "--headless-point", "--prompt", target["prompt"],
                    *target["verifyArguments"], *fixture_arguments,
                )
                result["targetName"] = target["name"]
                results.append(result)

                time_to_first_text = (result.get("usage") or {}).get("timeToFirstTextInSeconds")
                status_label = {"ok": "PASS", "unverified": "UNVERIFIED"}.get(result.get("status"), "MISS")
                print(
                    f"{status_label:<10}  {target['name']:<18}"
                    f" source={result.get('captureSource')}"
                    f" first_text={time_to_first_text if time_to_first_text is None else round(time_to_first_text, 2)}s"
                    f" point={result.get('pointInDisplayPoints')}"
                )
                if status_label != "PASS":
                    print(f"      {describe_miss(result)}")
    finally:
        with open(os.path.join(output_directory, "quit"), "w"):
            pass
        try:
            blender_process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            blender_process.terminate()

    passed_count = sum(1 for result in results if result.get("status") == "ok")
    first_text_times = [
        result["usage"]["timeToFirstTextInSeconds"]
        for result in results
        if (result.get("usage") or {}).get("timeToFirstTextInSeconds") is not None
    ]

    unverified_count = sum(1 for result in results if result.get("status") == "unverified")
    missed_count = len(results) - passed_count - unverified_count
    print(f"\n{passed_count} landed on target, {missed_count} missed, {unverified_count} unverified (no OCR match) of {len(results)}")
    if first_text_times:
        print(
            f"time to first text: median {statistics.median(first_text_times):.2f}s,"
            f" min {min(first_text_times):.2f}s, max {max(first_text_times):.2f}s"
        )
    capture_sources = sorted({str(result.get("captureSource")) for result in results})
    print(f"capture source: {', '.join(capture_sources)}")

    with open(os.path.join(output_directory, "results.json"), "w") as results_file:
        json.dump(results, results_file, indent=1)

    if arguments.keep:
        print(f"output kept in {output_directory}")
    else:
        shutil.rmtree(output_directory, ignore_errors=True)

    return 0 if results and missed_count == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
