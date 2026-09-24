# Review ledger — 2026-09-24-everyday-mad
Baseline: 099eccfddf44636334e84564e5944aba631bb3f7, isolated branch codex/everyday-mad-overhaul.
Source was obtained through a temporary read-only GitHub Actions snapshot because container networking is unavailable; remove the temporary workflow from final tree.
Ruling: The user's explicit request to change specifications and proceed authorizes implementation without an additional approval round.
Ruling: Keep old serialized event defaults, but change newly created arrangements to the new musical behavior.
Preflight: audio/video must share source duration and reverse. Native player trim identity must include ranges, not just file path.

Task DSP: interpolated F0, region metadata, source-derived retuning, exact source clock; portable DSP regression passes (40 checks), Foundation parse passes.
Task contracts/arranger: explicit source bounds, target MIDI, reverse/mirror, long phrase spotlights, sustained notes and real echoes implemented. Dart execution awaits connected CI.
Task video: audio-boundary scenes, live-source visibility, six-panel layout, per-voice tiles, mirror/punch, shared loop/reverse mapping implemented. Native device rendering not yet verified.
Task playback: commands serialized; stale views stopped; trim identity remount; explicit portrait composition transforms; awaited native seeks. Regression cases added, await CI.
