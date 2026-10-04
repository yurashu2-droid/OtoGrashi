# Free shared-folder limit and token-based deployment

User requests one shared folder created per free account, and deployment ready
once a Cloudflare API credential is supplied. User clarified they want an account
experience modeled on BeReal/setlog. Official BeReal help describes phone/SMS;
setlog's official FAQ describes passkeys and Apple login. Choose setlog-style
passkey accounts, keeping local recording/editing independent of login. No SMS,
email provider, paid tier or Apple Sign In credentials are introduced. Joining
friends' folders does not consume the creation quota. Closing an owned folder
releases its slot. Existing legacy folder credentials remain valid.

## Account contract

- Worker serves a Japanese passkey page on its own HTTPS origin. Verify actual
  WebAuthn attestations/assertions with pinned @simplewebauthn/server; require
  user verification and discoverable credentials. Origin and RP ID come from
  the request's origin, never client data. No CDN scripts or homegrown crypto.
- iOS opens that page in ASWebAuthenticationSession (existing media channel,
  no Apple associated-domain or Sign In with Apple entitlement required). Use
  state and SHA256 PKCE plus a single-use callback code, not a session in a URL.
- POST /v1/auth/start {state:64hex,codeChallenge:64hex} returns {authorizeUrl},
  with flow token in the fragment of /auth. Flow lifetime five minutes.
- Browser POST /v1/auth/options {requestId,mode:'register'|'login',displayName}
  returns {options}; POST /v1/auth/verify {requestId,mode,response} returns
  {callbackUrl:'otograshi://auth?state=...&code=...'}. Callbacks only this fixed
  scheme/host; consume challenges once, check signature/origin/RP/UV/counter.
- POST /v1/auth/exchange {state,code,codeVerifier} returns {token:64hex,
  expiresAt:ISO,account:{id,displayName,plan:'free',maxOwnedFolders:1}}.
  Store only credential public keys and hashed flow/codes/session tokens.
  Session lifetime 30 days. Logout revokes the supplied session. Expired flows,
  codes and sessions are removed by a serialized Durable Object alarm, without
  deleting accounts, credentials, memberships or quotas.
- Account session uses X-Oto-Session for account routes/create/join; folder
  CRUD retains independent Authorization membership tokens. GET /v1/account
  returns {account}; GET /v1/account/folders returns
  {folders:[{folder,membership}]} for restoring credentials on another device.
  POST /v1/auth/logout returns {ok:true}. No personal account ID from the client
  is trusted as authentication. Return 401 account_required/session_expired.
- POST /v1/folders additionally requires creationId (UUID v4). Persist the
  pending UUID in secure storage until success so lost responses are retryable.
  AuthAccounts SQLite DO stores account/credential/session/flow/membership/quota
  metadata; per-account serialization prevents concurrent second creation.
  Persist/reuse candidate folder ID before creating through private FOLDERS RPC.
  Different creationId while an owned folder is open: 409 owned_folder_limit.
  Same request retries recover original folder/owner credentials. Check closure
  server-side; use the same candidate if creation is incomplete.
- Private FOLDERS RPC can issue membership tokens for a verified account and
  restore access without changing its role/contributor. Store token hashes only;
  preserve up to ten hashes per member to support multiple signed-in devices.
  Public Worker must not expose private creation/recovery routes or trust forged
  internal headers. Account ID on members/folder creator is optional for legacy.
- App login calls /v1/account/folders and persists the returned {folder,
  membership} through existing save validation. Session and expiry are securely
  stored per origin. UI login is explicit before create/join; account name and
  logout are shown. Login failure cannot silently become an anonymous account.
- UI explains free limit. Server remains authoritative after device changes or
  local metadata loss. Multiple passkey accounts remain possible, so this is
  one folder per account, not proof of one physical human.

## Deployment

- New manual GitHub Actions workflow uses `CLOUDFLARE_API_TOKEN` repository
  secret; optional `CLOUDFLARE_ACCOUNT_ID` selects an account. A scoped token
  with one accessible account can discover its ID. Refuse ambiguous targets.
- Token is a Cloudflare management API token, not R2 S3 access keys or a Global
  API key. Never embed it in the app, commit it, or print it.
- Deployment helper provisions/reuses the configured private R2 bucket, refuses
  existing public exposure, generates deployment configuration without changing
  tracked files, deploys Worker and Durable Object migrations, and prints the
  service URL. R2 activation is an account prerequisite, not automated billing.
- No deployment runs on ordinary pushes/PRs. No live deployment without the
  credential/target. Tests and Wrangler dry-run remain independent of secrets.

## Verification

Focused workerd tests cover a real synthetic WebAuthn registration/assertion,
wrong origin/UV/replay, PKCE/session expiry, same-account concurrent creation,
independent accounts, owner close/replacement, failed/lost response retry,
forged internal headers and legacy access. Client tests cover origin-bound
sessions, callback/state/PKCE, stable creation retries and free limit; use CI because local
flutter_tester is blocked by Windows Application Control. Deployment tests use
mock API/process boundaries and exercise existing/missing buckets, target
ambiguity, public bucket rejection, and secret-free dry-run.

Passkeys belong to the chosen Worker/domain; changing the production origin
later needs a migration. Face ID/browser interaction and two-phone restoration
require deployed HTTPS and real phones; do not claim them tested by CI.
