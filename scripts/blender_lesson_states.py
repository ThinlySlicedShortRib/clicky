# Runs inside Blender. Walks Blender's real UI through a small task and exports
# the window after every state, for building a synthetic Show Me Once recording.
#
# Blender reads its own framebuffer, so this needs no Screen Recording
# permission. Nothing here is mocked: each image is Blender's real window after
# the state really changed. What's synthetic is that a script made the change
# rather than a person clicking. Started by scripts/make-synthetic-lesson.py.
#
# Arguments after `--`: output directory, then "teach" or "follow".

import json
import os
import sys

import bpy

ARGUMENTS = sys.argv[sys.argv.index("--") + 1:]
OUTPUT_DIRECTORY = ARGUMENTS[0]
SETUP_NAME = ARGUMENTS[1]

REDRAW_WAIT_SECONDS = 1.5

bpy.context.preferences.view.show_splash = False
# Factory startup must not write the light theme into the user's real prefs.
bpy.context.preferences.use_preferences_save = False


def properties_area():
    window = bpy.context.window_manager.windows[0]
    return next(area for area in window.screen.areas if area.type == "PROPERTIES")


def properties_tab():
    return properties_area().spaces.active.context


def set_workspace(workspace_name):
    bpy.context.window_manager.windows[0].workspace = bpy.data.workspaces[workspace_name]


def set_output_tab():
    properties_area().spaces.active.context = "OUTPUT"


def set_frame_end():
    bpy.context.scene.frame_end = 120


def prepare_follower_setup():
    """Makes the follower's setup visibly different from the teacher's: a light
    theme, a different object, and a different animation length."""
    preset_directory = bpy.utils.preset_paths("interface_theme")[0]
    bpy.ops.script.execute_preset(
        filepath=os.path.join(preset_directory, "Blender_Light.xml"),
        menu_idname="USERPREF_MT_interface_theme_presets",
    )

    scene = bpy.context.scene
    scene.frame_end = 480

    for existing_object in list(scene.objects):
        if existing_object.type == "MESH":
            bpy.data.objects.remove(existing_object)
    bpy.ops.mesh.primitive_monkey_add()
    bpy.ops.mesh.primitive_torus_add(location=(3, 0, 0))


# Each entry is (state name, change to make). The teacher and follower walk the
# same task, because a lesson has to work on someone else's copy of it.
STATES = [
    ("0-start", None),
    ("1-animation-tab", lambda: set_workspace("Animation")),
    ("2-output-tab", set_output_tab),
    ("3-frame-end", set_frame_end),
    ("4-back-to-layout", lambda: set_workspace("Layout")),
]


def rect_in_window_points(x, y, width, height, window_height_in_pixels, pixels_per_point):
    """Blender regions are bottom-left origin in pixels. Everything else uses
    top-left origin in points."""
    return {
        "x": x / pixels_per_point,
        "y": (window_height_in_pixels - (y + height)) / pixels_per_point,
        "width": width / pixels_per_point,
        "height": height / pixels_per_point,
    }


def force_redraw(window):
    """Timers run between redraws, and an unfocused window may not redraw at
    all, so a screenshot taken here can show a state from seconds ago. This
    draws and swaps first, so the image is the state it's named after."""
    with bpy.context.temp_override(window=window, area=window.screen.areas[0]):
        bpy.ops.wm.redraw_timer(type="DRAW_WIN_SWAP", iterations=2)


def export_state(state_name):
    window = bpy.context.window_manager.windows[0]
    force_redraw(window)
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
        areas.setdefault(area.type, []).append({
            "rect": rect_in_window_points(
                area.x, area.y, area.width, area.height,
                window_height_in_pixels, pixels_per_point,
            ),
            "regions": regions,
        })

    screenshot_path = os.path.join(OUTPUT_DIRECTORY, f"{SETUP_NAME}-{state_name}.png")
    with bpy.context.temp_override(window=window, area=window.screen.areas[0]):
        bpy.ops.screen.screenshot(filepath=screenshot_path, check_existing=False)

    layout_path = os.path.join(OUTPUT_DIRECTORY, f"{SETUP_NAME}-{state_name}.json")
    with open(layout_path, "w") as layout_file:
        json.dump({
            "windowInPoints": {"width": window.width, "height": window.height},
            "pixelsPerPoint": pixels_per_point,
            "frameEnd": bpy.context.scene.frame_end,
            "workspace": window.workspace.name,
            "propertiesTab": properties_tab(),
            "areas": areas,
        }, layout_file, indent=1)


class StateWalker:
    def __init__(self):
        self.next_state_index = 0

    def apply_next_state(self):
        _, change_state = STATES[self.next_state_index]
        if change_state is not None:
            change_state()
        for window in bpy.context.window_manager.windows:
            for area in window.screen.areas:
                area.tag_redraw()
        bpy.app.timers.register(self.settle_redraw, first_interval=REDRAW_WAIT_SECONDS)
        return None

    def settle_redraw(self):
        # A workspace's first switch lands on a later pass of the event loop,
        # after any redraw made in the same tick. So this draws once, hands
        # control back to the loop, and export_state draws again afterwards.
        force_redraw(bpy.context.window_manager.windows[0])
        bpy.app.timers.register(self.export_and_continue, first_interval=REDRAW_WAIT_SECONDS)
        return None

    def export_and_continue(self):
        state_name, _ = STATES[self.next_state_index]
        export_state(state_name)
        self.next_state_index += 1

        if self.next_state_index < len(STATES):
            bpy.app.timers.register(self.apply_next_state, first_interval=0.2)
        else:
            # Written last: its appearance tells the driver every state is done.
            with open(os.path.join(OUTPUT_DIRECTORY, f"{SETUP_NAME}-done"), "w") as done_file:
                done_file.write("done")
            bpy.app.timers.register(self.wait_for_quit, first_interval=0.25)
        return None

    def wait_for_quit(self):
        if os.path.exists(os.path.join(OUTPUT_DIRECTORY, f"{SETUP_NAME}-quit")):
            bpy.ops.wm.quit_blender()
            return None
        return 0.25


def begin():
    if SETUP_NAME == "follow":
        prepare_follower_setup()
    bpy.app.timers.register(StateWalker().apply_next_state, first_interval=2.0)
    return None


# Gives the first redraw time to finish before anything changes.
bpy.app.timers.register(begin, first_interval=3.0)
