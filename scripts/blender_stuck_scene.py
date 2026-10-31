# Runs inside Blender. Builds the Stuck demo: a plain cube, a goal shape with
# one corner pulled out, and a line of 3D text saying what to do. The cube is
# selected in Object Mode, which is the trap: G moves the whole cube, not a
# corner. Nothing here hints at the answer or changes how Blender behaves.
#
# With an output directory after `--`, it also exports what a check needs (a
# screenshot of Blender's own window and its layout) and quits once that
# directory contains a file named "quit". Without one, it leaves Blender open
# for a human.

import json
import math
import os
import sys

import bmesh
import bpy
from mathutils import Euler, Vector

OUTPUT_DIRECTORY = None
if "--" in sys.argv:
    OUTPUT_DIRECTORY = sys.argv[sys.argv.index("--") + 1]

bpy.context.preferences.view.show_splash = False


def make_text(body, location, size):
    text_curve = bpy.data.curves.new(name=body, type="FONT")
    text_curve.body = body
    text_curve.size = size
    text_curve.align_x = "CENTER"
    text_object = bpy.data.objects.new(body, text_curve)
    bpy.context.collection.objects.link(text_object)
    text_object.location = location
    text_object.rotation_euler = Euler((math.radians(90), 0, 0))
    return text_object


def make_goal_shape(location):
    """A cube with its top front right corner dragged up and out."""
    goal_mesh = bpy.data.meshes.new("goal")
    goal_bmesh = bmesh.new()
    bmesh.ops.create_cube(goal_bmesh, size=2.0)
    for vertex in goal_bmesh.verts:
        if vertex.co.x > 0 and vertex.co.y < 0 and vertex.co.z > 0:
            vertex.co += Vector((1.1, -0.9, 1.3))
    goal_bmesh.to_mesh(goal_mesh)
    goal_bmesh.free()

    goal_object = bpy.data.objects.new("goal", goal_mesh)
    bpy.context.collection.objects.link(goal_object)
    goal_object.location = location

    goal_material = bpy.data.materials.new("goal orange")
    goal_material.diffuse_color = (0.95, 0.42, 0.12, 1)
    goal_mesh.materials.append(goal_material)
    return goal_object


def build_scene():
    scene_objects = bpy.data.objects
    my_cube = scene_objects["Cube"]
    my_cube.location = (-2.6, 0, 1)

    make_goal_shape((2.6, 0, 1))

    make_text("mine", (-2.6, 0, 3.0), 0.7)
    make_text("goal", (2.6, 0, 3.6), 0.7)
    make_text("pull one corner out, like the goal", (0, 0, 5.0), 0.62)

    # The camera and lamp only add clutter to a beginner's view.
    scene_objects["Camera"].hide_set(True)
    scene_objects["Light"].hide_set(True)

    bpy.ops.object.select_all(action="DESELECT")
    my_cube.select_set(True)
    bpy.context.view_layer.objects.active = my_cube


def frame_view():
    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.type != "VIEW_3D":
                continue
            space = area.spaces.active
            space.region_3d.view_perspective = "PERSP"
            space.region_3d.view_rotation = Euler((math.radians(78), 0, math.radians(12))).to_quaternion()
            space.region_3d.view_location = (0, 0, 2.1)
            space.region_3d.view_distance = 15.5
            area.tag_redraw()
    return None


def rect_in_window_points(x, y, width, height, window_height_in_pixels, pixels_per_point):
    return {
        "x": x / pixels_per_point,
        "y": (window_height_in_pixels - (y + height)) / pixels_per_point,
        "width": width / pixels_per_point,
        "height": height / pixels_per_point,
    }


def export_for_check():
    window = bpy.context.window_manager.windows[0]
    pixels_per_point = bpy.context.preferences.system.pixel_size
    window_height_in_pixels = window.height * pixels_per_point

    areas = {}
    for area in window.screen.areas:
        areas[area.type] = {
            "rect": rect_in_window_points(
                area.x, area.y, area.width, area.height,
                window_height_in_pixels, pixels_per_point,
            ),
        }

    with bpy.context.temp_override(window=window, area=window.screen.areas[0]):
        bpy.ops.screen.screenshot(
            filepath=os.path.join(OUTPUT_DIRECTORY, "blender_window.png"),
            check_existing=False,
        )

    # Written last: its appearance tells the caller the screenshot is ready.
    with open(os.path.join(OUTPUT_DIRECTORY, "ground_truth.json"), "w") as ground_truth_file:
        json.dump({
            "windowInPoints": {"width": window.width, "height": window.height},
            "pixelsPerPoint": pixels_per_point,
            "areas": areas,
        }, ground_truth_file, indent=1)

    bpy.app.timers.register(quit_when_requested, first_interval=0.25)


def quit_when_requested():
    if os.path.exists(os.path.join(OUTPUT_DIRECTORY, "quit")):
        bpy.ops.wm.quit_blender()
        return None
    return 0.25


build_scene()
# The window manager doesn't exist yet while this script runs at startup.
bpy.app.timers.register(frame_view, first_interval=0.5)
if OUTPUT_DIRECTORY:
    bpy.app.timers.register(export_for_check, first_interval=4.0)
