# Runs inside Blender. Exports what a pointing check needs from a live UI:
# a screenshot of Blender's own window and the layout Blender says it has.
#
# Blender reads its own framebuffer, so this works with no Screen Recording
# permission. Started by scripts/verify_blender_point.py. Takes the output
# directory after `--`. Quits once that directory contains a file named "quit".

import json
import os
import sys

import bpy

OUTPUT_DIRECTORY = sys.argv[sys.argv.index("--") + 1]
SCREENSHOT_PATH = os.path.join(OUTPUT_DIRECTORY, "blender_window.png")
GROUND_TRUTH_PATH = os.path.join(OUTPUT_DIRECTORY, "ground_truth.json")
QUIT_REQUEST_PATH = os.path.join(OUTPUT_DIRECTORY, "quit")

# Factory startup always shows the splash, which would cover the UI under test.
bpy.context.preferences.view.show_splash = False


def rect_in_window_points(x, y, width, height, window_height_in_pixels, pixels_per_point):
    """Blender regions are bottom-left origin in pixels. The rest of the check
    uses top-left origin in points."""
    return {
        "x": x / pixels_per_point,
        "y": (window_height_in_pixels - (y + height)) / pixels_per_point,
        "width": width / pixels_per_point,
        "height": height / pixels_per_point,
    }


def export_ground_truth():
    window = bpy.context.window_manager.windows[0]
    pixels_per_point = bpy.context.preferences.system.pixel_size
    window_height_in_pixels = window.height * pixels_per_point

    areas = {}
    for area in window.screen.areas:
        regions = {
            region.type: rect_in_window_points(
                region.x, region.y, region.width, region.height,
                window_height_in_pixels, pixels_per_point,
            )
            for region in area.regions
        }
        areas[area.type] = {
            "rect": rect_in_window_points(
                area.x, area.y, area.width, area.height,
                window_height_in_pixels, pixels_per_point,
            ),
            "regions": regions,
        }

    with bpy.context.temp_override(window=window, area=window.screen.areas[0]):
        bpy.ops.screen.screenshot(filepath=SCREENSHOT_PATH, check_existing=False)

    # Written last: its appearance tells the caller the screenshot is ready.
    with open(GROUND_TRUTH_PATH, "w") as ground_truth_file:
        json.dump({
            "windowInPoints": {"width": window.width, "height": window.height},
            "pixelsPerPoint": pixels_per_point,
            "areas": areas,
        }, ground_truth_file, indent=1)

    bpy.app.timers.register(quit_when_requested, first_interval=0.25)


def quit_when_requested():
    if os.path.exists(QUIT_REQUEST_PATH):
        bpy.ops.wm.quit_blender()
        return None
    return 0.25


# Gives the first redraw time to finish before the framebuffer is read.
bpy.app.timers.register(export_ground_truth, first_interval=4.0)
