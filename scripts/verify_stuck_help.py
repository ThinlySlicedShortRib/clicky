#!/usr/bin/env python3
"""Judges the real Stuck help prompt against a real Blender window.

Opens the demo scene, then sends the exact prompt a yes sends, with a real
receipt line list, through the app's headless path. Ground truth doesn't come
from the model: Vision OCR finds the "Object Mode" dropdown in Blender's own
screenshot. A reply passes only if the point lands on that dropdown.

Uses a real capture if Clicky has Screen Recording, and otherwise Blender's
export of its own window, and records which in `captureSource`.

    scripts/verify_stuck_help.py --runs 10
    scripts/verify_stuck_help.py --model ollama:qwen3.6:35b-a3b --runs 5
    scripts/verify_stuck_help.py --keep-frame /abs/out.png --runs 0
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
sys.path.insert(0, SCRIPTS_DIRECTORY)

from verify_blender_point import (  # noqa: E402
    BLENDER_EXECUTABLE,
    blender_content_rect,
    run_headless,
    to_display_rect,
    wait_for_file,
)

SCENE_SCRIPT = os.path.join(SCRIPTS_DIRECTORY, "blender_stuck_scene.py")
TARGET_TEXT = "Object Mode"
RECEIPT_LINES = [
    "5 undos in 31s",
    "7 other key presses, not which keys",
    "11 clicks across 2 screen areas",
    "cursor moved for 26 seconds across 3 screen areas (2840pt)",
]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", help="BrainModel value, defaults to the configured one")
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--window", default="0,70,1512,860", help="Blender window as x,y,width,height")
    parser.add_argument("--keep-frame", help="save Blender's exported window here")
    parser.add_argument("--json", help="write every result here")
    parser.add_argument("--rect-file", help="write the content rectangle here")
    arguments = parser.parse_args()

    output_directory = tempfile.mkdtemp(prefix="clicky-stuck-help-")
    blender_process = subprocess.Popen(
        [
            BLENDER_EXECUTABLE, "--factory-startup",
            "--window-geometry", *arguments.window.split(","),
            "--python", SCENE_SCRIPT, "--", output_directory,
        ],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )

    results = []
    try:
        ground_truth_path = os.path.join(output_directory, "ground_truth.json")
        wait_for_file(ground_truth_path, blender_process)
        with open(ground_truth_path) as ground_truth_file:
            ground_truth = json.load(ground_truth_file)

        content_rect = blender_content_rect(ground_truth)
        image_rect = to_display_rect(
            {"x": 0, "y": 0, "width": content_rect["width"], "height": content_rect["height"]},
            content_rect,
        )
        frame_path = os.path.join(output_directory, "blender_window.png")
        print(f"Blender content on display: {content_rect}")

        if arguments.keep_frame:
            shutil.copy(frame_path, arguments.keep_frame)
        if arguments.rect_file:
            with open(arguments.rect_file, "w") as rect_file:
                rect_file.write(image_rect)

        headless_arguments = [
            "--headless-point", "--stuck-prompt",
            "--receipt-lines", "|".join(RECEIPT_LINES),
            "--image", frame_path, "--image-rect", image_rect,
            "--verify-text", TARGET_TEXT,
        ]
        if arguments.model:
            headless_arguments += ["--model", arguments.model]

        for run_index in range(arguments.runs):
            result = run_headless(*headless_arguments)
            results.append(result)
            usage = result.get("usage") or {}
            print(
                f"{result.get('status'):<20} first_text={usage.get('timeToFirstTextInSeconds')}"
                f" total={usage.get('totalDurationInSeconds')}"
                f" point={result.get('pointInDisplayPoints')} label={result.get('elementLabel')}"
            )
            print(f"    {result.get('spokenText')}")
    finally:
        with open(os.path.join(output_directory, "quit"), "w"):
            pass
        try:
            blender_process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            blender_process.terminate()

    if results:
        passed_count = sum(1 for result in results if result.get("status") == "ok")
        first_text_times = [
            result["usage"]["timeToFirstTextInSeconds"]
            for result in results
            if (result.get("usage") or {}).get("timeToFirstTextInSeconds") is not None
        ]
        total_times = [
            result["usage"]["totalDurationInSeconds"]
            for result in results
            if (result.get("usage") or {}).get("totalDurationInSeconds") is not None
        ]
        print(f"\n{passed_count} of {len(results)} pointed at {TARGET_TEXT!r}")
        if first_text_times:
            print(f"first text: median {statistics.median(first_text_times):.2f}s, min {min(first_text_times):.2f}s, max {max(first_text_times):.2f}s")
            print(f"total: median {statistics.median(total_times):.2f}s, min {min(total_times):.2f}s, max {max(total_times):.2f}s")
        print(f"capture source: {', '.join(sorted({str(result.get('captureSource')) for result in results}))}")

    if arguments.json:
        with open(arguments.json, "w") as results_file:
            json.dump(results, results_file, indent=1)

    shutil.rmtree(output_directory, ignore_errors=True)
    return 0 if arguments.runs == 0 or (results and passed_count == len(results)) else 1


if __name__ == "__main__":
    sys.exit(main())
