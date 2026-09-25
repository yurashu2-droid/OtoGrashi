# Everyday MAD Implementation Plan

**Goal:** Turn incidental recordings into musically pitched, recognizable, synchronized MAD videos.
**Architecture:** One sample-clock event contract drives audio, video, looping and reversal. Portable DSP owns pitch estimation / source-derived tuning; Dart owns arrangement and scene planning; the native player owns presentation timing.
**Tech Stack:** Existing Flutter/Dart + Swift/AVFoundation/CoreImage. No paid services or added runtime packages.
**Spec:** docs/superpowers/specs/2026-09-24-everyday-mad.md

## Global constraints
48 kHz; 15 seconds; 1–6 usable sources at engine level; saved v1 payload defaults preserved. Do not rewrite source media or shared development branches. Work from 099eccf on codex/everyday-mad-overhaul.

## Tasks
- [ ] DSP and analysis: reproduce the existing padded-tone/boundary failures; add portable assertions; implement interpolated range-safe YIN, region metadata, sample-derived musicalization and bounded looping; rerun assertions and inspect spectra.
- [ ] Shared event contract: add sourceDurationSamples/targetMidiNote/reverse/mirror/treatment with backward-compatible defaults and identical native/Dart validation; test malformed and round-trip payloads.
- [ ] Arrangement: build phrase/groove/hook/climax, preserve long source phrases, tune unmeasured clips, keep exact MIDI pitch intervals and add natural reaction accents; test all-speech/all-hit/short-source/quiet/multi-source inputs.
- [ ] Video: replace bar-only scene boundaries, render active assets including simultaneous takes, mirror/punch/reverse on events, preserve held frames during rests; test clock mappings and layout bounds for 1–6 sources.
- [ ] Playback: serialize controls, avoid stale readiness/seek state, detach native views, rebuild on trims, correct transformed preview composition, stop covered/disposed players; test rapid operations and lifecycle.
- [ ] Integration: run Dart analysis/tests and native CI; inspect renderer evidence; fix regressions; document verified limitations and publish branch/PR + patch.

## Review focus
- New source loaded into an existing popup must replace old audio/video, not only text.
- Speech/non-tonal recordings still get pitched musical events AND natural phrases.
- Long source vs short source: no hidden reads past selected range; loops reverse identically on both tracks.
- Multiple voices from one source are independent sounding/visible events, not unrelated decorative videos.
- Legacy project payloads keep decoding and rendering; old source coordinates are not silently reinterpreted.
