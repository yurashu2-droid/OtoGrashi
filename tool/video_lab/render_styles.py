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
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps

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
        self.pcm = pcm
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


def render_audio(events, sources, total):
    mix = np.zeros(total, np.float32)
    for e in events:
        src = sources[e.c]
        window = max(SPF, min(e.src_dur, src.samples))
        start = e.src_start % max(1, src.samples - window + 1)
        chunk = src.pcm[start:start + window]
        if e.kind == "tuned" and e.midi:
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
    def __init__(self, events, sources, total):
        self.events = events
        self.sources = sources
        self.total_t = total / SR
        self.names = [s.name for s in sources]

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
        src = self.sources[e.c]
        return src.frame_at_sample(e.source_sample(t, src))

    def level(self, e, t):
        i = int((t - e.t) * FPS)
        return float(e.env[i]) if 0 <= i < len(e.env) else 0.0


def draw_op(canvas, ctx, t, style):
    """0–1.4s: three flash cuts introduce the sounds, then the title holds."""
    if t >= 1.4:
        return canvas
    d = ImageDraw.Draw(canvas)
    if t < 0.45:
        i = int(t / 0.15) % len(ctx.sources)
        src = ctx.sources[i]
        canvas.paste(cover(src.frames[min(len(src.frames) - 1, 6)], W, H))
        d = ImageDraw.Draw(canvas)
        text_center(d, (W / 2, H * 0.80), ctx.names[i], font(FONT_BOLD, 92), (255, 255, 255), 10, INK)
        text_center(d, (W / 2, H * 0.72), f"SOUND {i + 1}/{len(ctx.sources)}", font(FONT_BOLD, 30),
                    CLIP_COLORS[i], 6, INK)
        return canvas
    a = 1 - ease_in_out((t - 1.1) / 0.3)
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    alpha = int(255 * a)
    if style == "paper":
        ld.rounded_rectangle((40, 70, 560, 240), 20, fill=(*PAPER, int(235 * a)))
        ld.text((70, 95), "なんでもない日の音", font=font(FONT_HAND, 50), fill=(*INK, alpha))
        ld.text((72, 170), "9.26 ・ 3つの音でできた15秒", font=font(FONT_HAND, 28), fill=(*CORAL, alpha))
    else:
        ld.text((48, 90), "なんでもない", font=font(FONT_BOLD, 76), fill=(255, 255, 255, alpha),
                stroke_width=8, stroke_fill=(*INK, alpha))
        ld.text((48, 185), "日の音。", font=font(FONT_BOLD, 76), fill=(*CORAL, alpha),
                stroke_width=8, stroke_fill=(*INK, alpha))
        ld.text((52, 290), "OTOGRASHI  ·  15 SEC", font=font(FONT_BOLD, 24), fill=(255, 255, 255, alpha))
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


def grid_cells(n):
    cols = {1: 1, 2: 1, 4: 2, 9: 3, 16: 4}[n]
    rows = n // cols
    return [(c * W / cols, r * H / rows, W / cols, H / rows) for r in range(rows) for c in range(cols)]


def lead_of(ctx, t):
    return ctx.last_onset(t, lambda e: e.kind != "rhythm") or ctx.last_onset(t) or ctx.events[0]


def punch(age, amount=0.14, length=0.12):
    return 1 + amount * max(0.0, 1 - age / length)


def shot_full(ctx, t, seg):
    lead = lead_of(ctx, t)
    pitch = max(-3, min(6, (lead.midi or 60) - 60))
    return cover(ctx.frame(lead, t), W, H, zoom=(1 + 0.04 * pitch / 6) * punch(t - lead.t))


def shot_flip(ctx, t, seg):
    """Every melodic note cuts to a mirrored / shifted crop of the same face."""
    lead = lead_of(ctx, t)
    notes = len(ctx.onsets_between(seg[0], t + 1e-6, lambda e: e.kind != "rhythm"))
    return cover(ctx.frame(lead, t), W, H, zoom=1.08 * punch(t - lead.t, 0.1),
                 mirror=notes % 2 == 1, dx=0.04 * (notes % 3 - 1))


def shot_stutter(ctx, t, seg):
    """Every 8th note re-cuts to a tighter crop of the same moment."""
    lead = lead_of(ctx, t)
    step = int((t - seg[0]) / (BEAT / 2))
    return cover(ctx.frame(lead, t), W, H, zoom=(1 + 0.12 * (step % 4)) * punch(t - lead.t, 0.08))


def shot_mirror(ctx, t, seg):
    lead = lead_of(ctx, t)
    half = cover(ctx.frame(lead, t), W / 2, H, zoom=1.05 * punch(t - lead.t, 0.08))
    canvas = Image.new("RGB", (W, H))
    canvas.paste(half, (0, 0))
    canvas.paste(ImageOps.mirror(half), (W // 2, 0))
    return canvas


def shot_kaleido(ctx, t, seg):
    lead = lead_of(ctx, t)
    q = cover(ctx.frame(lead, t), W / 2, H / 2, zoom=1.1 * punch(t - lead.t, 0.1))
    canvas = Image.new("RGB", (W, H))
    canvas.paste(q, (0, 0))
    canvas.paste(ImageOps.mirror(q), (W // 2, 0))
    canvas.paste(ImageOps.flip(q), (0, H // 2))
    canvas.paste(ImageOps.flip(ImageOps.mirror(q)), (W // 2, H // 2))
    return canvas


def shot_burst(ctx, t, seg):
    """Screens multiply with every hit, restarting on each downbeat."""
    bar_start = seg[0] + int((t - seg[0]) / BAR) * BAR
    hits = ctx.onsets_between(bar_start, t + 1e-6)
    count = len(hits)
    n = 1 if count <= 1 else 2 if count == 2 else 4 if count <= 4 else 9 if count <= 8 else 16
    cells = grid_cells(n)
    recent = hits[-n:] if hits else [lead_of(ctx, t)]
    canvas = Image.new("RGB", (W, H))
    for i, (x, y, w, h) in enumerate(cells):
        e = recent[i % len(recent)]
        mirror = (int(x / (W / 4)) + int(y / (H / 4))) % 2 == 1
        tile = cover(ctx.frame(e, t), w, h, zoom=1.02, mirror=mirror)
        if e is recent[-1] and t - e.t < 0.1:
            tile = Image.eval(tile, lambda v: min(255, int(v * 1.35)))
        canvas.paste(tile, (int(x), int(y)))
    d = ImageDraw.Draw(canvas)
    for x, y, w, h in cells:
        d.rectangle((x, y, x + w, y + h), outline=(0, 0, 0), width=3)
    return canvas


def name_stamp(canvas, ctx, t):
    stamp = ctx.last_onset(t, lambda e: e.kind != "rhythm")
    if stamp and t - stamp.t < 0.45 and t > 1.4:
        a = t - stamp.t
        size = int(110 * (1.4 - 0.4 * ease_out(a / 0.08)))
        d = ImageDraw.Draw(canvas)
        text_center(d, (W / 2, H * 0.70), ctx.names[stamp.c], font(FONT_BOLD, size),
                    CLIP_COLORS[stamp.c], 12, INK)


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


def sound_pill(canvas, ctx, e, t, cx, cy):
    """Capsule with the sound's name and its own live waveform."""
    d = ImageDraw.Draw(canvas, "RGBA")
    col = CLIP_COLORS[e.c]
    f = font(FONT_BOLD, 30)
    name_w = d.textlength(ctx.names[e.c], font=f)
    bars = 22
    w = name_w + 56 + bars * 9
    x0, y0 = cx - w / 2, cy - 36
    d.rounded_rectangle((x0, y0, x0 + w, y0 + 72), 36, fill=(255, 255, 255, 240))
    d.text((x0 + 28, cy), ctx.names[e.c], font=f, fill=INK, anchor="lm")
    i_now = int((t - e.t) * FPS)
    for b in range(bars):
        i = i_now - bars + 1 + b
        lvl = e.env[i] if 0 <= i < len(e.env) else 0
        hh = 6 + min(1, lvl * 1.6) ** 0.6 * 44
        x = x0 + name_w + 44 + b * 9
        d.rounded_rectangle((x, cy - hh / 2, x + 5, cy + hh / 2), 3,
                            fill=(*col, 255 if b == bars - 1 else 150 + b * 4))


def shot_pan(ctx, t, seg):
    board_w, board_h = BOARD_W * W, BOARD_H * H
    board = Image.new("RGB", (int(board_w), int(board_h)), PAPER)
    seen = []
    for e in ctx.events:
        if e.t <= t and e.c not in seen:
            seen.append(e.c)
    slots = []
    for i in range(len(BOARD_SLOTS)):
        c = seen[i % len(seen)] if seen else 0
        slots.append((c, BOARD_SLOTS[i], i >= len(seen)))
    lead = ctx.last_onset(t, lambda e: e.kind != "rhythm") or ctx.last_onset(t)
    rects = []
    for i, (c, (x, y, w, h, rot), mirrored) in enumerate(slots):
        live = [e for e in ctx.active(t) if e.c == c]
        e = live[-1] if live else (ctx.last_onset(t, lambda ev, c=c: ev.c == c) or lead)
        pw, ph = w * W, h * H
        hit = ctx.last_onset(t, lambda ev, c=c: ev.c == c)
        pop = 1 + 0.05 * max(0, 1 - (t - hit.t) / 0.15) if hit else 1
        tile = cover(ctx.frame(e, t), pw * pop, ph * pop, mirror=mirrored)
        if not live:
            tile = Image.blend(tile, ImageOps.grayscale(tile).convert("RGB"), 0.6)
        framed = Image.new("RGB", (tile.width + 20, tile.height + 20), (255, 255, 255))
        framed.paste(tile, (10, 10))
        framed = framed.rotate(rot, expand=True, resample=Image.BICUBIC, fillcolor=PAPER)
        cx, cy = x * W + pw / 2, y * H + ph / 2
        paste_center(board, framed, cx, cy)
        rects.append((cx, cy, pw, ph, c, mirrored))
    # camera: whip to the slot of the newest melodic/phrase sound, pull back on section changes
    target_slot = next((r for r in rects if r[4] == lead.c and not r[5]), rects[0])
    # pull back to the whole board at the start of the shot, then dive in
    bar = 0
    reveal = (t - seg[0]) < BEAT * 1.5
    prev = ctx.last_onset(lead.t - 1e-4, lambda e: e.kind != "rhythm")
    prev_slot = next((r for r in rects if prev and r[4] == prev.c and not r[5]), target_slot)
    k = ease_in_out((t - lead.t) / 0.22)
    cx = prev_slot[0] + (target_slot[0] - prev_slot[0]) * k
    cy = prev_slot[1] + (target_slot[1] - prev_slot[1]) * k
    zoom = min(W / (target_slot[2] + 60), H / (target_slot[3] + 60)) * 0.98
    if reveal:
        r = 1 - ease_in_out((t - seg[0] - BEAT) / (BEAT * 0.5))
        zoom = zoom + (max(W / board_w, H / board_h) * 1.02 - zoom) * r
        cx = cx + (board_w / 2 - cx) * r
        cy = cy + (board_h / 2 - cy) * r
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
    for e in ctx.active(t):
        if e.kind != "rhythm" and e is lead:
            sound_pill(view, ctx, e, t, W / 2, H * 0.86)
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
        if not live and depth > 0:
            tile = Image.blend(tile, ImageOps.grayscale(tile).convert("RGB"), 0.35)
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
            text_center(d, (cx, label_y), ctx.names[e.c], font(FONT_HAND, 54), INK, 8, (255, 255, 255))
            if live:
                scribble_wave(canvas, e, t, cx, label_y + 70, min(W * 0.8, framed.width * 1.1), CLIP_COLORS[e.c])
    return canvas


# ---------------------------------------------------------------- director

SHOTS = {"full": shot_full, "flip": shot_flip, "stutter": shot_stutter, "mirror": shot_mirror,
         "kaleido": shot_kaleido, "burst": shot_burst, "pan": shot_pan, "pile": shot_pile}
BLEED = {"full", "flip", "stutter", "mirror", "kaleido", "burst"}
LONG = {"pan", "pile"}  # need two bars to build up
POOLS = {
    "calm": ["full", "flip", "pan"],
    "mid": ["mirror", "stutter", "pile", "pan", "flip"],
    "high": ["burst", "kaleido", "stutter", "burst"],
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
    if shot in BLEED:
        name_stamp(canvas, ctx, t)
        if hud:
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
    audio = render_audio(events, sources, total)
    wav_path = out_dir / "mix.wav"
    with wave.open(str(wav_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes((audio * 32767).astype(np.int16).tobytes())
    ctx = Ctx(events, sources, total)
    frames = total // SPF
    for seed in seeds:
        plan = plan_shots(total / SR, seed)
        hud = seed % 2 == 1
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
