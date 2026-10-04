# Shared-folder free limit and deployment implementation plan

Goal: one open owned folder per free passkey account, plus manual token-based
Cloudflare deployment. Spec: ../specs/2026-10-05-sharing-free-limit-design.md.
User permits autonomous design and grouped risk-based verification.

- [x] Backend auth/quota feature: backend/shared-folders/src, integration tests,
  package.json/lock, wrangler config. Add passkey/PKCE and account-scoped creation/private recovery,
  preserve existing folder access and enforce quota on the server.
- [x] Deploy feature: backend/shared-folders/scripts, deployment tests, manual
  workflow and deployment docs. Provision/reuse private bucket, authenticated
  target selection, Worker deployment and URL output. Never deploy during tests.
- [x] Client/UI integration: secure per-origin session and pending creationId;
  ASWebAuthenticationSession bridge, login/restore, creation and limit messaging.
- [x] Verify grouped backend tests/typecheck/dry-run and Flutter analyze/targeted
  CI tests. Make one coherent code push, no IPA unless native integration or
  user request requires it. Report lack of live credentials separately.

## Verification progress

- Grouped backend tests passed 21/21, TypeScript check and credential-free deployment
  helper dry-run passed. Final review fixes then passed the focused passkey suite
  6/6 and TypeScript check; unrelated tests/builds were not repeated locally.
- Whole-app Flutter analyze passed. Local Flutter tests are blocked by Windows
  Application Control, so they run in the focused macOS CI job.
- One grouped review found and resolved expired auth-record cleanup and a retained
  creationId retry after another device closes the folder. Scoped re-review found
  both addressed. New Dart tests cover account state and an explicit login/create
  UI boundary.
- [Backend CI](https://github.com/yurashu2-droid/OtoGrashi/actions/runs/37219934728)
  passed typecheck, 22/22 tests and Worker dry-run for app/backend commit `80f652d`.
- [Focused Dart CI](https://github.com/yurashu2-droid/OtoGrashi/actions/runs/37220988683)
  passed whole-app analyze and 26/26 sharing, account, startup and creation-boundary
  UI tests for `03b6781`. Follow-ups only changed tests/CI; app code stayed `80f652d`.
  Widget stream fixtures required the real async zone; checking unrelated folder
  fetching after navigation was removed from the creation-boundary UI test. Native
  code and IPA were not rebuilt for these test-only corrections.
- [Unsigned device IPA](https://github.com/yurashu2-droid/OtoGrashi/actions/runs/37219934602)
  archived successfully for `80f652d`. Downloaded, matched its source commit and
  verified SHA-256 `85ac09947fe60fd890da466c99578f209f7fe605a2c9d118cfc67fe5af9ffd7e`.
  Local file: `C:/Users/raito/Downloads/OtoGrashi-shared-folders-80f652d.ipa`.
- Cloudflare live deployment and real Face ID/two-phone verification remain pending
  service credentials and a deployed HTTPS origin. No live credentials were used.
