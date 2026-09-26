"""Arrange clips into a 30-second MAD that stays recognisably *them*.

Structure (16 bars at 128 BPM):
  bars 1-2   introductions: each clip's own phrase, the first one stuttered in
  bars 3-4   beat + bass sung by a low voice, tail echoes as fills
  bars 5-12  the melody sung continuously by the lead voice, chops in rests
  bars 13-14 break: drums drop, the longest phrase plays raw up front
  bars 15-16 climax: the hook again, full kit, every clip stutters at the end

Every event says where in which clip it reads, so the renderer shows exactly
the moment being heard.

    python tool/video_lab/mad_arranger.py SONG SRC_DIR OUT.json
"""

import json
import sys
from pathlib import Path

import numpy as np

from arrange_score import SCORES, bundled_score, load
from lab_audio import SR, Voice

BEAT = 22_500
BAR = BEAT * 4
SIXTEENTH = BEAT // 4
BARS = 16


class Arrangement:
    def __init__(self, voices):
        self.voices = voices
        self.events = []

    def add(self, clip, start, dur, src, treatment, role, gain, src_dur=None, **extra):
        voice = self.voices[clip]
        src = int(max(0, min(src, len(voice.pcm) - 1)))
        dur = int(max(SIXTEENTH // 2, dur))
        e = {"assetId": f"clip-{clip}", "destinationStartSample": int(start), "durationSamples": dur,
             "sourceStartSample": src, "sourceDurationSamples": int(src_dur or dur), "gain": round(gain, 3),
             "fades": {"fadeInSamples": 96, "fadeOutSamples": 600}, "treatment": treatment, "role": role}
        e.update(extra)
        self.events.append(e)

    # -- building blocks ------------------------------------------------------

    def phrase(self, clip, start, region, gain=1.0, limit=2.2):
        a, b = region
        dur = min(b - a, int(limit * SR))
        self.add(clip, start, dur, a, "phrase", "phrase", gain)
        return dur

    def stutter_head(self, clip, start, region, times=3, step=SIXTEENTH, gain=0.9):
        """あっ、あっ、あっ — the first syllable on 16ths before the phrase."""
        chop = min(int(0.11 * SR), region[1] - region[0])
        for k in range(times):
            self.add(clip, start + k * step, chop, region[0], "rhythm", "chop", gain)
        return times * step

    def tail_echo(self, clip, start, region, times=3, step=BEAT // 2, gain=0.7):
        """…とう、とう、とう — the last syllable repeated and fading."""
        chop = min(int(0.18 * SR), region[1] - region[0])
        for k in range(times):
            self.add(clip, start + k * step, chop, region[1] - chop, "rhythm", "chop", gain * (0.8 ** k))

    def sung_line(self, clip, cursor, notes, bar_offset, gain, role, tune=1.0):
        """Sing notes with the clip's speech moving forward continuously.

        cursor walks through the clip's voiced regions; when a region runs out
        the next one continues, so the words keep advancing instead of
        restarting on every note. Returns the updated cursor."""
        regions = sorted(self.voices[clip].regions)
        ri, pos = cursor
        span = []  # notes of the current continuous event

        def flush():
            if not span:
                return
            start = span[0][0]
            end = span[-1][0] + span[-1][1]
            rel = [(n0 - start, midi) for n0, _, midi, _ in span]
            self.add(clip, start, end - start, span[0][3], "sung", role, gain,
                     notes=[[int(o), float(m)] for o, m in rel], tune=tune)
            span.clear()

        for b, length, midi in notes:
            start = int((b + bar_offset * 4) * BEAT)
            dur = int(length * BEAT) - 300
            if span and start - (span[-1][0] + span[-1][1]) > BEAT // 4:
                flush()  # a rest: the words pause and resume where they stopped
            # inside one event the clip plays at 1x, so its read position is
            # tied to output time; that is what keeps picture and sound together
            here = span[0][3] + (start - span[0][0]) if span else pos
            if here + dur > regions[ri][1]:  # this region is spent: continue with the next
                flush()
                ri = (ri + 1) % len(regions)
                here = regions[ri][0]
            if span:  # legato: stretch the previous note to meet this one
                prev = span[-1]
                span[-1] = (prev[0], start - prev[0], prev[2], prev[3])
            span.append((start, dur, midi, span[0][3] if span else here))
            pos = here + dur
        flush()
        return ri, pos

    def sampled_line(self, clip, cursor, notes, bar_offset, gain, role, ref_midi):
        """For clips with no steady pitch (mumbles, noises): play them sampler-style,
        pitched by speed, but keep reading forward so no two notes repeat the same spot."""
        regions = sorted(self.voices[clip].regions, key=lambda r: r[0])
        ri, pos = cursor
        for b, length, midi in notes:
            rate = float(np.clip(2 ** ((midi - ref_midi) / 12), 0.45, 2.0))
            dur = int(length * BEAT) - 600
            need = int(dur * rate)
            if pos + need > regions[ri][1]:
                ri = (ri + 1) % len(regions)
                pos = regions[ri][0]
            self.add(clip, (b + bar_offset * 4) * BEAT, dur, pos, "rhythm", role, gain, rate=round(rate, 4))
            pos += need
        return ri, pos

    def drums(self, kit, bar_from, bar_to, snare=True, hats=True, gain=1.0):
        for beat in range(bar_from * 4, bar_to * 4):
            clip, src = kit["kick"]
            if beat % 1 == 0 and (beat % 2 == 0 or not snare):
                self.add(clip, beat * BEAT, int(0.16 * SR), src, "rhythm", "kick", 0.95 * gain, rate=0.55)
            if snare and beat % 2 == 1:
                clip, src = kit["snare"]
                self.add(clip, beat * BEAT, int(0.12 * SR), src, "rhythm", "snare", 0.75 * gain)
            if hats:
                clip, src = kit["hat"]
                self.add(clip, beat * BEAT + BEAT // 2, int(0.045 * SR), src, "rhythm", "hat",
                         0.35 * gain, rate=1.6)


def main():
    song, src_dir, out = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    score = bundled_score() if song == "lilac" else SCORES[song]
    names = (src_dir / "names.txt").read_text(encoding="utf-8").split()
    voices = []
    for i in range(len(names)):
        pcm = load(src_dir / f"s{i}.wav")
        voices.append(Voice(pcm * (0.9 / max(1e-4, float(np.abs(pcm).max())))))
    arr = Arrangement(voices)
    n = len(voices)

    # the lead voice sings the melody: the clip with the most voiced sound
    lead = max(range(n), key=lambda i: voices[i].voiced_seconds())
    others = [i for i in range(n) if i != lead]
    # bass: the lowest steady voice, else the non-lead clip with the most sound
    steady = [i for i in others if voices[i].voiced_seconds() > 0.3]
    if steady:
        bass = min(steady, key=lambda i: voices[i].median_midi())
    elif others:
        bass = max(others, key=lambda i: sum(b - a for a, b in voices[i].regions))
    else:
        bass = lead
    sampled_bass = voices[bass].voiced_seconds() <= 0.3
    # transpose the whole song to the lead voice's own register (a key change)
    melody = score["melody"]
    shift = int(round(voices[lead].median_midi() - np.median([m for _, _, m in melody])))
    sung = [(b, l, m + shift) for b, l, m in melody]
    bass_line = score.get("bass_notes") or [(h * 2, 2, r) for h, r in enumerate(score["roots"])]
    bass_mid = voices[bass].median_midi() if not sampled_bass else 45.0
    bass_notes = []
    for b, l, m in bass_line:
        m += shift
        while m > bass_mid + 6:
            m -= 12
        while m < bass_mid - 18:
            m += 12
        bass_notes.append((b, l, m))

    # drum kit from the sharpest attacks, spread across clips
    attacks = sorted(((voices[i].rms[o // 480] if voices[i].onsets else 0, i, o)
                      for i in range(n) for o in voices[i].onsets[:2]), reverse=True)
    if not attacks:
        attacks = [(0, i, voices[i].regions[0][0]) for i in range(n)]
    pick = lambda k: (attacks[k % len(attacks)][1], attacks[k % len(attacks)][2])
    kit = {"kick": pick(0), "snare": pick(1 if len(attacks) > 1 else 0), "hat": pick(2)}

    longest = {i: voices[i].regions[0] for i in range(n)}  # longest region per clip

    # bars 1-2: introductions, first one stuttered in
    t = 0
    order = [lead] + others
    for k, i in enumerate(order):
        if t >= 2 * BAR - BEAT:
            break
        if k == 0:
            t += arr.stutter_head(i, t, longest[i])
        dur = arr.phrase(i, t, longest[i], gain=1.0, limit=1.4)
        t = int(np.ceil((t + dur) / BEAT)) * BEAT
    arr.drums(kit, 1, 2, snare=False, hats=False, gain=0.7)

    # bars 3-4: beat + bass, tail echoes as fills
    arr.drums(kit, 2, 4)
    bass_cursor = (0, sorted(voices[bass].regions)[0][0])

    def bass_part(cursor, notes, bar_offset, gain):
        if sampled_bass:
            return arr.sampled_line(bass, cursor, notes, bar_offset, gain, "bass", bass_mid)
        return arr.sung_line(bass, cursor, notes, bar_offset, gain, "bass")

    first_two = [(b - 0, l, m) for b, l, m in bass_notes if b < 8]
    bass_cursor = bass_part(bass_cursor, first_two, 2, 0.6)
    arr.tail_echo(order[-1], 3 * BAR + 2 * BEAT, longest[order[-1]], times=4, step=BEAT // 2, gain=0.6)

    # bars 5-12: the melody, sung continuously by the lead voice
    arr.drums(kit, 4, 12)
    lead_cursor = (0, sorted(voices[lead].regions)[0][0])
    lead_cursor = arr.sung_line(lead, lead_cursor, sung, 4, 0.95, "melody")
    bass_cursor = bass_part(bass_cursor, bass_notes, 4, 0.55)
    # chops answer in the gaps of bars 9-12
    for bar, clip in ((8, others[0] if others else lead), (10, others[-1] if others else lead)):
        arr.stutter_head(clip, bar * BAR + 3 * BEAT, longest[clip], times=4, step=SIXTEENTH, gain=0.55)

    # bars 13-14: break — the longest phrase raw and up front
    star = max(range(n), key=lambda i: longest[i][1] - longest[i][0])
    arr.add(kit["kick"][0], 12 * BAR, int(0.16 * SR), kit["kick"][1], "rhythm", "kick", 0.9, rate=0.55)
    dur = arr.phrase(star, 12 * BAR + BEAT // 2, longest[star], gain=1.0, limit=2.4)
    arr.tail_echo(star, 12 * BAR + BEAT // 2 + dur, longest[star], times=3, step=BEAT // 2, gain=0.8)
    quiet_bass = [(b, l, m) for b, l, m in bass_notes if 24 <= b < 32]
    bass_part(bass_cursor, [(b - 24, l, m) for b, l, m in quiet_bass], 12, 0.3)

    # bars 15-16: climax — the hook again, full kit, everyone stutters at the end
    arr.drums(kit, 14, 16)
    hook = [(b, l, m) for b, l, m in sung if b < 8]
    arr.sung_line(lead, lead_cursor, hook, 14, 1.0, "melody")
    bass_part(bass_cursor, [(b, l, m) for b, l, m in bass_notes if b < 8], 14, 0.55)
    for k, i in enumerate(order):
        arr.stutter_head(i, 15 * BAR + 2 * BEAT + k * SIXTEENTH * 2, longest[i], times=2,
                         step=SIXTEENTH, gain=0.7)

    arr.events.sort(key=lambda e: e["destinationStartSample"])
    recipe = {"arrangement": {"totalSamples": BARS * BAR, "sourceAssetIds": [f"clip-{i}" for i in range(n)],
                              "events": arr.events, "title": score["title"],
                              # lets the video director follow the song's own structure
                              "sections": [[0, 2, "calm"], [2, 4, "mid"], [4, 8, "mid"], [8, 12, "high"],
                                           [12, 14, "calm"], [14, 16, "high"]]}}
    out.write_text(json.dumps(recipe, ensure_ascii=False), encoding="utf-8")
    roles = {}
    for e in arr.events:
        roles[e["role"]] = roles.get(e["role"], 0) + 1
    print(f"lead={names[lead]} bass={names[bass]} shift={shift} kit={ {k: names[v[0]] for k, v in kit.items()} }",
          roles, flush=True)


if __name__ == "__main__":
    main()
