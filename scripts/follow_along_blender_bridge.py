# TEST ONLY. Runs inside Blender for scripts/rehearse_follow_along.py.
#
# Stands in for two things a rehearsal can't have without macOS permissions:
# ScreenCaptureKit, by exporting Blender's own window, and a human's mouse, by
# replaying events at exact coordinates through Window.event_simulate. That
# needs `--enable-event-simulate`, which also makes Blender ignore real input,
# so a rehearsal can't be disturbed and can't steal the user's mouse.
#
# Also reports Blender's own state, which gives a rehearsal a ground truth that
# doesn't come from any model.
#
# Everything goes through files in the directory after `--`:
#   capture-N.request  -> capture-N.png, then capture-N.done
#   command-N.json     -> command-N.done
#   state-N.request    -> state-N.json
#   quit               -> quits Blender

import json
import os
import sys
import traceback

import bpy

BRIDGE_DIRECTORY = sys.argv[sys.argv.index("--") + 1]
POLL_SECONDS = 0.05
SECONDS_BETWEEN_EVENTS = 0.12
SWAPCHAIN_BUFFER_COUNT = 3

bpy.context.preferences.view.show_splash = False

served_files = set()
active_command = None
last_mouse_position = [0, 0]


def bridge_path(name):
    return os.path.join(BRIDGE_DIRECTORY, name)


def main_window():
    return bpy.context.window_manager.windows[0]


def export_window(image_path):
    """Blender reads whichever swapchain buffer is next, so on an idle window
    exports cycle through old frames. A changed screen then never looks settled,
    and the frame can be out of date. Swapping until every buffer holds the
    current picture removes both problems. ScreenCaptureKit reads the composited
    display and doesn't have this issue."""
    window = main_window()
    with bpy.context.temp_override(window=window, area=window.screen.areas[0]):
        bpy.ops.wm.redraw_timer(type="DRAW_WIN_SWAP", iterations=SWAPCHAIN_BUFFER_COUNT)
        bpy.ops.screen.screenshot(filepath=image_path, check_existing=False)


def to_window_pixels(window, x_in_points, y_in_points):
    """Takes top-left window points. Events use native pixels from the bottom
    left, while window.width and window.height are reported in points."""
    pixels_per_point = bpy.context.preferences.system.pixel_size
    return (
        int(round(x_in_points * pixels_per_point)),
        int(round((window.height - y_in_points) * pixels_per_point)),
    )


def run_operations(operations):
    """A generator, so Blender can process each event before the next one."""
    window = main_window()
    # A key event carries a position too, and it defaults to the window's
    # corner, so it has to be sent from wherever the mouse was left.
    x, y = last_mouse_position
    for operation in operations:
        kind = operation["op"]
        if kind == "wait":
            yield operation["seconds"]
        elif kind == "move":
            x, y = to_window_pixels(window, operation["x"], operation["y"])
            last_mouse_position[:] = [x, y]
            window.event_simulate(type="MOUSEMOVE", value="NOTHING", x=x, y=y)
            yield SECONDS_BETWEEN_EVENTS
        elif kind == "button":
            x, y = to_window_pixels(window, operation["x"], operation["y"])
            window.event_simulate(type="LEFTMOUSE", value=operation["value"], x=x, y=y)
            yield SECONDS_BETWEEN_EVENTS
        elif kind == "key":
            window.event_simulate(type=operation["key"], value="PRESS", x=x, y=y, ctrl=operation.get("ctrl", False), unicode=operation.get("unicode"))
            window.event_simulate(type=operation["key"], value="RELEASE", x=x, y=y, ctrl=operation.get("ctrl", False))
            yield SECONDS_BETWEEN_EVENTS


def describe_state():
    window = main_window()
    state = {
        "workspace": window.workspace.name,
        "mode": bpy.context.mode,
        "viewportShading": None,
        "nodes": [],
        "links": [],
        "voronoi": None,
    }

    for area in window.screen.areas:
        if area.type == "VIEW_3D":
            state["viewportShading"] = area.spaces.active.shading.type
            break

    material = bpy.data.materials.get("Material")
    if material and material.node_tree:
        state["nodes"] = sorted(node.bl_idname for node in material.node_tree.nodes)
        state["links"] = sorted(
            f"{link.from_node.name}.{link.from_socket.name} -> {link.to_node.name}.{link.to_socket.name}"
            for link in material.node_tree.links
        )
        for node in material.node_tree.nodes:
            if node.bl_idname == "ShaderNodeTexVoronoi":
                state["voronoi"] = {
                    "scale": node.inputs["Scale"].default_value,
                    "feature": node.feature,
                    "distance": node.distance,
                }
    return state


def ground_truth():
    window = main_window()
    return {
        "windowInPoints": {"width": window.width, "height": window.height},
        "pixelsPerPoint": bpy.context.preferences.system.pixel_size,
        "blenderVersion": bpy.app.version_string,
    }


def serve_requests():
    global active_command

    for file_name in sorted(os.listdir(BRIDGE_DIRECTORY)):
        if file_name in served_files:
            continue

        if file_name.startswith("capture-") and file_name.endswith(".request"):
            served_files.add(file_name)
            base_name = file_name[: -len(".request")]
            export_window(bridge_path(base_name + ".png"))
            with open(bridge_path(base_name + ".done"), "w"):
                pass

        elif file_name.startswith("state-") and file_name.endswith(".request"):
            served_files.add(file_name)
            with open(bridge_path(file_name[: -len(".request")] + ".json"), "w") as state_file:
                json.dump(describe_state(), state_file)

        elif file_name.startswith("command-") and file_name.endswith(".json") and active_command is None:
            served_files.add(file_name)
            with open(bridge_path(file_name)) as command_file:
                operations = json.load(command_file)
            active_command = (file_name[: -len(".json")], run_operations(operations))

    if os.path.exists(bridge_path("quit")):
        bpy.ops.wm.quit_blender()
        return None

    if active_command is not None:
        command_name, operation_generator = active_command
        try:
            return next(operation_generator)
        except StopIteration:
            active_command = None
            with open(bridge_path(command_name + ".done"), "w"):
                pass

    return POLL_SECONDS


def serve_requests_safely():
    try:
        return serve_requests()
    except Exception:
        with open(bridge_path("bridge-error.txt"), "a") as error_file:
            error_file.write(traceback.format_exc())
        return POLL_SECONDS


def start_bridge():
    with open(bridge_path("ground_truth.json"), "w") as ground_truth_file:
        json.dump(ground_truth(), ground_truth_file)
    return serve_requests_safely()


# Gives the first redraw time to finish before the framebuffer is read.
bpy.app.timers.register(start_bridge, first_interval=4.0)
