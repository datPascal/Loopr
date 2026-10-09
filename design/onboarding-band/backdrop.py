"""Studio backdrop for the band film, shared by build_scene.py (the ghost skin's see-through
backdrop) and composite.py (the plate the frames are composited on). Needs numpy only.

The backdrop is one cool hue on the contract background: display colour = BG + g * (PEAK - BG),
with a scalar light map g(x, y) in [0, 1]. g is exactly 0 on the frame border, so the film's
edges are the contract background. The pool fades up with the lights (`fade`).

Looks (env LOOPR_BG):
  pool  a soft pool of cool light behind the wrist, falling off to the background at the edges
  haze  pool plus a faint drifting haze and a light shaft from the upper right
  cyc   a seamless cyclorama: a darker wall, a lit floor below a soft horizon and a contact glow
        on the floor under the wrist
"""

import math

import numpy as np

W, H = 1080, 2340
BG_HEX = "#0A0D11"
LOOKS = ("pool", "haze", "cyc")
DEFAULT_LOOK = "pool"
PEAK_HEX = {"pool": "#26323F", "haze": "#26323F", "cyc": "#24303C"}
FADE_FRAMES = (1, 22)          # the pool comes up with the lights (build_scene: frame 1 to fr(LIGHT_UP = 0.35))


def hex_display(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float64) / 255.0


def _smooth(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3.0 - 2.0 * x)


def _blob(X, Y, cx, cy, rl, rr, ru, rd, p):
    """(1 - r^2)^p with separate radii left/right/up/down (fractions of the frame height)"""
    dx = X - cx
    dy = Y - cy
    rx = np.where(dx < 0, rl, rr)
    ry = np.where(dy < 0, ru, rd)
    r2 = (dx / rx) ** 2 + (dy / ry) ** 2
    return np.clip(1.0 - r2, 0.0, 1.0) ** p


def _noise(X, Y, seed, scale):
    """cheap smooth value noise: a sum of a few random low-frequency cosines"""
    rng = np.random.default_rng(seed)
    out = np.zeros_like(X)
    for _ in range(7):
        a = rng.uniform(0, 2 * math.pi)
        k = rng.uniform(0.6, 1.4) / scale
        ph = rng.uniform(0, 2 * math.pi)
        out += np.cos((X * math.cos(a) + Y * math.sin(a)) * k * 2 * math.pi + ph)
    return out / math.sqrt(7 * 0.5)


def light_map(look=DEFAULT_LOOK, w=W, h=H):
    """g(x, y) in [0, 1], row 0 at the top. Coordinates are in frame heights, so the shapes
    don't depend on the resolution."""
    if look not in LOOKS:
        raise ValueError(f"backdrop look must be one of {LOOKS}, not {look!r}")
    ys = (np.arange(h) + 0.5) / h
    xs = (np.arange(w) + 0.5) / h                 # x in frame heights too
    X, Y = np.meshgrid(xs, ys)
    aw = w / h                                    # frame width in heights
    cx, cy = 0.52 * aw, 0.655                     # behind the wrist, toward the hand
    if look in ("pool", "haze"):
        g = _blob(X, Y, cx, cy, 0.60 * aw, 0.50 * aw, 0.22, 0.345, 2.0)
        if look == "haze":
            g = g * (1.0 + 0.22 * _noise(X, Y, 7, 0.22))
            # a shaft from the upper right, aimed at the wrist
            sx, sy = 1.05 * aw, -0.05
            dx, dy = cx - sx, cy - sy
            n = math.hypot(dx, dy)
            ux, uy = dx / n, dy / n
            along = (X - sx) * ux + (Y - sy) * uy
            perp = np.abs((X - sx) * -uy + (Y - sy) * ux)
            width = 0.035 + 0.10 * np.clip(along / n, 0, 1.2)
            shaft = np.exp(-(perp / width) ** 2) * _smooth(along / (0.35 * n)) * np.clip(1.15 - along / n, 0, 1)
            g = g + 0.38 * shaft * (1.0 + 0.25 * _noise(X, Y, 11, 0.08))
    else:
        yh = 0.745                                # horizon, below the wrist
        wall = _blob(X, Y, cx, cy - 0.03, 0.60 * aw, 0.50 * aw, 0.20, 0.30, 2.0) * 0.85
        horiz = _smooth((Y - (yh - 0.012)) / 0.024)                 # 0 on the wall, 1 on the floor
        floor_fall = np.clip(1.0 - ((Y - yh) / (1.0 - yh)) ** 1.0, 0, 1) ** 1.6
        floor_w = np.clip(1.0 - ((X - cx) / np.where(X < cx, 0.60 * aw, 0.50 * aw)) ** 2, 0, 1) ** 1.8
        floor = 0.75 * floor_fall * floor_w
        glow = _blob(X, Y, cx + 0.06 * aw, yh + 0.03, 0.30 * aw, 0.30 * aw, 0.022, 0.05, 2.0)
        g = wall * (1.0 - horiz) + (floor + 0.30 * wall) * horiz + 0.6 * glow
    # exactly 0 on the frame border
    ex = _smooth(np.minimum(X, aw - X) / (0.045 * aw))
    ey = _smooth(np.minimum(Y, 1.0 - Y) / 0.02)
    return np.clip(g * ex * ey, 0.0, 1.0)


def display_from_g(look, g):
    """display-referred sRGB colour (0..1 floats) for a light map value"""
    bg, pk = hex_display(BG_HEX), hex_display(PEAK_HEX[look])
    return bg + np.asarray(g)[..., None] * (pk - bg)


def fade(frame):
    """0 at the first frame, 1 once the lights are up (sine ease in-out, like the light keys)"""
    f0, f1 = FADE_FRAMES
    t = min(1.0, max(0.0, (frame - f0) / (f1 - f0)))
    return 0.5 - 0.5 * math.cos(math.pi * t)
