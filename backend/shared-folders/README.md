# OtoGrashi private shared folders

Implements the v1 contract in `../../docs/superpowers/specs/2026-10-05-r2-shared-folders-design.md`.
One SQLite Durable Object holds each folder's membership, invitation hashes,
clip metadata and reservations. The R2 bucket must stay private. No account
credentials or public bucket URL are needed by the app.

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
a GiB. `build` is a dry run and does not deploy. Dependencies and lockfile are
pinned together; the current Wrangler release depends on a Miniflare 5 alpha,
which is development tooling only. No runtime npm dependencies ship.

`wrangler dev` serves localhost. Local requests may use HTTP only for localhost
or 127.0.0.1; the native application still requires an HTTPS origin. Local data is
under `.wrangler/` and is separate from Cloudflare data.

## Deployment (operator action; not performed by this implementation)

1. Select the intended Cloudflare account. Enable Workers and R2 in that account.
   In the R2 dashboard create a bucket named `otograshi-shared-folders-private`,
   or change `r2_buckets[0].bucket_name` to your chosen private bucket name.
   Keep **Public development URL (r2.dev) disabled** and attach no public custom
   domain. Do not provision S3 credentials for the application.
2. In `wrangler.jsonc`, choose a unique Worker `name`. Keep the Durable Object
   binding/class and `v1` SQLite migration; Wrangler creates the namespace on
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
5. Smoke-test create, invite, join, upload, private download, revoke and close
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

The general API limiter allows 120 requests/minute; create/join share an
additional 10 requests/minute limit keyed by a hash of the Cloudflare client IP.
IP keys are intentional for this accountless entry point: people sharing a NAT
also share limits. Cloudflare rate limits are per-location guardrails, not an
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
account service. In production, use monitoring that does not expose credentials
and review usage/quota controls for the chosen account.

API errors are `{error:{code,message}}`; downloads use `Cache-Control: no-store`.
MP4 uses `video/mp4` + `extension: "mp4"`; MOV uses `video/quicktime` + `"mov"`.
Thumbnail PUT returns `{clip}` with `hasThumbnail: true`; its response shape is
unspecified in v1, and this matches the video PUT response shape.

## Official references

- [R2 Workers API/checksum validation](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/)
- [SQLite Durable Object storage](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)
- [Workers rate-limit bindings](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)
- [FixedLengthStream](https://developers.cloudflare.com/workers/runtime-apis/streams/transformstream/#fixedlengthstream)
