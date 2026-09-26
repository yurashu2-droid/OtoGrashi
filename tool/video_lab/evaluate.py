"""Measure whether an arrangement's melody can be heard as the song.

For each melody note it checks, on a melody-only render, how much of the
note is actually sounding at the target pitch (octave errors ignored), and
how loud the melody is against everything else during the melody bars.

    python tool/video_lab/evaluate.py RECIPE.json SRC_DIR
"""

import json
import sys
from pathlib import Path

import numpy as np

from lab_audio import SR, yin_frame
from render_styles import Event, Source, render_audio


def main():
    recipe = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["arrangement"]
    src_dir = Path(sys.argv[2])
    names = (src_dir / "names.txt").read_text(encoding="utf-8").split()
    order = recipe["sourceAssetIds"]
    sources = [Source(src_dir / f"s{i}.mp4", src_dir / f"s{i}.wav", names[i]) for i in range(len(order))]
    raw = recipe["events"]
    total = recipe["totalSamples"]

    def stem(pred):
        evs = [Event(r, order.index(r["assetId"]), i) for i, r in enumerate(raw) if pred(r)]
        return render_audio(evs, sources, total, master=False) if evs else np.zeros(total, np.float32)

    melody = stem(lambda r: r.get("role") in ("melody", "guide"))
    rest = stem(lambda r: r.get("role") not in ("melody", "guide"))
    notes = []
    for r in raw:
        if r.get("role") != "melody" or not (r.get("notes") or r.get("targetMidiNote")):
            continue  # raw attacks carry no pitch of their own
        steps = r.get("notes") or [[0, r["targetMidiNote"]]]
        for k, (off, midi) in enumerate(steps):
            end = steps[k + 1][0] if k + 1 < len(steps) else r["durationSamples"]
            notes.append((r["destinationStartSample"] + off, r["destinationStartSample"] + end, midi))
    hits = []
    for a, b, midi in notes:
        frames = range(a, max(a + 1, b - 1_920), 480)
        good = sounding = 0
        for i in frames:
            seg = melody[i:i + 1_920]
            if len(seg) < 1_920 or np.sqrt(np.mean(seg ** 2)) < 0.02:
                continue
            sounding += 1
            m, clarity = yin_frame(seg, SR // 4000, SR // 65)
            if clarity > 0.6 and abs(((m - midi + 6) % 12) - 6) < 1.0:
                good += 1
        # judged on the part that sounds: a syllable may end before its note does
        hits.append(good / max(1, sounding) if sounding >= 3 else 0.0)
    hits = np.array(hits)
    starts = np.array([a for a, _, _ in notes])
    # loudness of melody vs everything else while the melody plays
    mask = np.zeros(total, bool)
    for a, b, _ in notes:
        mask[a:b] = True
    ratio_db = 10 * np.log10((np.mean(melody[mask] ** 2) + 1e-9) / (np.mean(rest[mask] ** 2) + 1e-9))
    print(f"melody notes {len(notes)}  on-pitch coverage mean {hits.mean():.2f}  "
          f"notes >=50% covered {np.mean(hits >= 0.5):.2f}  melody/rest {ratio_db:+.1f} dB")
    for lo, hi, label in ((4, 12, "bars 5-12"), (14, 16, "bars 15-16")):
        sel = (starts >= lo * 90_000) & (starts < hi * 90_000)
        if sel.any():
            print(f"  {label}: coverage {hits[sel].mean():.2f}  notes>=50% {np.mean(hits[sel] >= 0.5):.2f}")


if __name__ == "__main__":
    main()
