"""Voice analysis and time-preserving pitch correction for the video lab.

The point is to keep a friend's voice recognisable while it sings: speech
keeps moving forward in time, consonants and breath stay untouched, and only
voiced frames are pulled toward the melody note.
"""

import math

import numpy as np

SR = 48_000
HOP = 480      # 10 ms analysis frames
WIN = 1_920    # 40 ms analysis window


def midi_of(f0):
    return 69 + 12 * math.log2(f0 / 440)


def yin_frame(x, lo, hi, threshold=0.2):
    """Returns (midi, clarity) for one window; clarity near 1 means clearly voiced."""
    x = x - x.mean()
    w = len(x) - hi
    e0 = float(np.sum(x[:w] ** 2))
    if e0 < 1e-7:
        return 0.0, 0.0
    cs = np.concatenate([[0.0], np.cumsum(x ** 2)])
    taus = np.arange(hi + 1)
    etau = cs[taus + w] - cs[taus]
    nfft = 1 << (2 * len(x) - 1).bit_length()
    corr = np.fft.irfft(np.fft.rfft(x, nfft) * np.conj(np.fft.rfft(x[:w], nfft)), nfft)[:hi + 1]
    d = np.maximum(e0 + etau - 2 * corr, 0)
    cmnd = np.ones_like(d)
    cmnd[1:] = d[1:] * taus[1:] / np.maximum(np.cumsum(d[1:]), 1e-12)
    below = np.where(cmnd[lo:] < threshold)[0]
    tau = lo + (below[0] if len(below) else int(np.argmin(cmnd[lo:])))
    while tau + 1 <= hi and cmnd[tau + 1] < cmnd[tau]:
        tau += 1
    return midi_of(SR / tau), 1 - float(cmnd[tau])


class Voice:
    """Per-10ms pitch, voicing and loudness of one clip, plus its audible regions."""

    def __init__(self, pcm):
        self.pcm = pcm
        lo, hi = SR // 800, SR // 65
        n = max(1, (len(pcm) - WIN) // HOP + 1)
        self.midi = np.zeros(n)
        self.voiced = np.zeros(n, bool)
        self.rms = np.zeros(n)
        for i in range(n):
            seg = pcm[i * HOP:i * HOP + WIN]
            if len(seg) < WIN:
                break
            self.rms[i] = float(np.sqrt(np.mean(seg ** 2)))
            self.midi[i], clarity = yin_frame(seg, lo, hi)
            self.voiced[i] = clarity > 0.6
        loud = self.rms > 0.12 * max(1e-6, self.rms.max())
        self.voiced &= loud
        # smooth the pitch of voiced frames so vibrato does not become noise
        smooth = self.midi.copy()
        for i in np.where(self.voiced)[0]:
            near = self.midi[max(0, i - 2):i + 3][self.voiced[max(0, i - 2):i + 3]]
            smooth[i] = float(np.median(near))
        self.midi = smooth
        self.onsets = self._onsets()
        self.regions = self._regions(loud) or [(o, min(len(pcm), o + int(0.15 * SR))) for o in self.onsets]
        if not self.regions:  # nothing stands out: use the whole clip
            self.regions = [(0, len(pcm))]

    def _regions(self, loud):
        """Audible stretches (merged across <120 ms gaps), longest first."""
        spans, start, gap = [], None, 0
        for i, on in enumerate(list(loud) + [False]):
            if on:
                start = i if start is None else start
                gap = 0
            elif start is not None:
                gap += 1
                if gap > 12 or i == len(loud):
                    end = i - gap + 1
                    if end - start >= 8:
                        spans.append((start * HOP, end * HOP + WIN))
                    start, gap = None, 0
        return sorted(spans, key=lambda s: s[0] - s[1])

    def _onsets(self):
        """Sharp level jumps, strongest first: raw material for drums and stutters."""
        peak = max(1e-6, self.rms.max())
        found = []
        for i in range(3, len(self.rms)):
            jump = self.rms[i] - self.rms[i - 3]
            if self.rms[i] > 0.25 * peak and jump > 0.15 * peak:
                if not found or i - found[-1][1] > 10:
                    found.append((jump, i))
        return [i * HOP for _, i in sorted(found, reverse=True)]

    def voiced_runs(self, min_len=0.06):
        """Stretches that hold a pitch (gaps up to 20 ms bridged), in time order."""
        runs, start, gap = [], None, 0
        for i, v in enumerate(list(self.voiced) + [False] * 3):
            if v:
                start = i if start is None else start
                gap = 0
            elif start is not None:
                gap += 1
                if gap > 2:
                    end = i - gap + 1
                    if (end - start) * HOP >= min_len * SR:
                        runs.append((start * HOP, end * HOP))
                    start, gap = None, 0
        return runs

    def pitch_spread(self):
        """10-90% range of the detected pitch in semitones: small for a steady,
        tuneful sound, large for bells, noise or wildly gliding cries."""
        v = self.midi[self.voiced]
        return float(np.percentile(v, 90) - np.percentile(v, 10)) if len(v) > 4 else 99.0

    def steadiest(self, frames=10):
        """Sample position of the most stable 100 ms of voiced sound."""
        best, where = 1e9, None
        for i in range(len(self.midi) - frames):
            if self.voiced[i:i + frames].all():
                spread = float(np.std(self.midi[i:i + frames]))
                if spread < best:
                    best, where = spread, i
        return (where if where is not None else int(np.argmax(self.rms))) * HOP

    def syllables(self, min_len=0.06):
        """Split audible regions at loudness valleys: コ / ケ / コッ / コー, あ / り / が / と / う.
        Returns (start, end, median_midi or None) in time order."""
        smooth = np.convolve(self.rms, np.ones(3) / 3, "same")
        out = []
        for a, b in sorted(self.regions):
            fa, fb = a // HOP, min(len(smooth), b // HOP)
            cuts = [fa]
            for i in range(fa + 3, fb - 3):
                left = smooth[max(fa, i - 15):i].max()
                right = smooth[i + 1:min(fb, i + 16)].max()
                if smooth[i] <= smooth[i - 1] and smooth[i] <= smooth[i + 1]                         and smooth[i] < 0.7 * min(left, right) and i - cuts[-1] >= min_len * 100:
                    cuts.append(i)
            cuts.append(fb)
            for s0, s1 in zip(cuts, cuts[1:]):
                if (s1 - s0) * HOP < min_len * SR:
                    continue
                v = self.midi[s0:s1][self.voiced[s0:s1]]
                out.append((s0 * HOP, s1 * HOP, float(np.median(v)) if len(v) >= 3 else None))
        return out

    def voiced_seconds(self):
        return float(self.voiced.sum()) * HOP / SR

    def median_midi(self):
        v = self.midi[self.voiced]
        return float(np.median(v)) if len(v) else 60.0


def sing(voice, src_start, duration, notes, tune=1.0, rate=1.0, accent=True, ref=None):
    """Pitch-synchronous overlap-add (TD-PSOLA) with the source moving at 1x.

    notes: [(offset_samples, midi), ...] target steps from the event start.
    ref: when given, the whole event is moved by (note - ref) semitones so the
    sound keeps its own rise and fall, flattened only by `tune`.
    In voiced frames, two-period grains are cut at the source's own pitch
    marks and laid down at the target period, which moves the pitch while
    keeping the voice's timbre. Unvoiced frames (consonants, breath) are
    copied through untouched, so the words stay intelligible.
    """
    pcm = voice.pcm
    out = np.zeros(duration + 4_096)
    norm = np.zeros(duration + 4_096)
    note_i = 0
    t = 0.0
    mark = None  # last source pitch mark, kept continuous between grains

    def lay(centre_src, at, half):
        a, b = int(centre_src) - half, int(centre_src) + half
        if a < 0 or b > len(pcm) or half < 8:
            return
        w = np.hanning(2 * half)
        o = int(at) - half
        lo = max(0, -o)
        hi = min(2 * half, len(out) - o)
        if hi <= lo:
            return
        out[o + lo:o + hi] += pcm[a + lo:a + hi] * w[lo:hi]
        norm[o + lo:o + hi] += w[lo:hi]

    while t < duration:
        while note_i + 1 < len(notes) and notes[note_i + 1][0] <= t:
            note_i += 1
        s = src_start + t * rate  # rate < 1 stretches a short voiced run without changing pitch
        f = int(min(max(s // HOP, 0), len(voice.midi) - 1))
        if voice.voiced[f]:
            src_midi = voice.midi[f]
            if ref is not None:
                # move the syllable as a whole, then flatten its own glide by `tune`
                # (0 keeps the natural rise and fall, 1 is a flat autotuned note)
                moved = src_midi + float(np.clip(notes[note_i][1] - ref, -12, 12))
                goal = moved + tune * (notes[note_i][1] - moved)
            else:
                goal = float(np.clip(src_midi + (notes[note_i][1] - src_midi) * tune, src_midi - 12, src_midi + 12))
            p_src = SR / (440 * 2 ** ((src_midi - 69) / 12))
            p_out = SR / (440 * 2 ** ((goal - 69) / 12))
            if mark is None or abs(mark - s) > p_src:
                mark = s
            while mark < s - p_src / 2:
                mark += p_src
            # snap to the local peak so successive grains stay in phase
            lo = int(max(0, mark - p_src * 0.25))
            hi = int(min(len(pcm) - 1, mark + p_src * 0.25))
            if hi > lo:
                mark = lo + int(np.argmax(pcm[lo:hi]))
            lay(mark, t, int(p_src))
            t += p_out
        else:
            mark = None
            lay(s, t, 240)
            t += 240
    out = out[:duration] / np.maximum(norm[:duration], 0.35)
    if accent:
        # a small dip before each note and a lift on its attack make the tune's rhythm audible
        env = np.ones(duration)
        for off, _ in notes[1:]:
            a = int(off)
            if 480 < a < duration - 1_440:
                env[a - 480:a] *= np.linspace(1, 0.35, 480)
                env[a:a + 1_440] *= np.linspace(0.35, 1.15, 1_440)
        out *= env
    return out.astype(np.float32)
