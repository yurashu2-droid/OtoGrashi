"""Arrange a well-known public-domain melody as a band played by recorded clips.

Writes a recipe JSON in the app's arrangement schema so render_styles.py can
render it. Melody notes go to voice clips (auto-tuned from their measured
pitch), a bass line to a low-pitched clip, and a drum kit to short chops.

    python tool/video_lab/arrange_score.py SONG SRC_DIR OUT.json

SONG is one of the keys in SCORES, or "lilac" for the app's bundled MIDI. SRC_DIR is the same folder render_styles.py
reads (s0.wav, s1.wav, ... and names.txt).
"""

import json
import math
import re
import sys
import wave
from pathlib import Path

import numpy as np

SR = 48_000
BEAT = 22_500  # 128 BPM, the app's fixed clock
BARS = 8

# (start beat, length in beats, MIDI note). Public-domain melodies only.
SCORES = {
    "ode_to_joy": {
        "title": "歓喜の歌",
        "melody": [
            (0, 1, 64), (1, 1, 64), (2, 1, 65), (3, 1, 67),
            (4, 1, 67), (5, 1, 65), (6, 1, 64), (7, 1, 62),
            (8, 1, 60), (9, 1, 60), (10, 1, 62), (11, 1, 64),
            (12, 1.5, 64), (13.5, 0.5, 62), (14, 2, 62),
            (16, 1, 64), (17, 1, 64), (18, 1, 65), (19, 1, 67),
            (20, 1, 67), (21, 1, 65), (22, 1, 64), (23, 1, 62),
            (24, 1, 60), (25, 1, 60), (26, 1, 62), (27, 1, 64),
            (28, 1.5, 62), (29.5, 0.5, 60), (30, 2, 60),
        ],
        # one root per half bar
        "roots": [36, 36, 43, 43, 36, 36, 43, 43, 36, 36, 43, 43, 36, 36, 43, 36],
    },
    "twinkle": {
        "title": "きらきら星",
        "melody": [
            (0, 1, 60), (1, 1, 60), (2, 1, 67), (3, 1, 67),
            (4, 1, 69), (5, 1, 69), (6, 2, 67),
            (8, 1, 65), (9, 1, 65), (10, 1, 64), (11, 1, 64),
            (12, 1, 62), (13, 1, 62), (14, 2, 60),
            (16, 1, 67), (17, 1, 67), (18, 1, 65), (19, 1, 65),
            (20, 1, 64), (21, 1, 64), (22, 2, 62),
            (24, 1, 67), (25, 1, 67), (26, 1, 65), (27, 1, 65),
            (28, 1, 64), (29, 1, 64), (30, 2, 62),
        ],
        "roots": [36, 36, 41, 36, 41, 36, 43, 36, 36, 41, 36, 43, 36, 41, 36, 43],
    },
}


def bundled_score():
    """The app's bundled three-part MIDI (lib/domain/midi_score_data.dart)."""
    text = Path(__file__).parents[2].joinpath("lib/domain/midi_score_data.dart").read_text(encoding="utf-8")
    parts = {}
    for name, body in re.findall(r"//\s*(Melody|Bass|Piano):.*?\n(.*?)(?=//\s*(?:Melody|Bass|Piano):|\Z)", text, re.S):
        parts[name] = [(int(a) / 480, int(b) / 480, int(c))
                       for a, b, c in re.findall(r"<int>\[(\d+), (\d+), (\d+)\]", body)]
    return {"title": "ライラック（冒頭）", "melody": parts["Melody"], "bass_notes": parts["Bass"],
            "keys": parts["Piano"]}


def load(path):
    with wave.open(str(path)) as wf:
        return np.frombuffer(wf.readframes(wf.getnframes()), np.int16).astype(np.float32) / 32768


def analyse(pcm):
    """Loudest 0.3s window (the audible reaction) and its fundamental as MIDI."""
    hop = 480
    rms = np.array([np.sqrt(np.mean(pcm[i:i + hop] ** 2)) for i in range(0, len(pcm) - hop, hop)])
    win = 30  # 0.3s in hops
    energy = np.convolve(rms, np.ones(win), "valid")
    start = int(np.argmax(energy)) * hop
    return start, yin_midi(pcm[start:start + int(0.3 * SR)])


def yin_midi(seg, fmin=60, fmax=700, threshold=0.15):
    """YIN fundamental estimate; plain autocorrelation locks onto overtones in speech."""
    seg = seg - seg.mean()
    size = len(seg) // 2
    lo, hi = SR // fmax, min(SR // fmin, size - 1)
    diff = np.array([np.sum((seg[:size] - seg[tau:tau + size]) ** 2) for tau in range(hi + 1)])
    cmnd = diff[1:] * np.arange(1, hi + 1) / np.maximum(np.cumsum(diff[1:]), 1e-9)
    cmnd = np.concatenate([[1.0], cmnd])
    below = np.where(cmnd[lo:] < threshold)[0]
    tau = lo + (below[0] if len(below) else int(np.argmin(cmnd[lo:])))
    while tau + 1 <= hi and cmnd[tau + 1] < cmnd[tau]:
        tau += 1
    return 69 + 12 * math.log2(SR / tau / 440)


def event(asset, start, dur, src, src_dur, gain, treatment, role, midi=None):
    e = {
        "assetId": asset, "sourceStartSample": int(src), "destinationStartSample": int(start),
        "durationSamples": int(dur), "gain": gain, "sourceDurationSamples": int(src_dur),
        "fades": {"fadeInSamples": 96, "fadeOutSamples": 480}, "treatment": treatment, "role": role,
    }
    if midi is not None:
        e["targetMidiNote"] = float(midi)
    return e


def main():
    song, src_dir, out = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    score = bundled_score() if song == "lilac" else SCORES[song]
    names = (src_dir / "names.txt").read_text(encoding="utf-8").split()
    ids = [f"clip-{i}" for i in range(len(names))]
    info = [analyse(load(src_dir / f"s{i}.wav")) for i in range(len(names))]
    bases = {ids[i]: info[i][1] for i in range(len(ids))}
    starts = {ids[i]: info[i][0] for i in range(len(ids))}
    # roles: shortest clip drums, lowest voice bass, the rest carry the melody
    durations = [len(load(src_dir / f"s{i}.wav")) for i in range(len(names))]
    drum = ids[int(np.argmin(durations))]
    others = [i for i in ids if i != drum] or ids
    bass = min(others, key=lambda i: bases[i])
    singers = [i for i in others if i != bass] or others
    # like the app, transpose the whole song to the singers' natural pitch
    # (a key change) instead of forcing each clip far from its own voice
    center = np.mean([n for _, _, n in score["melody"]])
    voice = np.mean([bases[i] for i in singers])
    octave = int(round(voice - center))

    events = []
    for k, (b, length, note) in enumerate(score["melody"]):
        bar = int(b // 4)
        singer = singers[(bar // 2) % len(singers)]
        dur = int(length * BEAT) - 600
        events.append(event(singer, b * BEAT, dur, starts[singer], min(dur, int(0.32 * SR)),
                            0.9, "tuned", "melody", note + octave))
    bass_line = score.get("bass_notes") or [(h * 2, 2, r) for h, r in enumerate(score["roots"])]
    for b, length, note in bass_line:
        if b < 8:  # bass joins in bar 3
            continue
        while note < 36:
            note += 12
        dur = int(length * BEAT) - 900
        events.append(event(bass, b * BEAT, dur, starts[bass], min(dur, int(0.25 * SR)),
                            0.55, "tuned", "bass", note))
    for b, length, note in score.get("keys", []):
        if b < 16:  # keys fill the second half
            continue
        dur = int(length * BEAT) - 600
        events.append(event(bass, b * BEAT, dur, starts[bass], min(dur, int(0.2 * SR)),
                            0.28, "tuned", "keys", note))
    for beat in range(BARS * 4):
        bar = beat // 4
        if bar < 2:
            continue  # drums enter after the melody has been heard
        if beat % 2 == 0:
            events.append(event(drum, beat * BEAT, int(0.16 * SR), starts[drum], int(0.16 * SR),
                                0.8, "tuned", "kick", bases[drum] - 14))
        else:
            events.append(event(drum, beat * BEAT, int(0.14 * SR), starts[drum], int(0.14 * SR),
                                0.6, "rhythm", "snare"))
        if bar >= 4:
            events.append(event(drum, beat * BEAT + BEAT // 2, int(0.05 * SR), starts[drum] + 2400,
                                int(0.05 * SR), 0.25, "rhythm", "hat"))
    events.sort(key=lambda e: e["destinationStartSample"])
    recipe = {
        "arrangement": {
            "totalSamples": BARS * 4 * BEAT, "sourceAssetIds": ids, "events": events,
            "title": score["title"], "sourcePitch": {i: round(bases[i], 1) for i in ids},
        }
    }
    out.write_text(json.dumps(recipe, ensure_ascii=False, indent=1), encoding="utf-8")
    print(score["title"], "drum", drum, "bass", bass, "singers", singers, "octave", octave,
          "pitch", recipe["arrangement"]["sourcePitch"])


if __name__ == "__main__":
    main()
