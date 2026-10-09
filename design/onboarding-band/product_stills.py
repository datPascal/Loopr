"""Band product stills for the app UI: the closed band alone on a transparent background.

Run (after ./render.sh build, so band-intro.blend is current):
  blender -b band-intro.blend --python product_stills.py -- OUT_DIR [VIEW ...] [--pct N] [--samples N]

VIEW: product (three-quarter), pairing (same view, blue side LED on), tap (the pod from the top).
Writes OUT_DIR/band-<view>.png as 1024 x 1024 16-bit straight-alpha RGBA; render.sh product
quantises them into Loopr/Loopr/Resources/Onboarding/.

Uses the film's own band at its last frame (closed, the loop fitted to the wrist) with the film's
materials. The hand, the ghost backdrop and the film's lights are hidden; a studio light rig
built here lights the band. The side LED only exists in the stills: a small lens on the pod's side
face, toward the fingers, glowing blue in the pairing view and dark otherwise.
"""

import math
import os
import sys

import bpy
import numpy as np
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Matrix, Vector

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
opts = {"--pct": 100, "--samples": 256}
rest = []
i = 0
while i < len(args):
    if args[i] in opts:
        opts[args[i]] = int(args[i + 1])
        i += 2
    else:
        rest.append(args[i])
        i += 1
OUT_DIR = rest[0]
VIEWS = rest[1:] or ["product", "pairing", "tap"]
os.makedirs(OUT_DIR, exist_ok=True)

scene = bpy.context.scene
scene.frame_set(scene.frame_end)
M = 0.001
BAND_PARTS = ["Pod", "PodInset", "PodSensor", "Slider", "ClaspFrame", "ClaspCap", "Strap"]
anchor = bpy.data.objects["BandAnchor"]
pod_motion = bpy.data.objects["PodMotion"]
A = anchor.matrix_world.copy()                    # band space (x ulnar, y dorsal, w fingers) -> world
ex, ey, ew = (A.to_3x3() @ Vector(v) for v in ((1, 0, 0), (0, 1, 0), (0, 0, 1)))
ex.normalize(); ey.normalize(); ew.normalize()

# --- hide everything that is not the band
from bpy_extras import anim_utils  # noqa: E402

keep = set(BAND_PARTS)
for ob in scene.objects:
    if ob.type in ("MESH", "LIGHT") and ob.name not in keep:
        ob.hide_render = True
for name in BAND_PARTS:
    # hide_render is keyed in the film (the band appears at bandIn): drop that key, keep the pose keys
    ob = bpy.data.objects[name]
    ad = ob.animation_data
    if ad and ad.action:
        cb = anim_utils.action_get_channelbag_for_slot(ad.action, ad.action_slot)
        for fc in [fc for fc in cb.fcurves if fc.data_path == "hide_render"]:
            cb.fcurves.remove(fc)
    ob.hide_render = False
scene.frame_set(scene.frame_end)

# --- side LED: a small lens on the pod's side face (w = +POD_W/2), part-way toward end A
pod = bpy.data.objects["Pod"]
pv = np.array([v.co[:] for v in pod.data.vertices])       # PodMotion local = band space (m)
wmax = pv[:, 2].max()
strip = pv[pv[:, 2] > wmax - 2e-6]                        # the flat band of the side face
top = pv[pv[:, 1] > np.percentile(pv[:, 1], 90)]
xy = strip[:, :2]
c = xy.mean(axis=0)
_, _, vt = np.linalg.svd(xy - c)
t2 = vt[0]                                                # along the pod (around the wrist)
proj = (xy - c) @ t2
led_q = float(os.environ.get("LOOPR_LED_POS", "-0.22"))    # fraction of the half length from the middle
target = led_q * (proj.max() - proj.min()) / 2
k = np.argsort(np.abs(proj - target))[:12]
p_led = strip[k].mean(axis=0)
n2 = np.array([-t2[1], t2[0]])
if (top[:, :2].mean(axis=0) - p_led[:2]) @ n2 < 0:
    n2 = -n2                                              # n2: toward the pod top (radial out)
# lens: a flat rounded pill in the side plane, 2.2 mm along the pod, 0.9 mm tall, 0.12 mm proud
LED_L, LED_H, LED_D = 2.2, 0.9, 0.12


def pill(nseg=24):
    pts = []
    r = LED_H / 2
    for a in np.linspace(-math.pi / 2, math.pi / 2, nseg // 2):
        pts.append(((LED_L / 2 - r) + r * math.cos(a), r * math.sin(a)))
    for a in np.linspace(math.pi / 2, 1.5 * math.pi, nseg // 2):
        pts.append((-(LED_L / 2 - r) + r * math.cos(a), r * math.sin(a)))
    return pts


ring = pill()
verts, faces = [], []
for depth in (-0.3, LED_D):                               # sunk into the face, 0.12 mm proud
    for (u, v) in ring:
        verts.append((u, v, depth))
nr = len(ring)
faces.append(tuple(range(nr, 2 * nr)))
faces.append(tuple(reversed(range(nr))))
for j in range(nr):
    faces.append((j, (j + 1) % nr, nr + (j + 1) % nr, nr + j))
me = bpy.data.meshes.new("PodSideLED")
me.from_pydata([tuple(np.array(v) * M) for v in verts], [], faces)
me.validate()
led = bpy.data.objects.new("PodSideLED", me)
scene.collection.objects.link(led)
led.parent = pod_motion
basis = Matrix(((t2[0], n2[0], 0.0), (t2[1], n2[1], 0.0), (0.0, 0.0, 1.0)))   # columns: u, v, out (+w)
led.matrix_parent_inverse = Matrix.Identity(4)
led.matrix_basis = Matrix.Translation(Vector((p_led[0], p_led[1], wmax))) @ basis.to_4x4()

m_led = bpy.data.materials.new("SideLED")
m_led.use_nodes = True
nt = m_led.node_tree
b = nt.nodes["Principled BSDF"]
b.inputs["Base Color"].default_value = (0.02, 0.025, 0.03, 1)
b.inputs["Roughness"].default_value = 0.12
b.inputs["Coat Weight"].default_value = 1.0
b.inputs["Emission Color"].default_value = (0.05, 0.32, 1.0, 1)
b.inputs["Emission Strength"].default_value = 0.0
me.materials.append(m_led)
led_light_data = bpy.data.lights.new("SideLEDGlow", "POINT")
led_light_data.color = (0.1, 0.4, 1.0)
led_light_data.shadow_soft_size = 0.0006
led_light_data.energy = 0.0
led_light = bpy.data.objects.new("SideLEDGlow", led_light_data)
scene.collection.objects.link(led_light)
led_light.parent = led
led_light.location = Vector((0.0, 0.0, 0.0012))

# --- studio rig (band space directions, converted to world)


def bs(x, y, w):
    return x * ex + y * ey + w * ew


def area(name, pos, size, size_y, energy, color=(1, 1, 1), target=Vector((0, 0, 0))):
    ld = bpy.data.lights.new(name, "AREA")
    ld.shape = "RECTANGLE"
    ld.size, ld.size_y = size, size_y
    ld.energy = energy
    ld.color = color
    ob = bpy.data.objects.new(name, ld)
    scene.collection.objects.link(ob)
    ob.location = pos
    ob.rotation_euler = (target - pos).to_track_quat("-Z", "Y").to_euler()
    return ob


studio = [
    area("S_Key", bs(-0.18, 0.30, 0.26), 0.30, 0.22, 3.2, (1.0, 0.98, 0.95)),
    area("S_Top", bs(0.0, 0.40, -0.05), 0.40, 0.40, 1.6, (0.95, 0.97, 1.0)),
    area("S_RimR", bs(0.34, 0.10, -0.22), 0.45, 0.05, 3.5, (0.85, 0.92, 1.0)),
    area("S_RimL", bs(-0.34, 0.05, -0.20), 0.45, 0.05, 2.5, (0.85, 0.92, 1.0)),
    area("S_Fill", bs(0.25, -0.05, 0.35), 0.40, 0.40, 0.45, (1.0, 0.97, 0.94)),
    area("S_Under", bs(0.0, -0.35, 0.10), 0.30, 0.30, 0.3, (0.9, 0.95, 1.0)),
]
# the titanium gets a long soft card to reflect, like the film's clasp card
world = scene.world
wbg = world.node_tree.nodes.get("Background")
wbg.inputs["Color"].default_value = (0.20, 0.21, 0.23, 1)
wbg.inputs["Strength"].default_value = 0.07

# --- camera
cam = scene.camera
cam.constraints.clear()
if cam.animation_data:
    cam.animation_data_clear()
cam.data.animation_data_clear() if cam.data.animation_data else None
cam.data.dof.use_dof = False
cam.data.lens = 100.0
cam.data.sensor_fit = "HORIZONTAL"
cam.data.sensor_width = 36.0
cam.data.clip_start = 0.01
VIEW_DIRS = {
    # camera position direction from the band centre, band space (x ulnar, y dorsal, w fingers)
    "product": ((0.52, 0.50, 0.70), (0.0, 1.0, 0.0)),
    "pairing": ((0.52, 0.50, 0.70), (0.0, 1.0, 0.0)),
    "tap": ((0.12, 1.0, 0.50), (0.0, 0.0, -1.0)),
}
FILL = {"product": 0.80, "pairing": 0.80, "tap": 0.80}

scene.render.resolution_x = scene.render.resolution_y = 1024
scene.render.resolution_percentage = opts["--pct"]
scene.render.film_transparent = True
scene.render.use_motion_blur = False
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.image_settings.color_depth = "16"
scene.cycles.samples = opts["--samples"]
scene.cycles.adaptive_threshold = 0.01
scene.cycles.transparent_max_bounces = 8
prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "METAL"
prefs.get_devices()
for d in prefs.devices:
    d.use = True
scene.cycles.device = "GPU"


def band_points(view):
    dg = bpy.context.evaluated_depsgraph_get()
    pts = []
    names = BAND_PARTS if view != "tap" else ["Pod", "Slider", "ClaspFrame", "ClaspCap", "Strap"]
    for name in names:
        oe = bpy.data.objects[name].evaluated_get(dg)
        mm = oe.to_mesh()
        mw = oe.matrix_world
        pts += [mw @ v.co for v in mm.vertices]
        oe.to_mesh_clear()
    return pts


def frame_camera(view):
    d, upv = VIEW_DIRS[view]
    d = bs(*d).normalized()
    upw = bs(*upv)
    pts = band_points(view)
    if view == "tap":
        # frame the pod and the top of the loop only
        pod_c = sum((pod.matrix_world @ v.co for v in pod.data.vertices), Vector()) / len(pod.data.vertices)
        pts = [p for p in pts if (p - pod_c).length < 0.034]
    center = sum(pts, Vector()) / len(pts)
    dist = 0.5
    cam.data.shift_x = cam.data.shift_y = 0.0
    for _ in range(8):
        cam.location = center + d * dist
        zc = -d
        xc = zc.cross(upw).normalized()
        yc = xc.cross(zc).normalized()
        cam.rotation_euler = Matrix((xc, yc, -zc)).transposed().to_euler()
        bpy.context.view_layer.update()
        uv = np.array([world_to_camera_view(scene, cam, p)[:2] for p in pts])
        lo, hi = uv.min(axis=0), uv.max(axis=0)
        ext = (hi - lo).max()
        cam.data.shift_x += ((lo[0] + hi[0]) / 2 - 0.5)
        cam.data.shift_y += ((lo[1] + hi[1]) / 2 - 0.5)
        dist *= ext / FILL[view]
    bpy.context.view_layer.update()
    uv = np.array([world_to_camera_view(scene, cam, p)[:2] for p in pts])
    print(f"[stills] {view}: extent {np.ptp(uv, axis=0).round(3)} centre {((uv.min(0) + uv.max(0)) / 2).round(3)}")


# --- reflection cards for the titanium: soft panels seen only by glossy rays on the metal parts
# (light linked), placed per view where the camera sees their mirror image in the rail tops, the
# rail facing the camera and the cap. Without them the metal reflects the dim grey world and
# reads as dark plastic.
metal_rx = bpy.data.collections.get("GlintReceivers")
CARD_GAIN = float(os.environ.get("LOOPR_STILL_CARDS", "1.0"))


def card(name, at, n, cam_dir, dist, size, size_y, strength, long_axis, ramp_lo=1.0, soft=0.14):
    n = n.normalized()
    r = (2 * (cam_dir @ n) * n - cam_dir).normalized()
    loc = at + r * dist
    zc = (at - loc).normalized()
    xc = long_axis - (long_axis @ zc) * zc
    xc.normalize()
    yc = zc.cross(xc)
    me_ = bpy.data.meshes.new(name)
    hx, hy = size / 2, size_y / 2
    me_.from_pydata([(-hx, -hy, 0), (hx, -hy, 0), (hx, hy, 0), (-hx, hy, 0)], [], [(0, 1, 2, 3)])
    ob = bpy.data.objects.new(name, me_)
    scene.collection.objects.link(ob)
    ob.matrix_world = Matrix.Translation(loc) @ Matrix((xc, yc, -zc)).transposed().to_4x4()
    for attr in ("visible_camera", "visible_diffuse", "visible_transmission", "visible_volume_scatter", "visible_shadow"):
        setattr(ob, attr, False)
    if metal_rx is not None:
        ob.light_linking.receiver_collection = metal_rx
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt_ = m.node_tree
    nt_.nodes.clear()
    out_ = nt_.nodes.new("ShaderNodeOutputMaterial")
    em = nt_.nodes.new("ShaderNodeEmission")
    tc_ = nt_.nodes.new("ShaderNodeTexCoord")
    sp = nt_.nodes.new("ShaderNodeSeparateXYZ")
    nt_.links.new(tc_.outputs["Generated"], sp.inputs["Vector"])
    fall = None
    for ax in ("X", "Y"):
        inv = nt_.nodes.new("ShaderNodeMath")
        inv.operation = "SUBTRACT"
        inv.inputs[0].default_value = 1.0
        nt_.links.new(sp.outputs[ax], inv.inputs[1])
        mn = nt_.nodes.new("ShaderNodeMath")
        mn.operation = "MINIMUM"
        nt_.links.new(sp.outputs[ax], mn.inputs[0])
        nt_.links.new(inv.outputs[0], mn.inputs[1])
        mr = nt_.nodes.new("ShaderNodeMapRange")
        mr.interpolation_type = "SMOOTHSTEP"
        mr.inputs["From Max"].default_value = soft
        nt_.links.new(mn.outputs[0], mr.inputs["Value"])
        if fall is None:
            fall = mr.outputs["Result"]
        else:
            mul = nt_.nodes.new("ShaderNodeMath")
            mul.operation = "MULTIPLY"
            nt_.links.new(fall, mul.inputs[0])
            nt_.links.new(mr.outputs["Result"], mul.inputs[1])
            fall = mul.outputs[0]
    grad = nt_.nodes.new("ShaderNodeMath")
    grad.operation = "MULTIPLY_ADD"
    nt_.links.new(sp.outputs["Y"], grad.inputs[0])
    grad.inputs[1].default_value = 1.0 - ramp_lo
    grad.inputs[2].default_value = ramp_lo
    mul = nt_.nodes.new("ShaderNodeMath")
    mul.operation = "MULTIPLY"
    nt_.links.new(fall, mul.inputs[0])
    nt_.links.new(grad.outputs[0], mul.inputs[1])
    amp = nt_.nodes.new("ShaderNodeMath")
    amp.operation = "MULTIPLY"
    nt_.links.new(mul.outputs[0], amp.inputs[0])
    amp.inputs[1].default_value = strength * CARD_GAIN
    nt_.links.new(amp.outputs[0], em.inputs["Strength"])
    nt_.links.new(em.outputs["Emission"], out_.inputs["Surface"])
    m.cycles.emission_sampling = "NONE"
    me_.materials.append(m)
    return ob


def place_cards(view):
    for ob in [o for o in scene.objects if o.name.startswith("S_Card")]:
        bpy.data.objects.remove(ob, do_unlink=True)
    centre = sum((p for p in band_points(view)), Vector()) / len(band_points(view))
    cam_dir = (cam.matrix_world.translation - centre).normalized()
    near = ew if cam_dir @ ew > 0 else -ew
    top = centre + ey * 0.012
    card("S_CardRailTop", top, ey, cam_dir, 0.30, 0.36, 0.025, 1.6, ex)
    card("S_CardRailNear", centre + near * 0.014, near, cam_dir, 0.30, 0.40, 0.03, 1.8, ex)
    card("S_CardRailSoft", centre + near * 0.014, near * 0.8 + ey * 0.6, cam_dir, 0.32, 0.40, 0.12, 0.6, ex, ramp_lo=0.15)
    card("S_CardCap", top, ey * 0.7 + to_b * 0.5, cam_dir, 0.26, 0.10, 0.22, 0.3, ew, ramp_lo=0.08)


# toward pod end B, where the cap sits: the cap plate's normal leans that way as it rounds down
_pod_c = sum((pod.matrix_world @ v.co for v in pod.data.vertices), Vector()) / len(pod.data.vertices)
to_b = ex if (bpy.data.objects["ClaspCap"].matrix_world.translation - _pod_c) @ ex > 0 else -ex

for view in VIEWS:
    on = view == "pairing"
    b.inputs["Emission Strength"].default_value = 60.0 if on else 0.0
    led_light_data.energy = 0.004 if on else 0.0
    frame_camera(view)
    place_cards(view)
    scene.render.filepath = os.path.join(OUT_DIR, f"band-{view}.png")
    bpy.ops.render.render(write_still=True)
    print("[stills] wrote", scene.render.filepath)
