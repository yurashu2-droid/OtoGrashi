#!/usr/bin/env bash
# Portable checks of the real Swift DSP and payload. Not an iOS build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
cd "$ROOT"
command -v swiftc >/dev/null
command -v python3 >/dev/null
swiftc -O ios/Runner/Media/EverydayAudioDSP.swift scripts/review/DSPRegression.swift -o "$TEMP/dsp"
"$TEMP/dsp"
swiftc -O ios/Runner/Media/EverydayAudioDSP.swift scripts/review/NaturalVoiceRegression.swift -o "$TEMP/natural"
"$TEMP/natural"
python3 scripts/review/check_analysis.py
python3 scripts/review/check_natural_contract.py
swiftc -frontend -parse ios/Runner/Media/EverydayAudioDSP.swift ios/Runner/Media/AudioAnalyzer.swift ios/Runner/Media/AudioRenderer.swift ios/Runner/Media/VideoRenderer.swift ios/RunnerTests/AudioRendererTests.swift
printf '\nPASS Swift syntax parse (5 edited Swift files)\n'
printf 'NOTE: Flutter analyze/test, iOS compilation and device playback are separate checks.\n'
