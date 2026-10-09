"""Synthesise the band intro sounds.

Run:  design/onboarding-band/.venv/bin/python design/onboarding-band/sound/make_sounds.py [--preview]

Writes two 48 kHz stereo 16-bit CAF files into Loopr/Loopr/Resources/Onboarding/:

  band-intro-approach.caf  starts at `bandIn`. A deep rise: a detuned saw an octave up from
                           E1 with the filter opening, a sub and a rumble. It stops 12 ms
                           before `click`, so the click lands in a moment of silence.
  band-intro-click.caf     starts at `click` (sample 0 is the click). A clean latch click,
                           a latch tick 45 ms later and a short small room.

The beats come from band-intro.timings.json. LATCH_DELAY must match
BandIntroChoreography.latchDelay, because Core Haptics plays the latch tick with it. `--preview` also writes a mixed WAV of the whole
film timeline to design/onboarding-band/sound/preview.wav.
"""
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfilt, fftconvolve

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OUT = os.path.join(ROOT, "Loopr", "Loopr", "Resources", "Onboarding")
SR = 48_000
RNG = np.random.default_rng(7)

# Shared with BandIntroChoreography.swift.
LATCH_DELAY = 0.045
PRE_CLICK_GAP = 0.012

timings = json.load(open(os.path.join(OUT, "band-intro.timings.json")))
BAND_IN, WRAP, CLICK = timings["bandIn"], timings["wrapStart"], timings["click"]


def n(sec):
    return int(round(sec * SR))


def t_axis(sec):
    return np.arange(n(sec)) / SR


def db(x):
    return 10 ** (x / 20)


def bp(x, lo, hi, order=2):
    return sosfilt(butter(order, [lo, hi], btype="band", fs=SR, output="sos"), x)


def hp(x, f, order=2):
    return sosfilt(butter(order, f, btype="high", fs=SR, output="sos"), x)


def lp(x, f, order=2):
    return sosfilt(butter(order, f, btype="low", fs=SR, output="sos"), x)


def swept_lowpass(x, f_start, f_end, curve):
    """One-pole low-pass whose cutoff follows f_start..f_end along `curve` (0..1 per sample)."""
    fc = f_start * (f_end / f_start) ** curve
    a = np.exp(-2 * np.pi * fc / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i in range(len(x)):
        acc = (1 - a[i]) * x[i] + a[i] * acc
        y[i] = acc
    return y


def pan(mono, p):
    """Equal-power pan, p in -1 (left) .. 1 (right); p may be an array."""
    ang = (np.asarray(p) + 1) * np.pi / 4
    return np.stack([mono * np.cos(ang), mono * np.sin(ang)], axis=1)


def modal(t, modes):
    """Sum of exponentially damped sines: (freq, tau, amp)."""
    return sum(a * np.sin(2 * np.pi * f * t) * np.exp(-t / tau) for f, tau, a in modes)


def fade(x, fin=0.0, fout=0.0):
    x = x.copy()
    if fin:
        k = n(fin)
        x[:k] *= np.linspace(0, 1, k)[:, None] if x.ndim == 2 else np.linspace(0, 1, k)
    if fout:
        k = n(fout)
        x[-k:] *= np.linspace(1, 0, k)[:, None] if x.ndim == 2 else np.linspace(1, 0, k)
    return x


# ---------------------------------------------------------------------------
# approach: a deep rise from bandIn to just before the click

def glide_phase(freq):
    return 2 * np.pi * np.cumsum(freq) / SR


def rich_tone(phase, harmonics=10):
    """Band-limited saw: every harmonic at 1/k, so the rise is heard on a phone
    speaker through its overtones even where the fundamental is too low."""
    return sum(np.sin(k * phase) / k for k in range(1, harmonics + 1))


def approach():
    total = CLICK - BAND_IN - PRE_CLICK_GAP
    t = t_axis(total)
    u = t / total
    # Slow start while the band flies in, most of the climb over the wrap.
    wrap_u = (WRAP - BAND_IN) / total
    climb = np.where(u < wrap_u, 0.15 * u / wrap_u, 0.15 + 0.85 * ((u - wrap_u) / (1 - wrap_u)) ** 2)

    f0 = 41.2 * 2 ** (1.0 * climb)                 # E1 up one octave to E2
    voices = []
    for detune, ph in ((1.0, 0.0), (1.004, 1.3), (0.996, 2.1)):
        voices.append(rich_tone(glide_phase(f0 * detune) + ph))
    saw = sum(voices) / 3
    sub = np.sin(glide_phase(f0))
    # The filter opens as it climbs: dark rumble to a brassy roar.
    body = swept_lowpass(saw, 140, 2400, climb)
    rumble = swept_lowpass(lp(RNG.standard_normal(len(t)), 900), 90, 700, climb) * 0.8
    mono = 0.9 * body + 0.7 * sub + 0.35 * rumble
    mono = np.tanh(2.2 * mono) / np.tanh(2.2)         # saturation adds audible harmonics
    level = db(-30 + 30 * climb)
    mono = mono * level

    # Width: the detuned voices a few ms apart, centred again at the top.
    left = mono
    right = np.roll(mono, n(0.004))
    out = np.stack([left, right], axis=1)
    return fade(out, fin=0.25, fout=0.008)


# ---------------------------------------------------------------------------
# click: a clean latch click with a short room, no echo

def dry_click():
    t = t_axis(0.12)
    snap = bp(RNG.standard_normal(len(t)), 1500, 9000) * np.exp(-t / 0.0012)
    shell = modal(t, [(1650, 0.018, 0.8), (2150, 0.020, 1.0), (3400, 0.014, 0.7), (5200, 0.009, 0.45), (7600, 0.005, 0.25)])
    body = modal(t, [(420, 0.016, 0.8)])
    click = 1.0 * snap + 0.8 * shell + 0.5 * body
    latch_t = t_axis(0.05)
    latch = bp(RNG.standard_normal(len(latch_t)), 2500, 10000) * np.exp(-latch_t / 0.0008)
    latch += modal(latch_t, [(3900, 0.005, 0.8), (6100, 0.004, 0.5)])
    i = n(LATCH_DELAY)
    click[i : i + len(latch_t)] += 0.4 * latch[: len(click) - i]
    # A little saturation gives the click weight without making it longer.
    return np.tanh(2.0 * click) / np.tanh(2.0)


def click_sound():
    dry = dry_click()
    out = np.zeros((n(0.6), 2))
    out[: len(dry)] += pan(dry, 0.0)
    # Short small room so the click sits in a space instead of in the head.
    ir_t = t_axis(0.45)
    decay = np.exp(-6.9 * ir_t / 0.35)
    ir = np.stack([lp(RNG.standard_normal(len(ir_t)), 6000), lp(RNG.standard_normal(len(ir_t)), 6000)], axis=1)
    ir *= decay[:, None]
    ir[: n(0.008)] = 0
    ir /= np.sqrt((ir ** 2).sum(axis=0))
    src = hp(dry, 300)
    wet = np.stack([fftconvolve(src, ir[:, 0])[: len(out)], fftconvolve(src, ir[:, 1])[: len(out)]], axis=1)
    out[: len(wet)] += wet * db(-20)
    return fade(out, fout=0.1)


def write_caf(path, stereo, peak_db):
    stereo = stereo / np.max(np.abs(stereo)) * db(peak_db)
    pcm = (np.clip(stereo, -1, 1) * 32767).astype(np.int16)
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "x.wav")
        wavfile.write(wav, SR, pcm)
        subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16@48000", wav, path], check=True)
    print(f"{os.path.relpath(path, ROOT)}  {len(stereo) / SR:.3f} s  peak {peak_db} dBFS  {os.path.getsize(path) // 1024} KB")
    return stereo


if __name__ == "__main__":
    a = write_caf(os.path.join(OUT, "band-intro-approach.caf"), approach(), -13.0)
    c = write_caf(os.path.join(OUT, "band-intro-click.caf"), click_sound(), -1.0)
    if "--preview" in sys.argv:
        mix = np.zeros((n(CLICK + 2.4), 2))
        mix[n(BAND_IN) : n(BAND_IN) + len(a)] += a
        mix[n(CLICK) : n(CLICK) + len(c)] += c
        wavfile.write(os.path.join(HERE, "preview.wav"), SR, (np.clip(mix, -1, 1) * 32767).astype(np.int16))
        print("preview.wav written")
