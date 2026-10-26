# OtoGrashi private shared folders

Implements the v1 contract in `../../docs/superpowers/specs/2026-10-05-r2-shared-folders-design.md`.
One SQLite Durable Object holds each folder's membership, invitation hashes,
clip metadata and reservations. A separate SQLite Durable Object verifies
passkeys and manages account sessions and the free owned-folder quota. A third
one holds the public [song catalogue](#song-catalogue).
The R2 bucket must stay private. Cloudflare credentials never belong in the app.

The account contract is in
`../../docs/superpowers/specs/2026-10-05-sharing-free-limit-design.md`.
Registration/login uses a same-origin web page and the pinned
`@simplewebauthn/server` 13.3.3 / browser 13.3.0 packages. The native iOS app opens
that page with ASWebAuthenticationSession, verifies the callback state and
exchanges a one-use code with SHA-256 PKCE. Authentication requires user
verification and discoverable credentials; the relying-party ID is the service
hostname. Keep this hostname stable after users register passkeys.

## Local verification

Use Node.js 22.15 or newer, with npm on PATH, from this directory:

```sh
npm ci
npm test
npm run typecheck
npm run build
npm run dev
```

`test` bundles the real Worker into local workerd/Miniflare with SQLite, R2 and
rate-limit bindings. It covers two contributors, unauthorized access, owner and
uploader permissions, origin rejection, invite rotation/expiry, hashed storage,
concurrent idempotency and quota, checksum failures, truncated input, expired
reservations, revocation and deletion. A test-only Durable Object subclass
simulates truncation after the HTTP boundary; it is excluded from the deployment
bundle. Near-quota fixtures use test-only SQLite inspection rather than uploading
a GiB. `test/songs.test.ts` covers the song catalogue the same way: every score
rule, paging, the account limits, use counting, reports, removal and the
operator secret. `test/account.test.ts` covers deleting an account and the
`poster` key. `build` is a dry run and does not deploy. Dependencies and lockfile are
pinned together; the current Wrangler release depends on a Miniflare 5 alpha,
which is development tooling only. SimpleWebAuthn ships in the Worker and its
same-origin browser bundle; no external CDN is required.

`wrangler dev` serves localhost. Local requests may use HTTP only for localhost
or 127.0.0.1; the native application still requires an HTTPS origin. Local data is
under `.wrangler/` and is separate from Cloudflare data.

## Deployment (operator action; not performed by this implementation)

The recommended path is the manual **Deploy shared folders** GitHub workflow:
see [deployment instructions](../../docs/shared-folders-deploy.md). Supply a
Cloudflare management API token through the repository secret
`CLOUDFLARE_API_TOKEN`; the helper creates/reuses a private bucket and reports the
HTTPS service URL. Account selection is automatic only when the token can
access one account. `npm run deploy -- --dry-run` is credential-free.

For direct Wrangler deployment:

1. Select the intended Cloudflare account. Enable Workers and R2 in that account.
   In the R2 dashboard create a bucket named `otograshi-shared-folders-private`,
   or change `r2_buckets[0].bucket_name` to your chosen private bucket name.
   Keep **Public development URL (r2.dev) disabled** and attach no public custom
   domain. Do not provision S3 credentials for the application.
2. In `wrangler.jsonc`, choose a unique Worker `name`. Keep the Durable Object
   bindings/classes and the `v1`, `v2` and `v3` SQLite migrations; Wrangler creates the namespaces on
   deployment. Select two unused positive integer rate-limit namespace IDs in
   your account (default `1001` and `1002`). IDs shared by other Workers share
   their counters, so change them if already used.
3. Authenticate and verify the target, then create the bucket via CLI if it was
   not created in the dashboard:

   ```sh
   npx wrangler login
   npx wrangler whoami
   npx wrangler r2 bucket create otograshi-shared-folders-private
   npm run build
   npx wrangler deploy
   ```

   Skip `bucket create` when the bucket already exists. Do not run deployment
   until the intended account and name have been confirmed. These commands are
   documentation, not evidence of a live deployment.
4. Use the HTTPS `workers.dev` origin printed by Wrangler as the application's
   `OTO_SHARED_API_URL` or configure that origin in the app. For a custom domain,
   configure a Workers Custom Domain in the dashboard, then use its HTTPS origin.
   No path, query or fragment belongs in the configured API origin.
5. Smoke-test passkey registration/login, folder restoration, the one-owned-folder
   quota, create, invite, join, upload, private download, revoke and close
   with two installations. Confirm direct R2 access is unavailable. This local
   verification does not claim live availability or multi-phone verification.

## Security and lifecycle

Member and invitation secrets are independent random 32-byte lowercase hex
tokens. Only SHA-256 hashes persist. Invitations last seven days, and their
secret stays in the HTTPS URL fragment. The static landing page uses an external
same-origin script, a restrictive CSP and `no-referrer`; it builds the app link
client-side. Native API requests have no CORS allowlist; cross-origin browser
requests are rejected. Credentials belong in Authorization headers, never URL
parameters. The implementation logs no request headers, bodies or credentials;
Worker observability is disabled in the supplied config. Do not add middleware
or logs that record secrets.

The general API limiter allows 120 requests/minute; create/join, posting or
reporting a song, and deleting an account share an
additional 10 requests/minute limit keyed by a hash of the Cloudflare client IP.
People sharing a NAT also share the IP-based entry limits. Cloudflare rate limits are per-location guardrails, not an
exact global cap or billing protection. Required bindings fail closed if absent.

The per-object queue serializes reads/mutations across R2 awaits; revocation and
deletion cannot race upload publication. File uploads stream through a bounded
FixedLengthStream with R2's expected SHA-256 and matching required Content-Length.
Inputs stalled for 30 seconds fail; the total input transfer budget is ten
minutes. Failed uploads never enter the visible clip list. Every attempt has a
unique private R2 key, so completed retries return the original clip/contributor
without overwriting metadata or bytes. Pending attempts consume quota and are
recovered after ten minutes. Alarms clean failed/staged objects; metadata and
tombstones are committed before destructive R2 operations so failures remain
inaccessible and deletion can retry. Closed-folder tombstones remain permanently.
Thumbnails use staged unique keys, are limited to 512 KiB and require matching
JPEG/PNG signatures; replacing one queues its old key for alarm cleanup.

Limits: 50 MiB/clip, 1 GiB/folder, 200 clips, 20 members, 180 seconds/video.
Video metadata is validated, but Workers do not decode video or transcode it;
native media inspection is the client boundary. Thumbnail checks are signature
checks, not full image decoding. Revocation cannot erase an already-started
download or copies on a device. Whole-folder serialization intentionally limits
throughput for this small friends feature; it does not aim to be a public
social network. In production, use monitoring that does not expose credentials
and review usage/quota controls for the chosen account.

API errors are `{error:{code,message}}`; downloads use `Cache-Control: no-store`.
MP4 uses `video/mp4` + `extension: "mp4"`; MOV uses `video/quicktime` + `"mov"`.
Thumbnail PUT returns `{clip}` with `hasThumbnail: true`; its response shape is
unspecified in v1, and this matches the video PUT response shape.

Account sessions live for 30 days; browser login flows/codes expire after five
minutes and challenges are consumed even after a failed verification. An indexed
expiry column and serialized alarm remove expired flows, codes and sessions.
Session,
invite and membership tokens are stored as hashes. Account sessions use the
`X-Oto-Session` header; existing folder requests retain membership Bearer tokens.
New create/join requests require an account. One free account may own one open
folder, while joining other folders does not consume that quota. The account
Durable Object serializes quota decisions, persists a candidate ID before folder
creation, and recovers interrupted requests without creating a second folder.
The private folder RPC is unreachable through public request headers. Existing
legacy membership credentials continue to work; they are not automatically
assigned to a newly registered account. Restoration preserves member identity,
role and display name, and rotates credentials while retaining ten active hashes.

This is an account-level limit, not proof of one account per physical person.
The feature does not include SMS, Apple Sign In, paid plans or alternate recovery
after losing a passkey. Local synthetic WebAuthn verification cannot prove actual
Face ID, iCloud synchronization or two-phone behavior; verify those on a deployed
HTTPS origin before public launch.

## Deleting an account

| Route | Needs | Answer |
| --- | --- | --- |
| `DELETE /v1/account` | account (`X-Oto-Session`) | `{ok: true}`; 401 `account_required` without a session, `session_expired` for an unknown one, 429 `rate_limited` past the entry limit |

The app's in-app account deletion calls this once. It removes, in this order:
every folder the account is in (a folder it owns closes exactly as the owner's
`DELETE /v1/folders/<id>` closes it, so the other members lose access and its
clips and thumbnails are deleted from R2; in any other folder the account leaves
as `DELETE /v1/folders/<id>/members/<memberId>` would, and clips it added there
stay with that folder); its songs (each one still listed becomes the same
tombstone as the poster's `DELETE`, and every row of the account, older
tombstones too, loses its display name, title, credit and score hash and gets a
random stand-in for the account ID; reports the account made on other songs are
deleted, while a song they helped hide stays hidden for the operator); and last,
in one transaction, the account, its passkey credentials, sessions, login flows
and codes, its folder quota and its membership list. Each step accepts having
run before, so if a request fails part-way the same session can simply call
`DELETE` again. Afterwards the old session answers 401 `session_expired`, and the
passkey no longer logs in: it can be deleted from the device, and registering
again creates a new, empty account.

## Song catalogue

`SongCatalog` (binding `SONGS`, migration `v3`, one instance named `catalog`)
holds public songs: small three-lane scores that the app converts from MIDI
files. Anyone can list songs and fetch one to make a piece with it; an account
posts, reports and removes its own. The object has no fetch handler. The Worker
and `AuthAccounts` call it by Durable Object RPC with values they verified
themselves, so public request headers confer no authority there. Everything is
JSON, `no-store` and without query strings; errors are `{error:{code,message}}`.

| Route | Needs | Answer |
| --- | --- | --- |
| `POST /v1/songs` | account | 201 `{song}`, or 200 with the existing song when this account already posted the same score |
| `GET /v1/songs`, `GET /v1/songs/after/<cursor>` | | `{songs, next?}`: public songs, newest first, 30 a page, without lanes; `next` is an opaque cursor |
| `GET /v1/songs/popular` | | `{songs}`: the 30 most used public songs, the newer first among equals |
| `GET /v1/songs/<id>` | | `{song}` with lanes; with the poster's session also their own hidden song |
| `GET /v1/account/songs` | account | `{songs}`: the account's songs with `status`, newest first, without lanes |
| `POST /v1/songs/<id>/use` | | `{uses}`: counted once per client address, song and UTC day |
| `POST /v1/songs/<id>/report` | account | 201 `{ok}`, or 200 when this account had already reported the song |
| `DELETE /v1/songs/<id>` | the poster | `{ok}` |
| `GET /v1/admin/songs/reported` | operator | `{songs}`, each with its `reports` |
| `POST /v1/admin/songs/<id>/hide`, `/restore`, `/remove` | operator | `{song}` with its new `status` |

A list entry is `{id, title, credit, rights, author, poster, beats, uses, createdAt}`;
the account's list adds `status`, and a single song adds `status` and `lanes`.
`author` is the poster's display name when posting. `poster` is an opaque key,
the same on every song of one account and different between accounts, so the
app can let someone block a poster and hide all their songs: the first 32 hex
digits of SHA-256 of `poster:` followed by the account ID. Account IDs never
leave the object.

A post is `{title, credit?, rights, score}` in at most 64 KiB: a title of up to
40 characters, a credit for the composer or source of up to 60, and `rights`,
the poster's own declaration, `own` or `public_domain`. The server cannot check
that declaration. `score` is `{"v":1,"beats":32|64,"lanes":[melody,bass,chords]}`.
A lane is a list of `[startTick, durationTicks, pitch]` integer notes at 480
ticks per beat, sorted by start tick, at most 600 per lane, inside the song and
with a pitch of 0 to 127; the melody must not be empty. Anything else is refused
with 400 and its own code: `invalid_text`, `invalid_rights`, `invalid_score`,
`unsupported_score_version`, `invalid_beats`, `invalid_lanes`, `empty_melody`,
`too_many_notes`, `invalid_note`, `invalid_note_time`, `invalid_pitch` or
`unsorted_notes`. The content hash that recognises a repeated post is the
SHA-256 of `{"beats":32,"lanes":[...]}` written without whitespace.

Limits: an account keeps 30 songs (409 `song_limit`) and posts 10 per UTC day
(429 `post_limit`); a removed song frees its place but still counts for the day
it was posted. A use is remembered as the hashed client address that already
keys the rate limits, the song and the day, and such rows are dropped after two
days. People behind one address count as one listener.

Reports and takedown: a report is `{reason, note?}` with the reason `rights`,
`inappropriate` or `other` and a note of up to 200 characters, one per account
and song; nobody can report their own song. Once three different accounts have
reported a public song it becomes `hidden`: it leaves the lists and only its
poster can still fetch it, until the operator decides. Removing a song, by its
poster or the operator, leaves a tombstone without lanes or reports, so the ID
is never reused; the same score can be posted again and becomes a new song.

Operator routes exist only while the Worker has a secret `ADMIN_TOKEN` of at
least 32 characters. Without it they answer 404 `not_found`. Set it once, after
the Worker is deployed, from this directory with Wrangler authenticated for the
same account:

```sh
node -e "console.log(require('node:crypto').randomBytes(32).toString('hex'))"
npx wrangler secret put ADMIN_TOKEN
```

Paste the generated value at the prompt and keep it out of the repository and
the app. The secret survives later deployments; `npx wrangler secret delete
ADMIN_TOKEN` switches the routes off again. Send it as `X-Oto-Admin: <token>`;
it is compared in constant time, and a wrong one is 401 `admin_required`.
`reported` lists up to 100 songs that have reports, the most recently reported
first, each with `status` and `reports` of `{reason, note, createdAt}` and no
account IDs. `hide` hides a song, `restore` makes it public again and clears its
reports, `remove` takes it down for good:

```sh
curl -H "X-Oto-Admin: $TOKEN" https://<service>/v1/admin/songs/reported
curl -X POST -H "X-Oto-Admin: $TOKEN" https://<service>/v1/admin/songs/<id>/remove
```

## Official references

- [R2 Workers API/checksum validation](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/)
- [SQLite Durable Object storage](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)
- [Workers rate-limit bindings](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)
- [FixedLengthStream](https://developers.cloudflare.com/workers/runtime-apis/streams/transformstream/#fixedlengthstream)
