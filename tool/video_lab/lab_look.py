"""'Pop glitch' look: a finishing layer over any shot, driven by the sound.

Inspired by the graphic language of recent Vocaloid music videos (a small
pastel/navy palette, dithered pixels, kinetic typography, glitch hits), not
by any specific work's images or song:

  grade    picture mapped onto a 4-colour palette with ordered dithering
  type     every melody note stamps the next character of the sound's name
           (呼・び・声 …) in a new face, size, angle and place; a phrase is
           typed out along the bottom like a lyric line
  glitch   each snare hit shifts colour channels and slides picture bands
  shake    each kick nudges the frame
  flash    a section that gets louder opens on an inverted frame
  hud      small bar / tempo / title text in the corners
"""

import math

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps

SR = 48_000
BAR = 90_000 / SR
NAVY = (27, 26, 74)
PINK = (255, 95, 162)
BLUSH = (255, 190, 214)
CYAN = (140, 230, 255)
WHITE = (255, 255, 255)
FACES = ["C:/Windows/Fonts/YuGothB.ttc", "C:/Windows/Fonts/UDDigiKyokashoN-B.ttc",
         "C:/Windows/Fonts/BIZ-UDMinchoM.ttc", "C:/Windows/Fonts/BIZ-UDGothicB.ttc"]
MONO = "C:/Windows/Fonts/BIZ-UDGothicR.ttc"
BAYER = (np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]) + 0.5) / 16
_fonts = {}


def font(path, size):
    key = (path, size)
    if key not in _fonts:
        _fonts[key] = ImageFont.truetype(path, size)
    return _fonts[key]


PALETTES = {
    "pink": [NAVY, PINK, BLUSH, WHITE],
    "cyan": [NAVY, (60, 120, 220), CYAN, WHITE],
}


def grade(img, scale=3, palette="pink"):
    """Luminance -> a 4-colour palette with a 4x4 ordered dither at 1/scale resolution."""
    w, h = img.size
    small = np.asarray(img.resize((w // scale, h // scale)).convert("L"), np.float32) / 255
    small = np.clip((small - 0.08) * 1.25, 0, 1)
    sh, sw = small.shape
    thresh = np.tile(BAYER, (sh // 4 + 1, sw // 4 + 1))[:sh, :sw]
    level = np.clip((small * 3 + thresh - 0.5).round(), 0, 3).astype(int)
    pal = np.array(PALETTES[palette], np.uint8)
    return Image.fromarray(pal[level]).resize((w, h), Image.NEAREST)


class PopGlitch:
    def __init__(self, ctx, plan, seed):
        self.ctx = ctx
        self.plan = plan
        self.seed = seed
        events = ctx.events
        # a melody note starts where its raw attack is (the pitched body follows it)
        self.notes = sorted((e for e in events if e.role == "melody" and not (e.notes or e.midi)),
                            key=lambda e: e.t)
        self.phrases = [e for e in events if e.role == "phrase"]
        self.snares = [e.t for e in events if e.role == "snare"]
        self.kicks = [e.t for e in events if e.role == "kick"]
        counters = {}
        self.char_of = {}
        for e in self.notes:
            name = [c for c in ctx.names[e.c] if not c.isspace()] or ["♪"]
            k = counters.get(e.c, 0)
            self.char_of[e.idx] = name[k % len(name)]
            counters[e.c] = k + 1

    def apply(self, img, t):
        w, h = img.size
        img = grade(img, palette=self._palette(t))
        img = self._glitch(img, t)
        img = self._shake(img, t)
        layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        self._phrase_line(layer, t)
        self._note_chars(layer, t)
        self._hud(layer, t)
        img = Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")
        return self._flash(img, t)

    def _palette(self, t):
        """Calm sections pink, busier ones cyan, the loudest trade colours every bar."""
        energy = next((p[3] for p in self.plan if p[1] <= t < p[2]), "calm")
        if energy == "high":
            return "pink" if int(t / BAR) % 2 else "cyan"
        return "cyan" if energy == "mid" else "pink"

    # -- sound-driven layers --------------------------------------------------

    def _note_chars(self, layer, t):
        recent = [e for e in self.notes if 0 <= t - e.t < 0.45][-3:]
        for n, e in enumerate(recent):
            rng = np.random.default_rng(self.seed * 1_000 + e.idx)
            age = t - e.t
            ch = self.char_of[e.idx]
            size = int(rng.choice([220, 300, 380]))
            f = font(FACES[int(rng.integers(len(FACES)))], size)
            pop = 1.35 - 0.35 * min(1, age / 0.06)
            fade = 1 if age < 0.3 else max(0, 1 - (age - 0.3) / 0.15)
            tile = Image.new("RGBA", (int(size * 1.6), int(size * 1.6)), (0, 0, 0, 0))
            d = ImageDraw.Draw(tile)
            cx = cy = tile.width // 2
            colours = [PINK, CYAN, WHITE, NAVY]
            main = colours[int(rng.integers(len(colours)))]
            ghost = colours[(colours.index(main) + 1) % len(colours)]
            d.text((cx + 10, cy + 8), ch, font=f, fill=(*ghost, int(200 * fade)), anchor="mm")
            d.text((cx, cy), ch, font=f, fill=(*main, int(255 * fade)), anchor="mm")
            tile = tile.rotate(float(rng.choice([-14, -7, 0, 7, 14])), resample=Image.BICUBIC)
            tile = tile.resize((max(1, int(tile.width * pop)), max(1, int(tile.height * pop))))
            x = int(rng.uniform(0.15, 0.85) * layer.width) - tile.width // 2
            y = int(rng.uniform(0.15, 0.75) * layer.height) - tile.height // 2
            layer.alpha_composite(tile, (max(-tile.width // 2, x), max(-tile.height // 2, y)))

    def _phrase_line(self, layer, t):
        live = [e for e in self.phrases if e.t <= t < e.end_t + 0.3]
        if not live:
            return
        e = live[-1]
        name = self.ctx.names[e.c]
        shown = max(1, math.ceil(len(name) * min(1, (t - e.t) / max(0.2, e.end_t - e.t) * 1.6)))
        d = ImageDraw.Draw(layer)
        f = font(FACES[0], 64)
        y = int(layer.height * 0.83)
        d.rectangle((0, y - 50, layer.width, y + 50), fill=(*NAVY, 200))
        d.text((40, y), name[:shown] + ("_" if shown < len(name) else ""), font=f, fill=(*WHITE, 255), anchor="lm")

    def _glitch(self, img, t):
        hit = [s for s in self.snares if 0 <= t - s < 0.08]
        if not hit:
            return img
        rng = np.random.default_rng(int(hit[-1] * 1_000) + self.seed)
        a = np.asarray(img).copy()
        a[..., 0] = np.roll(a[..., 0], 14, axis=1)
        a[..., 2] = np.roll(a[..., 2], -14, axis=1)
        for _ in range(6):
            y0 = int(rng.integers(0, a.shape[0] - 40))
            hgt = int(rng.integers(12, 70))
            a[y0:y0 + hgt] = np.roll(a[y0:y0 + hgt], int(rng.integers(-60, 60)), axis=1)
        return Image.fromarray(a)

    def _shake(self, img, t):
        hit = [k for k in self.kicks if 0 <= t - k < 0.05]
        if not hit:
            return img
        dx = int(8 * math.sin(hit[-1] * 97))
        return ImageOps.expand(img, border=10, fill=NAVY).crop((10 - dx, 10, 10 - dx + img.width, 10 + img.height))

    def _flash(self, img, t):
        for i, (_, start, _, energy) in enumerate(self.plan):
            prev = self.plan[i - 1][3] if i else "calm"
            louder = {"calm": 0, "mid": 1, "high": 2}[energy] > {"calm": 0, "mid": 1, "high": 2}[prev]
            if louder and 0 <= t - start < 2 / 30:
                return ImageOps.invert(img)
        return img

    def _hud(self, layer, t):
        d = ImageDraw.Draw(layer)
        f = font(MONO, 22)
        bar = int(t / BAR) + 1
        total = int(round(self.ctx.total_t / BAR))
        d.text((24, 22), f"BAR {bar:02d}/{total:02d}   \u2669=128", font=f, fill=(*WHITE, 220))
        d.text((layer.width - 24, layer.height - 30), f"{t:05.2f}", font=f, fill=(*WHITE, 220), anchor="ra")
        title = self.ctx.title or "OTOGRASHI"
        for i, ch in enumerate(title[:14]):
            d.text((layer.width - 36, 90 + i * 28), ch, font=f, fill=(*CYAN, 230), anchor="mm")
