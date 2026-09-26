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

sys.path.insert(0, str(Path(__file__).parent))
from lab_fx import (apply_master, gate_envelope, has_motion_fx, positions, sidechain_envelope,  # noqa: E402
                    video_post, video_time)

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
CLIP_COLORS = [CORAL, LAVENDER, MUSTARD, (90, 180, 150), (86, 160, 230), (230, 120, 190)]


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

    def mask_at_sample(self, sample):
        return self.masks[int(sample // SPF) % len(self.masks)]


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
        self.notes = raw.get("notes")  # sung events: [[offset, midi], ...]
        self.tune = raw.get("tune", 1.0)
        self.ref = raw.get("refMidi")  # syllable events keep their own contour
        self.rate = raw.get("rate")  # sampler-style speed change (drums)
        # MAD effects (see lab_fx.py); the picture reads the same positions as the sound
        self.glide = raw.get("glide")
        self.reverse = raw.get("reverse", False)
        self.scratch = raw.get("scratch")
        self.scratch_period = raw.get("scratchPeriod")
        self.gate = raw.get("gate")
        self._pos = None
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
        if has_motion_fx(self):
            if self._pos is None:
                self._pos = positions(self, max(1, self.dur))
            i = min(max(0, int((t - self.t) * SR)), len(self._pos) - 1)
            return int(min(max(self._pos[i], 0), src.samples - 1))
        offset = int((t - self.t) * SR)
        window = max(SPF, min(self.src_dur, src.samples))
        start = self.src_start % max(1, src.samples - window + 1)
        return start + offset % window


def render_audio(events, sources, total, source_pitch=None, master=True, fx=None):
    """source_pitch: measured MIDI pitch per clip index. Without it the legacy
    recipes keep a gentle ±semitone range around middle C."""
    mix = np.zeros(total, np.float32)
    kick_mix = np.zeros(total, np.float32)  # kept apart so sidechain can duck the rest
    voices = {}
    for e in events:
        src = sources[e.c]
        window = max(SPF, min(e.src_dur, src.samples))
        start = e.src_start % max(1, src.samples - window + 1)
        chunk = src.pcm[start:start + window]
        if e.kind == "sung" and e.notes:
            from lab_audio import Voice, sing
            if e.c not in voices:
                voices[e.c] = Voice(src.pcm)
            buf = sing(voices[e.c], e.src_start, e.dur, e.notes, e.tune, e.rate or 1.0,
                       accent=e.ref is None, ref=e.ref)
        elif has_motion_fx(e):
            pos = positions(e, e.dur)  # the picture follows the same positions
            buf = np.interp(pos, np.arange(src.samples), src.pcm, left=0.0, right=0.0).astype(np.float32)
            if e.role == "kick":
                buf *= np.exp(-np.arange(e.dur) / (0.07 * SR)).astype(np.float32)
        elif e.kind == "tuned" and e.midi:
            if source_pitch:
                ratio = float(np.clip(2 ** ((e.midi - source_pitch[e.c]) / 12), 0.3, 2.6))
            else:
                ratio = float(np.clip(2 ** ((e.midi - 60) / 12), 0.72, 1.45))
            pos = (np.arange(e.dur) * ratio) % len(chunk)
            buf = np.interp(pos, np.arange(len(chunk)), chunk).astype(np.float32)
        else:
            reps = int(math.ceil(e.dur / len(chunk)))
            buf = np.tile(chunk, reps)[:e.dur].copy()
        if e.gate:
            buf = buf * gate_envelope(len(buf), e.gate)
        n = len(buf)
        fi, fo = min(e.fade_in, n // 2), min(max(e.fade_out, 240), n // 2)
        if fi:
            buf[:fi] *= np.linspace(0, 1, fi)
        if fo:
            buf[-fo:] *= np.linspace(1, 0, fo)
        buf *= e.gain
        end = min(total, e.start + n)
        (kick_mix if e.role == "kick" else mix)[e.start:end] += buf[:end - e.start]
        blocks = (n + SPF - 1) // SPF
        padded = np.pad(np.abs(buf), (0, blocks * SPF - n))
        e.env = padded.reshape(blocks, SPF).max(axis=1)
    for f in fx or []:
        if f["type"] == "sidechain":
            a, b = int(f["start"]), min(total, int(f["start"] + f["dur"]))
            mix[a:b] *= sidechain_envelope(b - a, [k - a for k in f.get("kicks", [])])
    mix = mix + kick_mix
    if not master:  # raw sum, for measuring stems against each other
        return mix
    mix = apply_master(mix, fx)
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
        # clips that actually sound; silent ones stay out of the credits
        self.heard = sorted({e.c for e in events})
        # quiet backing plays show as a corner sticker, never in the main picture
        self.backing = [e for e in events if e.role == "backing"]
        self.events = events = [e for e in events if e.role != "backing"]
        self.runs = repeat_runs(events)
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

    def mask(self, e, t):
        src = self.sources[e.c]
        t = min(max(t, e.t), e.end_t - 1 / FPS)
        return src.mask_at_sample(e.source_sample(t, src))

    def voices(self, t, limit=9):
        """Events sounding at t, oldest first: one picture per voice."""
        # a guide layer is part of its singer's sound, not another picture
        live = sorted((e for e in self.active(t) if e.role != "guide"), key=lambda e: (e.t, e.idx))
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


REPEATABLE = {"chop", "fx", "echo", "phrase", None}


def repeat_runs(events):
    """Groups of the same sound played again and again: the same clip and the
    same place in it, each hit within 3/4 of a beat of the previous one.
    Drum hits repeat all song long, so they never count."""
    hits = sorted((e for e in events if e.role in REPEATABLE and e.kind != "sung"), key=lambda e: e.t)
    runs, open_runs = [], {}
    for e in hits:
        key = (e.c, e.src_start)
        run = open_runs.get(key)
        if run and e.t - run[-1].t <= 0.75 * BEAT:
            run.append(e)
        else:
            run = [e]
            open_runs[key] = run
            runs.append(run)
    return [r for r in runs if len(r) >= 2]


def repeat_moment(canvas, ctx, t, dim=True):
    """While a sound repeats, a still captured at each hit joins a strip.

    Every still keeps its size and its place relative to the others once laid;
    nothing is squeezed to fit. Only the strip as a whole slides sideways so
    the newest still settles in the centre, older ones drifting off-screen."""
    active = [r for r in ctx.runs if r[0].t <= t < r[-1].end_t + 0.3]
    if not active:
        return canvas
    # a long roll wins outright; otherwise the run heard most recently
    run = max(active, key=lambda r: (len(r) >= 4, max(e.t for e in r if e.t <= t), len(r)))
    # at most one still per 16th note: a 32nd-note pair shares one, so each still is seen
    shown, slots = [], set()
    for e in run:
        slot = math.floor(e.t / (BEAT / 4) + 1e-6)
        if e.t <= t and slot not in slots:
            slots.add(slot)
            shown.append(e)
    if len(shown) < (1 if len(run) >= 4 else 2):  # a roll shows from its first hit
        return canvas
    # footage behind the strip steps back; a plain ground stays as it is
    base = (ImageEnhance.Brightness(canvas).enhance(0.7) if dim else canvas).convert("RGBA")
    size = H * 0.42
    step = W * 0.2  # neighbours overlap heavily, like a row of clones
    # the strip slides to the new still and settles before the next hit arrives
    k = len(shown) - 1
    gap = max(BEAT / 4, shown[k].t - shown[k - 1].t) if k else BEAT / 4
    glide = ease_out((t - shown[k].t) / max(1 / 60, min(0.1, 0.8 * gap)))
    centre = step * (k - 1 + glide)
    offset = W / 2 - centre
    for i, e in enumerate(shown):
        x = offset + i * step
        if x < -step or x > W + step:
            continue  # scrolled out of view
        src = ctx.sources[e.c]
        still_t = e.t  # the picture at the moment of this hit, frozen
        piece = cutout(ctx, e, still_t, size, max_width=W * 0.55, outline=8) if getattr(src, "has_subject", False) else None
        if piece is not None:
            alpha = np.asarray(piece.getchannel("A"), np.float32) / 255
            if (alpha.mean(axis=1) > 0.2).mean() < 0.6:
                piece = None  # the mask only holds a band (tracks, ground): show the still itself
        if piece is None:
            photo = cover(ctx.frame(e, still_t), size * 0.75, size).convert("RGBA")
            edge = max(5, int(size * 0.03))
            piece = Image.new("RGBA", (photo.width + 2 * edge, photo.height + 2 * edge), (255, 255, 255, 255))
            piece.alpha_composite(photo, (edge, edge))
        # entrance: each still drops in from above, lands with a small hop and
        # settles its tilt; the size never changes. Fast repeats get a quicker entrance.
        later = [x.t for x in shown if x.t > e.t] or [x.t for x in run if x.t > e.t + BEAT / 4 - 1e-6]
        nxt = later[0] if later else e.t + 1.0
        dur = max(1 / 30, min(0.14, 0.7 * (nxt - e.t)))
        age = t - e.t
        tilt = (-5, 3, -2, 5, -4)[i % 5]
        if age < dur:
            u = age / dur
            drop = -H * 0.3 * (1 - u * u)
            tilt += 10 * (1 - u) * (1 if i % 2 else -1)
        elif age < dur + 0.1:
            drop = -H * 0.025 * math.sin(math.pi * (age - dur) / 0.1)
        else:
            drop = 0.0
        piece = piece.rotate(tilt, expand=True, resample=Image.BICUBIC)
        y = H * 0.42 + (18 if i % 2 else -18) + drop
        base.alpha_composite(piece, (int(x - piece.width / 2), int(y - piece.height / 2)))
    return base.convert("RGB")


def draw_op(canvas, ctx, t, style):
    """0–1.6s: the title rests on the first sounding picture (videos that open
    on the feed carry their cover on the first post instead)."""
    if t >= 1.6 or getattr(ctx, "feed", False):
        return canvas
    a = ease_out(t / 0.2) * (1 - ease_in_out((t - 1.3) / 0.3))
    alpha = int(255 * a)
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    cast = " ・ ".join(ctx.names[i] for i in ctx.heard)
    if style == "paper":
        ld = ImageDraw.Draw(layer)
        ld.rounded_rectangle((36, 64, 580, 236), 18, fill=(*PAPER, int(240 * a)))
        ld.text((64, 88), ctx.title or "なんでもない日の音", font=font(FONT_HAND, 50), fill=(*INK, alpha))
        size = 28
        while size > 16 and ld.textlength(cast, font=font(FONT_HAND, size)) > 500:
            size -= 1  # six names still fit on the card
        ld.text((66, 164), cast, font=font(FONT_HAND, size), fill=(*CORAL, alpha))
    else:
        soft_text(layer, (46, 84), ctx.title or "なんでもない日の音", font(FONT_BOLD, 60), (255, 255, 255), alpha)
        size = 26
        while size > 16 and ImageDraw.Draw(layer).textlength(cast, font=font(FONT_BOLD, size)) > W - 96:
            size -= 1
        soft_text(layer, (48, 170), cast, font(FONT_BOLD, size), (255, 255, 255), alpha)
        ImageDraw.Draw(layer).rounded_rectangle((48, 214, 120, 220), 3, fill=(*CORAL, alpha))
    return Image.alpha_composite(canvas.convert("RGBA"), layer).convert("RGB")


def draw_ed(canvas, ctx, t, style):
    """Last 1.3s: every sound freezes into a grid, then the logo lands."""
    start = ctx.total_t - 1.3
    if t < start:
        return canvas
    k = t - start
    n = len(ctx.heard)
    bg = PAPER if style == "paper" else INK
    out = Image.new("RGB", (W, H), bg)
    cols = 2
    cw, ch = (W - 72) / cols, (H * 0.56 - 24) / 2
    for i in range(4):
        src = ctx.sources[ctx.heard[i % n]]
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
            text_center(d, (W / 2, H * 0.875), "演奏：" + "・".join(ctx.names[i] for i in ctx.heard), font(FONT_HAND, 26), fg)
        else:
            text_center(d, (W / 2, H * 0.84), "・".join(ctx.names[i] for i in ctx.heard) + " でできた15秒",
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
        col = CLIP_COLORS[e.c % len(CLIP_COLORS)]
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
    featured = [e for e in live if e.role == "fx"]  # rolls, risers, reverses, scratches
    if featured:
        return featured[-1]
    melodic = [e for e in live if e.role == "phrase"] or [e for e in live if e.role == "melody"]
    if melodic:
        return melodic[-1]
    # the singer keeps the picture through the small gaps of its line (up to a beat);
    # bass and drum hits underneath must not steal it for a frame or two
    held = ctx.last_onset(t, lambda e: e.role in ("melody", "phrase"))
    if held and t - held.end_t < BEAT:
        return held
    melodic = [e for e in live if e.kind != "rhythm" and e.role in (None, "bass")]
    if melodic:
        return melodic[-1]
    if live:
        return live[-1]
    return ctx.last_onset(t) or ctx.events[0]


def punch(age, amount=0.14, length=0.12):
    return 1 + amount * max(0.0, 1 - age / length)


def dim(im, soft=False):
    """Silent pictures lose colour; a lone full-screen picture only fades a little."""
    grey = ImageOps.grayscale(im).convert("RGB")
    amount, light = (0.35, 0.75) if soft else (0.7, 0.45)
    return ImageEnhance.Brightness(Image.blend(im, grey, amount)).enhance(light)


def panel(ctx, e, t, w, h, mirror=False, zoom=1.0, dx=0.0, soft=False, hold=0.0):
    """One voice's picture: moving and pulsing while it sounds, frozen and dim after.
    hold: gaps shorter than this (between staccato notes) do not dim the picture."""
    live = e.active(t) or (hold > 0 and 0 <= t - e.end_t < hold)
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
    col = CLIP_COLORS[e.c % len(CLIP_COLORS)]
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
        outline=CLIP_COLORS[e.c % len(CLIP_COLORS)], width=width)


def single(ctx, t, e, **kw):
    canvas = panel(ctx, e, t, W, H, soft=True, hold=BEAT / 2, **kw)
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
    # one step per 16th-note slot that starts a sound (a note's attack and body count once)
    step = len({round(e.t / (BEAT / 2)) for e in ctx.onsets_between(seg[0], t + 1e-6)
                if e.role != "guide"})
    return single(ctx, t, lead, zoom=(1 + 0.12 * (step % 4)) * punch(t - lead.t, 0.08))


def voice_layout(n):
    if n <= 1:
        return [(0, 0, W, H)]
    rows = n if n <= 3 else math.ceil(n / 2) if n <= 6 else 3
    per_row = [n // rows + (1 if r < n % rows else 0) for r in range(rows)]
    return [(c * W / k, r * H / rows, W / k, H / rows) for r, k in enumerate(per_row) for c in range(k)]


def shot_voices(ctx, t, seg, limit=4):
    """One picture per *clip* heard so far in this bar: the grid grows 1→2→3→4
    as sounds join and resets on the next downbeat. The clip sounding now moves
    and glows; ones that have finished hold their last frame, dimmed.
    Counting clips rather than events keeps a note's attack and body on one
    picture, and each clip keeps its place for the whole shot."""
    w0 = seg[0] + math.floor((t - seg[0]) / BAR) * BAR
    window = [e for e in ctx.events if e.role != "guide" and w0 <= e.t <= t]
    if not window:
        return single(ctx, t, lead_of(ctx, t))
    first = {}
    for e in ctx.events:
        if e.role != "guide" and seg[0] <= e.t < seg[1]:
            first.setdefault(e.c, e.t)
    clips = sorted({e.c for e in window}, key=lambda c: first.get(c, 0))
    if len(clips) > limit:  # keep the ones heard most recently
        recent = sorted(clips, key=lambda c: max(e.t for e in window if e.c == c))[-limit:]
        clips = [c for c in clips if c in recent]
    rects = voice_layout(len(clips))
    canvas = Image.new("RGB", (W, H))
    shown = []
    for c, (x, y, w, h) in zip(clips, rects):
        live = [e for e in ctx.voices(t) if e.c == c]
        e = live[-1] if live else max((e for e in window if e.c == c), key=lambda e: e.t)
        im = panel(ctx, e, t, w, h, zoom=punch(t - e.t, 0.08, 0.1) if live else 1.0)
        canvas.paste(im, (int(x), int(y)))
        shown.append((e, (x, y, w, h), len(live)))
    d = ImageDraw.Draw(canvas)
    for x, y, w, h in rects:
        d.rectangle((x, y, x + w, y + h), outline=(0, 0, 0), width=3)
    for e, rect, count in shown:
        pulse_border(canvas, ctx, e, t, rect)
        voice_label(canvas, ctx, e, t, rect, max(1, count))
    return canvas


BACKDROPS = [(247, 190, 205), (196, 226, 242), (240, 232, 205), (204, 236, 214)]


def largest_blob(mask):
    """Keep only the biggest connected subject, so a small sticker never
    carries a stray piece of someone at the edge of the frame."""
    small = np.array(mask.resize((96, max(1, int(96 * mask.height / mask.width))), Image.BILINEAR)) > 96
    h, w = small.shape
    label = np.zeros((h, w), int)
    best, best_size, n = 0, 0, 0
    for y0 in range(h):
        for x0 in range(w):
            if not small[y0, x0] or label[y0, x0]:
                continue
            n += 1
            stack, size = [(y0, x0)], 0
            label[y0, x0] = n
            while stack:
                y, x = stack.pop()
                size += 1
                for yy, xx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
                    if 0 <= yy < h and 0 <= xx < w and small[yy, xx] and not label[yy, xx]:
                        label[yy, xx] = n
                        stack.append((yy, xx))
            if size > best_size:
                best, best_size = n, size
    if not best:
        return mask
    keep = Image.fromarray(((label == best) * 255).astype(np.uint8)).resize(mask.size, Image.BILINEAR)
    keep = keep.filter(ImageFilter.MaxFilter(9))
    return Image.fromarray(np.minimum(np.array(mask), np.array(keep)))


def cutout(ctx, e, t, height, close=False, outline=0, max_width=W * 0.8, largest=False):
    """The sounding subject on transparency, scaled to `height`. close=True keeps
    the top of the subject (a face or head) for a close-up."""
    frame = ctx.frame(e, t)
    if not getattr(ctx.sources[e.c], "has_subject", True):
        # nothing to cut out (a landscape, a crowd blur): use the shot as a photo card
        ph = height * (0.62 if not close else 0.8)
        pw = min(max_width, ph * 0.75)
        photo = cover(frame, pw, ph).convert("RGBA")
        edge = max(6, int(pw * 0.03))
        board = Image.new("RGBA", (photo.width + 2 * edge, photo.height + 2 * edge), (255, 255, 255, 255))
        board.alpha_composite(photo, (edge, edge))
        return board.rotate(-3, expand=True, resample=Image.BICUBIC)
    mask = ctx.mask(e, t).resize(frame.size, Image.BILINEAR)
    if largest:
        mask = largest_blob(mask)
    box = mask.point(lambda v: 255 if v > 96 else 0).getbbox()
    if not box:
        return None
    x0, y0, x1, y1 = box
    if close:
        y1 = y0 + int((y1 - y0) * 0.5)
    rgba = frame.convert("RGBA")
    rgba.putalpha(mask)
    piece = rgba.crop((x0, y0, x1, y1))
    scale = min(height / max(1, piece.height), max_width / max(1, piece.width))
    piece = piece.resize((max(1, int(piece.width * scale)), max(1, int(piece.height * scale))), Image.BILINEAR)
    if outline:
        # pad first so the white edge is not clipped at the cut-out's bounding box
        a = ImageOps.expand(piece.getchannel("A"), outline, 0).filter(ImageFilter.MaxFilter(outline * 2 + 1))
        board = Image.new("RGBA", a.size, (255, 255, 255, 255))
        board.putalpha(a.filter(ImageFilter.GaussianBlur(1)))
        board.alpha_composite(piece, (outline, outline))
        piece = board
    return piece


def appeared_at(ctx, t, gap=0.15):
    """When the figure last came back after at least `gap` seconds of silence."""
    def visible(x):
        return bool(ctx.voices(x)) or any(0 <= x - e.end_t < 0.12 for e in ctx.voices(x - 0.12))
    x = t
    while x > t - 2 and visible(x - 1 / 30):
        x -= 1 / 30
    return x


def drop_in(age, height):
    """Falls in from above in ~0.1 s (accelerating), then a small landing hop."""
    if age < 0.1:
        u = age / 0.1
        return -height * 0.6 * (1 - u * u)
    if age < 0.22:
        return -height * 0.03 * math.sin(math.pi * (age - 0.1) / 0.12)
    return 0.0


def shot_cutout(ctx, t, seg):
    """Flat pastel ground with the sounding subject cut out, after the reference:

    - the figure drops in from above when it comes back, with a small landing hop
    - repeats of the sound inside a beat add clones to its right, a quarter of a
      figure apart and *behind* it; the first figure never moves
    - clones are frozen at their own hit (only what sounds now moves)
    - silence leaves the empty ground
    - bars alternate full figure and close-up; a small vertical name sits at the right
    """
    rng = np.random.default_rng(getattr(ctx, "seed", 0))
    bg = BACKDROPS[int(rng.integers(len(BACKDROPS)))]
    canvas = Image.new("RGBA", (W, H), (*bg, 255))
    live = ctx.voices(t)
    lead = lead_of(ctx, t)
    if not live and t - lead.end_t > 0.12:
        return canvas.convert("RGB")
    close = False  # the close-up with clones read as a blur of big shapes; full figure only
    height = H * (0.95 if close else 0.8)
    beat_start = math.floor(t / BEAT) * BEAT
    hits = sorted((e for e in ctx.events if e.c == lead.c and e.role != "guide" and e.kind != "sung"
                   and beat_start <= e.t <= t), key=lambda e: e.t)[:5] or [lead]
    fall = drop_in(t - appeared_at(ctx, t), height)
    base_x = W * (0.5 if close else 0.36)
    pieces = []
    for i, e in enumerate(hits):
        at = t if e.active(t) else e.t  # clones hold the pose of their own hit
        piece = cutout(ctx, e, at, height, close=close, max_width=W * (0.9 if close else 0.75), outline=8)
        if piece is not None:
            pieces.append((i, piece))
    # draw back to front: later clones sit behind and to the right of earlier ones
    for i, piece in reversed(pieces):
        x = int(base_x - piece.width / 2 + i * piece.width * 0.25)
        canvas.alpha_composite(piece, (x, int(H * 0.99 - piece.height + fall)))
    d = ImageDraw.Draw(canvas)
    for j, ch in enumerate(ctx.names[lead.c][:10]):
        d.text((W * 0.9, H * 0.36 + j * 34), ch, font=font(FONT_HAND, 26), fill=(255, 255, 255, 235), anchor="mm")
    return canvas.convert("RGB")


def shot_sticker(ctx, t, seg):
    """On each hit the sounding subject is lifted out as a white-edged sticker over
    blurred scenery from another sound; then the subject's *real* surroundings
    rise from the bottom and replace the blur. The sticker sits exactly where
    the subject is in its shot, so the returning scene closes around it; the
    next hit lifts it onto a different blurred scene."""
    lead = lead_of(ctx, t)
    src = ctx.sources[lead.c]
    if not getattr(src, "has_subject", False):
        return single(ctx, t, lead)
    full = cover(ctx.frame(lead, t), W, H)
    hits = [e for e in ctx.events if e.c == lead.c and e.role != "guide" and e.t <= t and e.kind != "sung"]
    # like the reference, the lift-out restarts at most once per beat: the first hit
    # in a beat starts it and later hits in that beat let it play through
    beats_hit = sorted({math.floor(e.t / BEAT) for e in hits})
    beat_idx = beats_hit[-1] if beats_hit else math.floor(lead.t / BEAT)
    hit_t = min(e.t for e in hits if math.floor(e.t / BEAT) == beat_idx) if hits else lead.t
    since = t - hit_t
    # blurred scenery from another sound, a different one on every such beat
    others = sorted({e.c for e in ctx.events if e.c != lead.c and e.role != "guide"}) or [lead.c]
    n = len(beats_hit)
    other = ctx.sources[others[n % len(others)]]
    scene = cover(other.frames[(n * 11) % len(other.frames)], W, H, zoom=1.08).filter(ImageFilter.GaussianBlur(14))
    canvas = ImageEnhance.Brightness(scene).enhance(0.85).convert("RGBA")
    rise = ease_out((since - 0.08) / 0.35)
    if rise > 0:
        top = int(H * (1 - rise))
        canvas.paste(full.crop((0, top, W, H)).convert("RGBA"), (0, top))
        if rise < 1:
            ImageDraw.Draw(canvas).rectangle((0, top - 3, W, top + 3), fill=(255, 255, 255, 200))
    mask = cover(ctx.mask(lead, t), W, H).point(lambda v: 255 if v > 96 else 0)
    edge = mask.filter(ImageFilter.MaxFilter(21)).filter(ImageFilter.GaussianBlur(1))
    # where the subject runs off the frame, pull it in so the white edge closes around it too
    inner = np.asarray(mask).copy()
    inner[:10, :] = 0
    inner[-10:, :] = 0
    inner[:, :10] = 0
    inner[:, -10:] = 0
    white = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    white.putalpha(edge)
    subject = full.convert("RGBA")
    subject.putalpha(Image.fromarray(inner).filter(ImageFilter.GaussianBlur(1)))
    canvas.alpha_composite(white)
    canvas.alpha_composite(subject)
    voice_label(canvas, ctx, lead, t, (0, 0, W, H), sum(v.c == lead.c for v in ctx.voices(t)))
    return canvas.convert("RGB")


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
    # a paper margin around the board so a wide pull-back never shows black
    padded = Image.new("RGB", (board.width + 2 * W, board.height + 2 * H), PAPER)
    padded.paste(board, (W, H))
    box = tuple(int(v) for v in (cx - vw / 2 + W, cy - vh / 2 + H, cx + vw / 2 + W, cy + vh / 2 + H))
    view = padded.crop(box).resize((W, H), Image.BILINEAR)
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
        big = {"phrase": 0.86, "melody": 0.66, "bass": 0.5, "chop": 0.46}.get(
            e.role, {"phrase": 0.86, "tuned": 0.62, "sung": 0.62}.get(e.kind, 0.38))
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
                scribble_wave(canvas, e, t, cx, label_y + 70, min(W * 0.8, framed.width * 1.1), CLIP_COLORS[e.c % len(CLIP_COLORS)])
    return canvas


# ---------------------------------------------------------------- director

SHOTS = {"cutout": shot_cutout, "sticker": shot_sticker,
         "full": shot_full, "flip": shot_flip, "stutter": shot_stutter, "mirror": shot_mirror,
         "burst": shot_burst, "pan": shot_pan, "pile": shot_pile}
BLEED = {"full", "flip", "stutter", "mirror", "burst"}
LONG = {"pan", "pile"}  # need two bars to build up
POOLS = {
    "calm": ["full", "flip", "pan", "sticker", "cutout"],
    "mid": ["mirror", "stutter", "pile", "pan", "flip", "cutout", "sticker"],
    "high": ["burst", "mirror", "stutter", "burst"],
}


SOLO = ("full", "flip", "stutter")  # one picture over the whole frame


def plan_shots(total_t, seed, sections=None, solo_bars=()):
    """Pick one shot per bar along an energy curve; the seed makes every video different.
    sections: optional [[bar_from, bar_to, energy], ...] from the arrangement.
    solo_bars: bars that must show one full-frame picture (a backing sticker sits on them)."""
    rng = np.random.default_rng(seed)
    bars = int(round(total_t / BAR))
    plan, bar, last, used = [], 0, None, set()
    while bar < bars:
        p = bar / bars
        energy = "calm" if p < 0.25 else "mid" if p < 0.6 else "high"
        if bar == bars - 1:
            energy = "high"
        for a, b, level in sections or []:
            if a <= bar < b:
                energy = level
        choices = [c for c in POOLS[energy] if c != last and not (c in LONG and bar + 2 > bars - 1)
                   and not (c in LONG and bar + 1 in solo_bars)]
        if bar in solo_bars:
            choices = [c for c in SOLO if c != last] or list(SOLO)
        if bar == 0:  # the opening introduces a face, not a board
            choices = [c for c in choices if c in BLEED]
        fresh = [c for c in choices if c not in used]
        choices = fresh or choices
        shot = choices[rng.integers(len(choices))]
        used.add(shot)
        span = 2 if shot in LONG else 1
        plan.append((shot, bar * BAR, (bar + span) * BAR, energy))
        bar, last = bar + span, shot
    if not any(s == "burst" for s, *_ in plan) and int(plan[-1][1] / BAR) not in solo_bars:
        s0, a0, b0, e0 = plan[-1]
        plan[-1] = ("burst", a0, b0, e0)
    return plan


def backing_stickers(canvas, ctx, t, plan):
    """A clip playing quietly behind the melody pops up as a small sticker in
    the bottom-right corner, sways with its own level and pops away after."""
    shot = next((p for p in plan if p[1] <= t < p[2]), plan[-1])[0]
    if shot not in SOLO or any(len(r) >= 4 and r[0].t <= t < r[-1].end_t + 0.3 for r in ctx.runs):
        return canvas
    out = None
    for e in ctx.backing:
        if not (e.t <= t < e.end_t + 0.15):
            continue
        age = t - e.t
        scale = overshoot(age / 0.3) if t < e.end_t else 1 - ease_out((t - e.end_t) / 0.15)
        if scale <= 0.02:
            continue
        piece = cutout(ctx, e, min(t, e.end_t - 1 / FPS), H * 0.24, outline=8, max_width=W * 0.34, largest=True)
        if piece is None:
            continue
        level = ctx.norm_level(e, t) if t < e.end_t else 0.0
        piece = piece.resize((max(1, int(piece.width * scale)), max(1, int(piece.height * scale))), Image.BILINEAR)
        piece = piece.rotate(-6 + 5 * level * np.sin(age * 9), expand=True, resample=Image.BICUBIC)
        if out is None:
            out = canvas.convert("RGBA")
        shadow = Image.new("RGBA", piece.size, (0, 0, 0, 0))
        shadow.putalpha(piece.getchannel("A").point(lambda v: v * 0.35))
        x = int(W - 36 - piece.width)
        y = int(H - 170 - piece.height)
        out.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(10)), (x + 6, y + 10))
        out.alpha_composite(piece, (x, y))
        if scale > 0.6:
            d = ImageDraw.Draw(out)
            f = font(FONT_BOLD, 24)
            name = ctx.names[e.c]
            tw = d.textlength(name, font=f)
            cx = x + piece.width / 2
            d.rounded_rectangle((cx - tw / 2 - 14, y + piece.height - 6, cx + tw / 2 + 14, y + piece.height + 30),
                                18, fill=(*CLIP_COLORS[e.c % len(CLIP_COLORS)], 235))
            d.text((cx, y + piece.height + 12), name, font=f, fill=(255, 255, 255), anchor="mm")
    return canvas if out is None else out.convert("RGB")


# ---------------------------------------------------------------- opening feed

def feed_posts(ctx, intro_end):
    """The introductions as a feed: one post per clip, in the order they speak.
    Returns [(event, start_t)], a post lasting until the next one starts."""
    posts = []
    for e in sorted(ctx.events, key=lambda e: (e.t, e.idx)):
        if e.t >= intro_end or e.role not in ("phrase", "chop"):
            continue
        if not posts or posts[-1][0].c != e.c:
            posts.append((e, e.t))
        elif e.role == "phrase":
            posts[-1] = (e, posts[-1][1])  # the stuttered head leads into its phrase
    return posts


def feed_count(n):
    return f"{n / 10000:.1f}万" if n >= 10000 else f"{n:,}"


def feed_numbers(ctx, e, progress):
    """Plausible like and comment counts, fixed per clip and seed; the likes
    climb a little while the post is on screen."""
    rng = np.random.default_rng(getattr(ctx, "seed", 0) * 31 + e.c)
    likes = int(10 ** rng.uniform(2.6, 4.9))
    comments = max(3, int(likes * rng.uniform(0.01, 0.05)))
    return likes + int(progress * likes * 0.04), comments


def feed_icons(layer, col, likes, comments):
    """Right-hand column of a short-video app: like, comment, share, with counts."""
    d = ImageDraw.Draw(layer)
    x, y = W - 62, H * 0.52
    small = font(FONT_BOLD, 20)
    # like
    d.ellipse((x - 22, y - 16, x + 1, y + 6), fill=(*col, 255))
    d.ellipse((x - 1, y - 16, x + 22, y + 6), fill=(*col, 255))
    d.polygon([(x - 21, y - 1), (x + 21, y - 1), (x, y + 22)], fill=(*col, 255))
    d.text((x, y + 42), feed_count(likes), font=small, fill=(255, 255, 255, 255), anchor="mm")
    # comment
    y += 104
    d.rounded_rectangle((x - 22, y - 18, x + 22, y + 12), 12, fill=(255, 255, 255, 255))
    d.polygon([(x - 8, y + 10), (x + 4, y + 10), (x - 10, y + 22)], fill=(255, 255, 255, 255))
    d.text((x, y + 42), feed_count(comments), font=small, fill=(255, 255, 255, 255), anchor="mm")
    # share
    y += 104
    d.polygon([(x - 20, y + 14), (x - 20, y - 2), (x + 4, y - 2), (x + 4, y - 14), (x + 24, y + 4),
               (x + 4, y + 22), (x + 4, y + 10), (x - 8, y + 10)], fill=(255, 255, 255, 255))
    d.text((x, y + 44), "シェア", font=small, fill=(255, 255, 255, 255), anchor="mm")


def face_disc(ctx, c, size):
    """A round face sticker of clip c: its first picture, white rim."""
    first = next(e for e in ctx.events if e.c == c)
    face = cover(ctx.frame(first, first.t), size, size, focus_y=0.34).convert("RGBA")
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size - 1, size - 1), fill=255)
    face.putalpha(mask)
    rim = 6
    disc = Image.new("RGBA", (size + 2 * rim, size + 2 * rim), (0, 0, 0, 0))
    ImageDraw.Draw(disc).ellipse((0, 0, disc.width - 1, disc.height - 1), fill=(255, 255, 255, 255))
    disc.alpha_composite(face, (rim, rim))
    return disc


def cover_title(ctx, canvas):
    """The first frame is the cover a friend (and a feed thumbnail) sees before
    pressing play: whose everyday this is, and that オトグラシ made it. Complete
    from frame 0, kept clear of the app's own buttons at the bottom and right."""
    owner = __import__("os").environ.get("OTO_OWNER") or "わたし"
    headline = f"{owner}の日常"
    card = Image.new("RGBA", (W - 110, 210), (0, 0, 0, 0))
    d = ImageDraw.Draw(card)
    d.rounded_rectangle((0, 0, card.width - 1, card.height - 1), 26, fill=(*PAPER, 250))
    size = 104
    while size > 48 and d.textlength(headline, font=font(FONT_BOLD, size)) > card.width - 68:
        size -= 2
    d.text((34, 26), headline, font=font(FONT_BOLD, size), fill=(*INK, 255))
    d.text((card.width - 34, card.height - 36), "by オトグラシ", font=font(FONT_HAND, 32),
           fill=(*CORAL, 255), anchor="rm")
    card = card.rotate(3, expand=True, resample=Image.BICUBIC)
    shadow = Image.new("RGBA", card.size, (0, 0, 0, 0))
    shadow.putalpha(card.getchannel("A").point(lambda v: v * 0.4))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)), (46, 172))
    canvas.alpha_composite(card, (40, 160))
    return canvas


def feed_post(ctx, e, t, progress, first=False):
    """One full-screen post: the clip, its handle and tags, the side icons and
    a thin progress bar along the bottom. The first one carries the cover."""
    canvas = cover(ctx.frame(e, t), W, H).convert("RGBA")
    col = CLIP_COLORS[e.c % len(CLIP_COLORS)]
    shade = Image.new("L", (1, 256))
    shade.putdata([int(max(0, (i - 150) / 106) ** 1.5 * 170) for i in range(256)])
    shade = shade.resize((W, int(H * 0.36)))
    dark = Image.new("RGBA", (W, shade.height), (0, 0, 0, 255))
    dark.putalpha(shade)
    canvas.alpha_composite(dark, (0, H - shade.height))
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    feed_icons(layer, col, *feed_numbers(ctx, e, progress))
    d = ImageDraw.Draw(layer)
    d.ellipse((28, H - 196, 76, H - 148), fill=(*col, 255), outline=(255, 255, 255, 255), width=3)
    d.text((90, H - 172), "@" + ctx.names[e.c], font=font(FONT_BOLD, 30), fill=(255, 255, 255, 255), anchor="lm")
    d.text((30, H - 118), "#日常の音  #オトグラシ", font=font(FONT_BOLD, 24), fill=(255, 255, 255, 230), anchor="lm")
    d.rectangle((0, H - 6, W, H), fill=(255, 255, 255, 70))
    d.rectangle((0, H - 6, int(W * progress), H), fill=(255, 255, 255, 235))
    canvas.alpha_composite(layer)
    if first:
        canvas = cover_title(ctx, canvas)
    return canvas.convert("RGB")


STICKER_IN = 0.4  # seconds before the downbeat that the last post starts to lift


def accent_after_feed(ctx, e, intro_end):
    """The sound the song opens on: the last introduced clip on the downbeat."""
    return next((a for a in ctx.events if a.c == e.c and a.role == "phrase"
                 and abs(a.t - intro_end) < 1 / FPS), None)


def sticker_moment(ctx, e, t, intro_end):
    """ぐんっ: the last post punches in, its scene blurs away into a flat ground
    and the subject is left as a white-edged sticker, which then bounces on the
    downbeat as its own sound opens the song."""
    accent = accent_after_feed(ctx, e, intro_end)
    after = t >= intro_end
    shown = accent if after and accent else e
    at = min(max(t, shown.t), shown.end_t - 1 / FPS)
    frame = ctx.frame(shown, at)
    u = min(1.0, max(0.0, (t - (intro_end - STICKER_IN)) / STICKER_IN))
    zoom = 1 + 0.14 * overshoot(min(1.0, u / 0.35))
    lift = 1.0 if after else ease_out((u - 0.3) / 0.7)
    rng = np.random.default_rng(getattr(ctx, "seed", 0))
    ground = Image.new("RGB", (W, H), BACKDROPS[int(rng.integers(len(BACKDROPS)))])
    scene = cover(frame, W, H, zoom=zoom)
    bg = Image.blend(scene.filter(ImageFilter.GaussianBlur(2 + 16 * lift)), ground, 0.75 * lift)
    out = bg.convert("RGBA")
    piece = None
    if getattr(ctx.sources[e.c], "has_subject", True):
        mask = largest_blob(ctx.mask(shown, at).resize(frame.size, Image.BILINEAR))
        mask = cover(mask, W, H, zoom=zoom)
        if mask.getbbox():
            # padded so the white edge also runs along a side the subject is cut by
            pad = 16
            subject = scene.convert("RGBA")
            subject.putalpha(mask)
            piece = Image.new("RGBA", (W + 2 * pad, H + 2 * pad), (0, 0, 0, 0))
            piece.alpha_composite(subject, (pad, pad))
            edge = int(14 * lift)
            if edge > 1:
                grown = ImageOps.expand(mask, pad, 0).filter(ImageFilter.MaxFilter(2 * edge + 1))
                board = Image.new("RGBA", piece.size, (255, 255, 255, 255))
                board.putalpha(grown.filter(ImageFilter.GaussianBlur(1)))
                board.alpha_composite(piece)
                piece = board
    if piece is None:
        # nothing to cut out: the frame shrinks into a white-edged photo
        pw, ph = int(W * (1 - 0.32 * lift)), int(H * (1 - 0.32 * lift))
        photo = cover(frame, pw, ph, zoom=zoom).convert("RGBA")
        edge = int(4 + 12 * lift)
        piece = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        piece.paste((255, 255, 255, 255), ((W - pw) // 2 - edge, (H - ph) // 2 - edge,
                                           (W + pw) // 2 + edge, (H + ph) // 2 + edge))
        piece.alpha_composite(photo, ((W - pw) // 2, (H - ph) // 2))
    # it shrinks as it lifts off, so even a close-up leaves ground around it,
    # then pops on the downbeat with its own sound
    scale = 1 - 0.3 * lift
    tilt = 0.0
    if after:
        b = t - intro_end
        scale *= 0.9 + 0.1 * overshoot(b / 0.3)
        tilt = -3 * min(1.0, b / 0.2)
    if scale < 0.999:
        piece = piece.resize((int(piece.width * scale), int(piece.height * scale)), Image.BILINEAR)
    if tilt:
        piece = piece.rotate(tilt, resample=Image.BICUBIC)
    offset = ((W - piece.width) // 2, int((H - piece.height) * 0.45))
    shadow = Image.new("RGBA", piece.size, (0, 0, 0, 0))
    shadow.putalpha(piece.getchannel("A").point(lambda v: v * 0.35 * lift))
    out.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(12)), (offset[0] + 8, offset[1] + 14))
    out.alpha_composite(piece, offset)
    return out.convert("RGB")


def feed_frame(ctx, t, posts, intro_end):
    """Swiping through a feed: each new clip pushes the last one up and away,
    so a phrase cut short reads as a flick to the next post."""
    k = max(i for i, (_, start) in enumerate(posts) if start <= t) if posts[0][1] <= t else 0
    e, start = posts[k]
    end = posts[k + 1][1] if k + 1 < len(posts) else intro_end
    if k == len(posts) - 1 and t >= intro_end - STICKER_IN:
        return sticker_moment(ctx, e, t, intro_end)
    current = feed_post(ctx, e, t, min(1.0, (t - start) / max(1e-3, end - start)), first=k == 0)
    swipe = 0.16
    if k == 0 or t - start >= swipe:
        return current
    prev, prev_start = posts[k - 1]
    u = ease_out((t - start) / swipe)
    shift = int(H * u)
    before = feed_post(ctx, prev, t, 1.0, first=k == 1)
    canvas = Image.new("RGB", (W, H), INK)
    canvas.paste(before, (0, -shift))
    canvas.paste(current, (0, H - shift))
    return canvas


def director_frame(ctx, t, plan, hud):
    intro_end = (2 if ctx.total_t > 20 else 1) * BAR
    posts = feed_posts(ctx, intro_end)
    if posts and t < intro_end:
        return feed_frame(ctx, t, posts, intro_end)
    if posts:
        accent = accent_after_feed(ctx, posts[-1][0], intro_end)
        if accent and t < accent.end_t:
            return sticker_moment(ctx, posts[-1][0], t, intro_end)
    shot, start, end, energy = next((p for p in plan if p[1] <= t < p[2]), plan[-1])
    long_run = any(len(r) >= 4 and r[0].t <= t < r[-1].end_t + 0.3 for r in ctx.runs)
    if long_run and shot in ("cutout", "sticker"):
        # a roll is the moment: show its strip on a clean ground instead of the clones
        rng = np.random.default_rng(getattr(ctx, "seed", 0))
        canvas = Image.new("RGB", (W, H), BACKDROPS[int(rng.integers(len(BACKDROPS)))])
        canvas = repeat_moment(canvas, ctx, t, dim=False)
    else:
        canvas = SHOTS[shot](ctx, t, (start, end))
        if shot not in ("cutout", "sticker"):  # those already show repeats as clones / a single sticker
            canvas = repeat_moment(canvas, ctx, t)
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
    master_fx = arrangement.get("fx")
    audio = render_audio(events, sources, total, [pitch[i] for i in order] if pitch else None, fx=master_fx)
    wav_path = out_dir / "mix.wav"
    with wave.open(str(wav_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes((audio * 32767).astype(np.int16).tobytes())
    ctx = Ctx(events, sources, total, arrangement.get("title"))
    from lab_cutout import attach_masks
    attach_masks(sources, src_dir)
    sys.path.insert(0, str(Path(__file__).parent))
    frames = total // SPF
    for seed in seeds:
        ctx.seed = seed
        ctx.feed = bool(feed_posts(ctx, (2 if ctx.total_t > 20 else 1) * BAR))
        solo = {int(e.t / BAR + 1e-6) for e in ctx.backing}
        plan = plan_shots(total / SR, seed, arrangement.get("sections"), solo)
        forced = __import__("os").environ.get("OTO_SHOTS")  # e.g. "cutout,sticker" to audition shots
        if forced:
            names_forced = forced.split(",")
            plan = [(names_forced[i % len(names_forced)], a, b, en) for i, (_, a, b, en) in enumerate(plan)]
        hud = False
        look = "bold" if seed % 3 else "paper"
        print(f"seed {seed}: look={look} hud={hud} " + " > ".join(p[0] for p in plan))
        finish = None
        if __import__("os").environ.get("OTO_LOOK") == "pop":
            from lab_look import PopGlitch
            finish = PopGlitch(ctx, plan, seed)
        out = out_dir / f"seed{seed}.mp4"
        proc = subprocess.Popen([FFMPEG, "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                                 "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-i", str(wav_path),
                                 "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-preset", "fast",
                                 "-c:a", "aac", "-b:a", "160k", "-shortest", str(out)], stdin=subprocess.PIPE)
        for f in range(frames):
            t = f / FPS
            img = director_frame(ctx, video_time(t, master_fx), plan, hud)
            img = backing_stickers(img, ctx, video_time(t, master_fx), plan)
            img = video_post(img, t, master_fx)
            if finish and t < ctx.total_t - 1.3:
                img = finish.apply(img, t)
            img = draw_op(img, ctx, t, look)
            img = draw_ed(img, ctx, t, look)
            proc.stdin.write(img.convert("RGB").tobytes())
        proc.stdin.close()
        proc.wait()
        print("wrote", out)


if __name__ == "__main__":
    main()
