"""Offline look-development renderer for completed videos.

Plays an app arrangement recipe (the same JSON the iOS renderer receives)
against real source clips and writes one MP4 per visual style, so directions
can be compared on Windows without an iOS build. Audio is a simplified
re-implementation of the arrangement (chops, loops, resampled pitch); it is
for judging picture/sound sync, not final sound quality.

    python tool/video_lab/render_styles.py RECIPE.json SRC_DIR OUT_DIR [seed ...]

Each seed plans a different sequence of shots along the song's energy curve.

SRC_DIR holds s0.mp4/s0.wav, s1.mp4/s1.wav, ... and names.txt (one per line).
"""

import json
import math
import re
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps

import imageio_ffmpeg

FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()
SR = 48_000
FPS = 30
SPF = SR // FPS  # samples per frame
W, H = 720, 1280
BEAT = 22_500 / SR
BAR = BEAT * 4

FONT_BOLD = "C:/Windows/Fonts/YuGothB.ttc"
FONT_HAND = "C:/Windows/Fonts/UDDigiKyokashoN-B.ttc"
CORAL = (239, 113, 108)
LAVENDER = (156, 132, 240)
MUSTARD = (242, 169, 59)
INK = (35, 28, 26)
PAPER = (251, 243, 230)
CLIP_COLORS = [CORAL, LAVENDER, MUSTARD, (90, 180, 150)]


def font(path, size):
    return ImageFont.truetype(path, size)


def ease_out(x):
    x = min(1.0, max(0.0, x))
    return 1 - (1 - x) ** 3


def ease_in_out(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


def overshoot(x):
    """0→1 with a springy overshoot; used for pop-ins."""
    if x >= 1:
        return 1.0
    x = max(0.0, x)
    return 1 + math.sin(x * math.pi * 1.6) * math.exp(-x * 4) * 0.35 - (1 - ease_out(x)) * 0.35


# ---------------------------------------------------------------- sources

class Source:
    def __init__(self, video: Path, audio: Path, name: str):
        self.name = name
        probe = subprocess.run([FFMPEG, "-i", str(video)], capture_output=True, text=True).stderr
        size = re.search(r"Video:.*?(\d{2,5})x(\d{2,5})", probe)
        self.w, self.h = int(size.group(1)), int(size.group(2))
        raw = subprocess.run([FFMPEG, "-v", "error", "-i", str(video), "-r", str(FPS),
                              "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
        arr = np.frombuffer(raw, np.uint8).reshape(-1, self.h, self.w, 3)
        self.frames = [Image.fromarray(f) for f in arr]
        with wave.open(str(audio)) as wf:
            pcm = np.frombuffer(wf.readframes(wf.getnframes()), np.int16).astype(np.float32) / 32768
        # phone clips vary a lot in level; even them out before mixing
        self.pcm = pcm * (0.9 / max(1e-4, float(np.abs(pcm).max())))
        self.samples = len(pcm)

    def frame_at_sample(self, sample):
        return self.frames[int(sample // SPF) % len(self.frames)]


def cover(im, w, h, zoom=1.0, focus_y=0.42, mirror=False, dx=0.0):
    """Crop-to-fill with a face-friendly vertical focus."""
    w, h = max(1, int(w)), max(1, int(h))
    iw, ih = im.size
    s = max(w / iw, h / ih) * max(1.0, zoom)
    cw, ch = w / s, h / s
    cx = min(max(iw / 2 + dx * iw, cw / 2), iw - cw / 2)
    cy = min(max(ih * focus_y, ch / 2), ih - ch / 2)
    box = (max(0.0, cx - cw / 2), max(0.0, cy - ch / 2), min(iw, cx + cw / 2), min(ih, cy + ch / 2))
    out = im.resize((w, h), Image.BILINEAR, box=box)
    return ImageOps.mirror(out) if mirror else out


# ---------------------------------------------------------------- recipe

class Event:
    def __init__(self, raw, clip_index, idx):
        self.idx = idx
        self.c = clip_index
        self.start = raw["destinationStartSample"]
        self.dur = raw["durationSamples"]
        self.kind = raw.get("treatment", "rhythm")
        self.role = raw.get("role")  # melody / bass / kick / snare / hat in score arrangements
        self.midi = raw.get("targetMidiNote")
        self.src_start = raw["sourceStartSample"]
        self.src_dur = raw.get("sourceDurationSamples") or raw["durationSamples"]
        self.gain = raw["gain"]
        self.fade_in = raw["fades"]["fadeInSamples"]
        self.fade_out = raw["fades"]["fadeOutSamples"]
        self.t = self.start / SR
        self.end_t = (self.start + self.dur) / SR
        self.env = np.zeros(1)

    def active(self, t):
        return self.t <= t < self.end_t

    def source_sample(self, t, src: Source):
        """Source position for output time t: loops the event's source window."""
        offset = int((t - self.t) * SR)
        window = max(SPF, min(self.src_dur, src.samples))
        start = self.src_start % max(1, src.samples - window + 1)
        return start + offset % window


def render_audio(events, sources, total, source_pitch=None):
    """source_pitch: measured MIDI pitch per clip index. Without it the legacy
    recipes keep a gentle ±semitone range around middle C."""
    mix = np.zeros(total, np.float32)
    for e in events:
        src = sources[e.c]
        window = max(SPF, min(e.src_dur, src.samples))
        start = e.src_start % max(1, src.samples - window + 1)
        chunk = src.pcm[start:start + window]
        if e.kind == "tuned" and e.midi:
            if source_pitch:
                ratio = float(np.clip(2 ** ((e.midi - source_pitch[e.c]) / 12), 0.3, 2.6))
            else:
                ratio = float(np.clip(2 ** ((e.midi - 60) / 12), 0.72, 1.45))
            pos = (np.arange(e.dur) * ratio) % len(chunk)
            buf = np.interp(pos, np.arange(len(chunk)), chunk).astype(np.float32)
        else:
            reps = int(math.ceil(e.dur / len(chunk)))
            buf = np.tile(chunk, reps)[:e.dur].copy()
        n = len(buf)
        fi, fo = min(e.fade_in, n // 2), min(max(e.fade_out, 240), n // 2)
        if fi:
            buf[:fi] *= np.linspace(0, 1, fi)
        if fo:
            buf[-fo:] *= np.linspace(1, 0, fo)
        buf *= e.gain
        end = min(total, e.start + n)
        mix[e.start:end] += buf[:end - e.start]
        blocks = (n + SPF - 1) // SPF
        padded = np.pad(np.abs(buf), (0, blocks * SPF - n))
        e.env = padded.reshape(blocks, SPF).max(axis=1)
    mix = np.tanh(mix * 1.4)
    mix *= 0.89 / max(1e-6, np.abs(mix).max())
    return mix


# ---------------------------------------------------------------- shared overlays

def paper_texture(seed=7):
    rng = np.random.default_rng(seed)
    base = np.ones((H, W, 3), np.float32) * np.array(PAPER, np.float32)
    base += rng.normal(0, 5, (H, W, 1))
    return Image.fromarray(np.clip(base, 0, 255).astype(np.uint8))


def rounded_mask(w, h, r):
    m = Image.new("L", (int(w), int(h)), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, int(w) - 1, int(h) - 1), r, fill=255)
    return m


def paste_center(canvas, im, cx, cy, mask=None):
    canvas.paste(im, (int(cx - im.width / 2), int(cy - im.height / 2)), mask)


def text_center(draw, xy, s, f, fill, stroke=0, stroke_fill=None, anchor="mm"):
    draw.text(xy, s, font=f, fill=fill, anchor=anchor, stroke_width=stroke, stroke_fill=stroke_fill)


class Ctx:
    def __init__(self, events, sources, total, title=None):
        self.events = events
        self.sources = sources
        self.total_t = total / SR
        self.names = [s.name for s in sources]
        self.title = title

    def active(self, t, kinds=None):
        return [e for e in self.events if e.active(t) and (kinds is None or e.kind in kinds)]

    def last_onset(self, t, pred=lambda e: True):
        best = None
        for e in self.events:
            if e.t <= t and pred(e) and (best is None or e.t >= best.t):
                best = e
        return best

    def onsets_between(self, a, b, pred=lambda e: True):
        return [e for e in self.events if a <= e.t < b and pred(e)]

    def frame(self, e, t):
        """Picture for event e at time t. A finished sound holds its last frame."""
        src = self.sources[e.c]
        t = min(max(t, e.t), e.end_t - 1 / FPS)
        return src.frame_at_sample(e.source_sample(t, src))

    def voices(self, t, limit=9):
        """Events sounding at t, oldest first: one picture per voice."""
        live = sorted(self.active(t), key=lambda e: (e.t, e.idx))
        return live[-limit:]

    def level(self, e, t):
        i = int((t - e.t) * FPS)
        return float(e.env[i]) if 0 <= i < len(e.env) else 0.0

    def norm_level(self, e, t):
        peak = float(e.env.max()) if len(e.env) else 0.0
        return self.level(e, t) / peak if peak > 1e-5 else 0.0


def soft_text(layer, xy, s, f, fill, alpha):
    """Type lifted by a soft shadow instead of a hard outline."""
    shadow = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).text((xy[0], xy[1] + 3), s, font=f, fill=(0, 0, 0, int(alpha * 0.55)))
    layer.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(8)))
    ImageDraw.Draw(layer).text(xy, s, font=f, fill=(*fill, alpha))


def draw_op(canvas, ctx, t, style):
    """0–1.6s: the title rests on the first sounding picture."""
    if t >= 1.6:
        return canvas
    a = ease_out(t / 0.2) * (1 - ease_in_out((t - 1.3) / 0.3))
    alpha = int(255 * a)
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    cast = " ・ ".join(ctx.names)
    if style == "paper":
        ld = ImageDraw.Draw(layer)
        ld.rounded_rectangle((36, 64, 580, 236), 18, fill=(*PAPER, int(240 * a)))
        ld.text((64, 88), ctx.title or "なんでもない日の音", font=font(FONT_HAND, 50), fill=(*INK, alpha))
        ld.text((66, 164), cast, font=font(FONT_HAND, 28), fill=(*CORAL, alpha))
    else:
        soft_text(layer, (46, 84), ctx.title or "なんでもない日の音", font(FONT_BOLD, 60), (255, 255, 255), alpha)
        soft_text(layer, (48, 170), cast, font(FONT_BOLD, 26), (255, 255, 255), alpha)
        ImageDraw.Draw(layer).rounded_rectangle((48, 214, 120, 220), 3, fill=(*CORAL, alpha))
    return Image.alpha_composite(canvas.convert("RGBA"), layer).convert("RGB")


def draw_ed(canvas, ctx, t, style):
    """Last 1.3s: every sound freezes into a grid, then the logo lands."""
    start = ctx.total_t - 1.3
    if t < start:
        return canvas
    k = t - start
    n = len(ctx.sources)
    bg = PAPER if style == "paper" else INK
    out = Image.new("RGB", (W, H), bg)
    cols = 2
    cw, ch = (W - 72) / cols, (H * 0.56 - 24) / 2
    for i in range(4):
        src = ctx.sources[i % n]
        appear = ease_out((k - i * 0.08) / 0.2)
        if appear <= 0:
            continue
        x = 24 + (i % cols) * (cw + 24)
        y = 110 + (i // cols) * (ch + 24)
        tile = cover(src.frames[len(src.frames) // 2], cw, ch, mirror=i >= n)
        if style == "paper":
            framed = Image.new("RGB", (int(cw) + 16, int(ch) + 16), (255, 255, 255))
            framed.paste(tile, (8, 8))
            framed = framed.rotate((-3, 2, 3, -2)[i], expand=True, resample=Image.BICUBIC, fillcolor=bg)
            tile = framed
        oy = (1 - appear) * 80
        out.paste(tile, (int(x + cw / 2 - tile.width / 2), int(y + ch / 2 - tile.height / 2 + oy)))
    d = ImageDraw.Draw(out)
    fg = INK if style == "paper" else (255, 255, 255)
    logo_a = ease_out((k - 0.35) / 0.25)
    if logo_a > 0:
        size = int(96 + 30 * (1 - logo_a))
        text_center(d, (W / 2, H * 0.76), "オトグラシ", font(FONT_BOLD, size), fg)
        if ctx.title:
            text_center(d, (W / 2, H * 0.835), ctx.title, font(FONT_HAND, 34), CORAL)
            text_center(d, (W / 2, H * 0.875), "演奏：" + "・".join(ctx.names), font(FONT_HAND, 26), fg)
        else:
            text_center(d, (W / 2, H * 0.84), "・".join(ctx.names) + " でできた15秒",
                        font(FONT_HAND, 30), CORAL)
    # the curtain wipes up over the running footage for the first 0.2s
    wipe = ease_out(k / 0.2)
    if wipe < 1:
        top = int(H * (1 - wipe))
        canvas = canvas.copy()
        canvas.paste(out.crop((0, top, W, H)), (0, top))
        return canvas
    return out


# ---------------------------------------------------------------- style 1: ぞうしょく (grid burst)

def sequencer_ribbon(canvas, ctx, t):
    """Scrolling 3-lane note ribbon: every sound is a pill, the playhead is fixed."""
    d = ImageDraw.Draw(canvas, "RGBA")
    top, lane_h = H - 118, 26
    d.rectangle((0, top - 14, W, H), fill=(15, 12, 12, 170))
    px_per_s = 260
    head = W * 0.32
    for e in ctx.events:
        x0 = head + (e.t - t) * px_per_s
        x1 = head + (e.end_t - t) * px_per_s
        if x1 < 0 or x0 > W:
            continue
        y = top + e.c * (lane_h + 6)
        on = e.active(t)
        col = CLIP_COLORS[e.c]
        alpha = 255 if on else 110
        lvl = ctx.level(e, t) if on else 0
        grow = int(lvl * 10)
        d.rounded_rectangle((x0, y - grow / 2, max(x0 + 8, x1 - 2), y + lane_h + grow / 2), 9,
                            fill=(*col, alpha))
    d.line((head, top - 10, head, H - 10), fill=(255, 255, 255, 230), width=3)
    for i, name in enumerate(ctx.names):
        d.text((12, top + i * (lane_h + 6) + 2), name, font=font(FONT_BOLD, 18), fill=(255, 255, 255, 200))


def lead_of(ctx, t):
    """Newest sounding melodic voice, else newest sounding voice, else the last one heard."""
    live = ctx.voices(t)
    melodic = [e for e in live if e.role == "melody"] or [
        e for e in live if e.kind != "rhythm" and e.role is None]
    if melodic or live:
        return (melodic or live)[-1]
    return ctx.last_onset(t) or ctx.events[0]


def punch(age, amount=0.14, length=0.12):
    return 1 + amount * max(0.0, 1 - age / length)


def dim(im, soft=False):
    """Silent pictures lose colour; a lone full-screen picture only fades a little."""
    grey = ImageOps.grayscale(im).convert("RGB")
    amount, light = (0.35, 0.75) if soft else (0.7, 0.45)
    return ImageEnhance.Brightness(Image.blend(im, grey, amount)).enhance(light)


def panel(ctx, e, t, w, h, mirror=False, zoom=1.0, dx=0.0, soft=False):
    """One voice's picture: moving and pulsing while it sounds, frozen and dim after."""
    live = e.active(t)
    lvl = ctx.norm_level(e, t) if live else 0.0
    im = cover(ctx.frame(e, t), w, h, zoom=zoom * (1 + 0.04 * lvl), mirror=mirror, dx=dx)
    if not live:
        return dim(im, soft)
    return ImageEnhance.Brightness(im).enhance(1 + 0.18 * lvl)


def voice_label(canvas, ctx, e, t, rect, count=1):
    """Small caption in the panel corner: colour dot, name, live level bars."""
    x, y, w, h = rect
    if not e.active(t) or w < 150 or h < 120:
        return
    k = min(1.0, max(0.6, w / 520))
    d = ImageDraw.Draw(canvas, "RGBA")
    f = font(FONT_BOLD, int(26 * k))
    name = ctx.names[e.c] + (f"  ×{count}" if count > 1 else "")
    tw = d.textlength(name, font=f)
    ph = 46 * k
    pw = tw + 96 * k
    x0, y0 = x + 16 * k, y + h - ph - 16 * k
    d.rounded_rectangle((x0, y0, x0 + pw, y0 + ph), ph / 2, fill=(20, 16, 16, 150))
    col = CLIP_COLORS[e.c]
    cy = y0 + ph / 2
    d.ellipse((x0 + 14 * k, cy - 7 * k, x0 + 28 * k, cy + 7 * k), fill=col)
    d.text((x0 + 38 * k, cy), name, font=f, fill=(255, 255, 255), anchor="lm")
    lvl = ctx.norm_level(e, t)
    for b in range(4):
        bh = (6 + 18 * min(1.0, lvl * (1.3 - b * 0.2))) * k
        bx = x0 + 44 * k + tw + b * 9 * k
        d.rounded_rectangle((bx, cy - bh / 2, bx + 5 * k, cy + bh / 2), 2, fill=col)


def pulse_border(canvas, ctx, e, t, rect):
    """Colour edge that swells with this voice's own loudness."""
    if not e.active(t):
        return
    x, y, w, h = rect
    width = int(2 + 7 * ctx.norm_level(e, t))
    ImageDraw.Draw(canvas).rectangle(
        (x + width // 2, y + width // 2, x + w - width // 2 - 1, y + h - width // 2 - 1),
        outline=CLIP_COLORS[e.c], width=width)


def single(ctx, t, e, **kw):
    canvas = panel(ctx, e, t, W, H, soft=True, **kw)
    voice_label(canvas, ctx, e, t, (0, 0, W, H), sum(v.c == e.c for v in ctx.voices(t)))
    return canvas


def shot_full(ctx, t, seg):
    lead = lead_of(ctx, t)
    pitch = max(-3, min(6, (lead.midi or 60) - 60))
    return single(ctx, t, lead, zoom=(1 + 0.04 * pitch / 6) * punch(t - lead.t))


def shot_flip(ctx, t, seg):
    """Every melodic note cuts to a mirrored / shifted crop of the same face."""
    lead = lead_of(ctx, t)
    notes = len(ctx.onsets_between(seg[0], t + 1e-6, lambda e: e.kind != "rhythm"))
    return single(ctx, t, lead, zoom=1.08 * punch(t - lead.t, 0.1),
                  mirror=notes % 2 == 1, dx=0.04 * (notes % 3 - 1))


def shot_stutter(ctx, t, seg):
    """Each new sound re-cuts to a tighter crop of the lead face."""
    lead = lead_of(ctx, t)
    step = len(ctx.onsets_between(seg[0], t + 1e-6))
    return single(ctx, t, lead, zoom=(1 + 0.12 * (step % 4)) * punch(t - lead.t, 0.08))


def voice_layout(n):
    if n <= 1:
        return [(0, 0, W, H)]
    rows = n if n <= 3 else math.ceil(n / 2) if n <= 6 else 3
    per_row = [n // rows + (1 if r < n % rows else 0) for r in range(rows)]
    return [(c * W / k, r * H / rows, W / k, H / rows) for r, k in enumerate(per_row) for c in range(k)]


def shot_voices(ctx, t, seg):
    """One picture per sounding voice. Repeats of the same sound alternate mirror."""
    live = ctx.voices(t)
    if not live:
        return single(ctx, t, lead_of(ctx, t))
    rects = voice_layout(len(live))
    canvas = Image.new("RGB", (W, H))
    seen = {}
    for e, (x, y, w, h) in zip(live, rects):
        seen[e.c] = seen.get(e.c, 0) + 1
        im = panel(ctx, e, t, w, h, mirror=seen[e.c] % 2 == 0, zoom=punch(t - e.t, 0.1, 0.1))
        canvas.paste(im, (int(x), int(y)))
    d = ImageDraw.Draw(canvas)
    for x, y, w, h in rects:
        d.rectangle((x, y, x + w, y + h), outline=(0, 0, 0), width=3)
    for e, rect in zip(live, rects):
        pulse_border(canvas, ctx, e, t, rect)
        voice_label(canvas, ctx, e, t, rect)
    return canvas


def shot_burst(ctx, t, seg):
    return shot_voices(ctx, t, seg)


FLIPS = [(False, False), (True, False), (False, True), (True, True)]


def repeat_index(ctx, e):
    """How many times this exact chop has already played back to back."""
    n, prev = 0, e
    while True:
        before = ctx.last_onset(prev.t - 1e-4, lambda x: x.c == e.c)
        if not before or before.src_start != e.src_start or prev.t - before.t > BEAT * 2:
            return n
        n, prev = n + 1, before


def flipped(im, k):
    h, v = FLIPS[k % 4]
    im = ImageOps.mirror(im) if h else im
    return ImageOps.flip(im) if v else im


def shot_mirror(ctx, t, seg):
    """Loops read as reflections: each repeat of the same chop flips the picture,
    and stacked voices of one sound become a symmetric pair or a four-way mirror."""
    lead = lead_of(ctx, t)
    same = [e for e in ctx.voices(t) if e.c == lead.c]
    k = repeat_index(ctx, lead)
    zoom = 1.06 * punch(t - lead.t, 0.1)
    if len(same) >= 3:
        q = panel(ctx, lead, t, W / 2, H / 2, zoom=zoom)
        canvas = Image.new("RGB", (W, H))
        for i, (x, y) in enumerate([(0, 0), (W // 2, 0), (0, H // 2), (W // 2, H // 2)]):
            canvas.paste(flipped(q, i), (x, y))
    elif len(same) == 2:
        half = panel(ctx, lead, t, W / 2, H, zoom=zoom)
        canvas = Image.new("RGB", (W, H))
        canvas.paste(flipped(half, k), (0, 0))
        canvas.paste(flipped(half, k + 1), (W // 2, 0))
    else:
        canvas = flipped(panel(ctx, lead, t, W, H, zoom=zoom, soft=True), k)
    voice_label(canvas, ctx, lead, t, (0, 0, W, H), len(same))
    return canvas


# ---------------------------------------------------------------- style 2: パン (camera over a board)

BOARD_W, BOARD_H = 2.2, 1.35  # board size in screens
BOARD_SLOTS = [  # (x, y, w, h, rotation) in screen units on the board
    (0.06, 0.05, 0.92, 0.56, -2),
    (1.10, 0.04, 0.96, 0.50, 3),
    (0.08, 0.68, 0.86, 0.60, 2),
    (1.02, 0.62, 0.62, 0.36, -3),
    (1.52, 0.60, 0.62, 0.40, 4),
    (1.12, 1.02, 0.94, 0.30, -1),
]


def shot_pan(ctx, t, seg):
    board_w, board_h = BOARD_W * W, BOARD_H * H
    board = Image.new("RGB", (int(board_w), int(board_h)), PAPER)
    seen = []
    for e in ctx.events:
        if e.t <= t and e.c not in seen:
            seen.append(e.c)
    slots = [(c, BOARD_SLOTS[i], False) for i, c in enumerate(seen or [0])]
    lead = ctx.last_onset(t, lambda e: e.kind != "rhythm") or ctx.last_onset(t)
    rects = []
    for i, (c, (x, y, w, h, rot), mirrored) in enumerate(slots):
        live = [e for e in ctx.active(t) if e.c == c]
        e = live[-1] if live else (ctx.last_onset(t, lambda ev, c=c: ev.c == c) or lead)
        pw, ph = w * W, h * H
        pop = punch(t - e.t, 0.05, 0.15) if live else 1
        tile = panel(ctx, e, t, pw * pop, ph * pop, mirror=mirrored)
        framed = Image.new("RGB", (tile.width + 20, tile.height + 20), (255, 255, 255))
        framed.paste(tile, (10, 10))
        framed = framed.rotate(rot, expand=True, resample=Image.BICUBIC, fillcolor=PAPER)
        cx, cy = x * W + pw / 2, y * H + ph / 2
        paste_center(board, framed, cx, cy)
        rects.append((cx, cy, pw, ph, c, mirrored))
    # camera: whip to the slot of the newest melodic/phrase sound, pull back on section changes
    target_slot = next((r for r in rects if r[4] == lead.c and not r[5]), rects[0])
    # pull back to every placed photo at the start of the shot, then dive in
    reveal = (t - seg[0]) < BEAT * 1.5
    left = min(r[0] - r[2] / 2 for r in rects) - 40
    right = max(r[0] + r[2] / 2 for r in rects) + 40
    top = min(r[1] - r[3] / 2 for r in rects) - 40
    bottom = max(r[1] + r[3] / 2 for r in rects) + 40
    prev = ctx.last_onset(lead.t - 1e-4, lambda e: e.kind != "rhythm" and e.role in (None, "melody"))
    prev_slot = next((r for r in rects if prev and r[4] == prev.c and not r[5]), target_slot)
    k = ease_in_out((t - lead.t) / 0.22)
    cx = prev_slot[0] + (target_slot[0] - prev_slot[0]) * k
    cy = prev_slot[1] + (target_slot[1] - prev_slot[1]) * k
    zoom = min(W / (target_slot[2] + 60), H / (target_slot[3] + 60)) * 0.98
    if reveal:
        r = 1 - ease_in_out((t - seg[0] - BEAT) / (BEAT * 0.5))
        zoom = zoom + (min(W / (right - left), H / (bottom - top)) - zoom) * r
        cx = cx + ((left + right) / 2 - cx) * r
        cy = cy + ((top + bottom) / 2 - cy) * r
    rhythm = ctx.last_onset(t, lambda e: e.kind == "rhythm")
    if rhythm and t - rhythm.t < 0.1:
        zoom *= 1 + 0.03 * (1 - (t - rhythm.t) / 0.1)
    vw, vh = W / zoom, H / zoom
    cx = min(max(cx, vw / 2), board_w - vw / 2)
    cy = min(max(cy, vh / 2), board_h - vh / 2)
    box = tuple(int(v) for v in (cx - vw / 2, cy - vh / 2, cx + vw / 2, cy + vh / 2))
    view = board.crop(box).resize((W, H), Image.BILINEAR)
    moving = 0 < (t - lead.t) < 0.22 and prev_slot is not target_slot
    if moving:
        view = view.filter(ImageFilter.BoxBlur(6 * math.sin(math.pi * (t - lead.t) / 0.22)))
    count = sum(v.c == lead.c for v in ctx.voices(t))
    voice_label(view, ctx, lead, t, (0, 0, W, H - 40), count)
    return view


# ---------------------------------------------------------------- style 3: ステッカー (pile-up collage)

def scribble_wave(canvas, e, t, cx, cy, width, color):
    """Marker-style squiggle drawn from the event's own loudness, drawing itself on."""
    d = ImageDraw.Draw(canvas)
    n = max(2, min(len(e.env), int((t - e.t) * FPS) + 1))
    pts = []
    for i in range(n):
        x = cx - width / 2 + width * i / max(1, len(e.env) - 1) if len(e.env) > 1 else cx
        amp = min(1.0, e.env[i] / max(1e-4, float(e.env.max()))) * 54
        y = cy + (amp if i % 2 else -amp) * (0.6 + 0.4 * math.sin(i * 1.7))
        pts.append((x, y))
    if len(pts) > 1:
        d.line(pts, fill=(255, 255, 255), width=22, joint="curve")
        d.line(pts, fill=color, width=12, joint="curve")


PAPER_BG = None


def shot_pile(ctx, t, seg):
    global PAPER_BG
    PAPER_BG = PAPER_BG or paper_texture()
    canvas = PAPER_BG.copy()
    section_t = seg[0]
    section = int(section_t / BAR)
    spawned = ctx.onsets_between(section_t, t + 1e-6)
    carry = ctx.last_onset(section_t - 1e-6, lambda e: e.kind != "rhythm")
    if carry and (not spawned or spawned[0].t > section_t + 0.05):
        spawned = [carry] + spawned
    # keep the last 10 stickers; phrases and tuned notes get bigger cards
    cards = spawned[-10:]
    rng = np.random.default_rng(section * 101 + 3)
    layout = [(rng.uniform(0.18, 0.82), rng.uniform(0.2, 0.8), rng.uniform(-9, 9)) for _ in range(len(spawned) + 1)]
    clear = t > seg[1] - 0.12
    for rank, e in enumerate(cards):
        idx = spawned.index(e)
        fx, fy, rot = layout[idx]
        big = {"phrase": 0.86, "tuned": 0.62, "rhythm": 0.42}[e.kind]
        depth = len(cards) - 1 - rank
        scale = big * (1 - 0.04 * depth)
        age = max(0.0, t - max(e.t, section_t)) if e is spawned[0] else t - e.t
        s = overshoot(age / 0.25) * scale
        w, h = W * s, W * s * 1.25
        live = e.active(t)
        mirror = idx % 3 == 2
        tile = cover(ctx.frame(e, t) if live else ctx.frame(e, e.end_t - 1 / FPS), w, h, mirror=mirror)
        if not live:
            tile = dim(tile)
        border = max(6, int(w * 0.035))
        framed = Image.new("RGB", (tile.width + border * 2, tile.height + border * 2), (255, 255, 255))
        framed.paste(tile, (border, border))
        shadow = Image.new("RGBA", framed.size, (60, 30, 10, 70))
        rot_now = rot + (1 - ease_out(age / 0.2)) * 10
        framed = framed.convert("RGBA").rotate(rot_now, expand=True, resample=Image.BICUBIC)
        shadow = shadow.rotate(rot_now, expand=True).filter(ImageFilter.GaussianBlur(10))
        cx = fx * W
        cy = fy * H
        if clear:
            cx += (t - (seg[1] - 0.12)) / 0.12 * W * (1 if idx % 2 else -1)
        canvas.paste(shadow, (int(cx - shadow.width / 2 + 6), int(cy - shadow.height / 2 + 12)), shadow)
        canvas.paste(framed, (int(cx - framed.width / 2), int(cy - framed.height / 2)), framed)
        if rank == len(cards) - 1 and e.kind != "rhythm":
            d = ImageDraw.Draw(canvas)
            label_y = cy + framed.height / 2 + 36
            label_y = min(label_y, H - 150)
            text_center(d, (cx, label_y), ctx.names[e.c], font(FONT_HAND, 50), INK)
            if live:
                scribble_wave(canvas, e, t, cx, label_y + 70, min(W * 0.8, framed.width * 1.1), CLIP_COLORS[e.c])
    return canvas


# ---------------------------------------------------------------- director

SHOTS = {"full": shot_full, "flip": shot_flip, "stutter": shot_stutter, "mirror": shot_mirror,
         "burst": shot_burst, "pan": shot_pan, "pile": shot_pile}
BLEED = {"full", "flip", "stutter", "mirror", "burst"}
LONG = {"pan", "pile"}  # need two bars to build up
POOLS = {
    "calm": ["full", "flip", "pan"],
    "mid": ["mirror", "stutter", "pile", "pan", "flip"],
    "high": ["burst", "mirror", "stutter", "burst"],
}


def plan_shots(total_t, seed):
    """Pick one shot per bar along an energy curve; the seed makes every video different."""
    rng = np.random.default_rng(seed)
    bars = int(round(total_t / BAR))
    plan, bar, last, used = [], 0, None, set()
    while bar < bars:
        p = bar / bars
        energy = "calm" if p < 0.25 else "mid" if p < 0.6 else "high"
        if bar == bars - 1:
            energy = "high"
        choices = [c for c in POOLS[energy] if c != last and not (c in LONG and bar + 2 > bars - 1)]
        if bar == 0:  # the opening introduces a face, not a board
            choices = [c for c in choices if c in BLEED]
        fresh = [c for c in choices if c not in used]
        choices = fresh or choices
        shot = choices[rng.integers(len(choices))]
        used.add(shot)
        span = 2 if shot in LONG else 1
        plan.append((shot, bar * BAR, (bar + span) * BAR, energy))
        bar, last = bar + span, shot
    if not any(s == "burst" for s, *_ in plan):
        s0, a0, b0, e0 = plan[-1]
        plan[-1] = ("burst", a0, b0, e0)
    return plan


def director_frame(ctx, t, plan, hud):
    shot, start, end, energy = next((p for p in plan if p[1] <= t < p[2]), plan[-1])
    canvas = SHOTS[shot](ctx, t, (start, end))
    if shot in BLEED and hud:
        sequencer_ribbon(canvas, ctx, t)
    if energy != "calm" and t - start < 0.06 and start > 0:
        canvas = Image.blend(canvas, Image.new("RGB", (W, H), (255, 255, 255)), 0.6 * (1 - (t - start) / 0.06))
    return canvas


def main():
    recipe_path, src_dir, out_dir = map(Path, sys.argv[1:4])
    seeds = [int(v) for v in sys.argv[4:]] or [1, 2, 3]
    out_dir.mkdir(parents=True, exist_ok=True)
    recipe = json.loads(recipe_path.read_text(encoding="utf-8"))
    arrangement = recipe["arrangement"]
    names = (src_dir / "names.txt").read_text(encoding="utf-8").split()
    order = arrangement["sourceAssetIds"]
    sources = [Source(src_dir / f"s{i}.mp4", src_dir / f"s{i}.wav", names[i]) for i in range(len(order))]
    events = [Event(raw, order.index(raw["assetId"]), i) for i, raw in enumerate(arrangement["events"])]
    total = arrangement["totalSamples"]
    pitch = arrangement.get("sourcePitch")
    audio = render_audio(events, sources, total, [pitch[i] for i in order] if pitch else None)
    wav_path = out_dir / "mix.wav"
    with wave.open(str(wav_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes((audio * 32767).astype(np.int16).tobytes())
    ctx = Ctx(events, sources, total, arrangement.get("title"))
    frames = total // SPF
    for seed in seeds:
        plan = plan_shots(total / SR, seed)
        hud = False
        look = "bold" if seed % 3 else "paper"
        print(f"seed {seed}: look={look} hud={hud} " + " > ".join(p[0] for p in plan))
        out = out_dir / f"seed{seed}.mp4"
        proc = subprocess.Popen([FFMPEG, "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                                 "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-i", str(wav_path),
                                 "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-preset", "fast",
                                 "-c:a", "aac", "-b:a", "160k", "-shortest", str(out)], stdin=subprocess.PIPE)
        for f in range(frames):
            t = f / FPS
            img = director_frame(ctx, t, plan, hud)
            img = draw_op(img, ctx, t, look)
            img = draw_ed(img, ctx, t, look)
            proc.stdin.write(img.convert("RGB").tobytes())
        proc.stdin.close()
        proc.wait()
        print("wrote", out)


if __name__ == "__main__":
    main()
