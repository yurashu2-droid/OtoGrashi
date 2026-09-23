"""Generate OtoGrashi's deterministic synthetic practice fixtures.

These are authored test signals, not captured household recordings.  The
runtime never invokes Python or FFmpeg; this script is only for regenerating
the small checked-in development fixtures.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import wave

import numpy as np
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "source"
NATIVE_TEST_SOURCE = ROOT.parents[1] / "test" / "fixtures" / "native"
RATE = 48_000
DELAYED_AAC_OFFSET_SECONDS = "0.1482199546"
DELAYED_AAC_MARKER_SAMPLE_48K = 19_115
FFMPEG = Path(
    os.environ.get(
        "OTOGRASHI_FFMPEG",
        r"C:\Users\raito\.cache\otogurashi-tools\imageio_ffmpeg\binaries\ffmpeg-win-x86_64-v7.1.exe",
    )
)


def tap() -> np.ndarray:
    samples = np.zeros(RATE, dtype=np.float32)
    start = RATE // 4
    length = 4_800
    time = np.arange(length, dtype=np.float64) / RATE
    rng = np.random.default_rng(8_153)
    body = (np.sin(2 * np.pi * 880 * time) + rng.normal(0, 0.15, length))
    samples[start : start + length] = (body * np.exp(-time * 42) * 0.72).astype(np.float32)
    return samples


def sustain() -> np.ndarray:
    time = np.arange(RATE, dtype=np.float64) / RATE
    envelope = np.minimum(1, time / 0.03) * np.minimum(1, (1 - time) / 0.04)
    return (
        (np.sin(2 * np.pi * 220 * time) + 0.35 * np.sin(2 * np.pi * 330 * time))
        * envelope
        * 0.28
    ).astype(np.float32)


def texture() -> np.ndarray:
    length = RATE * 3 // 2
    rng = np.random.default_rng(22_092_026)
    noise = rng.normal(0, 1, length)
    smooth = np.convolve(noise, np.ones(96) / 96, mode="same")
    return (smooth * 0.025).astype(np.float32)


def write_wav(path: Path, samples: np.ndarray, sample_rate: int = RATE) -> None:
    pcm = np.clip(samples, -1, 1)
    pcm = np.round(pcm * 32_767).astype("<i2")
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(pcm.tobytes())


def draw_frames(name: str, frame_count: int, color: str, kind: str) -> Path:
    directory = SOURCE / f".{name}-frames"
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir()
    background = color.removeprefix("0x")
    rgb = tuple(int(background[index : index + 2], 16) for index in (0, 2, 4))
    for frame in range(frame_count):
        image = Image.new("RGB", (160, 90), rgb)
        draw = ImageDraw.Draw(image)
        if kind == "tap":
            cue = 8
            distance = abs(frame - cue)
            radius = max(5, 24 - distance * 5)
            y = 62 - max(0, cue - frame) * 6
            draw.ellipse((80 - radius, y - radius, 80 + radius, y + radius), fill="white")
            draw.line((42, 70, 118, 70), fill=(57, 38, 30), width=4)
        elif kind == "sustain":
            points = []
            for x in range(160):
                y = 45 + int(16 * np.sin((x + frame * 5) * 2 * np.pi / 80))
                points.append((x, y))
            draw.line(points, fill="white", width=4)
            draw.ellipse((frame * 5 % 170 - 10, 36, frame * 5 % 170 + 8, 54), fill=(255, 224, 130))
        else:
            for column in range(8):
                active = (frame // 3 + column) % 8 == 0
                shade = (245, 238, 214) if active else (74, 83, 76)
                x = 12 + column * 18
                draw.rounded_rectangle((x, 20, x + 12, 70), radius=3, fill=shade)
        image.save(directory / f"frame-{frame:03d}.png", optimize=True)
    return directory


def render_mp4(name: str, samples: np.ndarray, color: str, kind: str) -> Path:
    wav = SOURCE / f".{name}.wav"
    output = SOURCE / f"{name}.mp4"
    write_wav(wav, samples)
    duration = len(samples) / RATE
    frames = draw_frames(name, int(round(duration * 30)), color, kind)
    command = [
        str(FFMPEG),
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "image2",
        "-framerate",
        "30",
        "-i",
        str(frames / "frame-%03d.png"),
        "-i",
        str(wav),
        "-c:v",
        "libx264",
        "-preset",
        "veryslow",
        "-crf",
        "35",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-b:a",
        "64k",
        "-shortest",
        "-movflags",
        "+faststart",
        str(output),
    ]
    try:
        subprocess.run(command, check=True)
    finally:
        wav.unlink(missing_ok=True)
        shutil.rmtree(frames, ignore_errors=True)
    return output


def render_delayed_aac_regression() -> Path:
    """Create a 44.1 kHz AAC track whose first packet has a nonzero PTS."""
    sample_rate = 44_100
    samples = np.zeros(sample_rate, dtype=np.float32)
    samples[sample_rate // 4] = 0.92
    NATIVE_TEST_SOURCE.mkdir(parents=True, exist_ok=True)
    wav = NATIVE_TEST_SOURCE / ".delayed-44100-aac.wav"
    output = NATIVE_TEST_SOURCE / "delayed-44100-aac.mp4"
    write_wav(wav, samples, sample_rate=sample_rate)
    command = [
        str(FFMPEG),
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "lavfi",
        "-i",
        "color=c=0x252830:s=160x90:r=30:d=1.15",
        "-itsoffset",
        DELAYED_AAC_OFFSET_SECONDS,
        "-i",
        str(wav),
        "-c:v",
        "libx264",
        "-preset",
        "veryslow",
        "-crf",
        "40",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-ar",
        str(sample_rate),
        "-b:a",
        "96k",
        "-shortest",
        "-movflags",
        "+faststart",
        str(output),
    ]
    try:
        subprocess.run(command, check=True)
    finally:
        wav.unlink(missing_ok=True)
    return output


def render_video_regressions(source: Path) -> tuple[Path, Path]:
    """Create VFR/rotation and HDR inputs for native normalization tests."""
    NATIVE_TEST_SOURCE.mkdir(parents=True, exist_ok=True)
    vfr = NATIVE_TEST_SOURCE / ".rotated-vfr-base.mp4"
    rotated = NATIVE_TEST_SOURCE / "rotated-vfr-tap.mp4"
    hdr = NATIVE_TEST_SOURCE / "hdr10-tap.mp4"
    subprocess.run(
        [
            str(FFMPEG),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-vf",
            "select='not(eq(mod(n,5),1))'",
            "-fps_mode",
            "vfr",
            "-c:v",
            "libx264",
            "-preset",
            "veryslow",
            "-crf",
            "35",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "copy",
            str(vfr),
        ],
        check=True,
    )
    try:
        subprocess.run(
            [
                str(FFMPEG),
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-display_rotation",
                "90",
                "-i",
                str(vfr),
                "-c",
                "copy",
                str(rotated),
            ],
            check=True,
        )
    finally:
        vfr.unlink(missing_ok=True)
    subprocess.run(
        [
            str(FFMPEG),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-c:v",
            "libx265",
            "-preset",
            "fast",
            "-crf",
            "34",
            "-pix_fmt",
            "yuv420p10le",
            "-x265-params",
            (
                "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:"
                "master-display=G(8500,39850)B(6550,2300)R(35400,14600)"
                "WP(15635,16450)L(10000000,1):max-cll=1000,400"
            ),
            "-color_primaries",
            "bt2020",
            "-color_trc",
            "smpte2084",
            "-colorspace",
            "bt2020nc",
            "-c:a",
            "copy",
            "-tag:v",
            "hvc1",
            "-movflags",
            "+faststart+write_colr",
            str(hdr),
        ],
        check=True,
    )
    return rotated, hdr


def render_long_video_regression(source: Path) -> Path:
    """Create a long original whose selected six-second window is bounded."""
    output = NATIVE_TEST_SOURCE / "long-original-tap.mp4"
    subprocess.run(
        [
            str(FFMPEG),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-stream_loop",
            "79",
            "-i",
            str(source),
            "-t",
            "72",
            "-an",
            "-r",
            "30",
            "-c:v",
            "libx264",
            "-preset",
            "veryslow",
            "-crf",
            "35",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            str(output),
        ],
        check=True,
    )
    return output


def main() -> None:
    if not FFMPEG.is_file():
        raise SystemExit(f"FFmpeg not found: {FFMPEG}")
    SOURCE.mkdir(parents=True, exist_ok=True)
    definitions = [
        ("synthetic-tap", tap(), "0xD67A63", "transient", "tap", 12_000),
        ("synthetic-sustain", sustain(), "0x568EA3", "sustain", "sustain", 0),
        ("synthetic-texture", texture(), "0x88937D", "texture", "texture", 0),
    ]
    fixtures = []
    for name, samples, color, role, visual, cue_sample in definitions:
        path = render_mp4(name, samples, color, visual)
        fixtures.append(
            {
                "id": name,
                "path": f"source/{path.name}",
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "durationSamples": len(samples),
                "sampleRate": RATE,
                "videoFrameRate": 30,
                "videoCueFrame": (cue_sample * 30 + 24_000) // 48_000,
                "visual": visual,
                "suggestedAcousticRole": role,
            }
        )
    regression = render_delayed_aac_regression()
    rotated_vfr, hdr10 = render_video_regressions(SOURCE / "synthetic-tap.mp4")
    long_original = render_long_video_regression(SOURCE / "synthetic-tap.mp4")
    manifest = {
        "schemaVersion": 1,
        "label": "Synthetic practice fixtures — not real household recordings",
        "license": "CC0-1.0",
        "provenance": (
            "Authored for OtoGrashi from deterministic mathematical signals and "
            "geometric animation by assets/demo/generate_fixtures.py. No third-party media."
        ),
        "fixtures": fixtures,
        "nativeRegressionFixtures": [
            {
                "id": "delayed-44100-aac",
                "path": "../../test/fixtures/native/delayed-44100-aac.mp4",
                "sha256": hashlib.sha256(regression.read_bytes()).hexdigest(),
                "encodedSampleRate": 44_100,
                "presentationStartSample48k": 0,
                "authoredMarkerSample48k": DELAYED_AAC_MARKER_SAMPLE_48K,
                "analysisFrameSamples": 480,
                "purpose": "nonzero audio PTS, AAC priming, and 44.1-to-48 kHz mapping",
            },
            {
                "id": "rotated-vfr-tap",
                "path": "../../test/fixtures/native/rotated-vfr-tap.mp4",
                "sha256": hashlib.sha256(rotated_vfr.read_bytes()).hexdigest(),
                "purpose": "rotated, sparse VFR source-frame lookup and transform",
            },
            {
                "id": "hdr10-tap",
                "path": "../../test/fixtures/native/hdr10-tap.mp4",
                "sha256": hashlib.sha256(hdr10.read_bytes()).hexdigest(),
                "purpose": "PQ/BT.2020 input normalized to SDR BT.709 output",
            },
            {
                "id": "long-original-tap",
                "path": "../../test/fixtures/native/long-original-tap.mp4",
                "sha256": hashlib.sha256(long_original.read_bytes()).hexdigest(),
                "purpose": "long original with a bounded short-selection timestamp window",
            },
        ],
    }
    (ROOT / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
