# R2 Shared Folders Implementation Plan

> For agentic workers: follow superpowers:subagent-driven-development or
> superpowers:executing-plans. User permits proceeding without design approval and
> requests grouping work and risk-proportionate verification.

**Goal:** Friends join a private folder, contribute video sounds and use the
downloaded originals in OtoGrashi's existing music maker.

**Architecture:** Worker API + per-folder SQLite Durable Object + private R2.
Flutter service handles per-origin secure membership, bounded transfers and
imports. Screens reuse the local capture/music/render paths.

**Tech Stack:** Cloudflare Workers, TypeScript, Wrangler/local runtime tests,
Flutter/Dart IO, flutter_secure_storage, app_links, existing SQLite repositories.

**Spec:** ../specs/2026-10-05-r2-shared-folders-design.md

## Tasks

- [x] Cloudflare subsystem (`backend/shared-folders/`): implement the exact v1
  contract, permission/limits/streaming integrity, invitation landing page,
  deployment config/docs and focused runtime tests. Do not touch Flutter sources.
- [x] Flutter sharing service (`lib/sharing/`, `test/sharing/`): implement the
  spec's public models and SharedFolderService, secure per-origin credentials,
  persisted memberships, streamed IO, idempotent upload and validated/deduplicated
  download. Do not modify app host/UI or pubspec; parent integrates dependencies.
- [x] App experience (parent): add secure storage/deep-link dependencies and
  platform configuration; wire AppDependencies/CreationFlow/HomeScreen; implement
  shared folders list/detail/picker/invitation/member actions. Match existing
  themes and reuse thumbnails/sound preview/local asset selection. Owner actions
  are role-gated and destructive actions explain shared-only deletion.
- [x] Integration (parent): inspect both deliverables against the API contract,
  run narrow backend/client checks and Flutter analyze + affected UI tests. Add
  one CI job for backend checks. Make one coherent push/build if needed for iOS
  plugin integration; do not claim cloud deployment or multi-phone verification
  without having performed it.

## Review focus

- An invitation from a different origin must never receive existing credentials.
- A failed/truncated/hash-mismatched transfer must not become a local usable asset
  or a remotely published clip; retry must not overwrite someone else's sound.
- Owner/member permissions and revocation are checked on every API operation.
- Concurrent uploads/deletion must not exceed quota or resurrect deleted files.
- Cold-start links and app restarts must preserve pending invitations/membership;
  shared deletion never deletes already-imported personal originals.

Use gpt-6.1-sol for backend and client subsystem implementation; parent owns UI
integration. Shared workspace, disjoint owned file paths; no worker commits/pushes.

## Verification status

Flutter analyze passes. Local Flutter test execution is blocked by Windows
Application Control on flutter_tester.exe, so verification ran on macOS CI.

- Backend: 9 workerd integration tests, TypeScript check and deployment dry-run
  passed in https://github.com/yurashu2-droid/OtoGrashi/actions/runs/37216638037.
- Client/app: 14 sharing and startup tests, Flutter analyze and unsigned iOS
  simulator build passed for 998ebb2 in
  https://github.com/yurashu2-droid/OtoGrashi/actions/runs/37217052023.
- The first grouped run also passed 44 existing creation/library/folder checks;
  these were not repeated after the bounded sharing/home follow-up.
- The first run exposed a self-await in download cleanup and a narrow-screen
  wordmark overflow. Both were fixed; existing download/retry tests and the new
  invitation startup test then passed.
- Release IPA: https://github.com/yurashu2-droid/OtoGrashi/actions/runs/37217052026.
  Consult this run's status/artifacts; do not infer completion from this link.

Live Cloudflare deployment and two-device use remain unverified. Wrangler whoami
confirmed this machine is not authenticated; no account, bucket or production
Worker has been created by this implementation. See ../../shared-folders-setup.md
for the operator setup and in-app flow.
