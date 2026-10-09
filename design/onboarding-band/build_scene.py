"""Build the Loopr onboarding band film scene.

Run:  [LOOPR_SKIN=ghost|ghost-bones|ghost-anatomy|real] [LOOPR_BLEND_OUT=path]
      blender -b --factory-startup --python design/onboarding-band/build_scene.py [-- --verify]

Appends the hand skin, nails and rig (and, for the anatomy looks, bones, muscles and wrist
tendons) from the Crimpwell hand (read only), builds a procedural, unbranded band that works like
a WHOOP 4.0 band (pod, hinged U-frame, pivoting cap, slider, knit strap; see
research/whoop4-band-mechanics.md), bakes its drop-in, wrap, swing and click per frame, animates the
beats from CONTRACT.md and saves design/onboarding-band/band-intro.blend next to this script.

Frame f shows time (f - 1) / 60 s. Click = frame 181 (t = 3.000 s).
All dimensions of the band are modelled in millimetres, converted to metres.
"""

import bpy
import math
import os
import sys

import numpy as np
from bpy_extras import anim_utils
from mathutils import Matrix, Quaternion, Vector
from mathutils.bvhtree import BVHTree

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get("LOOPR_HAND_BLEND") or os.path.join(HERE, "CrimpwellHand.blend")  # rigged BodyParts3D hand, see ASSET_NOTICES.md
OUT = os.environ.get("LOOPR_BLEND_OUT") or os.path.join(HERE, "band-intro.blend")
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []

# Skin look (env LOOPR_SKIN):
#   ghost        translucent rim-lit skin (Crimpwell cw_style._ghost_skin recipe, rebuilt for Cycles)
#   ghost-bones  ghost skin with the Crimpwell bones inside, following the finger pose
#   ghost-anatomy  ghost skin with bones, muscles and the wrist tendons inside
#   real         the v2 realistic skin with subsurface scattering and nails
SKIN_LOOKS = ("ghost", "ghost-bones", "ghost-anatomy", "real")
SKIN_LOOK = os.environ.get("LOOPR_SKIN", "ghost")
if SKIN_LOOK not in SKIN_LOOKS:
    raise SystemExit(f"LOOPR_SKIN must be one of {', '.join(SKIN_LOOKS)}, not {SKIN_LOOK!r}")
GHOST = SKIN_LOOK != "real"
WITH_BONES = SKIN_LOOK in ("ghost-bones", "ghost-anatomy")
WITH_SOFT = SKIN_LOOK == "ghost-anatomy"

# ---------------------------------------------------------------------------
# Timing (contract). Frame 1 is t = 0.
FPS = 60
def fr(t):
    return 1 + int(round(t * FPS))

F_FIRST = 1
F_LAST = 276                 # 4.6 s * 60 fps frames, last frame shows t = 4.583
F_HAND_END = fr(1.40)        # 85
F_BAND_IN = fr(1.40)         # 85
F_WRAP = fr(1.90)            # 115
F_CLICK = fr(3.00)           # 181

# ---------------------------------------------------------------------------
# Band geometry (mm)
GAP = 0.7                    # skin hull -> strap inner surface
STRAP_W = 22.0
STRAP_T = float(os.environ.get("LOOPR_STRAP_T", "1.9"))   # knit thickness; the edges are rounded right over
STRAP_RC = 0.42 * STRAP_T                                  # edge radius: a bound, pillowed selvedge
POD_L, POD_W, POD_H = 36.0, 26.0, 7.5
POD_R = 3.3
POD_RP = 6.0                 # plan corner radius of the pod
POD_PILLOW = 0.55           # extra height at the centre of the pod top

# ---------------------------------------------------------------------------
# Composition. The band centre sits at the world origin; the final camera looks along +Y,
# tilted down by CAM_EL. Arm and dorsum directions are given in that camera's basis
# (r = image right, u = image up, f = away from camera).
LENS = 85.0
FSTOP = float(os.environ.get("LOOPR_FSTOP", "11"))   # deep enough that the fingers, 7-9 cm behind the clasp, stay sharp
FOCUS_TO_HAND = float(os.environ.get("LOOPR_FOCUS_TO_HAND", "15"))   # mm the focus sits from the clasp toward the knuckles
LIGHT_UP = float(os.environ.get("LOOPR_LIGHT_UP", "0.35"))   # s for the lights (and the backdrop pool) to come up
FINAL_FRAME_W = 0.182        # metres of frame width at the band in the final frame
CAM_EL = 31.0
ARM_CAM = (-0.45, 0.42, 0.79)      # forearm axis (toward the fingers)
DORSAL_CAM = (0.08, 0.55, -0.80)   # back of the wrist faces the camera and up
# camera states: frame -> (distance factor, azimuth deg, elevation deg, band image x, band image y from top)
CAM_STATES = {
    "first": (1.06, 3.5, 29.5, 0.58, 0.64),
    "wrap": (0.97, 1.8, 30.5, 0.61, 0.645),
    "click": (0.82, 0.0, 31.0, 0.60, 0.63),
    "last": tuple(float(v) for v in os.environ.get("LOOPR_CAM_LAST", "0.90,-1.2,31.0,0.64,0.685").split(",")),
}

# ---------------------------------------------------------------------------
# helpers

def log(*a):
    print("[band]", *a, flush=True)


def fcurves_of(idb):
    ad = idb.animation_data
    if ad is None or ad.action is None:
        return []
    cb = anim_utils.action_get_channelbag_for_slot(ad.action, ad.action_slot)
    return list(cb.fcurves) if cb else []


def kf(struct, prop, frame, value, interp="BEZIER", easing="AUTO", handles="AUTO_CLAMPED"):
    """Insert a key and set its interpolation. Never linear."""
    if prop.startswith('["'):
        struct[prop[2:-2]] = value
    else:
        setattr(struct, prop, value)
    struct.keyframe_insert(prop, frame=frame)
    full = struct.path_from_id(prop) if struct != struct.id_data else prop
    for fc in fcurves_of(struct.id_data):
        if fc.data_path == full:
            for kp in fc.keyframe_points:
                if abs(kp.co.x - frame) < 1e-3:
                    kp.interpolation = interp
                    kp.easing = easing
                    kp.handle_left_type = handles
                    kp.handle_right_type = handles
            fc.update()


def find_fc(idb, path, index=0):
    for fc in fcurves_of(idb):
        if fc.data_path == path and fc.array_index == index:
            return fc
    return None


def smoothstep(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3.0 - 2.0 * x)


def new_mesh_object(name, verts_m, faces, uvs=None, parent=None, coll=None, smooth=True, extra_uvs=None,
                    attrs=None, loop_uv_fix=None):
    """uvs / extra_uvs {name: per-vertex (n, 2)}; attrs {name: per-vertex (n, 3)} as point float
    vectors (shader Attribute node); loop_uv_fix(loop_uv (n_loops, 2), loop_vert, loop_face) may
    rewrite the UVMap per face corner (seams)."""
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in verts_m], [], faces)
    me.validate(clean_customdata=False)
    lv = np.empty(len(me.loops), dtype=np.int32)
    me.loops.foreach_get("vertex_index", lv)
    layers = ([("UVMap", uvs)] if uvs is not None else []) + list((extra_uvs or {}).items())
    for lname, arr in layers:
        uvl = me.uv_layers.new(name=lname)
        luv = np.asarray(arr, dtype=np.float64)[lv]
        if lname == "UVMap" and loop_uv_fix is not None:
            lf = np.empty(len(me.loops), dtype=np.int32)
            for p_ in me.polygons:
                lf[p_.loop_start:p_.loop_start + p_.loop_total] = p_.index
            luv = loop_uv_fix(luv, lv, lf)
        uvl.data.foreach_set("uv", luv.astype(np.float32).ravel())
    if uvs is not None:
        me.uv_layers.active = me.uv_layers["UVMap"]
        me.uv_layers["UVMap"].active_render = True
    for aname, arr in (attrs or {}).items():
        at = me.attributes.new(aname, "FLOAT_VECTOR", "POINT")
        at.data.foreach_set("vector", np.asarray(arr, dtype=np.float32).ravel())
    me.shade_smooth() if smooth else None
    ob = bpy.data.objects.new(name, me)
    (coll or bpy.context.scene.collection).objects.link(ob)
    if parent is not None:
        ob.parent = parent
    return ob


# ---------------------------------------------------------------------------
# procedural meshes in "flat band space": X = along band (mm), Y = across (mm), Z = radial (mm)

def _axis_coords(length, r, m_edge, max_step):
    half = length / 2.0
    inner = half - r
    edge = [r * (1.0 - math.cos(t)) for t in np.linspace(0.0, math.pi / 2.0, m_edge + 1)]
    n_mid = max(1, int(math.ceil(2.0 * inner / max_step)))
    mid = list(np.linspace(-inner, inner, n_mid + 1))
    left = [-half + e for e in edge][:-1]
    right = [half - e for e in reversed(edge)][1:]
    return left + mid + right


def rounded_box(dims, r, center, m_edge=5, max_step=1.0):
    xs, ys, zs = [_axis_coords(d, r, m_edge, max_step) for d in dims]
    nx, ny, nz = len(xs) - 1, len(ys) - 1, len(zs) - 1
    idx = {}
    verts = []

    def vid(i, j, k):
        key = (i, j, k)
        if key not in idx:
            idx[key] = len(verts)
            verts.append((xs[i], ys[j], zs[k]))
        return idx[key]

    faces = []
    for i, flip in ((0, True), (nx, False)):
        for j in range(ny):
            for k in range(nz):
                q = [vid(i, j, k), vid(i, j + 1, k), vid(i, j + 1, k + 1), vid(i, j, k + 1)]
                faces.append(q[::-1] if flip else q)
    for j, flip in ((0, True), (ny, False)):
        for i in range(nx):
            for k in range(nz):
                q = [vid(i, j, k), vid(i, j, k + 1), vid(i + 1, j, k + 1), vid(i + 1, j, k)]
                faces.append(q[::-1] if flip else q)
    for k, flip in ((0, True), (nz, False)):
        for i in range(nx):
            for j in range(ny):
                q = [vid(i, j, k), vid(i + 1, j, k), vid(i + 1, j + 1, k), vid(i, j + 1, k)]
                faces.append(q[::-1] if flip else q)
    v = np.array(verts, dtype=np.float64)
    half = np.array(dims) / 2.0
    inner = half - r
    c = np.clip(v, -inner, inner)
    d = v - c
    n = np.linalg.norm(d, axis=1)
    m = n > 1e-9
    v[m] = c[m] + d[m] / n[m, None] * r
    v += np.array(center)
    return v, faces


def _dense_axis(length, r_dense, step_edge, step_mid):
    """grid coordinates over [-L/2, L/2]: step_edge within r_dense of either end, step_mid between"""
    half = length / 2.0
    inner = max(half - r_dense, 0.0)
    n_e = max(2, int(math.ceil((half - inner) / step_edge)))
    edge = list(np.linspace(-half, -inner, n_e + 1))
    n_m = max(1, int(math.ceil(2.0 * inner / step_mid)))
    mid = list(np.linspace(-inner, inner, n_m + 1))
    return edge[:-1] + mid + [-v for v in reversed(edge[:-1])]


def rounded_slab(dims, r, r_plan, center, step_edge=0.2, step_mid=0.8):
    """A box with every edge rounded: radius r over the top and bottom edges, a larger radius
    r_plan at the four vertical (plan) corners. Minkowski sum of a rounded-rectangle prism and a
    sphere of radius r, so the corners blend as torus patches with no flats or creases."""
    L, W, H = dims
    xs = _dense_axis(L, r_plan, step_edge, step_mid)
    ys = _dense_axis(W, r_plan, step_edge, step_mid)
    zs = _dense_axis(H, r, step_edge, step_mid)
    nx, ny, nz = len(xs) - 1, len(ys) - 1, len(zs) - 1
    idx = {}
    verts = []

    def vid(i, j, k):
        key = (i, j, k)
        if key not in idx:
            idx[key] = len(verts)
            verts.append((xs[i], ys[j], zs[k]))
        return idx[key]

    faces = []
    for i, flip in ((0, True), (nx, False)):
        for j in range(ny):
            for k in range(nz):
                q = [vid(i, j, k), vid(i, j + 1, k), vid(i, j + 1, k + 1), vid(i, j, k + 1)]
                faces.append(q[::-1] if flip else q)
    for j, flip in ((0, True), (ny, False)):
        for i in range(nx):
            for k in range(nz):
                q = [vid(i, j, k), vid(i, j, k + 1), vid(i + 1, j, k + 1), vid(i + 1, j, k)]
                faces.append(q[::-1] if flip else q)
    for k, flip in ((0, True), (nz, False)):
        for i in range(nx):
            for j in range(ny):
                q = [vid(i, j, k), vid(i + 1, j, k), vid(i + 1, j + 1, k), vid(i, j + 1, k)]
                faces.append(q[::-1] if flip else q)
    v = np.array(verts, dtype=np.float64)
    # nearest point on the inner prism: plan = rounded rect (half dims - r, corner r_plan - r)
    rho = r_plan - r
    hx, hy, hz = L / 2 - r, W / 2 - r, H / 2 - r
    qxy = np.clip(v[:, :2], [-(hx - rho), -(hy - rho)], [hx - rho, hy - rho])
    dxy = v[:, :2] - qxy
    nd = np.linalg.norm(dxy, axis=1)
    far = nd > rho
    qxy[far] += dxy[far] / nd[far, None] * rho
    qxy[~far] = v[~far, :2]
    c = np.c_[qxy, np.clip(v[:, 2], -hz, hz)]
    d = v - c
    n = np.linalg.norm(d, axis=1)
    m = n > 1e-9
    v[m] = c[m] + d[m] / n[m, None] * r
    v += np.array(center)
    return v, faces


def sweep_profile(path, profile, end0=0.0, end1=0.0, end_rows=8):
    """Sweep a closed 2D profile along a planar path. path: (n, 2) points in the (x, z) plane;
    profile: (m, 2) points (a, y) with a along the path's in-plane normal and y out of plane.
    end0 / end1 > 0 close that end with an elliptic cap that far past the path's end (the profile
    shrinks toward its centre); 0 closes it flat. Returns verts (x, y, z), faces, arc length per vertex."""
    P = np.asarray(path, dtype=np.float64)
    T = np.gradient(P, axis=0)
    T /= np.linalg.norm(T, axis=1)[:, None]
    N = np.c_[-T[:, 1], T[:, 0]]
    s_ = np.r_[0.0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]
    prof = np.asarray(profile, dtype=np.float64)
    pc = prof.mean(axis=0)
    rows = []          # (centre xz, normal, scale, arc)
    if end0 > 0:
        for th in np.linspace(math.pi / 2, 0.0, end_rows + 1)[1:-1]:
            rows.append((P[0] - T[0] * end0 * math.sin(th), N[0], math.cos(th), -end0 * math.sin(th)))
    for i in range(len(P)):
        rows.append((P[i], N[i], 1.0, s_[i]))
    if end1 > 0:
        for th in np.linspace(0.0, math.pi / 2, end_rows + 1)[1:-1]:
            rows.append((P[-1] + T[-1] * end1 * math.sin(th), N[-1], math.cos(th), s_[-1] + end1 * math.sin(th)))
    m = len(prof)
    verts, arcs = [], []
    for (c, n, sc, a) in rows:
        for (pa, py) in prof:
            aa = pc[0] + (pa - pc[0]) * sc
            yy = pc[1] + (py - pc[1]) * sc
            xz = c + n * aa
            verts.append((xz[0], yy, xz[1]))
            arcs.append(a)
    faces = []
    nrow = len(rows)
    for i in range(nrow - 1):
        for j in range(m):
            a_, b_ = i * m + j, i * m + (j + 1) % m
            faces.append((a_, b_, b_ + m, a_ + m))
    for end, ext, row, sgn in ((0, end0, 0, -1.0), (1, end1, nrow - 1, 1.0)):
        if ext > 0:
            c = P[-1 if end else 0] + sgn * T[-1 if end else 0] * ext
            xz = c + N[-1 if end else 0] * pc[0]
            pole = len(verts)
            verts.append((xz[0], pc[1], xz[1]))
            arcs.append(s_[-1] + ext if end else -ext)
            for j in range(m):
                a_, b_ = row * m + j, row * m + (j + 1) % m
                faces.append((a_, b_, pole) if end else (b_, a_, pole))
        else:
            ring_ = tuple(row * m + j for j in range(m))
            faces.append(ring_[::-1] if end == 0 else ring_)
    return np.array(verts), faces, np.array(arcs)


def d_profile(height, width, out_sign, r_in=0.28, p_out=2.4, n_out=28, n_in=6):
    """Rail cross-section (a, y), a in [-h/2, h/2]: a flat inner face (y = 0) with small rounded
    corners and an outer face that bulges as a superellipse to y = out_sign * width. Counter-
    clockwise for out_sign > 0."""
    h = height / 2.0
    pts = []
    # outer face: from the bottom inner corner, around the bulge, to the top inner corner
    for t in np.linspace(-math.pi / 2, math.pi / 2, n_out + 1):
        c_, s_ = math.cos(t), math.sin(t)
        a = h * math.copysign(abs(s_) ** (2.0 / p_out), s_)
        y = width * abs(c_) ** (2.0 / p_out)
        pts.append((a, y))
    # pull the two ends in to the inner face with a small radius
    pts[0] = (-h + r_in * 0.3, r_in * 0.6)
    pts[-1] = (h - r_in * 0.3, r_in * 0.6)
    for a in np.linspace(h - r_in, -h + r_in, n_in + 1):
        pts.append((a, 0.0))
    pts = np.array(pts)
    if out_sign < 0:
        pts = pts[::-1] * np.array([1.0, -1.0])
    return pts


def _signed_vol(v, faces):
    v = np.asarray(v, dtype=np.float64)
    vol = 0.0
    for f_ in faces:
        a = v[f_[0]]
        for k_ in range(1, len(f_) - 1):
            vol += float(np.dot(a, np.cross(v[f_[k_]], v[f_[k_ + 1]])))
    return vol / 6.0


def rr_ring(width, thick, rc, ring_top=16, ring_corner=5):
    """rounded-rectangle cross-section, counter-clockwise in (w, h): bottom edge left->right,
    right side up, top right->left, left side down"""
    hw = width / 2.0
    ring = []
    for w in np.linspace(-hw + rc, hw - rc, ring_top + 1)[:-1]:
        ring.append((w, 0.0))
    for a in np.linspace(-math.pi / 2, 0, ring_corner + 1)[:-1]:
        ring.append((hw - rc + rc * math.cos(a), rc + rc * math.sin(a)))
    for a in np.linspace(0, math.pi / 2, ring_corner + 1)[:-1]:
        ring.append((hw - rc + rc * math.cos(a), thick - rc + rc * math.sin(a)))
    for w in np.linspace(hw - rc, -hw + rc, ring_top + 1)[:-1]:
        ring.append((w, thick))
    for a in np.linspace(math.pi / 2, math.pi, ring_corner + 1)[:-1]:
        ring.append((-hw + rc + rc * math.cos(a), thick - rc + rc * math.sin(a)))
    for a in np.linspace(math.pi, 1.5 * math.pi, ring_corner + 1)[:-1]:
        ring.append((-hw + rc + rc * math.cos(a), rc + rc * math.sin(a)))
    return ring


def strap_strip(p0, p1, dp=0.6, ring_top=16, ring_corner=8, rc=None):
    """Rounded-rectangle cross-section swept along p. Returns flat verts, faces, uv (m).
    uv x = along the strap; uv y = around the cross-section's perimeter, 0 at the top centre, so
    the knit runs on over the rounded edges and round the inner face (the seam is at the inner
    face's centre, against the skin; strap_uv_fix mends it per face corner)."""
    rc = STRAP_RC if rc is None else rc
    ring = rr_ring(STRAP_W, STRAP_T, rc, ring_top, ring_corner)
    nr = len(ring)
    rp = np.array(ring + ring[:1])
    per = np.r_[0.0, np.cumsum(np.linalg.norm(np.diff(rp, axis=0), axis=1))]
    PER = per[-1]
    top_c = int(np.argmin(np.abs(np.array(ring)[:, 0]) + 10.0 * (np.array(ring)[:, 1] < STRAP_T / 2)))
    # perimeter coordinate centred on the top centre, wrapped to (-PER/2, PER/2]
    pc = (per[:-1] - per[top_c] + PER / 2) % PER - PER / 2
    n_rows = max(2, int(math.ceil((p1 - p0) / dp)) + 1)
    ps = np.linspace(p0, p1, n_rows)
    verts = []
    uvs = []
    for p in ps:
        for (w, h), c_ in zip(ring, pc):
            verts.append((p, w, h))
            uvs.append((p * 0.001, c_ * 0.001))
    faces = []
    for i in range(n_rows - 1):
        for j in range(nr):
            a = i * nr + j
            b = i * nr + (j + 1) % nr
            faces.append((a, b, b + nr, a + nr))
    # end caps (fans)
    c0 = len(verts)
    verts.append((p0, 0.0, STRAP_T / 2))
    uvs.append((p0 * 0.001, 0.0))
    c1 = len(verts)
    verts.append((p1, 0.0, STRAP_T / 2))
    uvs.append((p1 * 0.001, 0.0))
    last = (n_rows - 1) * nr
    for j in range(nr):
        faces.append((c0, (j + 1) % nr, j))
        faces.append((c1, last + j, last + (j + 1) % nr))
    strap_uv_fix.period = PER * 0.001
    return np.array(verts), faces, np.array(uvs)


def strap_uv_fix(luv, lv, lf):
    """faces across the perimeter seam: lift their negative-side corners by one period"""
    per = strap_uv_fix.period
    y = luv[:, 1]
    fmax = np.full(lf.max() + 1, -1e9)
    fmin = np.full(lf.max() + 1, 1e9)
    np.maximum.at(fmax, lf, y)
    np.minimum.at(fmin, lf, y)
    wrap = (fmax - fmin)[lf] > per / 2
    luv = luv.copy()
    luv[wrap & (y < 0), 1] += per
    return luv


# ---------------------------------------------------------------------------
# 1. scene

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.name = "BandIntro"
scene.render.fps = FPS
scene.render.fps_base = 1.0
scene.frame_start = F_FIRST
scene.frame_end = F_LAST
scene.unit_settings.system = "METRIC"

col_hand = bpy.data.collections.new("Hand")
col_band = bpy.data.collections.new("Band")
col_light = bpy.data.collections.new("Lights")
col_glint = bpy.data.collections.new("GlintReceivers")
col_product = bpy.data.collections.new("ProductKeyReceivers")
for c in (col_hand, col_band, col_light):
    scene.collection.children.link(c)

# ---------------------------------------------------------------------------
# 2. append hand (skin, nails, rig only)

with bpy.data.libraries.load(SRC, link=False) as (src, dst):
    dst.objects = [n for n in src.objects if n in ("Hand_rig", "R_FMA7163") or n.endswith("_nail")]
    # same append call, so the anatomy shares the appended Hand_rig
    dst.collections = (["bones"] if WITH_BONES else []) + (["muscles", "tendons"] if WITH_SOFT else [])
rig = skin = None
nails = []
bones = []
muscles = []
tendons = []


def _anatomy_keep(coll_name, ob):
    if ob.type != "MESH" or "__" in ob.name:          # Crimpwell injury variants
        return False
    if coll_name == "bones":
        return ob.name != "R_FMA23130"                # distal humerus, beyond the forearm cut
    if coll_name == "muscles":
        return ob.name != "R_FMA37388"                # stray copy half a metre off the hand
    # tendons: only the armature-driven wrist tendons. The per-digit tendons are posed at
    # runtime by Crimpwell's cw_anatomy.FittedAnatomy and would stay frozen at rest here.
    return ob.name.startswith("R_FMA") and any(m.type == "ARMATURE" for m in ob.modifiers)


for col_src in list(dst.collections):
    kind = col_src.name.split(".")[0]
    bucket = {"bones": bones, "muscles": muscles, "tendons": tendons}[kind]
    for ob in col_src.objects:
        if _anatomy_keep(kind, ob):
            col_hand.objects.link(ob)
            bucket.append(ob)
    bpy.data.collections.remove(col_src)
for ob in dst.objects:
    col_hand.objects.link(ob)
    ob.hide_render = False
    ob.hide_viewport = False
    if ob.type == "ARMATURE":
        rig = ob
    elif ob.name == "R_FMA7163":
        skin = ob
    else:
        nails.append(ob)
skin.name = "HandSkin"
rig.name = "HandRig"
rig.show_in_front = False
rig.hide_render = True
anatomy = bones + muscles + tendons
for ob in [skin] + nails + anatomy:
    for m in ob.modifiers:
        if m.type == "ARMATURE":
            m.object = rig
for ob in anatomy:
    assert ob.parent is rig, (ob.name, ob.parent)
    ob.hide_render = False
    ob.hide_viewport = False
log("hand appended", skin.name, len(skin.data.vertices), "verts", "skin look", SKIN_LOOK,
    f"bones {len(bones)} muscles {len(muscles)} tendons {len(tendons)}")


def smooth_wrist_weights(ob, y0=-0.028, y1=-0.004, fall=0.008, iters=20, rate=0.5):
    """The Crimpwell skin's forearm/wrist weights step from 0 to 1 between neighbouring vertices
    in a ring at rig Y ~ -15 mm (dorsal-ulnar worst). Any wrist rotation (WRIST_EXT) then shears
    that ring into a jagged fold that the ghost rim and the real skin's specular both trace.
    The rest mesh is smooth there, so diffuse all deform weights over the mesh graph inside a
    soft Y band and renormalise. In memory only; the source .blend is never saved."""
    me_ = ob.data
    n_ = len(me_.vertices)
    co_ = np.empty(n_ * 3)
    me_.vertices.foreach_get("co", co_)
    y_ = co_.reshape(-1, 3)[:, 1]
    mask = np.clip(np.minimum((y_ - (y0 - fall)) / fall, ((y1 + fall) - y_) / fall), 0.0, 1.0)
    mask = mask * mask * (3.0 - 2.0 * mask)
    idx = np.where(mask > 0.0)[0]
    E_ = np.empty(len(me_.edges) * 2, dtype=np.int64)
    me_.edges.foreach_get("vertices", E_)
    E_ = E_.reshape(-1, 2)
    deg = np.zeros(n_)
    np.add.at(deg, E_[:, 0], 1)
    np.add.at(deg, E_[:, 1], 1)
    groups = list(ob.vertex_groups)
    W = np.zeros((n_, len(groups)))
    for v in me_.vertices:
        for g in v.groups:
            W[v.index, g.group] = g.weight
    W0 = W.copy()
    for _ in range(iters):
        acc = np.zeros_like(W)
        np.add.at(acc, E_[:, 0], W[E_[:, 1]])
        np.add.at(acc, E_[:, 1], W[E_[:, 0]])
        W += (rate * mask)[:, None] * (acc / np.maximum(deg, 1)[:, None] - W)
    W /= np.maximum(W.sum(axis=1, keepdims=True), 1e-9)
    for k, g in enumerate(groups):
        col = W[idx, k]
        g.remove(idx[col <= 1e-4].tolist())
        for vi, wv in zip(idx[col > 1e-4], col[col > 1e-4]):
            g.add([int(vi)], float(wv), "REPLACE")
    log(f"wrist weights smoothed on {len(idx)} verts, max change {np.abs(W - W0).max():.2f}")


smooth_wrist_weights(skin)

# ---------------------------------------------------------------------------
# 3. finger pose.  Rig space: fingers +Y, palm +Z, dorsum -Z, thumb -X (anatomically a left hand).

Z = Vector((0, 0, 1))


def bone_axis(name, which="flex"):
    b = rig.data.bones[name]
    d = (b.tail_local - b.head_local).normalized()
    if which == "flex":
        return d.cross(Z).normalized()      # +angle curls toward the palm
    return Z.copy()


def local_quat(name, axis_arm, ang):
    b = rig.data.bones[name]
    ax = (b.matrix_local.to_3x3().inverted() @ axis_arm).normalized()
    return Quaternion(ax, ang)


# relaxed pose: (flex MCP, PIP, DIP) degrees and spread (about palm normal)
# the fingers fan a little (index to little finger) and curl a little more toward the little
# finger, so seen end-on from the camera they separate instead of merging into one shape
SPREAD = float(os.environ.get("LOOPR_SPREAD", "3.6"))
RELAX = {
    "R_D2": ((-3, 5, 2), -2.0 * SPREAD),
    "R_D3": ((-1, 8, 3), -0.5 * SPREAD),
    "R_D4": ((2, 11, 5), 1.5 * SPREAD),
    "R_D5": ((5, 14, 7), 3.0 * SPREAD),
}
THUMB = {"R_D1_CMC": (3, -4), "R_D1_MCP": (5, 0), "R_D1_IP": (7, 0)}
WRIST_EXT = 3.0              # degrees of wrist extension so the hand doesn't hang


def pose_hand(amount=1.0, twitch=0.0):
    """Returns {bone: Quaternion}. amount 0 = rest (open), 1 = relaxed. twitch = extra flex deg."""
    out = {}
    for f, ((m, p, d), spread) in RELAX.items():
        for seg, ang in (("MCP", m), ("PIP", p), ("DIP", d)):
            name = f"{f}_{seg}"
            q = local_quat(name, bone_axis(name), math.radians(ang * amount + twitch * (0.6 if seg == "DIP" else 1.0)))
            if seg == "MCP":
                q = local_quat(name, Z, math.radians(spread * amount)) @ q
            out[name] = q
    out["wrist"] = local_quat("wrist", bone_axis("wrist"), math.radians(-WRIST_EXT))
    for name, (flex, add) in THUMB.items():
        q = local_quat(name, bone_axis(name), math.radians(flex * amount + 0.5 * twitch))
        if add:
            q = local_quat(name, Z, math.radians(add * amount)) @ q
        out[name] = q
    return out


def key_pose(frame, amount, twitch=0.0, interp="BEZIER", easing="AUTO"):
    for name, q in pose_hand(amount, twitch).items():
        pb = rig.pose.bones[name]
        pb.rotation_mode = "QUATERNION"
        kf(pb, "rotation_quaternion", frame, q, interp, easing)


# fingers relax during the glide, tiny reaction after the click
key_pose(F_FIRST, 0.35, interp="SINE", easing="EASE_IN_OUT")
key_pose(fr(1.55), 1.0)
key_pose(F_CLICK, 1.0)
key_pose(F_CLICK + 6, 1.0, twitch=2.2)
key_pose(F_CLICK + 26, 1.0)

scene.frame_set(F_WRAP + 20)
bpy.context.view_layer.update()

# ---------------------------------------------------------------------------
# 4. wrist cross-section -> band loop (rig space, rig at identity)

rig.matrix_world = Matrix.Identity(4)
bpy.context.view_layer.update()
dg = bpy.context.evaluated_depsgraph_get()
sk_eval = skin.evaluated_get(dg)
me_eval = sk_eval.to_mesh()
V = np.empty(len(me_eval.vertices) * 3)
me_eval.vertices.foreach_get("co", V)
V = V.reshape(-1, 3)
E = np.empty(len(me_eval.edges) * 2, dtype=np.int64)
me_eval.edges.foreach_get("vertices", E)
E = E.reshape(-1, 2)
tri_polys = [tuple(p.vertices) for p in me_eval.polygons]
sk_eval.to_mesh_clear()
V = (np.array(skin.matrix_world) @ np.c_[V, np.ones(len(V))].T).T[:, :3]


def plane_points(o, n, near=0.07):
    d = (V - o) @ n
    a, b = E[:, 0], E[:, 1]
    m = (d[a] > 0) != (d[b] > 0)
    t = d[a[m]] / (d[a[m]] - d[b[m]])
    pts = V[a[m]] + t[:, None] * (V[b[m]] - V[a[m]])
    return pts[np.linalg.norm(pts - o, axis=1) < near]


def polygon_centroid(pts2):
    c = pts2.mean(axis=0)
    ang = np.arctan2(pts2[:, 1] - c[1], pts2[:, 0] - c[0])
    p = pts2[np.argsort(ang)]
    x, y = p[:, 0], p[:, 1]
    x1, y1 = np.roll(x, -1), np.roll(y, -1)
    cr = x * y1 - x1 * y
    A = cr.sum() / 2
    return np.array([((x + x1) * cr).sum() / (6 * A), ((y + y1) * cr).sum() / (6 * A)])


def slice_centroid(o, n):
    pts = plane_points(o, n)
    n = n / np.linalg.norm(n)
    u = np.cross(n, [0, 0, 1.0]); u /= np.linalg.norm(u)
    v = np.cross(n, u)
    c2 = polygon_centroid(np.c_[(pts - o) @ u, (pts - o) @ v])
    return o + c2[0] * u + c2[1] * v


BAND_Y = -0.046
axis = np.array([0.0, 1.0, 0.0])
cen = np.array([0.0, BAND_Y, 0.0])
for _ in range(3):
    c_dist = slice_centroid(cen + axis * 0.022, axis)
    c_prox = slice_centroid(cen - axis * 0.030, axis)
    axis = (c_dist - c_prox) / np.linalg.norm(c_dist - c_prox)
    cen = slice_centroid(np.array([0.0, BAND_Y, 0.0]) + 0 * axis, axis)
e_w = axis
dors = np.array([0.0, 0.0, -1.0])
e_y = dors - (dors @ e_w) * e_w
e_y /= np.linalg.norm(e_y)
e_x = np.cross(e_y, e_w)
O = cen
log("band axis", np.round(e_w, 3), "centre", np.round(O, 4))

# local axis check: centroids of slices across the band's own width only
_ca = slice_centroid(O + e_w * 0.012, e_w)
_cb = slice_centroid(O - e_w * 0.012, e_w)
_ax = (_ca - _cb) / np.linalg.norm(_ca - _cb)
log(f"band plane vs local forearm axis (+-12 mm): {math.degrees(math.acos(min(1.0, abs(_ax @ e_w)))):.1f} deg")

# Wrist cross-sections across the band's width, in band space (mm): x = e_x, y = e_y, w = e_w.
W_SL = np.arange(-16.5, 16.51, 0.5)
slices = []
for wk in W_SL:
    pp = plane_points(O + e_w * wk * 0.001, e_w, near=0.06)
    slices.append(np.c_[(pp - O) @ e_x, (pp - O) @ e_y] * 1000.0)   # mm


def convex_hull(P):
    P = sorted(map(tuple, P))
    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lo, up = [], []
    for p in P:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], p) <= 0:
            lo.pop()
        lo.append(p)
    for p in reversed(P):
        while len(up) >= 2 and cross(up[-2], up[-1], p) <= 0:
            up.pop()
        up.append(p)
    return np.array(lo[:-1] + up[:-1])


hull = convex_hull(np.vstack(slices))
hc = polygon_centroid(hull)
N_TH = 1440
TH = np.linspace(0, 2 * math.pi, N_TH, endpoint=False)
DIRS = np.c_[np.cos(TH), np.sin(TH)]


def offset_radius(pts, r):
    """Minkowski offset of one (star-shaped) slice by a disc of radius r, as the distance from
    hc along each ray TH. The slice is closed and densified to 0.2 mm, then each ray's far
    intersection with every point's disc is taken; a disc-offset star-shaped set stays star-shaped."""
    rel = pts - hc
    ang = np.arctan2(rel[:, 1], rel[:, 0])
    rel = rel[np.argsort(ang)]
    nxt = np.roll(rel, -1, axis=0)
    seg = np.linalg.norm(nxt - rel, axis=1)
    dense = [rel[i] + (nxt[i] - rel[i]) * t for i in range(len(rel))
             for t in np.linspace(0.0, 1.0, max(1, int(math.ceil(seg[i] / 0.2))), endpoint=False)]
    dense = np.array(dense)
    a_ = dense @ DIRS.T                                   # (points, rays) projections
    h2 = (dense ** 2).sum(1)[:, None] - a_ ** 2
    t_ = np.where(h2 <= r * r, a_ + np.sqrt(np.maximum(r * r - h2, 0.0)), -1e9)
    return t_.max(axis=0)


RW = np.array([offset_radius(sl, GAP) for sl in slices])     # (w, ray): skin offset by GAP


def circ_smooth(v, sigma_deg):
    k = int(round(sigma_deg / 360.0 * N_TH * 3))
    x = np.arange(-k, k + 1)
    g = np.exp(-0.5 * (x / (sigma_deg / 360.0 * N_TH)) ** 2)
    g /= g.sum()
    return np.convolve(np.r_[v[-k:], v, v[:k]], g, mode="valid")


def envelope_smooth(v, sigma_deg, iters=30):
    """smooth, never below v: a taut membrane over small dents"""
    out = v.copy()
    for _ in range(iters):
        out = np.maximum(v, circ_smooth(out, sigma_deg))
    return out


# The strap's inner face at across-position w sits at radius B_TH + A_TH * w: a line fitted to the
# skin across the pod's width (the forearm tapers toward the wrist), raised until it clears every
# slice. So the strap hugs the skin at both edges instead of standing off at the narrow one.
_wm = np.abs(W_SL) <= POD_W / 2 + 0.01
_wv = W_SL[_wm]
A_TH = circ_smooth(((RW[_wm] - RW[_wm].mean(0)) * (_wv - _wv.mean())[:, None]).sum(0) / ((_wv - _wv.mean()) ** 2).sum(), 10.0)
B_TH = envelope_smooth((RW[_wm] - A_TH[None] * _wv[:, None]).max(0), 2.0)
_st = np.abs(W_SL) <= STRAP_W / 2 + 0.01
CAP_ENV = RW.max(0)                                        # the cap is flat and wider than the strap


def th_of(xy):
    xy = np.atleast_2d(xy)
    return np.mod(np.arctan2(xy[:, 1] - hc[1], xy[:, 0] - hc[0]), 2 * math.pi)


def per_th(arr, th):
    return np.interp(th, np.r_[TH, 2 * math.pi], np.r_[arr, arr[0]])


def slope_at(xy):
    return per_th(A_TH, th_of(xy))


def rad_clear(env, xy):
    """radial clearance of points outside a star-shaped envelope around hc (+ = outside)"""
    xy = np.atleast_2d(xy)
    return np.linalg.norm(xy - hc, axis=1) - per_th(env, th_of(xy))


SKIN_C = hc + DIRS * B_TH[:, None]                         # strap inner face at w = 0, ccw
_gw = RW[_st] - (B_TH[None] + A_TH[None] * W_SL[_st][:, None])
log(f"wrist fit: slope across the band {np.degrees(np.arctan(A_TH.min())):+.1f} to {np.degrees(np.arctan(A_TH.max())):+.1f} deg; "
    f"inner face off the skin at the strap edges and centre: {GAP - _gw.max():.2f} mm at least (hugs), "
    f"median {np.median(GAP - _gw.max(0)):.2f} mm, worst {np.max(GAP - _gw.max(0)):.2f} mm")

# Rigid-part loop: the pod and its hardware sit on a smooth curve through the top of the wrist
# (a stiff pod does not follow tendons). Fourier fit of B_TH, lifted by its deficit over the pod's
# arc only, so the rest of the loop stays at the skin.
K = 6
Bm = np.c_[[np.ones_like(TH)] + [f(k * TH) for k in range(1, K + 1) for f in (np.cos, np.sin)]].T
coef, *_ = np.linalg.lstsq(Bm, B_TH, rcond=None)
R_FIT = Bm @ coef
_pod_arc = np.abs(np.mod(TH - math.pi / 2 + math.pi, 2 * math.pi) - math.pi) < math.radians(48)
R_FIT = R_FIT + max(0.0, float((B_TH - R_FIT)[_pod_arc].max()))
TH2 = np.linspace(0, 2 * math.pi, 8192, endpoint=False)
R2 = per_th(R_FIT, TH2)
Bc = hc + np.c_[R2 * np.cos(TH2), R2 * np.sin(TH2)]
# re-parameterise by arc length, s = 0 at the top (dorsal direction +y from hull centre)
seg = np.linalg.norm(np.roll(Bc, -1, axis=0) - Bc, axis=1)
L_LOOP = float(seg.sum())
s_raw = np.r_[0.0, np.cumsum(seg)[:-1]]
top_i = int(np.argmin(np.abs(TH2 - math.pi / 2)))
s_raw = (s_raw - s_raw[top_i]) % L_LOOP
order = np.argsort(s_raw)
s_sorted = s_raw[order]
B_sorted = Bc[order]
DS = 0.1
S_GRID = np.arange(0.0, L_LOOP, DS)


def _per_interp(s, arr):
    s = np.mod(s, L_LOOP)
    xs = np.r_[s_sorted - L_LOOP, s_sorted, s_sorted + L_LOOP]
    return np.interp(s, xs, np.r_[arr, arr, arr])


LX = _per_interp(S_GRID, B_sorted[:, 0])
LY = _per_interp(S_GRID, B_sorted[:, 1])


def loop_pt(s):
    s = np.asarray(s, dtype=np.float64)
    return np.c_[np.interp(np.mod(s, L_LOOP), np.r_[S_GRID, L_LOOP], np.r_[LX, LX[0]]),
                 np.interp(np.mod(s, L_LOOP), np.r_[S_GRID, L_LOOP], np.r_[LY, LY[0]])]


def loop_frame(s, eps=0.05):
    p = loop_pt(s)
    t = loop_pt(np.asarray(s) + eps) - loop_pt(np.asarray(s) - eps)
    t /= np.linalg.norm(t, axis=1)[:, None]
    n = np.c_[t[:, 1], -t[:, 0]]        # outward for ccw
    return p, t, n


_sk_len = float(np.linalg.norm(np.roll(SKIN_C, -1, axis=0) - SKIN_C, axis=1).sum())
log(f"rigid loop {L_LOOP:.1f} mm, skin loop {_sk_len:.1f} mm (inner face at w = 0), "
    f"hull w {np.ptp(hull[:,0]):.1f} h {np.ptp(hull[:,1]):.1f}")

# ---------------------------------------------------------------------------
# 5. band mechanics, after research/whoop4-band-mechanics.md (a generic look-alike, no marks)
#
# Parts: the pod (window against the skin, long side around the wrist); a U-shaped metal frame
# hinged on pins at pod end A (hinge axis along the forearm); a blank cap on the strap's fixed
# end, hooked on the frame's free end and free to pivot there; a C-bar slider at pod end B that
# holds the strap's other end (the spare tail stays hidden inside it).
# Closed: from the slider the strap runs under the wrist, up at end A, back over the pod top
# between the frame rails, to the cap, which sits over end B.
# Motion (simplified: the cap end starts free, so the loop never passes over the hand): the pod
# lands on the wrist with the frame parked open and the strap hanging open from the slider; the
# strap wraps the wrist from end B until its cap meets the frame's tip; the frame swings about the
# hinge, up and over the pod, drags the strap over the top and takes up the slack; the cap lands
# over end B at the click. See "# --- timeline" below.
# 2D work is in band space, mm: x = e_x (ulnar), y = e_y (dorsal), w = e_w (toward the fingers).
# Loop arc length s: s = 0 on top, s > 0 toward the radial (thumb) side.

A_SIGN = {"radial": 1, "ulnar": -1}[os.environ.get("LOOPR_HINGE", "ulnar")]   # side of hinge end A
ORIENT = A_SIGN                  # strap traversal from the cap: over the top toward A, then under
S_A = A_SIGN * POD_L / 2         # pod end A (hinge)
S_B = -S_A                       # pod end B (slider; the cap lands over it)
RAIL_W = 1.3
RAIL_Y = POD_W / 2 + RAIL_W / 2 + 0.3
RAIL_Z1 = POD_H + STRAP_T + 0.5
RAIL_Z0 = RAIL_Z1 - float(os.environ.get("LOOPR_RAIL_H", "2.8"))
HINGE_IN, HINGE_Z = 3.8, float(os.environ.get("LOOPR_HINGE_Z", "5.4"))   # hinge pin: from end A, height
# (high on the pod side: the rails above the pin swing to below it when the frame is open)
K_IN, K_Z = 4.2, POD_H + 0.3               # cap hook axis (frame tip) when closed: from end B, height
# The cap is a thin plate on the strap's end: it rides 0.45 mm proud of the knit, runs 1.8 mm in
# from the hook axis and follows the pod's end rounding down over end B, so closed it sits nearly
# flush with the pod's end instead of standing on it as a block.
CAP_W = 2 * RAIL_Y + RAIL_W + 0.4
CAP_T = STRAP_T + 0.1 + 0.45               # holds the strap's end (0.1 under it), 0.45 over it
CAP_IN = 1.8                               # past the hook axis toward end A
CAP_WRAP = 62.0                            # deg the plate follows the end rounding down
CAP_RC = 0.7                               # edge radius
SLIDER_T = 3.4
OVERTRAVEL = {1: -0.9, 2: -0.45, 3: 0.12, 4: 0.04}   # deg past closed, frames after the click


def q_to_s(q):
    """distance q from end A toward end B -> loop arc length s"""
    return S_A - A_SIGN * np.asarray(q, dtype=np.float64)


def closed_loop_fn(s):
    p, _, n = loop_frame(s)
    return p, n


def flat_to_band(flat):
    """pod-flat (s, w, radial) mm -> band space (x, y, w) mm along the closed wrist loop. Across
    the band the radial offset follows the wrist's taper (slope_at), so the pod and its hardware
    sit on the skin at both edges."""
    pos, n = closed_loop_fn(flat[:, 0])
    rad = flat[:, 2:3] + slope_at(pos)[:, None] * flat[:, 1:2]
    return np.c_[pos + n * rad, flat[:, 1]]


def rot2(v, deg):
    a = math.radians(deg)
    c, s_ = math.cos(a), math.sin(a)
    return np.c_[c * v[:, 0] - s_ * v[:, 1], s_ * v[:, 0] + c * v[:, 1]]


def hull_np(P):
    return convex_hull(np.round(np.asarray(P, dtype=np.float64), 4))


def outside_dist(Hh, P):
    """convex ccw polygon: max over edges of the outward distance (negative = inside)"""
    e = np.roll(Hh, -1, axis=0) - Hh
    nrm = np.c_[e[:, 1], -e[:, 0]] / np.linalg.norm(e, axis=1)[:, None]
    return ((P[:, None, :] - Hh[None]) * nrm[None]).sum(-1).max(axis=1)


def pillow(v):
    """dome the top of the pod slightly so the edges read soft and pillowed"""
    v = v.copy()
    top = np.clip((v[:, 2] - (POD_H - POD_R)) / POD_R, 0.0, 1.0)
    fx = np.clip(1.0 - (v[:, 0] / (POD_L / 2)) ** 2, 0.0, 1.0)
    fy = np.clip(1.0 - (v[:, 1] / (POD_W / 2)) ** 2, 0.0, 1.0)
    v[:, 2] += POD_PILLOW * top * fx * fy
    return v


# --- rigid parts in their closed pose (pod-flat mm, then band space mm)
pv, pf = rounded_slab((POD_L, POD_W, POD_H), POD_R, POD_RP, (0.0, 0.0, POD_H / 2), step_edge=0.22, step_mid=0.8)
pv_flat = pv.copy()                                        # the shader's parting line and finish zones
pv = pillow(pv)
iv, iff = rounded_slab((25.0, 15.0, 0.12), 0.05, 3.0, (0.0, 0.0, POD_H - 0.01), step_edge=0.05, step_mid=0.8)   # 0.05 mm step
iv_flat = iv.copy()
iv = pillow(iv)
lv, lf = rounded_slab((11.0, 7.0, 0.30), 0.12, 2.4, (0.0, 0.0, 0.06), step_edge=0.1, step_mid=0.6)
b_out = -A_SIGN                                            # outward from end B along s
slv, slf = rounded_slab((SLIDER_T, POD_W, 3.8), 1.2, 1.6, (S_B + b_out * (0.15 + SLIDER_T / 2), 0.0, 0.5 + 1.9),
                        step_edge=0.15, step_mid=0.8)

# frame: one bent bar per side. It runs along the pod's long edge as a rail (a D section: flat
# toward the pod, a rounded bulge outward), bends down over end A into the knuckle and ends on
# the hinge pin. Rounded ends at both tips.
q_h, q_k = HINGE_IN, POD_L - K_IN
RAIL_ZC = (RAIL_Z0 + RAIL_Z1) / 2
RAIL_HH = (RAIL_Z1 - RAIL_Z0) / 2
BEND_R = RAIL_HH + 0.25                                   # centre-line bend radius over end A: a tight, machined turn
_bar = []
_qs = q_h
_zb = HINGE_Z - 0.5                                       # knuckle tip (the pin sits in it)
for z_ in np.arange(_zb, RAIL_ZC - BEND_R, 0.3):
    _bar.append((_qs, z_))
for a_ in np.linspace(math.pi, math.pi / 2, 19):
    _bar.append((_qs + BEND_R + BEND_R * math.cos(a_), RAIL_ZC - BEND_R + BEND_R * math.sin(a_)))
for q_ in np.arange(_qs + BEND_R + 0.3, q_k + 1.5 - 0.65, 0.3):
    _bar.append((q_, RAIL_ZC))
_bar = np.array(_bar)
fr_parts = []
for side in (-1, 1):
    prof = d_profile(2 * RAIL_HH, RAIL_W, side)
    # profile a along the bar's normal; the normal of a path heading +q is +z, so a = z - centre
    bv, bf, barc = sweep_profile(_bar, prof, end0=0.4, end1=0.65)
    bv[:, 1] += side * (RAIL_Y - RAIL_W / 2)
    xq = bv[:, 0].copy()
    bv[:, 0] = q_to_s(xq)
    uv_ = np.c_[xq, bv[:, 1]] * 0.001                      # uv x: distance from end A (glint)
    br_ = np.c_[barc, bv[:, 1]] * 0.001                    # brush: arc length along the bar
    if _signed_vol(bv, bf) < 0:
        bf = [tuple(reversed(f_)) for f_ in bf]
    fr_parts.append((bv, bf, uv_, br_))
    # pin into the pod side
    v_, f_ = rounded_slab((1.6, 2.2, 1.6), 0.6, 0.79, (float(q_to_s(q_h)), side * (POD_W / 2 - 0.1), HINGE_Z),
                          step_edge=0.12, step_mid=0.5)
    fr_parts.append((v_, f_, np.c_[np.full(len(v_), q_h), v_[:, 1]] * 0.001, np.c_[v_[:, 2], v_[:, 1]] * 0.001))
fv, ff, f_uv, f_br = [], [], [], []
for v_, f_, u_, b_ in fr_parts:
    ff += [tuple(i + len(fv) for i in f) for f in f_]
    fv += list(v_)
    f_uv += list(u_)
    f_br += list(b_)
fv = np.array(fv)
f_uv = np.array(f_uv)
f_br = np.array(f_br)

POD_B = flat_to_band(pv)
INSET_B = flat_to_band(iv)
SENS_B = flat_to_band(lv)
SLIDER_B = flat_to_band(slv)
FRAME_B = flat_to_band(fv)
H2 = flat_to_band(np.array([[float(q_to_s(q_h)), 0.0, HINGE_Z]]))[0, :2]
K0 = flat_to_band(np.array([[float(q_to_s(q_k)), 0.0, K_Z]]))[0, :2]
SL_T = flat_to_band(np.array([[S_B + b_out * (0.15 + SLIDER_T / 2), 0.0, 0.6]]))[0, :2]

# pod silhouette for the strap to wrap (at w = 0, plus 0.25 mm clearance over the top and ends)
_c = POD_L / 2 - POD_R
_xs = np.linspace(-_c, _c, 41)
_prof = [np.c_[_xs, POD_H + POD_PILLOW * (1 - (_xs / (POD_L / 2)) ** 2) + 0.25]]
for sg in (-1, 1):
    a_ = np.linspace(0, math.pi / 2, 9)
    _prof.append(np.c_[sg * (_c + (POD_R + 0.25) * np.sin(a_)), POD_H - POD_R + (POD_R + 0.25) * np.cos(a_)])
    _prof.append(np.c_[np.full(5, sg * (POD_L / 2 + 0.25)), np.linspace(POD_H - POD_R, 0.0, 5)])
_prof = np.vstack(_prof)
POD_SIL = flat_to_band(np.c_[_prof[:, 0], np.zeros(len(_prof)), _prof[:, 1]])[:, :2]
# the same silhouette in order, end A foot -> over the top -> end B foot
_c_pts = []
for sg in (-1, 1):
    a_ = np.linspace(0, math.pi / 2, 12)
    arc_ = np.c_[sg * (_c + (POD_R + 0.25) * np.sin(a_)), POD_H - POD_R + (POD_R + 0.25) * np.cos(a_)]
    side_ = np.c_[np.full(8, sg * (POD_L / 2 + 0.25)), np.linspace(POD_H - POD_R, 0.0, 8)]
    _c_pts.append(np.vstack([arc_, side_[1:]]))
_ordered = np.vstack([_c_pts[0][::-1], np.c_[_xs, POD_H + POD_PILLOW * (1 - (_xs / (POD_L / 2)) ** 2) + 0.25], _c_pts[1]])
POD_PROFILE = flat_to_band(np.c_[_ordered[:, 0], np.zeros(len(_ordered)), _ordered[:, 1]])[:, :2]


def taut_path(K, O, target):
    """Shortest strap path from K around the convex obstacle O (ccw hull), leaving K toward end A,
    running under the wrist and ending at the boundary point nearest target."""
    Hh = O if ORIENT > 0 else O[::-1]
    rel = Hh - K
    cr = rel[:, None, 0] * rel[None, :, 1] - rel[:, None, 1] * rel[None, :, 0]
    ok = (ORIENT * cr).min(axis=1) >= -1e-6
    if ok.any():
        idx = np.where(ok)[0]
        i = int(idx[np.argmax(np.linalg.norm(rel[idx], axis=1))])
    else:
        i = int(np.argmin(np.linalg.norm(rel, axis=1)))
    j = int(np.argmin(np.linalg.norm(Hh - target, axis=1)))
    n = len(Hh)
    steps = (j - i) % n
    pts = np.vstack([K[None], Hh[(i + np.arange(steps + 1)) % n]])
    return pts


def resample(P, step=0.25):
    seg = np.linalg.norm(np.diff(P, axis=0), axis=1)
    keep = np.r_[True, seg > 1e-6]
    P = P[keep]
    s_ = np.r_[0.0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]
    L = s_[-1]
    t = np.linspace(0.0, L, max(8, int(math.ceil(L / step)) + 1))
    return np.c_[np.interp(t, s_, P[:, 0]), np.interp(t, s_, P[:, 1])], L


def smooth_path(P, iters=6):
    P = P.copy()
    for _ in range(iters):
        P[1:-1] = 0.25 * P[:-2] + 0.5 * P[1:-1] + 0.25 * P[2:]
    return P


def path_normals(P):
    t = np.gradient(P, axis=0)
    t /= np.linalg.norm(t, axis=1)[:, None]
    return t, ORIENT * np.c_[t[:, 1], -t[:, 0]]      # outward (the obstacle is on the other side)


# --- timeline
# Band in: the pod drops onto the back of the wrist, tilted, and lands softly. The frame stands
# parked open at end A. The strap hangs open from the slider at end B, its cap end free.
# Wrap: the strap rolls onto the wrist from end B, down the near side, across the underside and
# up the far side, at the loop's small offset from the skin. Its free part curls a little more
# with every frame until its cap reaches the frame's tip (F_HOOK).
# Close: the frame swings over the pod, drags the strap across the top and tightens the loop;
# the cap lands over end B at the click.
F_LAND = F_WRAP - 2                        # pod down
F_HOOK = F_CLICK - 32                      # cap reaches the frame's tip
PHI_PARK = float(os.environ.get("LOOPR_PHI_PARK", "150"))       # frame parked open (deg)
DROP = np.array([float(v) for v in os.environ.get("LOOPR_DROP", "-150,55").split(",")])   # mm (x, y) at bandIn
DROP_TILT = float(os.environ.get("LOOPR_DROP_TILT", "-14"))     # deg, about the pod centre, at bandIn
K_HANG = float(os.environ.get("LOOPR_K_HANG", "0.22"))          # hanging strap: share of the wrap's curl
HANG_OUT = float(os.environ.get("LOOPR_HANG_OUT", "62"))        # deg the open strap lies out from end B
HANG_SWING = float(os.environ.get("LOOPR_HANG_SWING", "25"))    # extra deg it trails while the pod drops
WRAP_EASE = float(os.environ.get("LOOPR_WRAP_EASE", "1.5"))     # >1: the wrap accelerates
STRAP_CLEAR = 0.5                          # mm the strap's inner face keeps off the wrist obstacle
F_BAKE0, F_BAKE1 = F_BAND_IN - 1, F_CLICK + 6
POD_C = flat_to_band(np.array([[0.0, 0.0, POD_H / 2]]))[0, :2]


def drop_amt(f):
    t = np.clip((f - F_BAND_IN) / (F_LAND - F_BAND_IN), 0.0, 1.0)
    return float((1.0 - t) ** 3)                              # fast in, soft landing


def pod_xf(f):
    r = drop_amt(f)
    return DROP_TILT * r, DROP * r                            # tilt (deg), offset (mm)


def xf2(P, rho, d):
    return rot2(np.atleast_2d(P) - POD_C, rho) + POD_C + d


def phi_of(f):
    if f <= F_HOOK:
        return PHI_PARK
    if f <= F_CLICK:
        t = (f - F_HOOK) / (F_CLICK - F_HOOK)
        return PHI_PARK * (1.0 - t ** 2.0)                   # ease in: arrives at full speed
    return OVERTRAVEL.get(int(round(f - F_CLICK)), 0.0)


def frame_pts(phi, rho=0.0, d=(0.0, 0.0)):
    """frame rails, band space mm, rotated open by phi about the hinge, then moved with the pod"""
    xy = rot2(FRAME_B[:, :2] - H2, A_SIGN * phi) + H2
    return np.c_[xf2(xy, rho, np.asarray(d)), FRAME_B[:, 2]]


def cap_pivot(phi, rho=0.0, d=(0.0, 0.0)):
    return xf2(rot2((K0 - H2)[None], A_SIGN * phi) + H2, rho, np.asarray(d))[0]


LOOP_O = hull_np(SKIN_C)


def swing_clearance(phi_open):
    worst = 1e9
    for ph in np.linspace(0.0, phi_open, 45):
        worst = min(worst, outside_dist(LOOP_O, frame_pts(ph)[::5, :2]).min(),
                    outside_dist(LOOP_O, cap_pivot(ph)[None])[0] - 3.0)
    return worst


# LOOP_O is the snug fit, GAP off the skin, so 0 here is still GAP off the wrist (--verify checks in 3D)
if swing_clearance(PHI_PARK) <= 0.0:
    raise SystemExit(f"frame parked at {PHI_PARK} deg does not clear the wrist ({swing_clearance(PHI_PARK):.2f} mm)")
log(f"hinge end A {'radial' if A_SIGN > 0 else 'ulnar'}, frame parked {PHI_PARK:.1f} deg open, "
    f"swing clearance {swing_clearance(PHI_PARK):.2f} mm over the loop")

def bridge_pockets(Pc, depth=1.5):
    """Closed ccw outline -> the same outline with only its deep pockets bridged (the corners
    where the pod's ends meet the wrist). Shallow dents in the skin stay: the strap follows them."""
    n = len(Pc)
    idx = sorted(range(n), key=lambda i: (Pc[i, 0], Pc[i, 1]))
    def cross(o, a, b):
        return (Pc[a, 0] - Pc[o, 0]) * (Pc[b, 1] - Pc[o, 1]) - (Pc[a, 1] - Pc[o, 1]) * (Pc[b, 0] - Pc[o, 0])
    lo, up = [], []
    for i in idx:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], i) <= 0:
            lo.pop()
        lo.append(i)
    for i in reversed(idx):
        while len(up) >= 2 and cross(up[-2], up[-1], i) <= 0:
            up.pop()
        up.append(i)
    hv = sorted(set(lo[:-1] + up[:-1]))
    keep = []
    for k_, i in enumerate(hv):
        j = hv[(k_ + 1) % len(hv)]
        span = [(i + m) % n for m in range(1, (j - i) % n)]
        keep.append(i)
        if not span:
            continue
        a_, b_ = Pc[i], Pc[j]
        e_ = (b_ - a_) / max(np.linalg.norm(b_ - a_), 1e-9)
        d_ = np.abs((Pc[span] - a_) @ np.array([-e_[1], e_[0]]))
        if d_.max() <= depth:
            keep += span
    out = Pc[keep]
    return resample(np.vstack([out, out[:1]]), 0.25)[0][:-1]


def ray_max(pts, r=0.15):
    """per ray TH from hc: the farthest point of discs of radius r around pts (-1 where none)"""
    rel = pts - hc
    a_ = rel @ DIRS.T
    h2 = (rel ** 2).sum(1)[:, None] - a_ ** 2
    t_ = np.where((h2 <= r * r) & (a_ > 0), a_ + np.sqrt(np.maximum(r * r - h2, 0.0)), -1.0)
    return t_.max(axis=0)


def outline_with_pod():
    """The strap's snug path around the wrist with the pod on it (w = 0, ccw from +x): the skin
    loop, or the pod's silhouette where that stands higher, with the pod-end corners bridged."""
    prof, _ = resample(POD_PROFILE, 0.15)
    R_ = np.maximum(B_TH, ray_max(prof))
    return bridge_pockets(hc + DIRS * R_[:, None])


OB = outline_with_pod()
R_OB = ray_max(OB, 0.14)                              # the outline as a radius per ray
log(f"snug outline {np.linalg.norm(np.roll(OB, -1, axis=0) - OB, axis=1).sum():.1f} mm around, {len(OB)} points")


def contact_slope(P):
    """the wrist's taper per strap point, full where the strap lies on the skin or the pod and
    fading out over 3 mm as it lifts off"""
    return np.clip(1.0 - np.abs(rad_clear(R_OB, P)) / 3.0, 0.0, 1.0) * slope_at(P)


def route(phi):
    """snug strap path, cap -> slider: from the cap on the frame tip, over end A, around the
    underside and up to the slider, at the loop's offset from the skin"""
    P = taut_path(cap_pivot(phi), OB, SL_T)
    P, _ = resample(P)
    return smooth_path(P)


def arc(P):
    return np.r_[0.0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]


G_PARK = route(PHI_PARK)[::-1]                        # slider -> frame tip
G_S = arc(G_PARK)
_tg = np.gradient(G_PARK, axis=0)
G_TH = np.unwrap(np.arctan2(_tg[:, 1], _tg[:, 0]))
L_PARK = float(G_S[-1])


def wrap_shape(c, k, L, out=0.0):
    """slider -> free end. Up to arc c the strap lies on the snug route; beyond it, it follows
    the rest of the route's turning scaled by k (k = 1: the route itself, k < 1: it peels off)."""
    q = np.linspace(0.0, L, max(8, int(math.ceil(L / 0.25)) + 1))
    on = q <= c
    P = np.empty((len(q), 2))
    P[on] = np.c_[np.interp(q[on], G_S, G_PARK[:, 0]), np.interp(q[on], G_S, G_PARK[:, 1])]
    if (~on).any():
        qq = np.r_[c, q[~on]]
        th0 = np.interp(c, G_S, G_TH)
        th = th0 + k * (np.interp(np.minimum(qq, G_S[-1]), G_S, G_TH) - th0)
        thm = 0.5 * (th[1:] + th[:-1])
        dq = np.diff(qq)
        start = np.array([np.interp(c, G_S, G_PARK[:, 0]), np.interp(c, G_S, G_PARK[:, 1])])
        P[~on] = start + np.cumsum(np.c_[np.cos(thm) * dq, np.sin(thm) * dq], axis=0)
        if out:
            P[~on] = rot2(P[~on] - start, A_SIGN * out) + start     # lifted off the wrist, outward
    return P


def cap_outline(P, cap_end=0):
    """the cap's outline (band space, w = 0) for a strap path P"""
    Q = P if cap_end == 0 else P[::-1]
    i = min(len(Q) - 1, 8)
    t = (Q[i] - Q[0]) / np.linalg.norm(Q[i] - Q[0])
    n = ORIENT * np.array([t[1], -t[0]])
    return Q[0] + CAP_PROFILE[:, :1] * t + CAP_PROFILE[:, 1:2] * n


def strap_clear(P, cap_end=0):
    """radial clearance of the strap's inner face (w = 0) off its snug fit at the skin, and of the
    cap off the skin's widest slice (+ = outside); cap_end = which end carries the cap (0 first, -1 last)"""
    return min(float(rad_clear(B_TH, P[::2]).min()), float(rad_clear(CAP_ENV, cap_outline(P, cap_end)).min()))


P_final = route(0.0)
L_STRAP = float(arc(P_final)[-1])

# cap profile in the frame of its hook axis at the closed pose: u along the strap (toward end A),
# r outward. Its underside follows the pod's top and end rounding (POD_PROFILE, 0.25 mm off the
# pod), 0.1 mm under the strap's inner face.
_Pc, _ = resample(P_final, 0.2)
_K0 = _Pc[0]
_t0 = (_Pc[8] - _K0) / np.linalg.norm(_Pc[8] - _K0)
_n0 = ORIENT * np.array([_t0[1], -_t0[0]])
_pu = np.c_[(POD_PROFILE - _K0) @ _t0, (POD_PROFILE - _K0) @ _n0]
_pu = smooth_path(resample(_pu, 0.1)[0], 25)
_near = np.where(np.abs(_pu[:, 0]) < 1.5)[0]
_i0 = int(_near[np.argmax(_pu[_near, 1])])            # the profile under the hook axis
_dir = 1 if _pu[min(_i0 + 5, len(_pu) - 1), 0] < _pu[_i0, 0] else -1   # walking toward end B (u < 0)
_ang = np.degrees(np.arctan2(-np.gradient(_pu[:, 1]) * _dir, -np.gradient(_pu[:, 0]) * _dir))
_cb = [_i0]
while 0 < _cb[-1] < len(_pu) - 1 and _ang[_cb[-1]] < CAP_WRAP:
    _cb.append(_cb[-1] + _dir)
_cb_in = [i for i in range(_i0, 0 if _dir > 0 else len(_pu) - 1, -_dir) if _pu[i, 0] <= CAP_IN]
CAP_BOT = np.vstack([_pu[_cb_in[::-1]], _pu[_cb[1:]]])[::-1]     # from the outer (end B) edge inward
CAP_BOT[:, 1] -= 0.1 + max(0.0, float(CAP_BOT[np.argmin(np.abs(CAP_BOT[:, 0])), 1]))   # 0.1 under the strap at the hook
CAP_BOT = smooth_path(resample(CAP_BOT, 0.2)[0], 3)
_tb = np.gradient(CAP_BOT, axis=0)
_tb /= np.linalg.norm(_tb, axis=1)[:, None]
CAP_NB = np.c_[-_tb[:, 1], _tb[:, 0]]
CAP_NB *= np.sign(CAP_NB[np.argmin(np.abs(CAP_BOT[:, 0])), 1])  # outward: +r at the hook
CAP_PROFILE = np.vstack([CAP_BOT, CAP_BOT + CAP_NB * CAP_T])
CAP_SLOPE = float(slope_at(_K0)[0])
log(f"cap: {arc(CAP_BOT)[-1]:.1f} mm along the band, {CAP_T:.2f} mm thick, top {CAP_T - 0.1 - STRAP_T:.2f} mm "
    f"over the knit, u {CAP_BOT[:, 0].min():.1f} to {CAP_BOT[:, 0].max():.1f} mm, r down to {CAP_BOT[:, 1].min():.1f} mm")
L_HANG = float(os.environ.get("LOOPR_L_HANG_FRAC", "0.93")) * L_PARK    # relaxed knit
log(f"strap length {L_STRAP:.1f} mm closed, {L_PARK:.1f} mm when the cap meets the parked frame, "
    f"{L_HANG:.1f} mm hanging; loop length {L_LOOP:.1f} mm")

frames_b = np.arange(F_BAKE0, F_BAKE1 + 1)
states = {}
for f in frames_b:
    rho, d = pod_xf(f)
    phi = phi_of(f)
    if f < F_WRAP:
        # hanging: the relaxed strap trails outward while the pod drops, then swings in
        swing = HANG_SWING * drop_amt(f) ** 0.5
        base = wrap_shape(0.0, K_HANG, L_HANG, HANG_OUT)
        for extra in np.arange(0.0, 60.0, 1.0):
            P = rot2(base - base[0], A_SIGN * (swing + extra)) + base[0]
            P = xf2(P, rho, d)
            if strap_clear(P, -1) >= STRAP_CLEAR:
                break
        if extra > 0:
            log(f"frame {f}: hanging strap swung {extra:.0f} deg further out to clear the wrist")
        tag = "hang"
    elif f <= F_HOOK:
        tau = (f - F_WRAP) / (F_HOOK - F_WRAP)
        e = tau ** WRAP_EASE
        L = L_HANG + (L_PARK - L_HANG) * float(smoothstep(tau))
        c = L * e
        # it curls toward the wrist as it swings in (so it never dangles below the arm), then snugs
        k = K_HANG + (1.0 - K_HANG) * (0.86 * float(smoothstep(tau / 0.30)) + 0.14 * float(smoothstep(tau)))
        out = HANG_OUT * (1.0 - float(smoothstep(tau / 0.46)))       # the open strap swings in first
        P = wrap_shape(c, k, L, out)
        k_used = k
        while strap_clear(P, -1) < STRAP_CLEAR - GAP and k_used > 0.0:   # contact part sits at the loop
            k_used -= 0.02
            P = wrap_shape(c, k_used, L, out)
        if k_used < k:
            log(f"frame {f}: free strap uncurled {k:.2f} -> {k_used:.2f} to clear the wrist")
        tag = f"wrap c {c:5.1f} k {k:.2f}"
    else:
        P = route(phi)[::-1]
        tag = "close"
    P = P[::-1]                                   # cap -> slider, like the mesh
    P, _ = resample(P, 0.2)
    t_, n_ = path_normals(P)
    # the taper is sampled with the pod moved back onto the wrist (the strap rides with it)
    Pr = rot2(P - POD_C - d, -rho) + POD_C
    states[f] = dict(w=0.0, phi=phi, rho=rho, d=d, P=P, T=t_, N=n_, L=float(arc(P)[-1]),
                     SL=contact_slope(Pr),
                     clear=strap_clear(P), tag=tag)
for f in list(range(F_BAKE0, F_WRAP, 6)) + list(range(F_WRAP, F_BAKE1 + 1, 6)) + [F_HOOK, F_CLICK]:
    st = states[f]
    log(f"frame {f}: {st['tag']}, pod tilt {st['rho']:5.1f} deg off ({st['d'][0]:5.1f}, {st['d'][1]:5.1f}) mm, "
        f"frame {st['phi']:6.1f} deg, strap {st['L']:.1f} mm, strap clearance {st['clear']:+.2f} mm")

if os.environ.get("LOOPR_STOP") == "mechanics":
    raise SystemExit(0)

# ---------------------------------------------------------------------------
# 6. band objects. Rigid parts ride on PodMotion (and FrameHinge); the strap bakes one shape
#    key per frame, driven by the frame number.

band_anchor = bpy.data.objects.new("BandAnchor", None)
col_band.objects.link(band_anchor)
band_anchor.parent = rig
band_anchor.matrix_parent_inverse = Matrix.Identity(4)
MA = Matrix.Identity(4)
for i in range(3):
    MA[i][0], MA[i][1], MA[i][2], MA[i][3] = e_x[i], e_y[i], e_w[i], O[i]
band_anchor.matrix_basis = MA
band_anchor.empty_display_size = 0.02

band = bpy.data.objects.new("BandMotion", None)      # click recoil only
col_band.objects.link(band)
band.parent = band_anchor
band.empty_display_size = 0.03

pod_motion = bpy.data.objects.new("PodMotion", None)
col_band.objects.link(pod_motion)
pod_motion.parent = band
pod_motion.empty_display_size = 0.01

hinge = bpy.data.objects.new("FrameHinge", None)
col_band.objects.link(hinge)
hinge.parent = pod_motion
hinge.location = Vector((H2[0] * 0.001, H2[1] * 0.001, 0.0))
hinge.rotation_mode = "XYZ"
hinge.empty_display_size = 0.006

M = 0.001
pod = new_mesh_object("Pod", POD_B * M, pf, uvs=pv[:, :2] * M, parent=pod_motion, coll=col_band, attrs={"flat": pv_flat * M})
inset = new_mesh_object("PodInset", INSET_B * M, iff, uvs=iv[:, :2] * M, parent=pod_motion, coll=col_band,
                        attrs={"flat": iv_flat * M})
sensor = new_mesh_object("PodSensor", SENS_B * M, lf, uvs=lv[:, :2] * M, parent=pod_motion, coll=col_band)
slider = new_mesh_object("Slider", SLIDER_B * M, slf, uvs=slv[:, :2] * M, parent=pod_motion, coll=col_band,
                         extra_uvs={"Brush": slv[:, 1:3] * M})
frame_ob = new_mesh_object("ClaspFrame", np.c_[FRAME_B[:, :2] - H2, FRAME_B[:, 2]] * M, ff, uvs=f_uv,
                           parent=hinge, coll=col_band, extra_uvs={"Brush": f_br})
# cap: local x along the strap, local y outward from the strap (mirrored so the frame stays right-handed)
CAP_RPLAN = 2.2                     # plan corner radius of the plate


def cap_mesh():
    """the plate swept along CAP_BOT: (u, r, across) verts, faces, brush uv (arc, across). Its
    edges are rounded all round: CAP_RC over the long edges and both ends (the section shrinks
    as a quarter round past each end), CAP_RPLAN at the four plan corners."""
    rt, rcn = 22, 8
    nr = len(rr_ring(CAP_W, CAP_T, CAP_RC, rt, rcn))
    tb = np.gradient(CAP_BOT, axis=0)
    tb /= np.linalg.norm(tb, axis=1)[:, None]
    sb = arc(CAP_BOT)
    Lb = sb[-1]
    rows = []                                    # (point on the bottom line, normal, inset d, arc)
    for th in np.linspace(math.pi / 2, 0.0, rcn + 1)[1:-1]:
        e_, d_ = CAP_RC * math.sin(th), CAP_RC * (1 - math.cos(th))
        rows.append((CAP_BOT[0] - tb[0] * e_, CAP_NB[0], d_, -e_))
    for Pb, Nb, s0 in zip(CAP_BOT, CAP_NB, sb):
        rows.append((Pb, Nb, 0.0, s0))
    for th in np.linspace(0.0, math.pi / 2, rcn + 1)[1:-1]:
        e_, d_ = CAP_RC * math.sin(th), CAP_RC * (1 - math.cos(th))
        rows.append((CAP_BOT[-1] + tb[-1] * e_, CAP_NB[-1], d_, Lb + e_))
    verts, brush = [], []
    for Pb, Nb, d_, s0 in rows:
        # plan corners: the width pulls in near both ends
        de = min(s0 + CAP_RC, Lb + CAP_RC - s0)
        ext = CAP_RPLAN - CAP_RC
        pin = 0.0 if de >= ext else ext - math.sqrt(max(ext * ext - (ext - de) ** 2, 0.0))
        ring = rr_ring(CAP_W - 2 * d_ - 2 * pin, CAP_T - 2 * d_, max(CAP_RC - d_, 0.02), rt, rcn)
        for (w_, h_) in ring:
            wb = -ORIENT * w_
            q = Pb + Nb * (h_ + d_) + np.array([0.0, CAP_SLOPE * wb])     # the wrist's taper, like the pod
            verts.append((q[0], q[1], w_))
            brush.append((s0, w_))
    faces = []
    n_rows = len(rows)
    for i in range(n_rows - 1):
        for j in range(nr):
            a_, b_ = i * nr + j, i * nr + (j + 1) % nr
            faces.append((a_, b_, b_ + nr, a_ + nr))
    for row, flip in ((0, True), (n_rows - 1, False)):
        ring_ = tuple(row * nr + j for j in range(nr))
        faces.append(ring_[::-1] if flip else ring_)
    return np.array(verts), faces, np.array(brush) * 0.001


cv, cf, cbr = cap_mesh()
cap_local = np.c_[cv[:, 0], -ORIENT * cv[:, 1], -ORIENT * cv[:, 2]]
cap_uv = np.c_[(q_k - cv[:, 0]), cv[:, 2]] * M                  # continues the rails' uv x
def signed_volume(v, faces):
    vol = 0.0
    for f_ in faces:
        for k_ in range(1, len(f_) - 1):
            vol += np.dot(v[f_[0]], np.cross(v[f_[k_]], v[f_[k_ + 1]]))
    return vol / 6.0


if signed_volume(cap_local, cf) < 0:
    cf = [tuple(reversed(f_)) for f_ in cf]
cap = new_mesh_object("ClaspCap", cap_local * M, cf, uvs=cap_uv, parent=band, coll=col_band, extra_uvs={"Brush": cbr[:, ::-1]})   # brushed across the band
cap.rotation_mode = "XYZ"
col_glint.objects.link(cap)
col_glint.objects.link(frame_ob)
col_glint.objects.link(slider)
for ob_ in (pod, inset):
    col_product.objects.link(ob_)

# strap mesh: p = 0 under the cap, p = L_STRAP inside the slider
sv, sf, suv = strap_strip(0.0, L_STRAP)


def strap_at(f):
    st = states[f]
    P, Nn = st["P"], st["N"]
    s_ = np.r_[0.0, np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))]
    ell = sv[:, 0] * (s_[-1] / L_STRAP)
    px, py = np.interp(ell, s_, P[:, 0]), np.interp(ell, s_, P[:, 1])
    nx, ny = np.interp(ell, s_, Nn[:, 0]), np.interp(ell, s_, Nn[:, 1])
    nn = np.hypot(nx, ny)
    wb = sv[:, 1] * ORIENT
    rad = sv[:, 2] + np.interp(ell, s_, st["SL"]) * wb             # follows the wrist's taper
    xy = np.c_[px, py] + np.c_[nx / nn, ny / nn] * rad[:, None]
    return np.c_[xy, wb + st["w"]] * M


def cap_pose(f):
    st = states[f]
    P = st["P"]
    K = P[0]
    i = min(len(P) - 1, 8)
    t = (P[i] - K) / np.linalg.norm(P[i] - K)
    return K, t, ORIENT * np.array([t[1], -t[0]])


strap = new_mesh_object("Strap", strap_at(F_BAKE1), sf, uvs=suv, parent=band, coll=col_band, loop_uv_fix=strap_uv_fix)
strap.shape_key_add(name="Basis", from_mix=False)
for f in frames_b:
    kb = strap.shape_key_add(name=f"f{f:03d}", from_mix=False)
    kb.data.foreach_set("co", strap_at(f).astype(np.float32).ravel())
    kb.slider_min = 0.0
    d_ = kb.driver_add("value").driver
    d_.type = "SCRIPTED"
    if f == frames_b[0]:
        d_.expression = f"1.0 if frame <= {f} else max(0.0, 1.0 - abs(frame - {f}))"
    elif f == frames_b[-1]:
        d_.expression = f"1.0 if frame >= {f} else max(0.0, 1.0 - abs(frame - {f}))"
    else:
        d_.expression = f"max(0.0, 1.0 - abs(frame - {f}))"

# rigid keys, one per baked frame (the sampled motion itself, so no easing is added on top)
for f in frames_b:
    st = states[f]
    loc2 = st["d"] + POD_C - rot2(POD_C[None], st["rho"])[0]      # tilt about the pod centre
    kf(pod_motion, "location", int(f), Vector((loc2[0] * M, loc2[1] * M, st["w"] * M)), "LINEAR")
    kf(pod_motion, "rotation_euler", int(f), Vector((0.0, 0.0, math.radians(st["rho"]))), "LINEAR")
    kf(hinge, "rotation_euler", int(f), Vector((0.0, 0.0, math.radians(A_SIGN * st["phi"]))), "LINEAR")
    K, t, _ = cap_pose(f)
    kf(cap, "location", int(f), Vector((K[0] * M, K[1] * M, st["w"] * M)), "LINEAR")
    kf(cap, "rotation_euler", int(f), Vector((0.0, 0.0, math.atan2(t[1], t[0]))), "LINEAR")
fc_rot = find_fc(cap, "rotation_euler", 2)
vals = np.unwrap([kp.co.y for kp in fc_rot.keyframe_points])
for kp, v_ in zip(fc_rot.keyframe_points, vals):
    kp.co.y = float(v_)
    kp.handle_left.y = kp.handle_right.y = float(v_)
fc_rot.update()

# band parts appear when the band comes in (it starts off frame to the right)
band_parts = [pod, inset, sensor, slider, frame_ob, cap, strap]
for ob_ in band_parts:
    kf(ob_, "hide_render", F_FIRST, True, "CONSTANT")
    kf(ob_, "hide_render", F_BAND_IN, False, "CONSTANT")

# final (closed) cap pose, band space
K_F, T_F, N_F = cap_pose(F_BAKE1)
_ctop = CAP_PROFILE[len(CAP_BOT):].mean(axis=0)
fpos = np.array([*(K_F + N_F * _ctop[1] + T_F * _ctop[0]), 0.0]) * M
focus = bpy.data.objects.new("FocusClasp", None)
col_band.objects.link(focus)
focus.parent = band_anchor
focus.location = Vector(fpos) + Vector((0.0, 0.0, FOCUS_TO_HAND * M))     # band space z = toward the fingers
focus.empty_display_size = 0.005
scene.frame_set(F_WRAP + 20)

# LED light under the pod
led_data = bpy.data.lights.new("SensorLED", "POINT")
led_data.color = (0.12, 1.0, 0.28)
led_data.shadow_soft_size = 0.004
led_data.energy = 0.0
led = bpy.data.objects.new("SensorLED", led_data)
col_band.objects.link(led)
led.parent = pod_motion
led.location = Vector(flat_to_band(np.array([[0.0, 0.0, -0.25]]))[0] * M)

# ---------------------------------------------------------------------------
# 7. materials


def principled(name):
    m = bpy.data.materials.new(name)
    try:
        m.use_nodes = True
    except Exception:
        pass
    nt = m.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    return m, nt, bsdf


def node(nt, t, x=0, y=0, **kw):
    n = nt.nodes.new(t)
    n.location = (x, y)
    for k, v in kw.items():
        setattr(n, k, v)
    return n


def math_node(nt, op, a=None, b=None, x=0, y=0):
    n = node(nt, "ShaderNodeMath", x, y, operation=op)
    for i, v in enumerate((a, b)):
        if v is None:
            continue
        if isinstance(v, (int, float)):
            n.inputs[i].default_value = v
        else:
            nt.links.new(v, n.inputs[i])
    return n.outputs[0]


# skin
m_skin, nt, b = principled("Skin")
b.inputs["Base Color"].default_value = (0.30, 0.185, 0.14, 1)
b.inputs["Subsurface Weight"].default_value = 1.0
b.inputs["Subsurface Radius"].default_value = (1.0, 0.66, 0.52)
b.inputs["Subsurface Scale"].default_value = 0.0011
b.inputs["Roughness"].default_value = 0.42
b.inputs["Specular IOR Level"].default_value = 0.22
b.inputs["Coat Weight"].default_value = 0.0
b.inputs["Coat Roughness"].default_value = 0.35
b.inputs["Sheen Weight"].default_value = 0.04
b.inputs["Sheen Roughness"].default_value = 0.4
b.inputs["Sheen Tint"].default_value = (1.0, 0.85, 0.78, 1)
tc = node(nt, "ShaderNodeTexCoord", -1400, 0)
pores = node(nt, "ShaderNodeTexNoise", -1100, -300)
pores.inputs["Scale"].default_value = 2400.0
pores.inputs["Detail"].default_value = 2.0
cells = node(nt, "ShaderNodeTexVoronoi", -1100, -600)
cells.inputs["Scale"].default_value = 900.0
blot = node(nt, "ShaderNodeTexNoise", -1100, 250)
blot.inputs["Scale"].default_value = 55.0
blot.inputs["Detail"].default_value = 4.0
for n_ in (pores, cells, blot):
    nt.links.new(tc.outputs["Object"], n_.inputs["Vector"])
mix_c = node(nt, "ShaderNodeMix", -600, 250, data_type="RGBA", blend_type="MULTIPLY")
mix_c.inputs["Factor"].default_value = 0.35
nt.links.new(blot.outputs["Color"], mix_c.inputs["B"])
mix_c.inputs["A"].default_value = (0.30, 0.185, 0.14, 1)
ramp = node(nt, "ShaderNodeValToRGB", -850, 250)
ramp.color_ramp.elements[0].color = (0.85, 0.80, 0.80, 1)
ramp.color_ramp.elements[1].color = (1.0, 0.93, 0.90, 1)
nt.links.new(blot.outputs["Fac"], ramp.inputs["Fac"])
nt.links.new(ramp.outputs["Color"], mix_c.inputs["B"])
# light pool: the forearm falls off into darkness toward the elbow; fingers a touch redder
sxyz = node(nt, "ShaderNodeSeparateXYZ", -1100, 600)
nt.links.new(tc.outputs["Object"], sxyz.inputs["Vector"])
fade = node(nt, "ShaderNodeMapRange", -850, 650, interpolation_type="SMOOTHSTEP")
fade.inputs["From Min"].default_value = -0.175
fade.inputs["From Max"].default_value = -0.05
fade.inputs["To Min"].default_value = 0.03
fade.inputs["To Max"].default_value = 1.0
nt.links.new(sxyz.outputs["Y"], fade.inputs["Value"])
redf = node(nt, "ShaderNodeMapRange", -850, 450, interpolation_type="SMOOTHSTEP")
redf.inputs["From Min"].default_value = 0.055
redf.inputs["From Max"].default_value = 0.115
redf.inputs["To Min"].default_value = 0.0
redf.inputs["To Max"].default_value = 0.2
nt.links.new(sxyz.outputs["Y"], redf.inputs["Value"])
mix_r = node(nt, "ShaderNodeMix", -450, 350, data_type="RGBA", blend_type="MIX")
nt.links.new(redf.outputs["Result"], mix_r.inputs["Factor"])
nt.links.new(mix_c.outputs["Result"], mix_r.inputs["A"])
mix_r.inputs["B"].default_value = (0.30, 0.13, 0.10, 1)
mix_f = node(nt, "ShaderNodeMix", -250, 350, data_type="RGBA", blend_type="MULTIPLY")
mix_f.inputs["Factor"].default_value = 1.0
# redder knuckles, paler inner (palm-side) wrist
knk = node(nt, "ShaderNodeMapRange", -850, 850, interpolation_type="SMOOTHSTEP")
knk.inputs["From Min"].default_value = 0.012
knk.inputs["From Max"].default_value = 0.0
knk.inputs["To Min"].default_value = 0.0
knk.inputs["To Max"].default_value = 0.35
yk = math_node(nt, "ABSOLUTE", math_node(nt, "SUBTRACT", sxyz.outputs["Y"], 0.072, -1000, 850), None, -950, 850)
nt.links.new(yk, knk.inputs["Value"])
mix_k = node(nt, "ShaderNodeMix", -450, 550, data_type="RGBA", blend_type="MIX")
nt.links.new(knk.outputs["Result"], mix_k.inputs["Factor"])
nt.links.new(mix_r.outputs["Result"], mix_k.inputs["A"])
mix_k.inputs["B"].default_value = (0.33, 0.15, 0.115, 1)
pale = node(nt, "ShaderNodeMapRange", -850, 1050, interpolation_type="SMOOTHSTEP")
pale.inputs["From Min"].default_value = -0.004
pale.inputs["From Max"].default_value = 0.016
pale.inputs["To Min"].default_value = 0.0
pale.inputs["To Max"].default_value = 0.45
nt.links.new(sxyz.outputs["Z"], pale.inputs["Value"])
nt.links.new(math_node(nt, "MULTIPLY", pale.outputs["Result"], math_node(nt, "LESS_THAN", sxyz.outputs["Y"], 0.03, -900, 1200), -700, 1050), (mix_p := node(nt, "ShaderNodeMix", -350, 700, data_type="RGBA", blend_type="MIX")).inputs["Factor"])
nt.links.new(mix_k.outputs["Result"], mix_p.inputs["A"])
mix_p.inputs["B"].default_value = (0.36, 0.25, 0.20, 1)
nt.links.new(mix_p.outputs["Result"], mix_f.inputs["A"])
nt.links.new(fade.outputs["Result"], mix_f.inputs["B"])
nt.links.new(mix_f.outputs["Result"], b.inputs["Base Color"])
nt.links.new(math_node(nt, "MULTIPLY", fade.outputs["Result"], 0.22, -250, 150), b.inputs["Specular IOR Level"])

rough = math_node(nt, "MULTIPLY_ADD", pores.outputs["Fac"], 0.2, -600, -100)
rough.node.inputs[2].default_value = 0.46
nt.links.new(rough, b.inputs["Roughness"])
crease = node(nt, "ShaderNodeTexVoronoi", -1100, -900, feature="DISTANCE_TO_EDGE")
crease.inputs["Scale"].default_value = 1100.0
nt.links.new(tc.outputs["Object"], crease.inputs["Vector"])
crease_l = math_node(nt, "POWER", math_node(nt, "MINIMUM", math_node(nt, "MULTIPLY", crease.outputs["Distance"], 9.0, -900, -900), 1.0, -800, -900), 0.5, -700, -900)
bump_sum = math_node(nt, "ADD", math_node(nt, "ADD", pores.outputs["Fac"], math_node(nt, "MULTIPLY", cells.outputs["Distance"], 0.6, -800, -600), -650, -500), math_node(nt, "MULTIPLY", crease_l, 0.35, -650, -900), -600, -400)
bump = node(nt, "ShaderNodeBump", -300, -400)
bump.inputs["Strength"].default_value = 0.42
bump.inputs["Distance"].default_value = 0.00012
nt.links.new(bump_sum, bump.inputs["Height"])
nt.links.new(bump.outputs["Normal"], b.inputs["Normal"])
skin.data.materials.clear()
skin.data.materials.append(m_skin)

m_nail, nt, b = principled("Nail")
b.inputs["Base Color"].default_value = (0.50, 0.40, 0.37, 1)
b.inputs["Subsurface Weight"].default_value = 0.15
b.inputs["Subsurface Radius"].default_value = (1.0, 0.4, 0.25)
b.inputs["Subsurface Scale"].default_value = 0.002
b.inputs["Roughness"].default_value = 0.28
b.inputs["Coat Weight"].default_value = 0.3
b.inputs["Coat Roughness"].default_value = 0.15
for n_ in nails:
    n_.data.materials.clear()
    n_.data.materials.append(m_nail)


def hex_linear(h):
    h = h.lstrip("#")
    c = [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    return tuple((v / 12.92) if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in c)


# ghost skin. Crimpwell recipe: Layer Weight facing -> Map Range -> mix Transparent / rim Emission.
# Cycles has no backface culling or single-layer blending, so the shader keeps only the first
# front face a camera ray meets (Backfacing and Transparent Depth), which is what EEVEE's
# culled, no-overlap BLENDED mode shows in Crimpwell.
GHOST_COLORS = {
    "brand": hex_linear("#2AD4E6"),          # Loopr dark-mode brand cyan
    "crimpwell": (0.42, 0.78, 0.92),         # cw_style.SKIN_RIM
}
_gc = os.environ.get("LOOPR_GHOST_COLOR", "crimpwell")
GHOST_RIM_COLOR = GHOST_COLORS.get(_gc) or hex_linear(_gc)
GHOST_RIM = float(os.environ.get("LOOPR_GHOST_RIM", "2.6"))
GHOST_LAYER2 = float(os.environ.get("LOOPR_GHOST_LAYER2", "0.45"))   # rim share of a skin fold seen through the first one
GHOST_OPACITY = float(os.environ.get("LOOPR_GHOST_OPACITY", "0.03"))   # faint glass body, so the hand reads on a phone
GHOST_EDGE = float(os.environ.get("LOOPR_GHOST_EDGE", "0.45"))
GHOST_BLEND = 0.55
GHOST_POWER = float(os.environ.get("LOOPR_GHOST_POWER", "10.0"))   # >1 pulls the rim tighter to the silhouette
GLOW_COLOR = (0.12, 1.0, 0.28)               # sensor LED green
GLOW_RADIUS = 0.007                          # m, falloff of the LED glow inside the wrist
GLOW_STRENGTH = 2.0


def forearm_fade(nt, x=-900, y=600, lo=0.0):
    """0 toward the elbow, 1 at the wrist (rig space Y, shared by skin and bones)."""
    tc_ = node(nt, "ShaderNodeTexCoord", x - 400, y)
    sx = node(nt, "ShaderNodeSeparateXYZ", x - 200, y)
    nt.links.new(tc_.outputs["Object"], sx.inputs["Vector"])
    f_ = node(nt, "ShaderNodeMapRange", x, y, interpolation_type="SMOOTHSTEP")
    f_.inputs["From Min"].default_value = -0.175
    f_.inputs["From Max"].default_value = -0.05
    f_.inputs["To Min"].default_value = lo
    f_.inputs["To Max"].default_value = 1.0
    nt.links.new(sx.outputs["Y"], f_.inputs["Value"])
    return f_.outputs["Result"]


m_ghost = bpy.data.materials.new("GhostSkin")
m_ghost.use_nodes = True
nt = m_ghost.node_tree
nt.nodes.clear()
g_out = node(nt, "ShaderNodeOutputMaterial", 900, 0)
g_fade = forearm_fade(nt, -900, 500)
g_lw = node(nt, "ShaderNodeLayerWeight", -900, 150)
g_lw.inputs["Blend"].default_value = GHOST_BLEND
g_ramp = node(nt, "ShaderNodeMapRange", -650, 150)
g_ramp.inputs["To Min"].default_value = GHOST_OPACITY * 0.25
g_ramp.inputs["To Max"].default_value = GHOST_OPACITY + GHOST_EDGE
nt.links.new(math_node(nt, "POWER", g_lw.outputs["Facing"], GHOST_POWER, -700, 250), g_ramp.inputs["Value"])
g_geo = node(nt, "ShaderNodeNewGeometry", -900, -150)
g_lp = node(nt, "ShaderNodeLightPath", -900, -400)
g_front = math_node(nt, "SUBTRACT", 1.0, g_geo.outputs["Backfacing"], -650, -150)
# the first front face a ray meets gets the full rim; a second one (a finger behind a finger, the
# palm behind curled fingers) gets GHOST_LAYER2 of it, so the fingers read as separate shapes
g_first = math_node(nt, "ADD", math_node(nt, "LESS_THAN", g_lp.outputs["Transparent Depth"], 0.5, -800, -400),
                    math_node(nt, "MULTIPLY", math_node(nt, "LESS_THAN", math_node(nt, "ABSOLUTE",
                              math_node(nt, "SUBTRACT", g_lp.outputs["Transparent Depth"], 1.0, -900, -500), None, -850, -500),
                              0.5, -800, -500), GHOST_LAYER2, -750, -500), -650, -400)
g_mask = math_node(nt, "MULTIPLY", math_node(nt, "MULTIPLY", g_front, g_first, -450, -250), g_fade, -250, -100)
g_fac = math_node(nt, "MULTIPLY", g_ramp.outputs["Result"], g_mask, -50, 100)
g_emit = node(nt, "ShaderNodeEmission", -50, 300)
g_emit.inputs["Color"].default_value = (*GHOST_RIM_COLOR, 1.0)
g_emit.inputs["Strength"].default_value = GHOST_RIM
g_tr = node(nt, "ShaderNodeBsdfTransparent", -50, 450)
g_mix = node(nt, "ShaderNodeMixShader", 250, 200)
nt.links.new(g_fac, g_mix.inputs["Fac"])
nt.links.new(g_tr.outputs["BSDF"], g_mix.inputs[1])
nt.links.new(g_emit.outputs["Emission"], g_mix.inputs[2])
# sensor glow: at the click the LEDs light the wrist from inside, falling off with distance to the LED
g_tcl = node(nt, "ShaderNodeTexCoord", -900, -650)
g_tcl.object = led
g_len = node(nt, "ShaderNodeVectorMath", -700, -650, operation="LENGTH")
nt.links.new(g_tcl.outputs["Object"], g_len.inputs[0])
g_amp = node(nt, "ShaderNodeValue", -700, -850)
g_amp.name = "GlowAmp"
g_amp.outputs[0].default_value = 0.0
g_exp = math_node(nt, "EXPONENT", math_node(nt, "MULTIPLY", g_len.outputs["Value"], -1.0 / GLOW_RADIUS, -500, -650), None, -350, -650)
g_glow = math_node(nt, "MINIMUM", math_node(nt, "MULTIPLY", math_node(nt, "MULTIPLY", g_exp, g_amp.outputs[0], -200, -700), g_mask, -50, -600), 1.0, 100, -600)
g_gem = node(nt, "ShaderNodeEmission", 250, -300)
g_gem.inputs["Color"].default_value = (*GLOW_COLOR, 1.0)
g_gem.inputs["Strength"].default_value = GLOW_STRENGTH
g_mix2 = node(nt, "ShaderNodeMixShader", 550, 0)
nt.links.new(g_glow, g_mix2.inputs["Fac"])
nt.links.new(g_mix.outputs["Shader"], g_mix2.inputs[1])
nt.links.new(g_gem.outputs["Emission"], g_mix2.inputs[2])
nt.links.new(g_mix2.outputs["Shader"], g_out.inputs["Surface"])
try:
    m_ghost.cycles.emission_sampling = "NONE"   # the rim is seen, it does not light the band
except AttributeError:
    pass

# bones: quiet Crimpwell bone, dissolving toward the elbow with the skin
m_bone, nt, b = principled("Bone")
BONE_DIM = float(os.environ.get("LOOPR_BONE_DIM", "0.3"))
b.inputs["Base Color"].default_value = (0.80 * BONE_DIM, 0.77 * BONE_DIM, 0.71 * BONE_DIM, 1)
b.inputs["Roughness"].default_value = 0.55
b.inputs["Specular IOR Level"].default_value = 0.3
b_out = nt.nodes["Material Output"]
b_fade = forearm_fade(nt, -900, 500)
BONE_ALPHA = float(os.environ.get("LOOPR_BONE_ALPHA", "1.0"))
b_tr = node(nt, "ShaderNodeBsdfTransparent", -100, 300)
b_mix = node(nt, "ShaderNodeMixShader", 200, 200)
nt.links.new(math_node(nt, "MULTIPLY", b_fade, BONE_ALPHA, -300, 500), b_mix.inputs["Fac"])
nt.links.new(b_tr.outputs["BSDF"], b_mix.inputs[1])
nt.links.new(b.outputs["BSDF"], b_mix.inputs[2])
nt.links.new(b_mix.outputs["Shader"], b_out.inputs["Surface"])
for ob in bones:
    ob.data.materials.clear()
    ob.data.materials.append(m_bone)
    ob.visible_shadow = True


# Band occlusion: as the strap closes, the anatomy inside the strap's slab of the wrist thins
# out, so the whole ring (the far run of the strap too) reads in front of the tissue, and the
# tissue reads as passing under the strap. BandAnchor object space: z runs along the forearm.
BAND_OCC_LO = float(os.environ.get("LOOPR_BAND_OCC", "0.25"))    # anatomy opacity left in the slab
band_occ_nodes = []


def band_occlusion(nt_, x=-900, y=-400):
    tc_ = node(nt_, "ShaderNodeTexCoord", x - 400, y)
    tc_.object = band_anchor
    sx_ = node(nt_, "ShaderNodeSeparateXYZ", x - 200, y)
    nt_.links.new(tc_.outputs["Object"], sx_.inputs["Vector"])
    slab = node(nt_, "ShaderNodeMapRange", x, y, interpolation_type="SMOOTHSTEP")
    slab.inputs["From Min"].default_value = (STRAP_W / 2 - 2.0) * 0.001
    slab.inputs["From Max"].default_value = (STRAP_W / 2 + 6.0) * 0.001
    slab.inputs["To Min"].default_value = BAND_OCC_LO
    slab.inputs["To Max"].default_value = 1.0
    nt_.links.new(math_node(nt_, "ABSOLUTE", sx_.outputs["Z"], None, x - 100, y - 150), slab.inputs["Value"])
    amt = node(nt_, "ShaderNodeValue", x, y - 250)
    amt.name = "BandOcc"
    amt.outputs[0].default_value = 0.0
    band_occ_nodes.append(amt)
    # 1 - amt * (1 - slab)
    return math_node(nt_, "SUBTRACT", 1.0, math_node(nt_, "MULTIPLY", amt.outputs[0],
                     math_node(nt_, "SUBTRACT", 1.0, slab.outputs["Result"], x + 150, y), x + 300, y), x + 450, y)


TISSUE_SPEC = float(os.environ.get("LOOPR_TISSUE_SPEC", "0.12"))   # low: glossy silhouettes read as white streaks


def glass_tissue(name, color, alpha_face, alpha_edge, rough=0.45, coat=0.0, sheen=0.0, power=1.6):
    """Crimpwell tissue colour as a see-through layer: thin where it faces the camera, denser at
    its silhouette, front faces only (so a muscle counts once, not twice), dissolving toward the
    elbow with the skin's forearm fade."""
    m, nt_, b_ = principled(name)
    b_.inputs["Base Color"].default_value = color
    b_.inputs["Roughness"].default_value = rough
    b_.inputs["Coat Weight"].default_value = coat
    b_.inputs["Coat Roughness"].default_value = 0.3
    b_.inputs["Sheen Weight"].default_value = sheen
    b_.inputs["Sheen Roughness"].default_value = 0.5
    b_.inputs["Specular IOR Level"].default_value = TISSUE_SPEC
    out_ = nt_.nodes["Material Output"]
    fade_ = forearm_fade(nt_, -900, 500)
    lw_ = node(nt_, "ShaderNodeLayerWeight", -900, 150)
    lw_.inputs["Blend"].default_value = 0.4
    edge_ = math_node(nt_, "POWER", lw_.outputs["Facing"], power, -700, 150)
    a_ = math_node(nt_, "MULTIPLY_ADD", edge_, alpha_edge - alpha_face, -500, 150)
    a_.node.inputs[2].default_value = alpha_face
    geo_ = node(nt_, "ShaderNodeNewGeometry", -900, -100)
    front_ = math_node(nt_, "SUBTRACT", 1.0, geo_.outputs["Backfacing"], -700, -100)
    fac_ = math_node(nt_, "MULTIPLY", math_node(nt_, "MULTIPLY", a_, fade_, -350, 250), front_, -200, 150)
    fac_ = math_node(nt_, "MULTIPLY", fac_, band_occlusion(nt_), -100, 100)
    tr_ = node(nt_, "ShaderNodeBsdfTransparent", -100, 350)
    mx_ = node(nt_, "ShaderNodeMixShader", 200, 200)
    nt_.links.new(fac_, mx_.inputs["Fac"])
    nt_.links.new(tr_.outputs["BSDF"], mx_.inputs[1])
    nt_.links.new(b_.outputs["BSDF"], mx_.inputs[2])
    nt_.links.new(mx_.outputs["Shader"], out_.inputs["Surface"])
    return m


# muscles: Crimpwell MUSCLE red, glassy so the bones read through; tendons: Crimpwell TENDON, denser
MUSCLE_ALPHA = (float(os.environ.get("LOOPR_MUSCLE_FACE", "0.22")), float(os.environ.get("LOOPR_MUSCLE_EDGE", "0.8")))
m_muscle = glass_tissue("Muscle", (0.55, 0.16, 0.14, 1), *MUSCLE_ALPHA, rough=0.55)
TENDON_DIM = float(os.environ.get("LOOPR_TENDON_DIM", "0.45"))
m_tendon = glass_tissue("Tendon", (0.74 * TENDON_DIM, 0.70 * TENDON_DIM, 0.60 * TENDON_DIM, 1), 0.28, 0.7, rough=0.6)
if WITH_SOFT:
    # bones take the same band occlusion (ghost-bones keeps its v3 look)
    _bn = m_bone.node_tree
    _bmix = [n_ for n_ in _bn.nodes if n_.type == "MIX_SHADER"][0]
    _bfac = _bmix.inputs["Fac"].links[0].from_socket
    _bn.links.new(math_node(_bn, "MULTIPLY", _bfac, band_occlusion(_bn), 0, 500), _bmix.inputs["Fac"])
for obs_, m_ in ((muscles, m_muscle), (tendons, m_tendon)):
    for ob in obs_:
        ob.data.materials.clear()
        ob.data.materials.append(m_)
        ob.visible_shadow = True

if GHOST:
    skin.data.materials.clear()
    skin.data.materials.append(m_ghost)
    # camera only: it neither shadows the band nor shows up in the strap's or clasp's reflections
    skin.visible_shadow = False
    skin.visible_diffuse = False
    skin.visible_glossy = False
    skin.visible_transmission = False
    skin.visible_volume_scatter = False
    for n_ in nails:
        n_.hide_render = True
        n_.hide_viewport = True

# knit strap. UV x runs along the strap, UV y around its section (0 at the top centre, the inner
# face's centre at +-STRAP_PER / 2), both in metres. Knit: fine V stitches (wales across, courses
# along), every second wale raised into a lengthwise rib that reads at film distance, heathered
# yarn, microfibre sheen for the fuzz. Each edge is wrapped in a tighter, smoother binding.
STRAP_PER = strap_uv_fix.period
BIND_HALF = 0.001 * ((STRAP_T - 2 * STRAP_RC) / 2 + math.pi / 2 * STRAP_RC + 0.55)   # binding half width around the edge
KNIT_SHEEN = float(os.environ.get("LOOPR_KNIT_SHEEN", "0.45"))
m_knit, nt, b = principled("KnitStrap")
uv = node(nt, "ShaderNodeUVMap", -2200, 0)
uv.uv_map = "UVMap"
sep = node(nt, "ShaderNodeSeparateXYZ", -2000, 0)
nt.links.new(uv.outputs["UV"], sep.inputs["Vector"])
U = sep.outputs["X"]      # along strap (m)
Vv = sep.outputs["Y"]     # around the section (m)
# binding mask: 1 within BIND_HALF of the middle of either side
e_mid = math_node(nt, "ABSOLUTE", math_node(nt, "SUBTRACT", math_node(nt, "ABSOLUTE", Vv, None, -1800, 500),
                                             STRAP_PER / 4, -1650, 500), None, -1500, 500)
bind_r = node(nt, "ShaderNodeMapRange", -1300, 500, interpolation_type="SMOOTHSTEP")
bind_r.inputs["From Min"].default_value = BIND_HALF - 0.00012
bind_r.inputs["From Max"].default_value = BIND_HALF + 0.00004
bind_r.inputs["To Min"].default_value = 1.0
bind_r.inputs["To Max"].default_value = 0.0
nt.links.new(e_mid, bind_r.inputs["Value"])
BIND = bind_r.outputs["Result"]
# body knit
wale = math_node(nt, "DIVIDE", Vv, 0.00068, -1400, 100)          # columns across
course = math_node(nt, "DIVIDE", U, 0.00058, -1400, -100)        # rows along
wa = math_node(nt, "FRACT", wale, None, -1250, 100)
xa = math_node(nt, "ABSOLUTE", math_node(nt, "SUBTRACT", wa, 0.5, -1100, 100), None, -950, 100)   # 0..0.5
yb = math_node(nt, "FRACT", math_node(nt, "ADD", course, math_node(nt, "MULTIPLY", xa, 1.1, -800, 150), -800, -50), None, -650, -50)
leg = math_node(nt, "SINE", math_node(nt, "MULTIPLY", yb, math.pi, -500, -50), None, -350, -50)     # 0..1..0 along each V
groove = math_node(nt, "SINE", math_node(nt, "MULTIPLY", wa, math.pi, -500, 150), None, -350, 150)
stitch = math_node(nt, "MULTIPLY", math_node(nt, "POWER", leg, 0.7, -200, -50), math_node(nt, "POWER", groove, 0.45, -200, 150), -50, 50)
# lengthwise rib: every second wale stands proud
rib = math_node(nt, "ABSOLUTE", math_node(nt, "SINE", math_node(nt, "MULTIPLY", Vv, math.pi / 0.00136, -1250, 300), None, -1100, 300), None, -950, 300)
rib = math_node(nt, "MULTIPLY_ADD", math_node(nt, "POWER", rib, 1.6, -800, 300), 0.55, -650, 300)
rib.node.inputs[2].default_value = 0.45
height = math_node(nt, "MULTIPLY", stitch, rib, 100, 100)
fib = node(nt, "ShaderNodeTexNoise", -500, -350)
fib.inputs["Scale"].default_value = 1.0
fib.inputs["Detail"].default_value = 6.0
fmap = node(nt, "ShaderNodeMapping", -700, -350)
fmap.inputs["Scale"].default_value = (9000.0, 2500.0, 1.0)
nt.links.new(uv.outputs["UV"], fmap.inputs["Vector"])
nt.links.new(fmap.outputs["Vector"], fib.inputs["Vector"])
yarn = node(nt, "ShaderNodeTexNoise", -500, -600)
yarn.inputs["Scale"].default_value = 1.0
ymap = node(nt, "ShaderNodeMapping", -700, -600)
ymap.inputs["Scale"].default_value = (1300.0, 60.0, 1.0)
nt.links.new(uv.outputs["UV"], ymap.inputs["Vector"])
nt.links.new(ymap.outputs["Vector"], yarn.inputs["Vector"])
yv = math_node(nt, "MULTIPLY_ADD", yarn.outputs["Fac"], 0.6, -300, -600)
yv.node.inputs[2].default_value = 0.7
height = math_node(nt, "MULTIPLY", height, yv, 250, 0)
h_body = math_node(nt, "MULTIPLY_ADD", fib.outputs["Fac"], 0.35, 400, -100)
nt.links.new(height, h_body.node.inputs[2])
# binding: a tight cord along the edge, fine ridges across it
cord = math_node(nt, "SINE", math_node(nt, "MULTIPLY", U, 2 * math.pi / 0.00034, -1300, 800), None, -1150, 800)
cord = math_node(nt, "MULTIPLY_ADD", cord, 0.25, -1000, 800)
cord.node.inputs[2].default_value = 0.55
h_bind = math_node(nt, "MULTIPLY_ADD", fib.outputs["Fac"], 0.15, -850, 800)
nt.links.new(cord, h_bind.node.inputs[2])
h_mix = node(nt, "ShaderNodeMix", 600, 300, data_type="FLOAT")
nt.links.new(BIND, h_mix.inputs["Factor"])
nt.links.new(h_body, h_mix.inputs["A"])
nt.links.new(h_bind, h_mix.inputs["B"])
h_all = h_mix.outputs["Result"]
kb_ = node(nt, "ShaderNodeBump", 800, -200)
kb_.inputs["Strength"].default_value = 0.9
kb_.inputs["Distance"].default_value = 0.00018
nt.links.new(h_all, kb_.inputs["Height"])
nt.links.new(kb_.outputs["Normal"], b.inputs["Normal"])
# heathered yarn: short lighter flecks along the courses
heat = node(nt, "ShaderNodeTexNoise", -500, -900)
heat.inputs["Scale"].default_value = 1.0
heat.inputs["Detail"].default_value = 2.0
hmap = node(nt, "ShaderNodeMapping", -700, -900)
hmap.inputs["Scale"].default_value = (2200.0, 5200.0, 1.0)
nt.links.new(uv.outputs["UV"], hmap.inputs["Vector"])
nt.links.new(hmap.outputs["Vector"], heat.inputs["Vector"])
fleck = node(nt, "ShaderNodeMapRange", -300, -900)
fleck.inputs["From Min"].default_value = 0.58
fleck.inputs["From Max"].default_value = 0.72
nt.links.new(heat.outputs["Fac"], fleck.inputs["Value"])
col_ramp = node(nt, "ShaderNodeValToRGB", 600, 600)
col_ramp.color_ramp.elements[0].color = (0.0036, 0.0038, 0.0043, 1)
col_ramp.color_ramp.elements[1].color = (0.019, 0.020, 0.023, 1)
nt.links.new(h_all, col_ramp.inputs["Fac"])
col_f = node(nt, "ShaderNodeMix", 800, 600, data_type="RGBA", blend_type="MIX")
nt.links.new(math_node(nt, "MULTIPLY", fleck.outputs["Result"], math_node(nt, "SUBTRACT", 1.0, BIND, 500, 800), 650, 800), col_f.inputs["Factor"])
nt.links.new(col_ramp.outputs["Color"], col_f.inputs["A"])
col_f.inputs["B"].default_value = (0.026, 0.027, 0.030, 1)
col_b = node(nt, "ShaderNodeMix", 1000, 600, data_type="RGBA", blend_type="MULTIPLY")
nt.links.new(BIND, col_b.inputs["Factor"])
nt.links.new(col_f.outputs["Result"], col_b.inputs["A"])
col_b.inputs["B"].default_value = (0.72, 0.72, 0.74, 1)
nt.links.new(col_b.outputs["Result"], b.inputs["Base Color"])
rough_k = node(nt, "ShaderNodeMapRange", 800, 400)
nt.links.new(BIND, rough_k.inputs["Value"])
rough_k.inputs["To Min"].default_value = 0.82
rough_k.inputs["To Max"].default_value = 0.6
nt.links.new(rough_k.outputs["Result"], b.inputs["Roughness"])
b.inputs["Sheen Weight"].default_value = KNIT_SHEEN
b.inputs["Sheen Roughness"].default_value = 0.42
b.inputs["Sheen Tint"].default_value = (0.36, 0.38, 0.43, 1)
b.inputs["Specular IOR Level"].default_value = float(os.environ.get("LOOPR_KNIT_SPEC", "0.06"))
strap.data.materials.append(m_knit)

# pod polymer: dark, bead-blasted, no coat. The shell parts at a fine line low on the sides; the
# underside shell below it is a smoother satin. "flat" = the pod's own (s, w, radial) coordinates.
POD_PART_Z = 2.6                           # mm, the parting line's height
m_pod, nt, b = principled("PodPolymer")
b.inputs["Specular IOR Level"].default_value = 0.25
b.inputs["Sheen Weight"].default_value = 0.06
b.inputs["Sheen Roughness"].default_value = 0.5
b.inputs["Sheen Tint"].default_value = (0.25, 0.26, 0.29, 1)
pa = node(nt, "ShaderNodeAttribute", -1400, 0, attribute_name="flat", attribute_type="GEOMETRY")
psep = node(nt, "ShaderNodeSeparateXYZ", -1200, 0)
nt.links.new(pa.outputs["Vector"], psep.inputs["Vector"])
pz = psep.outputs["Z"]
lower = node(nt, "ShaderNodeMapRange", -1000, 200, interpolation_type="SMOOTHSTEP")
lower.inputs["From Min"].default_value = POD_PART_Z * 0.001 + 0.00005
lower.inputs["From Max"].default_value = POD_PART_Z * 0.001 - 0.00005
nt.links.new(pz, lower.inputs["Value"])
pgr = node(nt, "ShaderNodeMapRange", -1000, -100, interpolation_type="SMOOTHSTEP")
pgr.inputs["From Min"].default_value = 0.00004
pgr.inputs["From Max"].default_value = 0.00016
pgr.inputs["To Min"].default_value = 1.0
pgr.inputs["To Max"].default_value = 0.0
nt.links.new(math_node(nt, "ABSOLUTE", math_node(nt, "SUBTRACT", pz, POD_PART_Z * 0.001, -1050, -250), None, -1000, -300), pgr.inputs["Value"])
blast = node(nt, "ShaderNodeTexNoise", -900, -500)
blast.inputs["Scale"].default_value = 9000.0
blast.inputs["Detail"].default_value = 4.0
nt.links.new(pa.outputs["Vector"], blast.inputs["Vector"])
macro = node(nt, "ShaderNodeTexNoise", -900, -800)
macro.inputs["Scale"].default_value = 250.0
macro.inputs["Detail"].default_value = 2.0
nt.links.new(pa.outputs["Vector"], macro.inputs["Vector"])
p_rough = node(nt, "ShaderNodeMapRange", -500, 300)
nt.links.new(lower.outputs["Result"], p_rough.inputs["Value"])
p_rough.inputs["To Min"].default_value = 0.74
p_rough.inputs["To Max"].default_value = 0.45
nt.links.new(math_node(nt, "ADD", p_rough.outputs["Result"], math_node(nt, "MULTIPLY", math_node(nt, "SUBTRACT", macro.outputs["Fac"], 0.5, -600, -800), 0.14, -450, -800), -300, 300), b.inputs["Roughness"])
p_col = node(nt, "ShaderNodeMix", -300, 500, data_type="RGBA", blend_type="MIX")
nt.links.new(pgr.outputs["Result"], p_col.inputs["Factor"])
p_col.inputs["A"].default_value = (0.0055, 0.0058, 0.0066, 1)
p_col.inputs["B"].default_value = (0.0018, 0.0018, 0.0021, 1)
nt.links.new(p_col.outputs["Result"], b.inputs["Base Color"])
pb1 = node(nt, "ShaderNodeBump", -300, -200)
pb1.inputs["Strength"].default_value = 1.0
pb1.inputs["Distance"].default_value = 0.00007
pb1.invert = True
nt.links.new(pgr.outputs["Result"], pb1.inputs["Height"])
pb2 = node(nt, "ShaderNodeBump", -100, -300)
nt.links.new(math_node(nt, "SUBTRACT", 1.0, math_node(nt, "MULTIPLY", lower.outputs["Result"], 0.6, -400, -450), -250, -450), pb2.inputs["Strength"])
pb2.inputs["Distance"].default_value = 0.000012
nt.links.new(blast.outputs["Fac"], pb2.inputs["Height"])
nt.links.new(pb1.outputs["Normal"], pb2.inputs["Normal"])
nt.links.new(pb2.outputs["Normal"], b.inputs["Normal"])
pod.data.materials.append(m_pod)

m_gloss = m_pod                                  # the top step is the same plastic; only its edge shows
inset.data.materials.append(m_pod)

m_sensor, nt, b = principled("SensorWindow")
b.inputs["Base Color"].default_value = (0.002, 0.003, 0.002, 1)
b.inputs["Roughness"].default_value = 0.1
b.inputs["Emission Color"].default_value = (0.12, 1.0, 0.28, 1)
b.inputs["Emission Strength"].default_value = 0.0
sensor.data.materials.append(m_sensor)

# anodised titanium: a fine brush along each part (the "Brush" uv: arc length along the bar or
# plate), anisotropic highlights that stretch along the rails, crisp on the rounded edges
METAL_COLOR = tuple(float(v) for v in os.environ.get("LOOPR_METAL", "0.23,0.225,0.22").split(","))
m_ti, nt, b = principled("BrushedTitanium")
b.inputs["Base Color"].default_value = (*METAL_COLOR, 1)
b.inputs["Metallic"].default_value = 1.0
b.inputs["Anisotropic"].default_value = 0.65
uvb = node(nt, "ShaderNodeUVMap", -1000, -500)
uvb.uv_map = "Brush"
uvt = node(nt, "ShaderNodeTangent", -400, -500, direction_type="UV_MAP", uv_map="Brush")
nt.links.new(uvt.outputs["Tangent"], b.inputs["Tangent"])
uv = node(nt, "ShaderNodeUVMap", -1000, -200)
uv.uv_map = "UVMap"
mp = node(nt, "ShaderNodeMapping", -800, -200)
mp.inputs["Scale"].default_value = (60.0, 30000.0, 1.0)
nt.links.new(uvb.outputs["UV"], mp.inputs["Vector"])
br = node(nt, "ShaderNodeTexNoise", -600, -200)
br.inputs["Scale"].default_value = 1.0
br.inputs["Detail"].default_value = 8.0
nt.links.new(mp.outputs["Vector"], br.inputs["Vector"])
rr = math_node(nt, "MULTIPLY_ADD", br.outputs["Fac"], 0.07, -300, 0)
rr.node.inputs[2].default_value = 0.21
nt.links.new(rr, b.inputs["Roughness"])
bb = node(nt, "ShaderNodeBump", -300, -250)
bb.inputs["Strength"].default_value = 0.04
bb.inputs["Distance"].default_value = 0.00002
nt.links.new(br.outputs["Fac"], bb.inputs["Height"])
nt.links.new(bb.outputs["Normal"], b.inputs["Normal"])
# click glint: a narrow slanted streak that runs along the latch (UV x = arc length in metres)
gsep = node(nt, "ShaderNodeSeparateXYZ", -800, 400)
nt.links.new(uv.outputs["UV"], gsep.inputs["Vector"])
gpos = node(nt, "ShaderNodeValue", -800, 600)
gpos.name = "GlintPos"
gamp = node(nt, "ShaderNodeValue", -800, 700)
gamp.name = "GlintAmp"
slant = math_node(nt, "MULTIPLY_ADD", gsep.outputs["Y"], 0.35, -600, 450)
nt.links.new(gsep.outputs["X"], slant.node.inputs[2])
gd = math_node(nt, "ABSOLUTE", math_node(nt, "SUBTRACT", slant, gpos.outputs[0], -450, 450), None, -300, 450)
gm = math_node(nt, "POWER", math_node(nt, "MAXIMUM", math_node(nt, "SUBTRACT", 1.0, math_node(nt, "DIVIDE", gd, 0.0009, -200, 450), -100, 450), 0.0, 0, 450), 2.0, 100, 450)
nt.links.new(math_node(nt, "MULTIPLY", gm, gamp.outputs[0], 250, 450), b.inputs["Emission Strength"])
b.inputs["Emission Color"].default_value = (1.0, 0.95, 0.88, 1)
for ob_ in (frame_ob, slider):
    ob_.data.materials.append(m_ti)
# the cap faces the lights squarely; a darker anodised finish keeps it below the rails' peaks
CAP_DARK = float(os.environ.get("LOOPR_CAP_DARK", "0.55"))
m_cap = m_ti.copy()
m_cap.name = "AnodisedCap"
m_cap.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*[c * CAP_DARK for c in METAL_COLOR], 1)
cap.data.materials.append(m_cap)

# ---------------------------------------------------------------------------
# 8. skin smoothing (render only)
sub = skin.modifiers.new("Smooth render", "SUBSURF")
sub.levels = 0
sub.render_levels = int(os.environ.get("LOOPR_SUBD", "2"))
sub.quality = 3

# BodyParts3D anatomy pokes through the skin in places (finger tips, forearm muscle bellies,
# the muscles that run on toward the elbow). Pull only the offending vertices back inside the
# posed skin, 1 mm under its surface. Target Normal Project, because plain nearest-point
# misreads inside/outside where the palm creases at the knuckles when the fingers twitch.
ANATOMY_MARGIN = 0.001
for ob in anatomy:
    sw = ob.modifiers.new("Keep inside skin", "SHRINKWRAP")
    sw.target = skin
    sw.wrap_method = "TARGET_PROJECT"
    sw.wrap_mode = "INSIDE"
    sw.offset = ANATOMY_MARGIN

# ---------------------------------------------------------------------------
# 9. composition: camera basis, hand placement, hand-in animation (world)

def cam_basis(az_deg, el_deg):
    az, el = math.radians(az_deg), math.radians(el_deg)
    f = Vector((math.sin(az) * math.cos(el), math.cos(az) * math.cos(el), -math.sin(el)))
    r = f.cross(Vector((0, 0, 1))).normalized()
    u = r.cross(f).normalized()
    return r, u, f


FRAME_H = FINAL_FRAME_W * 2340.0 / 1080.0
D0 = FRAME_H * LENS / 36.0            # sensor fit AUTO: 36 mm across the long (vertical) side
r0, u0, f0 = cam_basis(0.0, CAM_EL)
D = (ARM_CAM[0] * r0 + ARM_CAM[1] * u0 + ARM_CAM[2] * f0).normalized()
U = DORSAL_CAM[0] * r0 + DORSAL_CAM[1] * u0 + DORSAL_CAM[2] * f0
U = (U - (U @ D) * D).normalized()
X = U.cross(D)
R_world = Matrix((X, U, D)).transposed()                       # band-local -> world
R_rig = Matrix((Vector(e_x), Vector(e_y), Vector(e_w))).transposed()
R_final = R_world @ R_rig.transposed()
loc_final = -(R_final @ Vector(O))
rig.rotation_mode = "QUATERNION"
q_final = R_final.to_quaternion()


def to_band(v_world):
    """world direction -> band-local direction (BandMotion space)"""
    return R_world.transposed() @ Vector(v_world)


# glide in from the lower right, starting outside the frame
start_off = r0 * 0.21 - u0 * 0.23 - f0 * 0.05
q_start = Quaternion(D, math.radians(-18.0)) @ Quaternion(u0, math.radians(-10.0)) @ q_final
kf(rig, "location", F_FIRST, loc_final + start_off, "BEZIER")
kf(rig, "rotation_quaternion", F_FIRST, q_start, "BEZIER")
kf(rig, "location", F_HAND_END, loc_final, "BEZIER")
kf(rig, "rotation_quaternion", F_HAND_END, q_final, "BEZIER")
# micro reaction to the click
q_react = Quaternion(D, math.radians(0.6)) @ Quaternion(X, math.radians(-0.35)) @ q_final
kf(rig, "location", F_CLICK, loc_final)
kf(rig, "rotation_quaternion", F_CLICK, q_final)
kf(rig, "location", F_CLICK + 4, loc_final - U * 0.0008)
kf(rig, "rotation_quaternion", F_CLICK + 4, q_react)
kf(rig, "location", F_CLICK + 24, loc_final)
kf(rig, "rotation_quaternion", F_CLICK + 24, q_final)
# the glide: quick entry, long soft settle (custom handles, no linear keys)
for path, n, h0, h1 in (("location", 3, (13, 0.40), 44), ("rotation_quaternion", 4, (16, 0.32), 48)):
    for idx in range(n):
        fc = find_fc(rig, path, idx)
        k0, k1 = fc.keyframe_points[0], fc.keyframe_points[1]
        for kp in (k0, k1):
            kp.handle_left_type = kp.handle_right_type = "FREE"
        dv = k1.co.y - k0.co.y
        k0.handle_left = (k0.co.x - 5, k0.co.y)
        k0.handle_right = (k0.co.x + h0[0], k0.co.y + dv * h0[1])
        k1.handle_left = (k1.co.x - h1, k1.co.y)
        fc.update()

# ---------------------------------------------------------------------------
# 10. band recoil, LED pulse, glow (BandMotion local = band space, mm)


def band_key(frame, loc_world_mm, rot_deg, interp="BEZIER", easing="AUTO", handles="AUTO_CLAMPED"):
    band.rotation_mode = "XYZ"
    kf(band, "location", frame, to_band(loc_world_mm) * 0.001, interp, easing, handles)
    kf(band, "rotation_euler", frame, Vector([math.radians(a) for a in rot_deg]), interp, easing, handles)


# the drop, wrap, swing and landing are baked in section 6; BandMotion only adds the recoil
band_key(F_FIRST, Vector((0.0, 0.0, 0.0)), (0.0, 0.0, 0.0), "CONSTANT")
band_key(F_CLICK, Vector((0.0, 0.0, 0.0)), (0.0, 0.0, 0.0))
band_key(F_CLICK + 2, -U * 0.25 + X * 0.10, (0.0, 0.0, -0.55))
band_key(F_CLICK + 4, U * 0.06 - X * 0.03, (0.0, 0.0, 0.15))
band_key(F_CLICK + 7, Vector((0.0, 0.0, 0.0)), (0.0, 0.0, 0.0))

# LED pulse + sensor emission
kf(led_data, "energy", F_FIRST, 0.0, "CONSTANT")
kf(led_data, "energy", F_CLICK, 0.0, "SINE", "EASE_OUT")
kf(led_data, "energy", F_CLICK + 5, 0.16, "SINE", "EASE_IN_OUT")
kf(led_data, "energy", F_CLICK + 34, 0.0)
sens_in = m_sensor.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"]
kf(sens_in, "default_value", F_FIRST, 0.0, "CONSTANT")
kf(sens_in, "default_value", F_CLICK, 0.0, "SINE", "EASE_OUT")
kf(sens_in, "default_value", F_CLICK + 5, 10.0, "SINE", "EASE_IN_OUT")
kf(sens_in, "default_value", F_CLICK + 34, 0.0)
for amt in band_occ_nodes:
    kf(amt.outputs[0], "default_value", F_FIRST, 0.0, "CONSTANT")
    kf(amt.outputs[0], "default_value", F_WRAP, 0.0, "SINE", "EASE_IN_OUT")
    kf(amt.outputs[0], "default_value", F_HOOK, 1.0)
glow_amp = m_ghost.node_tree.nodes["GlowAmp"].outputs[0]
kf(glow_amp, "default_value", F_FIRST, 0.0, "CONSTANT")
kf(glow_amp, "default_value", F_CLICK, 0.0, "SINE", "EASE_OUT")
kf(glow_amp, "default_value", F_CLICK + 5, 1.0, "SINE", "EASE_IN_OUT")
kf(glow_amp, "default_value", F_CLICK + 34, 0.0)

# ---------------------------------------------------------------------------
# 11. lights (world). Positions are given relative to the final camera basis.


def area(name, loc, target, size, energy, color, size_y=None, spread=None):
    ld = bpy.data.lights.new(name, "AREA")
    ld.shape = "RECTANGLE"
    ld.size = size
    ld.size_y = size_y if size_y is not None else size
    ld.energy = energy
    ld.color = color
    if spread is not None:
        ld.spread = math.radians(spread)
    ob = bpy.data.objects.new(name, ld)
    col_light.objects.link(ob)
    ob.location = Vector(loc)
    dvec = Vector(target) - Vector(loc)
    ob.rotation_euler = dvec.to_track_quat("-Z", "Y").to_euler()
    return ob


def kelvin(k):
    t = k / 100.0
    r = 255 if t <= 66 else 329.698727446 * ((t - 60) ** -0.1332047592)
    g = 99.4708025861 * math.log(t) - 161.1195681661 if t <= 66 else 288.1221695283 * ((t - 60) ** -0.0755148492)
    bl = 255 if t >= 66 else (0 if t <= 19 else 138.5177312231 * math.log(t - 10) - 305.0447927307)
    c = [max(0.0, min(255.0, v)) / 255.0 for v in (r, g, bl)]
    return tuple((v / 12.92) if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in c)


up = Vector((0, 0, 1))
hand_pt = D * 0.07                          # a bit toward the knuckles
LIGHTS = {
    # name: (position, target, size, size_y, energy, kelvin, spread)
    "Key": (-r0 * 0.30 + up * 0.26 - f0 * 0.10, hand_pt, 0.26, 0.20, 0.30, 5200, 34),
    "RimCool": (r0 * 0.20 + up * 0.18 + f0 * 0.40, Vector((0, 0, 0.01)), 0.55, 0.035, 2.3, 9500, 45),
    "RimCoolLeft": (-r0 * 0.34 + up * 0.08 + f0 * 0.38, hand_pt, 0.45, 0.035, 0.6, 9000, 45),
    "FillWarm": (-r0 * 0.10 - f0 * 0.45 + up * 0.10, hand_pt, 0.5, 0.5, 0.05, 3000, 40),
}
light_objs = {}
# the skin lights skip the titanium clasp, which gets its own card and the click glint
col_no_clasp = bpy.data.collections.new("SkinLightReceivers")
for ob_ in (frame_ob, cap, slider):
    col_no_clasp.objects.link(ob_)
for item in col_no_clasp.collection_objects:
    item.light_linking.link_state = "EXCLUDE"
for name, (loc, tgt, s, sy, en, k, spr) in LIGHTS.items():
    light_objs[name] = area(name, loc, tgt, s, en, kelvin(k), size_y=sy, spread=spr)
    if name in ("Key", "RimCool", "RimCoolLeft"):
        light_objs[name].light_linking.receiver_collection = col_no_clasp
# product key: only lights the band, so the product can sit brighter than the skin
light_objs["ProductKey"] = area("ProductKey", -r0 * 0.20 + up * 0.30 - f0 * 0.20, Vector((0, 0, 0)), 0.30, 0.07, kelvin(6800), size_y=0.22, spread=40)
light_objs["ProductKey"].light_linking.receiver_collection = col_product
# product highlight: long strip mirrored about the pod's top so it streaks across the glossy inset
cam_dir = (-f0).normalized()
refl = (2 * (cam_dir @ U) * U - cam_dir).normalized()          # mirror of the view ray
pod_top = U * 0.031
light_objs["PodStrip"] = area("PodStrip", pod_top + refl * 0.30, pod_top, 0.30, 0.05, kelvin(6200), size_y=0.02, spread=30)
# soft card mirrored about the latch top so the brushed titanium has something to reflect
latch_n = R_world @ Vector((*N_F, 0.0))
latch_p = R_world @ Vector(fpos)
refl_c = (2 * (cam_dir @ latch_n) * latch_n - cam_dir).normalized()
light_objs["ClaspCard"] = area("ClaspCard", latch_p + refl_c * 0.25 + up * 0.04, latch_p, 0.22, 0.03, kelvin(6000), size_y=0.10, spread=60)
light_objs["ClaspCard"].light_linking.receiver_collection = col_glint
# kicker: a strip behind and above the band, for the band only. It draws the strap's knit sheen,
# the rails' top edges and the pod's far edges as a thin bright line against the dark.
col_band_rx = bpy.data.collections.new("BandLightReceivers")
for ob_ in (strap, frame_ob, slider):          # not the cap or the pod: the strip turns their tops grey
    col_band_rx.objects.link(ob_)
KICK = float(os.environ.get("LOOPR_KICK", "0.55"))
light_objs["BandKicker"] = area("BandKicker", f0 * 0.30 + u0 * 0.20 + r0 * 0.06, U * 0.01, 0.30, 2.2 * KICK, kelvin(7500),
                                size_y=0.05, spread=50)
light_objs["BandKicker"].light_linking.receiver_collection = col_band_rx
light_objs["BandUnder"] = area("BandUnder", -f0 * 0.10 - u0 * 0.28 + r0 * 0.12, U * 0.0, 0.25, 0.25 * KICK, kelvin(5600),
                               size_y=0.05, spread=60)
light_objs["BandUnder"].light_linking.receiver_collection = col_band_rx

# Reflection cards: soft emissive panels seen only by glossy rays (no camera, no diffuse, no
# shadow), placed where the camera sees their mirror image in the band's key surfaces at the
# final pose. They give the titanium something to reflect (a lit top edge, a highlight band
# along the near rail's outer face, a sheet over the cap) and the pod a soft sheen.
CARD_GAIN = float(os.environ.get("LOOPR_CARD_GAIN", "1.0"))
col_cards = bpy.data.collections.new("ReflectionCards")
scene.collection.children.link(col_cards)
cards = {}


def card(name, at, n, dist, size, size_y, strength, kel, long_axis, soft=0.14, lift=Vector((0, 0, 0)), ramp_lo=1.0,
         receivers=None):
    n = Vector(n).normalized()
    r = (2 * (cam_dir @ n) * n - cam_dir).normalized()
    loc = Vector(at) + r * dist + lift
    zc = (Vector(at) - loc).normalized()                         # local -z faces away; both sides emit
    xc = Vector(long_axis) - (Vector(long_axis) @ zc) * zc
    xc.normalize()
    yc = zc.cross(xc)
    me = bpy.data.meshes.new(name)
    hx, hy = size / 2, size_y / 2
    me.from_pydata([(-hx, -hy, 0), (hx, -hy, 0), (hx, hy, 0), (-hx, hy, 0)], [], [(0, 1, 2, 3)])
    ob = bpy.data.objects.new(name, me)
    col_cards.objects.link(ob)
    ob.matrix_world = Matrix.Translation(loc) @ Matrix((xc, yc, -zc)).transposed().to_4x4()
    for attr in ("visible_camera", "visible_diffuse", "visible_transmission", "visible_volume_scatter", "visible_shadow"):
        setattr(ob, attr, False)
    ob.visible_glossy = True
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt_ = m.node_tree
    nt_.nodes.clear()
    o_ = node(nt_, "ShaderNodeOutputMaterial", 600, 0)
    em = node(nt_, "ShaderNodeEmission", 300, 0)
    em.inputs["Color"].default_value = (*kelvin(kel), 1)
    tc__ = node(nt_, "ShaderNodeTexCoord", -600, 0)
    sp = node(nt_, "ShaderNodeSeparateXYZ", -400, 0)
    nt_.links.new(tc__.outputs["Generated"], sp.inputs["Vector"])
    fall = None
    for ax in ("X", "Y"):
        edge = math_node(nt_, "MINIMUM", sp.outputs[ax], math_node(nt_, "SUBTRACT", 1.0, sp.outputs[ax], -250, 0), -100, 0)
        mr = node(nt_, "ShaderNodeMapRange", 0, 0, interpolation_type="SMOOTHSTEP")
        mr.inputs["From Min"].default_value = 0.0
        mr.inputs["From Max"].default_value = soft
        nt_.links.new(edge, mr.inputs["Value"])
        fall = mr.outputs["Result"] if fall is None else math_node(nt_, "MULTIPLY", fall, mr.outputs["Result"], 150, 0)
    amp = node(nt_, "ShaderNodeValue", 0, -300)
    amp.name = "CardAmp"
    amp.outputs[0].default_value = strength * CARD_GAIN
    # brighter toward the card's +y edge, so flat faces show a gradient instead of a flat sheet
    grad = math_node(nt_, "MULTIPLY_ADD", sp.outputs["Y"], 1.0 - ramp_lo, -100, -400)
    grad.node.inputs[2].default_value = ramp_lo
    nt_.links.new(math_node(nt_, "MULTIPLY", math_node(nt_, "MULTIPLY", fall, grad, 100, -300), amp.outputs[0], 200, -200), em.inputs["Strength"])
    nt_.links.new(em.outputs["Emission"], o_.inputs["Surface"])
    m.cycles.emission_sampling = "NONE"
    me.materials.append(m)
    if receivers is not None:
        ob.light_linking.receiver_collection = receivers     # emissive meshes take light linking too
    cards[name] = (ob, amp)
    return ob


band_c = Vector((0, 0, 0))
col_pod_rx = bpy.data.collections.new("PodCardReceivers")
col_pod_rx.objects.link(pod)
# metal only: the knit and the pod would turn grey in them
card("CardRailTop", band_c + U * 0.009, U, 0.30, 0.36, 0.022, 1.6, 6500, X, receivers=col_glint)
card("CardRailNear", band_c - D * 0.014, -D, 0.30, 0.40, 0.03, 1.8, 6800, X, receivers=col_glint)
card("CardRailNearSoft", band_c - D * 0.014, (-D * 0.8 + U * 0.6), 0.32, 0.40, 0.12, 0.6, 6000, X, ramp_lo=0.15,
     receivers=col_glint)
card("CardCap", latch_p, latch_n, 0.26, 0.10, 0.22, 0.35, 6200, D, ramp_lo=0.08, receivers=col_glint)
# the pod: one faint soft sheet, so its rounded sides and ends show their form
card("CardPod", band_c - D * 0.012, (-D * 0.7 + U * 0.7), 0.30, 0.30, 0.10, float(os.environ.get("LOOPR_POD_CARD", "0.12")),
     6000, X, soft=0.3, ramp_lo=0.2, receivers=col_pod_rx)
for name, (ob, amp) in cards.items():
    v_ = amp.outputs[0].default_value
    kf(amp.outputs[0], "default_value", F_FIRST, 0.0, "SINE", "EASE_IN_OUT")
    kf(amp.outputs[0], "default_value", fr(LIGHT_UP), v_, "SINE", "EASE_IN_OUT")
# lights come up with the hand
for name, ob in light_objs.items():
    en = ob.data.energy
    kf(ob.data, "energy", F_FIRST, 0.0, "SINE", "EASE_IN_OUT")
    kf(ob.data, "energy", fr(LIGHT_UP), en, "SINE", "EASE_IN_OUT")

# glint: linked only to the clasp, sweeps across it at the click
glint = area("Glint", Vector((0, 0, 0)), Vector((0, 0, 0.01)), 0.012, 0.0, kelvin(6500), size_y=0.20)
glint.light_linking.receiver_collection = col_glint
kf(glint.data, "energy", F_FIRST, 0.0, "CONSTANT")
kf(glint.data, "energy", F_CLICK, 0.0, "SINE", "EASE_OUT")
kf(glint.data, "energy", F_CLICK + 2, 0.2, "SINE", "EASE_IN_OUT")
kf(glint.data, "energy", F_CLICK + 10, 0.0)
latch_t = (R_world @ Vector((*T_F, 0.0))).normalized()
g_mid = latch_p + refl_c * 0.20
kf(glint, "location", F_FIRST, g_mid - latch_t * 0.06, "CONSTANT")
kf(glint, "location", F_CLICK, g_mid - latch_t * 0.06, "SINE", "EASE_IN_OUT")
kf(glint, "location", F_CLICK + 10, g_mid + latch_t * 0.06)
u0 = (HINGE_IN - 3.0) * 0.001                  # uv x runs from end A along the rails onto the cap
u1 = (q_k - CAP_BOT[:, 0].min() + 1.5) * 0.001
for m_g in (m_ti, m_cap):
    g_nodes = m_g.node_tree.nodes
    kf(g_nodes["GlintPos"].outputs[0], "default_value", F_FIRST, u0, "CONSTANT")
    kf(g_nodes["GlintPos"].outputs[0], "default_value", F_CLICK, u0, "SINE", "EASE_IN_OUT")
    kf(g_nodes["GlintPos"].outputs[0], "default_value", F_CLICK + 9, u1)
    kf(g_nodes["GlintAmp"].outputs[0], "default_value", F_FIRST, 0.0, "CONSTANT")
    kf(g_nodes["GlintAmp"].outputs[0], "default_value", F_CLICK, 0.0, "SINE", "EASE_OUT")
    kf(g_nodes["GlintAmp"].outputs[0], "default_value", F_CLICK + 3, 6.0, "SINE", "EASE_IN_OUT")
    kf(g_nodes["GlintAmp"].outputs[0], "default_value", F_CLICK + 9, 0.0)
# thin strip across the latch width, aimed at the latch: its reflection is a narrow streak
# that travels along the brushed titanium as the light moves along the latch tangent
gz = -(latch_p - g_mid).normalized()
gy = (D - (D @ gz) * gz).normalized()
gx = gy.cross(gz)
glint.rotation_euler = Matrix((gx, gy, gz)).transposed().to_euler()
glint.data.size = 0.0025
glint.data.size_y = 0.14

world = bpy.data.worlds.new("Dark")
scene.world = world
try:
    world.use_nodes = True
except Exception:
    pass
wbg = world.node_tree.nodes.get("Background")
wbg.inputs["Color"].default_value = (0.0, 0.0, 0.0, 1)
wbg.inputs["Strength"].default_value = 0.0

# ---------------------------------------------------------------------------
# 12. camera

cam_data = bpy.data.cameras.new("Camera")
cam = bpy.data.objects.new("Camera", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam
cam_data.lens = LENS
cam_data.sensor_fit = "AUTO"
cam_data.sensor_width = 36.0
cam_data.clip_start = 0.02
cam_data.clip_end = 10.0
cam_data.dof.use_dof = True
cam_data.dof.focus_object = focus
cam_data.dof.aperture_fstop = FSTOP
cam_data.dof.aperture_blades = 7
cam_data.dof.aperture_rotation = math.radians(12)

aim = bpy.data.objects.new("CameraAim", None)
scene.collection.objects.link(aim)
aim.empty_display_size = 0.02
tc_ = cam.constraints.new("TRACK_TO")
tc_.target = aim
tc_.track_axis = "TRACK_NEGATIVE_Z"
tc_.up_axis = "UP_Y"


def cam_state(key_name, anchor):
    dist_f, az, el, ix, iy = CAM_STATES[key_name]
    r, u, f = cam_basis(az, el)
    dist = D0 * dist_f
    H = dist * 36.0 / LENS
    W = H * 1080.0 / 2340.0
    a = Vector(anchor) + r * ((0.5 - ix) * W) + u * ((iy - 0.5) * H)
    return a - f * dist, a


clasp_world = R_world @ Vector(fpos)
for frame, name, anchor in ((F_FIRST, "first", Vector((0, 0, 0))), (F_WRAP, "wrap", Vector((0, 0, 0))),
                            (F_CLICK, "click", clasp_world * 0.6), (F_LAST, "last", Vector((0, 0, 0)))):
    c, a = cam_state(name, anchor)
    kf(cam, "location", frame, c)
    kf(aim, "location", frame, a)
for ob in (cam, aim):
    for idx in range(3):
        fc = find_fc(ob, "location", idx)
        last = fc.keyframe_points[-1]
        prev = fc.keyframe_points[-2]
        last.handle_left_type = "FREE"
        last.handle_left = (last.co.x - (last.co.x - prev.co.x) * 0.45, last.co.y)
        fc.update()

# f-stop: a touch shallower at the click
kf(cam_data.dof, "aperture_fstop", F_FIRST, FSTOP)
kf(cam_data.dof, "aperture_fstop", F_CLICK, FSTOP * 0.8)
kf(cam_data.dof, "aperture_fstop", F_LAST, FSTOP)

# ---------------------------------------------------------------------------
# 13. render settings

scene.render.resolution_x = 1080
scene.render.resolution_y = 2340
scene.render.resolution_percentage = 100
scene.render.film_transparent = True
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.image_settings.color_depth = "16"
scene.render.use_persistent_data = True
scene.render.use_motion_blur = True
scene.render.motion_blur_shutter = 0.4
try:
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "AgX - Medium High Contrast"
except TypeError:
    pass
scene.view_settings.exposure = 0.0

scene.render.engine = "CYCLES"
cy = scene.cycles
cy.device = "GPU"
cy.samples = 96
cy.use_adaptive_sampling = True
cy.adaptive_threshold = 0.02
cy.use_denoising = True
cy.denoiser = "OPENIMAGEDENOISE"
cy.denoising_input_passes = "RGB_ALBEDO_NORMAL"
cy.max_bounces = 8
cy.diffuse_bounces = 3
cy.glossy_bounces = 4
cy.transmission_bounces = 4
cy.transparent_max_bounces = 32 if WITH_SOFT else 8    # skin + stacked glass muscle layers
cy.caustics_reflective = False
cy.caustics_refractive = False
cy.blur_glossy = 1.0
cy.sample_clamp_indirect = 8.0


def contract_bg_hex():
    """The decided background from CONTRACT.md (same rule as render.sh bg_hex)."""
    import re
    txt = open(os.path.join(HERE, "CONTRACT.md")).read()
    sec = txt.split("## Background", 1)[1].split("\n## ", 1)[0]
    m = re.search(r"Final:.*?(#[0-9A-Fa-f]{6})", sec) or re.search(r"#[0-9A-Fa-f]{6}", sec)
    return m.group(1) if m else "#07090B"


def solve_display_linear(targets, margin=0.0):
    """Scene-linear RGB that the scene's view transform displays as each target (n x 3 display
    floats; a hair below, per channel, so the composite's floor at the backdrop snaps it exactly).
    One small image, one pixel per target, Newton steps with a numeric Jacobian per pixel."""
    import OpenImageIO as oiio
    tg = np.atleast_2d(np.asarray(targets, dtype=np.float64)) - margin / 255.0
    n = len(tg)
    img = bpy.data.images.new("_bgsolve", n, 1, float_buffer=True)
    path = os.path.join(bpy.app.tempdir or "/tmp", "loopr_bgsolve.png")
    fmt = scene.render.image_settings
    old = (fmt.file_format, fmt.color_depth, fmt.color_mode)
    fmt.file_format, fmt.color_depth, fmt.color_mode = "PNG", "16", "RGB"

    def show(lin):
        img.pixels.foreach_set(np.c_[lin, np.ones(n)].astype(np.float32).ravel())
        img.save_render(path, scene=scene)
        return oiio.ImageInput.open(path).read_image(format="float")[0, :, :3].astype(np.float64)

    def to_lin(d):
        return np.where(d <= 0.04045, d / 12.92, ((d + 0.055) / 1.055) ** 2.4)

    lin = to_lin(tg) * 0.5 + 1e-4
    for _ in range(60):
        d = show(lin)
        err = tg - d
        if np.abs(err).max() < 0.02 / 255.0:
            break
        J = np.zeros((n, 3, 3))
        h = np.maximum(lin * 0.02, 1e-6)
        for k in range(3):
            dl = np.zeros_like(lin)
            dl[:, k] = h[:, k]
            J[:, :, k] = (show(lin + dl) - d) / h[:, k:k + 1]
        lin = np.maximum(lin + np.linalg.solve(J, err[..., None])[..., 0], 1e-7)
    fmt.file_format, fmt.color_depth, fmt.color_mode = old
    bpy.data.images.remove(img)
    log(f"backdrop solve: {n} colours, worst error {np.abs(err).max() * 255.0:.3f} of 255")
    return lin


sys.path.insert(0, HERE)
import backdrop as bdmod  # noqa: E402

BG_LOOK = os.environ.get("LOOPR_BG", bdmod.DEFAULT_LOOK)
BEHIND_DIM = float(os.environ.get("LOOPR_BEHIND_DIM", "0.5"))   # band seen through the skin keeps 1 - this
GLASS_SEE = float(os.environ.get("LOOPR_GLASS_SEE", "0.35"))    # share of the backdrop's light seen through the skin

if GHOST:
    # Camera-only backdrop. Direct camera rays hit a holdout, so the film stays transparent and the
    # background composite (composite.py) stays exact. Rays that already went through the ghost
    # skin hit the studio backdrop instead (backdrop.py: a light map g in screen space, through a
    # colour ramp solved so the view transform shows exactly the composite's plate), so the ghost
    # blends with the backdrop exactly like it blends with the strap and bones behind it.
    if contract_bg_hex().upper() != bdmod.BG_HEX.upper():
        raise SystemExit(f"CONTRACT.md background {contract_bg_hex()} != backdrop.py {bdmod.BG_HEX}")
    G_STOPS = np.linspace(0.0, 1.0, 32)
    ramp_lin = solve_display_linear(bdmod.display_from_g(BG_LOOK, G_STOPS))
    gw, gh = 1080 // 4, 2340 // 4
    gmap = bdmod.light_map(BG_LOOK, gw, gh)[::-1]                  # Blender images start at the bottom
    g_img = bpy.data.images.new("BackdropLightMap", gw, gh, float_buffer=True)
    g_img.pixels.foreach_set(np.dstack([gmap, gmap, gmap, np.ones_like(gmap)]).astype(np.float32).ravel())
    g_img.filepath_raw = os.path.join(bpy.app.tempdir or "/tmp", "loopr_backdrop_g.exr")
    g_img.file_format = "OPEN_EXR"
    g_img.save()
    g_img.pack()
    g_img.colorspace_settings.name = "Non-Color"
    bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16, radius=4.0, location=(0, 0, 0))
    backdrop = bpy.context.active_object
    backdrop.name = "GhostBackdrop"
    for c in list(backdrop.users_collection):
        c.objects.unlink(backdrop)
    scene.collection.objects.link(backdrop)
    backdrop.visible_shadow = False
    backdrop.visible_diffuse = False
    backdrop.visible_glossy = False
    backdrop.visible_transmission = False
    backdrop.visible_volume_scatter = False
    m_bd = bpy.data.materials.new("GhostBackdrop")
    m_bd.use_nodes = True
    nt = m_bd.node_tree
    nt.nodes.clear()
    bd_out = node(nt, "ShaderNodeOutputMaterial", 600, 0)
    bd_lp = node(nt, "ShaderNodeLightPath", -400, 0)
    bd_hold = node(nt, "ShaderNodeHoldout", 0, 150)
    bd_tc = node(nt, "ShaderNodeTexCoord", -1200, -200)
    bd_tex = node(nt, "ShaderNodeTexImage", -1000, -200, image=g_img, interpolation="Linear", extension="EXTEND")
    nt.links.new(bd_tc.outputs["Window"], bd_tex.inputs["Vector"])
    bd_sep = node(nt, "ShaderNodeSeparateColor", -750, -200)
    nt.links.new(bd_tex.outputs["Color"], bd_sep.inputs["Color"])
    bd_fade = node(nt, "ShaderNodeValue", -750, -400)
    bd_fade.name = "BackdropFade"
    bd_ramp = node(nt, "ShaderNodeValToRGB", -350, -200)
    cr = bd_ramp.color_ramp
    cr.interpolation = "LINEAR"
    cr.color_mode = "RGB"
    while len(cr.elements) < len(G_STOPS):
        cr.elements.new(0.5)
    for el, gv, lv in zip(cr.elements, G_STOPS, ramp_lin):
        el.position = float(gv)
        el.color = (*[float(v) for v in lv], 1.0)
    nt.links.new(math_node(nt, "MULTIPLY", math_node(nt, "MULTIPLY", bd_sep.outputs["Red"], bd_fade.outputs[0], -600, -250),
                           GLASS_SEE, -500, -250), bd_ramp.inputs["Fac"])
    bd_em = node(nt, "ShaderNodeEmission", 0, -100)
    nt.links.new(bd_ramp.outputs["Color"], bd_em.inputs["Color"])
    bd_em.inputs["Strength"].default_value = 1.0
    bd_mix = node(nt, "ShaderNodeMixShader", 300, 0)
    nt.links.new(math_node(nt, "GREATER_THAN", bd_lp.outputs["Transparent Depth"], 0.5, -200, 0), bd_mix.inputs["Fac"])
    nt.links.new(bd_hold.outputs["Holdout"], bd_mix.inputs[1])
    nt.links.new(bd_em.outputs["Emission"], bd_mix.inputs[2])
    nt.links.new(bd_mix.outputs["Shader"], bd_out.inputs["Surface"])
    m_bd.cycles.emission_sampling = "NONE"
    backdrop.data.materials.append(m_bd)
    # the pool comes up with the lights, on the same curve as composite.py (backdrop.fade)
    f0, f1 = bdmod.FADE_FRAMES
    kf(bd_fade.outputs[0], "default_value", f0, 0.0, "SINE", "EASE_IN_OUT")
    kf(bd_fade.outputs[0], "default_value", f1, 1.0, "SINE", "EASE_IN_OUT")
    log(f"backdrop '{BG_LOOK}', light map {gw}x{gh}, fade frames {f0}-{f1}")

    # Depth cue: band surfaces reached through the skin (the far run of the strap, the frame on
    # the far side) keep only 1 - BEHIND_DIM of their light, so they read as behind the glass
    # rather than inside the arm. Band surfaces in front of the skin are untouched.
    def behind_glass(m):
        nt_ = m.node_tree
        out_ = [n_ for n_ in nt_.nodes if n_.type == "OUTPUT_MATERIAL"][0]
        src = out_.inputs["Surface"].links[0].from_socket
        lp_ = node(nt_, "ShaderNodeLightPath", out_.location.x - 600, out_.location.y - 400)
        blk = node(nt_, "ShaderNodeEmission", out_.location.x - 300, out_.location.y - 300)
        blk.inputs["Color"].default_value = (0.0, 0.0, 0.0, 1.0)
        blk.inputs["Strength"].default_value = 0.0
        mx = node(nt_, "ShaderNodeMixShader", out_.location.x - 150, out_.location.y - 100)
        nt_.links.new(math_node(nt_, "MULTIPLY", math_node(nt_, "GREATER_THAN", lp_.outputs["Transparent Depth"], 0.5,
                                                            out_.location.x - 400, out_.location.y - 400),
                                BEHIND_DIM, out_.location.x - 250, out_.location.y - 400), mx.inputs["Fac"])
        nt_.links.new(src, mx.inputs[1])
        nt_.links.new(blk.outputs["Emission"], mx.inputs[2])
        nt_.links.new(mx.outputs["Shader"], out_.inputs["Surface"])

    if BEHIND_DIM > 0:
        for m_ in (m_knit, m_pod, m_sensor, m_ti, m_cap):
            behind_glass(m_)

try:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
except Exception as e:  # noqa
    log("cycles prefs", e)

# ---------------------------------------------------------------------------
# 14. verify: strap / caps / pod never enter the skin

RAY_DIRS = [Vector(d).normalized() for d in ((0.31, 0.93, 0.19), (-0.72, 0.05, 0.69), (0.12, -0.41, -0.90),
                                              (0.95, -0.22, 0.2), (-0.3, -0.6, 0.74))]


def inside_by_parity(tree, p):
    """Majority vote of ray-crossing parity; robust in concave creases where the nearest face's
    normal points the wrong way."""
    votes = 0
    for d in RAY_DIRS:
        o, hits = p.copy(), 0
        while hits < 64:
            loc, _, _, _ = tree.ray_cast(o, d)
            if loc is None:
                break
            hits += 1
            o = loc + d * 1e-6
        votes += hits % 2
    return votes * 2 > len(RAY_DIRS)


def band_skin_distance(tree, ob, dg_):
    """min signed distance of an object's vertices to the skin (- = inside); nearest-normal test,
    confirmed by ray parity where it says inside (creases between the fingers mislead it)"""
    oe = ob.evaluated_get(dg_)
    mm = oe.to_mesh()
    ow = oe.matrix_world
    best = 1e9
    for v in mm.vertices:
        p = ow @ v.co
        loc, nrm, _, dist = tree.find_nearest(p, 0.02)
        if loc is None:
            continue
        sd = dist if (p - loc).dot(nrm) >= 0 else -dist
        if sd < 0 and not inside_by_parity(tree, p):
            sd = dist
        best = min(best, sd)
    oe.to_mesh_clear()
    return best


def verify(frames):
    """Signed distance of every band vertex to the skin at each frame (subframes allowed).
    Returns (frame, mm, part) per frame. The skin is checked at its render subdivision, the
    surface the camera sees."""
    worst = []
    view_levels = sub.levels
    sub.levels = sub.render_levels
    for f in frames:
        fi = int(math.floor(f))
        scene.frame_set(fi, subframe=float(f - fi))
        dg_ = bpy.context.evaluated_depsgraph_get()
        se = skin.evaluated_get(dg_)
        m = se.to_mesh()
        mw = se.matrix_world
        tree = BVHTree.FromPolygons([mw @ v.co for v in m.vertices], [tuple(p.vertices) for p in m.polygons])
        se.to_mesh_clear()
        per = {ob.name: band_skin_distance(tree, ob, dg_) for ob in (strap, pod, slider, frame_ob, cap)}
        name, fmin = min(per.items(), key=lambda kv: kv[1])
        worst.append((f, fmin * 1000.0, name))
        if fmin < 0 or f == int(f) and (fi - F_BAND_IN) % 6 == 0:
            log(f"frame {f:g}: min band-to-skin distance "
                + (f"{fmin * 1000.0:+.2f} mm ({name})" if fmin < 1e3 else "none within 20 mm")
                + ("  FAIL" if fmin < 0 else ""))
    sub.levels = view_levels
    return worst


def verify_anatomy(frames, stride=3):
    """Anatomy stays inside the skin: signed distance of every stride-th vertex (+ = outside).
    Points the nearest-normal test calls outside are re-checked by ray parity."""
    for f in frames:
        scene.frame_set(f)
        dg_ = bpy.context.evaluated_depsgraph_get()
        se = skin.evaluated_get(dg_)
        m = se.to_mesh()
        tree = BVHTree.FromPolygons([se.matrix_world @ v.co for v in m.vertices], [tuple(p.vertices) for p in m.polygons])
        se.to_mesh_clear()
        worst, worst_name = -1e9, ""
        for ob in anatomy:
            oe = ob.evaluated_get(dg_)
            mm = oe.to_mesh()
            ow = oe.matrix_world
            for i in range(0, len(mm.vertices), stride):
                p = ow @ mm.vertices[i].co
                loc, nrm, _, dist = tree.find_nearest(p, 0.05)
                if loc is not None:
                    sd = dist if (p - loc).dot(nrm) >= 0 else -dist
                    if sd > 0 and inside_by_parity(tree, p):
                        sd = -dist
                    if sd > worst:
                        worst, worst_name = sd, ob.name
            oe.to_mesh_clear()
        log(f"frame {f}: anatomy max outside skin {worst * 1000.0:+.2f} mm ({worst_name})"
            + ("  FAIL" if worst > 0 else ""))


def composition_report(frames):
    from bpy_extras.object_utils import world_to_camera_view
    rig_inv_pts = None
    for f in frames:
        scene.frame_set(f)
        dg_ = bpy.context.evaluated_depsgraph_get()
        tops = []
        hand_x = []
        cut_vis = 0
        for ob in (skin, strap, pod, frame_ob, cap):
            oe = ob.evaluated_get(dg_)
            mm = oe.to_mesh()
            mw = oe.matrix_world
            co = np.empty(len(mm.vertices) * 3)
            mm.vertices.foreach_get("co", co)
            co = co.reshape(-1, 3)[::3]
            oe.to_mesh_clear()
            for v in co:
                p = world_to_camera_view(scene, cam, mw @ Vector(v))
                inside = 0 <= p.x <= 1 and 0 <= p.y <= 1 and p.z > 0
                if inside:
                    tops.append(1 - p.y)
                ry = (rig.matrix_world.inverted() @ (mw @ Vector(v))).y
                if ob is skin and inside and ry < -0.255:
                    cut_vis += 1
                if ob is skin and ry > 0.0:
                    hand_x.append(p.x)
        fc_ = world_to_camera_view(scene, cam, focus.matrix_world.translation)
        log(f"frame {f}: top of subject {min(tops) if tops else 1:.3f}, forearm-cut verts in frame {cut_vis}, clasp at ({fc_.x:.2f}, {1 - fc_.y:.2f}), hand x [{min(hand_x):.3f}, {max(hand_x):.3f}]")


bpy.context.view_layer.update()
if "--composition" in ARGS:
    composition_report([1, 20, 40, 60, 85, 100, 115, 150, 181, 190, 200, 215, 230, 250, F_LAST])
if "--verify" in ARGS:
    composition_report([1, 20, 40, 60, 85, 100, 115, 150, 181, 230, F_LAST])
    if anatomy:
        verify_anatomy([1, 60, 100, F_CLICK, F_CLICK + 6, F_LAST])
    # every frame from bandIn to click + 10, the half frames between them (the motion-blur
    # shutter sees the band between baked frames) and the last frame
    vf = [f for f in np.arange(F_BAND_IN, F_CLICK + 10.01, 0.5)] + [F_LAST]
    res = verify(vf)
    fmin, dmin, pmin = min(res, key=lambda r: r[1])
    fails = [r for r in res if r[1] < 0]
    log(f"verify: {len(res)} frames checked ({F_BAND_IN} to {F_CLICK + 10} in half frames, plus {F_LAST}); "
        f"minimum band-to-skin clearance {dmin:+.2f} mm ({pmin}, frame {fmin:g})"
        + (f"; {len(fails)} FAIL" if fails else "; no penetration"))
    for lbl, sel in (("before the click", [r for r in res if r[0] < F_CLICK]), ("from the click on", [r for r in res if r[0] >= F_CLICK])):
        fm, dm, pm = min(sel, key=lambda r: r[1])
        log(f"verify {lbl}: minimum {dm:+.2f} mm ({pm}, frame {fm:g})")

scene.frame_set(F_LAST)
bpy.context.preferences.filepaths.save_version = 0
bpy.ops.wm.save_as_mainfile(filepath=OUT, compress=True)
log("saved", OUT)
