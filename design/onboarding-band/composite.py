"""Composite rendered RGBA frames onto the studio backdrop (backdrop.py).

Run with Blender's Python (it has numpy and OpenImageIO):
  blender -b --factory-startup --python composite.py -- [--bits 16|8] OUT_DIR IN.png[:FRAME] ...

Each input is a straight-alpha 16-bit RGBA PNG from build_scene.py's scene; FRAME (default: the
number at the end of the file name) sets the backdrop's fade. Writes OUT_DIR/<same name>.png as
RGB, 16 bit (for the encoder) or 8 bit (posters, review stills). Env LOOPR_BG picks the look.

Colour is floored at the contract background, as before the backdrop had light in it.
Where the backdrop has light in it, a fine triangular grain of about three 10-bit codes (under
one 8-bit code) keeps the gradient from banding, in the 10-bit film and on 8-bit displays, and
in the 8-bit poster. The border, where the backdrop is exactly the contract background, gets no grain.
"""

import os
import re
import sys

import numpy as np
import OpenImageIO as oiio

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import backdrop  # noqa: E402

args = sys.argv[sys.argv.index("--") + 1:]
bits = 16
if args[:1] == ["--bits"]:
    bits = int(args[1])
    args = args[2:]
out_dir, inputs = args[0], args[1:]
os.makedirs(out_dir, exist_ok=True)
look = os.environ.get("LOOPR_BG", backdrop.DEFAULT_LOOK)
GRAIN = float(os.environ.get("LOOPR_GRAIN", "3.0"))      # triangular grain amplitude, 10-bit codes
g_cache = {}
bg = backdrop.hex_display(backdrop.BG_HEX)


def read_rgba(path):
    cfg = oiio.ImageSpec()
    cfg.attribute("oiio:UnassociatedAlpha", 1)
    inp = oiio.ImageInput.open(path, cfg)
    px = inp.read_image(format="float")
    inp.close()
    if px.shape[2] == 3:
        px = np.dstack([px, np.ones(px.shape[:2], np.float32)])
    return px


for item in inputs:
    path, _, fr = item.partition(":")
    frame = int(fr) if fr else int(re.findall(r"(\d+)\.png$", path)[0])
    px = read_rgba(path)
    h, w = px.shape[:2]
    if (w, h) not in g_cache:
        g_cache[(w, h)] = backdrop.light_map(look, w, h)
    gk = g_cache[(w, h)] * backdrop.fade(frame)
    plate = backdrop.display_from_g(look, gk)
    a = px[:, :, 3:4]
    out = plate * (1.0 - a) + a * np.maximum(px[:, :, :3], bg)
    lsb = 1.0 / 1023.0                            # grain in 10-bit codes for both outputs
    rng = np.random.default_rng(1000 + frame)
    mask = np.clip(gk / 0.02, 0.0, 1.0)[..., None]
    grain = (rng.random((h, w, 1)) - rng.random((h, w, 1))) * lsb * GRAIN
    out = np.clip(out + grain * mask, 0.0, 1.0)
    fmt = oiio.UINT16 if bits == 16 else oiio.UINT8
    dst = os.path.join(out_dir, os.path.basename(path))
    o = oiio.ImageOutput.create(dst)
    o.open(dst, oiio.ImageSpec(w, h, 3, fmt))
    o.write_image(out.astype(np.float32))
    o.close()
    print("composited", dst, flush=True)
