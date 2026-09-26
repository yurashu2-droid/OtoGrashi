"""Arrange clips into a 30-second MAD that stays recognisably *them*.

Structure (16 bars at 128 BPM):
  bars 1-2   introductions: each clip's own phrase, the first one stuttered in
  bars 3-4   beat + bass sung by a low voice, tail echoes as fills
  bars 5-12  the melody sung continuously by the lead voice, chops in rests;
             clips with no part of their own play quietly behind it
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
SEED = int(__import__("os").environ.get("OTO_SEED", "5"))  # picks the effects per slot
FLATTEN = float(__import__("os").environ.get("OTO_FLATTEN", "0.6"))  # 0 natural glide … 1 flat
GUIDE = float(__import__("os").environ.get("OTO_GUIDE", "0"))  # forced-melody layer, 0 = off


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
        """Sing notes with the clip moving forward through its *voiced* sound.

        The cursor walks the clip's voiced runs in order, so the words keep
        advancing instead of restarting on every note, but a note never lands
        on a consonant, breath or silence: when the current run cannot carry
        it, the cursor skips to the next run. A run shorter than its note is
        read more slowly (pitch unchanged) rather than letting the note die.
        Returns the updated cursor."""
        voice = self.voices[clip]
        runs = voice.voiced_runs() or sorted(voice.regions)
        ri, pos = cursor
        ri %= len(runs)
        pos = min(max(pos, runs[ri][0]), runs[ri][1])
        span = []  # (start, dur, midi, src, rate) notes of the current continuous event

        def flush():
            if not span:
                return
            start, rate = span[0][0], span[0][4]
            end = span[-1][0] + span[-1][1]
            rel = [(n0 - start, midi) for n0, _, midi, _, _ in span]
            extra = {"rate": round(rate, 4)} if rate != 1.0 else {}
            self.add(clip, start, end - start, span[0][3], "sung", role, gain,
                     notes=[[int(o), float(m)] for o, m in rel], tune=tune, **extra)
            span.clear()

        for b, length, midi in notes:
            start = int((b + bar_offset * 4) * BEAT)
            dur = int(length * BEAT) - 300
            if span and start - (span[-1][0] + span[-1][1]) > BEAT // 4:
                flush()  # a rest: the words pause and resume where they stopped
            if span and span[0][4] == 1.0:
                pos = span[0][3] + (start - span[0][0])  # 1x inside an event keeps picture and sound tied
            left = runs[ri][1] - pos
            if left < 0.9 * dur:
                if span or left < 0.4 * dur or left < 0.08 * SR:
                    flush()
                    ri = (ri + 1) % len(runs)
                    pos = runs[ri][0]
                    left = runs[ri][1] - pos
            rate = 1.0 if left >= 0.9 * dur else max(0.3, left / dur)
            if span and (rate != 1.0 or span[0][4] != 1.0):
                flush()
            if span:  # legato: stretch the previous note to meet this one
                prev = span[-1]
                span[-1] = (prev[0], start - prev[0], prev[2], prev[3], prev[4])
            span.append((start, dur, midi, span[0][3] if span else pos, rate))
            pos += int(dur * rate)
            if rate != 1.0:
                flush()
        flush()
        return ri, pos

    def syllable_line(self, clip, cursor, notes, bar_offset, gain, role):
        """One note = attack of the next syllable + a sung body.

        Each note opens with the raw first ~40 ms of the next syllable (コッ, ケッ,
        あ, り...), so every note is visibly and audibly a new hit of the real
        sound; its body comes from the clip's clearest voiced stretch, read
        forward note by note and tuned to the note, so the tune is heard. Notes
        stop a little early, so the line never melts into one continuous tone.
        cursor = (syllable index, body read position)."""
        voice = self.voices[clip]
        syl = voice.syllables() or [(a, b, None) for a, b in sorted(voice.regions)]
        runs = voice.voiced_runs() or sorted(voice.regions)
        pure = voice.purity() > 0.6  # whistle-like: retune by speed, not by grains
        body = max(runs, key=lambda r: r[1] - r[0])  # the clearest sustained part
        k, pos = cursor
        pos = body[0] if pos is None else pos
        attack = int(0.04 * SR)
        for b, length, midi in notes:
            start = int((b + bar_offset * 4) * BEAT)
            dur = int(length * BEAT * 0.85)
            a0, a1, _ = syl[k % len(syl)]
            hit = min(attack, a1 - a0, dur // 3)
            self.add(clip, start, hit, a0, "rhythm", role, gain)
            rest = dur - hit
            if rest > int(0.03 * SR):
                span = body[1] - body[0]
                # how fast the body is read: speed-retuned (pure) clips use more source
                if pure:
                    f = int(min(max(pos // 480, 0), len(voice.midi) - 1))
                    here = voice.midi[f] if voice.voiced[f] else voice.median_midi()
                    speed = float(np.clip(2 ** ((midi - here) / 12), 0.5, 2.0))
                else:
                    speed = 1.0
                need = int(rest * speed)
                if need > span:  # a very long note: read the whole body, slower
                    speed *= span / need
                    need, pos = span, body[0]
                elif pos + need > body[1]:
                    pos = body[0]
                if pure:
                    self.add(clip, start + hit, rest, pos, "rhythm", role, gain,
                             rate=round(speed, 4), targetMidiNote=float(midi))
                else:
                    extra = {"rate": round(speed, 4)} if speed != 1.0 else {}
                    self.add(clip, start + hit, rest, pos, "sung", role, gain, notes=[[0, float(midi)]], **extra)
                pos += need
            k += 1
        return (k % len(syl), pos)

    # -- MAD effects (rendered by lab_fx.py) -----------------------------------

    def fx_roll(self, clip, end, syllable, gain=0.8):
        """Build-up roll into `end`: 8ths, then 16ths, then 32nds, pitch rising a fifth."""
        hits, t = [], end - 2 * BEAT
        for length, step in ((BEAT, BEAT // 2), (BEAT // 2, BEAT // 4), (BEAT // 2, BEAT // 8)):
            for k in range(length // step):
                hits.append((t + k * step, step))
            t += length
        for i, (at, step) in enumerate(hits):
            rate = 2 ** (7 * i / max(1, len(hits) - 1) / 12)
            self.add(clip, at, int(step * 0.8), syllable[0], "rhythm", "fx", gain * (0.6 + 0.4 * i / len(hits)),
                     rate=round(rate, 4))

    def fx_riser(self, clip, end, region, beats=4, gain=0.55):
        """A long sound pushed up an octave over `beats`, speeding up as it climbs."""
        dur = beats * BEAT
        self.add(clip, end - dur, dur, region[0], "rhythm", "fx", gain, rate=0.7, glide=12)
        self.events[-1]["fades"] = {"fadeInSamples": dur // 2, "fadeOutSamples": 480}

    def fx_reverse(self, clip, end, region, beats=1.5, gain=0.8):
        """The phrase played backwards, swelling into the downbeat (sucked in)."""
        dur = min(int(beats * BEAT), region[1] - region[0])
        self.add(clip, end - dur, dur, region[0], "rhythm", "fx", gain, reverse=True)
        self.events[-1]["fades"] = {"fadeInSamples": int(dur * 0.85), "fadeOutSamples": 240}

    def fx_scratch(self, clip, start, syllable, beats=2, gain=0.8):
        """Rub a syllable back and forth on 8th notes like a record under a hand."""
        self.add(clip, start, beats * BEAT, syllable[0], "rhythm", "fx", gain,
                 scratch=round(min(0.2, (syllable[1] - syllable[0]) / SR), 3), scratchPeriod=BEAT // 2)

    def fx_stabs(self, clip, syllable, ref, bar_from, bars, root, gain=0.22):
        """Off-beat power chords (root, fifth, octave) cut from one syllable."""
        for bar in range(bar_from, bar_from + bars):
            for beat in range(4):
                at = bar * BAR + beat * BEAT + BEAT // 2
                for interval in (0, 7, 12):
                    self.add(clip, at, int(0.16 * SR), syllable[0], "sung", "stab", gain,
                             notes=[[0, float(root + interval)]], refMidi=round(ref, 2), tune=0.8)

    def guide_line(self, clip, notes, bar_offset, gain):
        """Off when gain is 0.
        The forced-melody layer: the singer's steadiest instant held and
        retuned note by note, in its own timbre, under the moving words."""
        if gain <= 0:
            return
        src = self.voices[clip].steadiest()
        group = []

        def flush():
            if not group:
                return
            start = group[0][0]
            end = group[-1][0] + group[-1][1]
            self.add(clip, start, end - start, src, "sung", "guide", gain,
                     notes=[[int(n0 - start), float(m)] for n0, _, m in group], rate=0.04)
            group.clear()

        for b, length, midi in notes:
            start = int((b + bar_offset * 4) * BEAT)
            dur = int(length * BEAT) - 300
            if group and start - (group[-1][0] + group[-1][1]) > BEAT // 4:
                flush()
            if group:
                g = group[-1]
                group[-1] = (g[0], start - g[0], g[2])
            group.append((start, dur, midi))
        flush()

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
    voices, peaks = [], []
    for i in range(len(names)):
        pcm = load(src_dir / f"s{i}.wav")
        peaks.append(float(np.abs(pcm).max()))
        voices.append(Voice(pcm * (0.9 / max(1e-4, peaks[-1]))))
    arr = Arrangement(voices)
    n = len(voices)
    # a clip that is almost silent would only contribute amplified hiss
    usable = [i for i in range(n) if peaks[i] >= 0.03] or list(range(n))

    # singers: clips that hold a *steady* pitch; bells and noise make poor singers.
    # A second singer trades phrases only if it is nearly as tuneful as the first.
    candidates = sorted((i for i in usable if voices[i].voiced_seconds() > 0.5),
                        key=lambda i: voices[i].pitch_spread())
    singers = candidates[:1]
    if len(candidates) > 1 and voices[candidates[1]].pitch_spread() < min(14.0, max(4.0, 1.5 * voices[candidates[0]].pitch_spread())):
        singers.append(candidates[1])
    if not singers:
        singers = [max(usable, key=lambda i: voices[i].voiced_seconds())]
    lead = singers[0]
    others = [i for i in usable if i != lead]
    # bass: the lowest steady voice outside the singers, else the fullest remaining clip
    pool = [i for i in usable if i not in singers] or others or [lead]
    steady = [i for i in pool if voices[i].voiced_seconds() > 0.3]
    if steady:
        bass = min(steady, key=lambda i: voices[i].median_midi())
    else:
        bass = max(pool, key=lambda i: sum(b - a for a, b in voices[i].regions))
    sampled_bass = voices[bass].voiced_seconds() <= 0.3
    # transpose the whole song to the lead voice's own register (a key change);
    # a second singer moves by whole octaves only, so the key stays the same
    melody = score["melody"]
    centre = float(np.median([m for _, _, m in melody]))
    shift = int(round(voices[lead].median_midi() - centre))

    def octave_fit(m, target):
        while m > target + 6:
            m -= 12
        while m < target - 6:
            m += 12
        return m

    def fit_singer(s):
        """Same key for everyone; each singer takes the whole tune in the octave
        that keeps its highest and lowest notes closest to their own voice."""
        line = [(b, l, m + shift) for b, l, m in melody]
        top, bottom = max(m for _, _, m in line), min(m for _, _, m in line)
        med = voices[s].median_midi()
        octave = min((12 * k for k in range(-3, 4)),
                     key=lambda o: (max(abs(top + o - med), abs(bottom + o - med)), abs(o)))
        return [(b, l, m + octave) for b, l, m in line]

    sung = {s: fit_singer(s) for s in singers}
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

    # drum kit from the loudest real attacks (measured before levelling), one clip per drum
    attacks = sorted(((voices[i].rms[min(o // 480, len(voices[i].rms) - 1)] * peaks[i], i, o)
                      for i in usable for o in voices[i].onsets[:2]), reverse=True)
    if not attacks:
        attacks = [(0, i, voices[i].regions[0][0]) for i in usable]
    kit, taken = {}, set()
    for drum in ("kick", "snare", "hat"):
        choice = next((a for a in attacks if a[1] not in taken), attacks[0])
        kit[drum] = (choice[1], choice[2])
        taken.add(choice[1])

    longest = {i: voices[i].regions[0] for i in range(n)}  # longest region per clip

    # bars 1-2: every clip introduces itself, quick-fire, the first one stuttered in
    t = 0
    order = [lead] + others
    slot = max(BEAT // 2, (2 * BAR - 3 * SIXTEENTH) // max(1, len(order)))
    last_intro = lead
    for k, i in enumerate(order):
        if t >= 2 * BAR - BEAT // 2:
            break
        last_intro = i
        if k == 0:
            t += arr.stutter_head(i, t, longest[i])
        dur = arr.phrase(i, t, longest[i], gain=1.0, limit=min(1.4, (slot - 600) / SR))
        # with many clips each one keeps to its slot, so nobody is squeezed out
        t += slot if len(order) > 3 else int(np.ceil((t + dur) / BEAT)) * BEAT - t
    arr.drums(kit, 1, 2, snare=False, hats=False, gain=0.7)
    # the song proper opens on the last clip introduced: its sound lands on the
    # downbeat while the picture turns it into a sticker
    arr.phrase(last_intro, 2 * BAR, longest[last_intro], gain=1.0, limit=0.45)

    # bars 3-4: beat + bass, tail echoes as fills
    arr.drums(kit, 2, 4)
    bass_cursor = (0, sorted(voices[bass].regions)[0][0])

    def bass_part(cursor, notes, bar_offset, gain):
        if sampled_bass:
            return arr.sampled_line(bass, cursor, notes, bar_offset, gain, "bass", bass_mid)
        return arr.sung_line(bass, cursor, notes, bar_offset, gain, "bass")

    first_two = [(b, l, m) for b, l, m in bass_notes if b < 8]
    bass_cursor = bass_part(bass_cursor, first_two, 2, 0.6)
    arr.tail_echo(order[-1], 3 * BAR + 2 * BEAT, longest[order[-1]], times=4, step=BEAT // 2, gain=0.6)

    # bars 5-12: the melody, sung continuously; two singers trade every two bars
    arr.drums(kit, 4, 12)
    cursors = {s: (0, None) for s in singers}
    for chunk in range(4):
        s = singers[chunk % len(singers)]
        part = [(b, l, m) for b, l, m in sung[s] if chunk * 8 <= b < chunk * 8 + 8]
        cursors[s] = arr.syllable_line(s, cursors[s], part, 4, 0.95, "melody")
        arr.guide_line(s, part, 4, GUIDE)
    bass_cursor = bass_part(bass_cursor, bass_notes, 4, 0.55)
    # clips with no part of their own (neither singing nor bass) are heard
    # quietly behind the melody, whole, every other bar
    cameo = [i for i in usable if i not in singers and i != bass]
    whole = {i: (min(a for a, _ in voices[i].regions), max(b for _, b in voices[i].regions)) for i in cameo}
    for k, bar in enumerate((5, 7, 9, 11) if cameo else ()):
        i = cameo[k % len(cameo)]
        a, b = whole[i]
        # bars 9-12 keep their last beat clear for the answering chops
        limit = int(1.6 * SR) if bar < 8 else int(1.1 * SR)
        arr.add(i, bar * BAR + BEAT // 2, min(b - a, limit), a, "phrase", "backing", 0.38,
                fades={"fadeInSamples": 480, "fadeOutSamples": 2400})
    # chops answer in the gaps of bars 9-12, the clips with the least to do first
    answer = cameo + [i for i in others if i not in singers and i not in cameo] or others or [lead]
    for k, bar in enumerate((8, 9, 10, 11)):
        clip = answer[k % len(answer)]
        arr.stutter_head(clip, bar * BAR + 3 * BEAT, longest[clip], times=4, step=SIXTEENTH, gain=0.55)

    # bars 13-14: break — the longest phrase raw and up front
    star = max(usable, key=lambda i: longest[i][1] - longest[i][0])
    arr.add(kit["kick"][0], 12 * BAR, int(0.16 * SR), kit["kick"][1], "rhythm", "kick", 0.9, rate=0.55)
    dur = arr.phrase(star, 12 * BAR + BEAT // 2, longest[star], gain=1.0, limit=2.4)
    arr.tail_echo(star, 12 * BAR + BEAT // 2 + dur, longest[star], times=3, step=BEAT // 2, gain=0.8)
    quiet_bass = [(b, l, m) for b, l, m in bass_notes if 24 <= b < 32]
    bass_part(bass_cursor, [(b - 24, l, m) for b, l, m in quiet_bass], 12, 0.3)

    # bars 15-16: climax — the hook again, full kit, everyone stutters at the end
    arr.drums(kit, 14, 16)
    s = singers[-1]
    hook = [(b, l, m) for b, l, m in sung[s] if b < 8]
    arr.syllable_line(s, cursors[s], hook, 14, 1.0, "melody")
    arr.guide_line(s, hook, 14, GUIDE)
    bass_part(bass_cursor, [(b, l, m) for b, l, m in bass_notes if b < 8], 14, 0.55)
    for k, i in enumerate(order):
        arr.stutter_head(i, 15 * BAR + 2 * BEAT + k * SIXTEENTH * 2 % (2 * BEAT), longest[i], times=2,
                         step=SIXTEENTH, gain=0.7)

    # MAD effects at the song's turning points; the seed picks one option per slot
    rng = np.random.default_rng(SEED)
    choose = lambda options: options[int(rng.integers(len(options)))]
    syl = {i: (voices[i].syllables() or [(a, b, None) for a, b in voices[i].regions]) for i in range(n)}
    long_clip = max(usable, key=lambda i: longest[i][1] - longest[i][0])
    master, used = [], []
    into_melody = choose(["roll", "riser", "reverse"])
    into_break = choose(["tapestop", "scratch"])
    # pairs that belong together: after a tape stop the break usually opens with a sweep
    in_break = ("sweep" if rng.random() < 0.8 else "gate") if into_break == "tapestop" else choose(["sweep", "gate"])
    into_climax = choose(["roll", "reverse", "riser"])
    for slot, end in ((into_melody, 4 * BAR), (into_climax, 14 * BAR)):
        if slot == "roll":
            arr.fx_roll(lead, end, syl[lead][0])
        elif slot == "riser":
            arr.fx_riser(long_clip, end, longest[long_clip])
        else:
            arr.fx_reverse(lead, end, longest[lead])
        used.append(slot)
    if into_break == "tapestop":
        master.append({"type": "tapestop", "start": 12 * BAR - BEAT, "dur": BEAT})
    else:
        arr.fx_scratch(lead, 12 * BAR - 2 * BEAT, syl[lead][0])
    used.append(into_break)
    if in_break == "sweep":
        master.append({"type": "sweep", "start": 12 * BAR, "dur": 2 * BAR})
    else:
        for e in arr.events:
            if e["role"] == "phrase" and 12 * BAR <= e["destinationStartSample"] < 13 * BAR:
                e["gate"] = 4
    used.append(in_break)
    if rng.random() < 0.6:
        stab_clip = next((i for i in usable if i not in singers and any(m for _, _, m in syl[i])), None)
        if stab_clip is not None:
            s0 = next(x for x in syl[stab_clip] if x[2] is not None)
            root = bass_notes[0][2] + 12
            arr.fx_stabs(stab_clip, s0, s0[2], 8, 2, root)
            used.append("stabs")
    if rng.random() < 0.6:
        arr.fx_scratch(lead, 15 * BAR, syl[lead][0], beats=2, gain=0.6)
        used.append("scratch-fill")

    # second wave of effects; each is optional so no two videos stack the same set
    intro_phrases = [e for e in arr.events if e["role"] == "phrase" and e["destinationStartSample"] < 2 * BAR
                     and e["assetId"] != f"clip-{lead}"]
    if intro_phrases and rng.random() < 0.5:
        e = intro_phrases[int(rng.integers(len(intro_phrases)))]
        e["rate"] = choose([1.45, 0.7])  # chipmunk or monster; the face speeds up or slows down with it
        used.append("character-high" if e["rate"] > 1 else "character-low")
    if rng.random() < 0.4:
        bounce = [e for e in arr.events if e["role"] == "melody" and 8 * BAR <= e["destinationStartSample"] < 10 * BAR
                  and (e.get("notes") or e.get("targetMidiNote"))]
        for j, e in enumerate(bounce):
            if j % 2:
                if e.get("notes"):
                    e["notes"] = [[o, m + 12] for o, m in e["notes"]]
                else:
                    e["targetMidiNote"] += 12
                    e["rate"] = round(min(2.0, e["rate"] * 2), 4)
        used.append("octave-bounce")
    halftime = rng.random() < 0.35
    if halftime:
        arr.events = [e for e in arr.events if not (e["role"] in ("kick", "snare", "hat")
                                                    and 14 * BAR <= e["destinationStartSample"] < 15 * BAR)]
        k_clip, k_src = kit["kick"]
        s_clip, s_src = kit["snare"]
        arr.add(k_clip, 14 * BAR, int(0.16 * SR), k_src, "rhythm", "kick", 0.95, rate=0.55)
        arr.add(s_clip, 14 * BAR + 2 * BEAT, int(0.14 * SR), s_src, "rhythm", "snare", 0.85)
        master.append({"type": "halftime", "start": 14 * BAR, "dur": BAR})
        used.append("halftime")
    if rng.random() < (0.3 if halftime else 0.5):
        a, d = choose([(4 * BAR, 8 * BAR), (14 * BAR, 2 * BAR)])
        kicks = [e["destinationStartSample"] for e in arr.events if e["role"] == "kick" and a <= e["destinationStartSample"] < a + d]
        master.append({"type": "sidechain", "start": a, "dur": d, "kicks": kicks})
        used.append("sidechain")
    if rng.random() < 0.5:
        for e in [e for e in arr.events if e["role"] == "phrase" and 12 * BAR <= e["destinationStartSample"] < 13 * BAR]:
            for k in (1, 2, 3):  # a dotted-eighth echo trail after the break line
                copy = dict(e, destinationStartSample=e["destinationStartSample"] + e["durationSamples"] + k * (3 * BEAT // 4),
                            gain=round(e["gain"] * 0.5 ** k, 3), role="echo")
                arr.events.append(copy)
        used.append("delay-throw")
    if rng.random() < 0.35:
        master.append({"type": "bitcrush", "start": 11 * BAR, "dur": BAR - BEAT})
        used.append("bitcrush")

    arr.events.sort(key=lambda e: e["destinationStartSample"])
    recipe = {"arrangement": {"totalSamples": BARS * BAR, "sourceAssetIds": [f"clip-{i}" for i in range(n)],
                              "events": arr.events, "title": score["title"], "fx": master,
                              # lets the video director follow the song's own structure
                              "sections": [[0, 2, "calm"], [2, 4, "mid"], [4, 8, "mid"], [8, 12, "high"],
                                           [12, 14, "calm"], [14, 16, "high"]]}}
    out.write_text(json.dumps(recipe, ensure_ascii=False), encoding="utf-8")
    roles = {}
    for e in arr.events:
        roles[e["role"]] = roles.get(e["role"], 0) + 1
    print("fx:", " / ".join(used))
    print(f"lead={names[lead]} bass={names[bass]} shift={shift} kit={ {k: names[v[0]] for k, v in kit.items()} }",
          roles, flush=True)


if __name__ == "__main__":
    main()
