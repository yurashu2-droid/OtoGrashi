"""MAD sound-editing effects for the video lab, each with its picture twin.

Per-event effects change *where in the clip* the sound reads, and the video
reads the same positions, so a scratch makes the face jerk back and forth, a
reverse plays the picture backwards and a riser speeds it up:

  rate     constant speed (sampler pitch)       picture at the same speed
  glide    speed ramps by N semitones (riser)   picture accelerates
  reverse  read backwards (reverse swell)       picture runs backwards
  scratch  back-and-forth over a depth          face rocks back and forth
  gate     chop a held sound into 16ths         the panel blinks with it

Master effects act on the whole mix at a moment in the song:

  tapestop  the song slows to a halt            picture slows to a freeze and darkens
  sweep     low-pass opening from muffled       picture goes from blurred to sharp
"""

import math

import numpy as np

SR = 48_000
BEAT = 22_500


def has_motion_fx(e):
    return bool(e.rate or e.glide or e.reverse or e.scratch)


def positions(e, n):
    """Source sample position for each of the event's first n output samples."""
    t = np.arange(n, dtype=np.float64)
    rate = e.rate or 1.0
    if e.glide:
        speed = rate * 2 ** (e.glide * t / max(1, e.dur) / 12)
        p = np.concatenate([[0.0], np.cumsum(speed)[:-1]])
    else:
        p = t * rate
    if e.reverse:
        span = (e.dur - 1) * rate
        p = span - p
    if e.scratch:
        period = e.scratch_period or BEAT // 2
        phase = (t % period) / period
        # a hand on the record: quick push forward, slower pull back
        wave = np.where(phase < 0.35, phase / 0.35, 1 - (phase - 0.35) / 0.65)
        p = wave * e.scratch * SR + (t // period) * period * 0.15
    return e.src_start + p


def gate_envelope(n, steps_per_beat, duty=0.55, ramp=96):
    """Square chop (trance gate) with short ramps so it clicks less."""
    step = BEAT / steps_per_beat
    t = np.arange(n)
    phase = (t % step) / step
    env = np.where(phase < duty, 1.0, 0.04)
    k = np.ones(ramp) / ramp
    return np.convolve(env, k, "same").astype(np.float32)


def apply_master(mix, fx_list):
    out = mix.copy()
    for fx in fx_list or []:
        a, n = int(fx["start"]), int(fx["dur"])
        b = min(len(out), a + n)
        if fx["type"] == "tapestop":
            u = np.arange(b - a) / max(1, n)
            src = a + n * (u - u ** 2 / 2)  # speed falls linearly from 1 to 0
            seg = np.interp(src, np.arange(len(mix)), mix)
            out[a:b] = seg * (1 - u ** 3)
        elif fx["type"] == "sweep":
            # one-pole low-pass whose cutoff opens exponentially 250 Hz -> 16 kHz
            u = np.arange(b - a) / max(1, n)
            cutoff = 250 * (16_000 / 250) ** u
            alpha = 1 - np.exp(-2 * math.pi * cutoff / SR)
            y = 0.0
            seg = out[a:b].copy()
            for i in range(len(seg)):
                y += alpha[i] * (seg[i] - y)
                seg[i] = y
            out[a:b] = seg
    return out


def video_time(t, fx_list):
    """Picture clock under master effects: a tape stop slows the picture too."""
    for fx in fx_list or []:
        if fx["type"] != "tapestop":
            continue
        a, d = fx["start"] / SR, fx["dur"] / SR
        if a <= t < a + d:
            u = (t - a) / d
            return a + d * (u - u * u / 2)
    return t


def video_post(img, t, fx_list):
    from PIL import ImageEnhance, ImageFilter
    for fx in fx_list or []:
        a, d = fx["start"] / SR, fx["dur"] / SR
        if not a <= t < a + d:
            continue
        u = (t - a) / d
        if fx["type"] == "tapestop":
            img = ImageEnhance.Brightness(img).enhance(1 - 0.7 * u ** 2)
        elif fx["type"] == "sweep":
            img = img.filter(ImageFilter.GaussianBlur(16 * (1 - u) ** 1.5))
    return img
