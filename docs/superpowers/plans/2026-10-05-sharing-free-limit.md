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
- [ ] Verify grouped backend tests/typecheck/dry-run and Flutter analyze/targeted
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
- CI/iOS archive pending. Cloudflare live deployment and real Face ID/two-phone
  verification are pending service credentials and a deployed HTTPS origin.
