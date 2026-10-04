# R2 shared sound folders

## Intent and scope

Friends collect their own recorded video/sounds in one private folder, download
each other's sounds and use them in the existing on-device music maker. A person
creates a folder, shares an invitation, friends join under a display name, and
members explicitly upload sounds from their personal stock. Refresh retrieves new
contributions. Existing local folders and originals remain local and intact.

New subsystem: Cloudflare Worker + one SQLite-backed Durable Object per folder +
a private R2 bucket. Do not expose R2 credentials, bucket URLs or public access.
No account system, payments, push notifications, live co-editing, or automatic
upload of all existing sounds in this change. Join links grant contribution rights;
tell people to send them only to intended participants. An owner can revoke a
member, replace an invitation and close a folder. Revocation cannot erase copies
already downloaded onto another phone.

## API contract (v1)

All API paths are relative to one HTTPS origin. Native clients use Authorization:
Bearer <member token> except create/join. Responses are JSON, errors are
{error: {code: string, message: string}} with appropriate 400/401/403/404/409/413/
429/500 status. Tokens are cryptographically random 32-byte hex strings, only
SHA-256 hashes persist server-side. No secrets in server logs. Dates are UTC ISO.

POST /v1/folders {title, displayName} -> 201 {membership, folder}
POST /v1/folders/:id/join {inviteToken, displayName} -> {membership, folder}
GET /v1/folders/:id -> {folder}
PATCH /v1/folders/:id {title} -> {folder}, owner only
POST /v1/folders/:id/invite -> {inviteUrl, expiresAt}, owner only, replaces prior
invitation, lifetime seven days; existing members stay joined.
DELETE /v1/folders/:id/members/:memberId -> {ok:true}, owner or self (owner cannot
leave without closing the folder).
DELETE /v1/folders/:id -> {ok:true}, owner only; revoke access and clean R2 files.

PUT /v1/folders/:id/clips/:clipId -> {clip}; body is video bytes, Content-Length
is required and must match metadata.sizeBytes. X-Clip-Metadata contains unpadded
base64url of UTF-8 JSON: {label, sha256, sizeBytes, durationUs, width, height,
rotation, audioTrackStartUs, selectionStartUs, selectionDurationUs, extension}.
Content-Type video/mp4 or video/quicktime. clipId = clip.sha256 (64 lower hex);
idempotent retries return an already-completed clip without overwriting it.
Pending reservations consume quota, expire after ten minutes and are cleaned.
Validate byte limits while streaming and R2 SHA-256 on put before publishing.
GET /v1/folders/:id/clips/:clipId/file -> authenticated video stream, no-store.
PUT /v1/folders/:id/clips/:clipId/thumbnail -> JPEG/PNG bytes, max 512 KiB,
uploader or owner; sets hasThumbnail true after successful put.
GET /v1/folders/:id/clips/:clipId/thumbnail -> authenticated image or 404.
DELETE /v1/folders/:id/clips/:clipId -> {ok:true}, uploader or owner, frees quota.

membership = {folderId, memberId, token, role: 'owner'|'member', title}
folder = {id, title, createdAt, members:[{id, displayName, role}], clips:[clip],
limits:{maxClipBytes:52428800,maxFolderBytes:1073741824,maxClips:200,maxMembers:20}}
clip = metadata + {id, memberId, memberName, createdAt, hasThumbnail: bool}
Display names 1..30 Unicode code points, folder titles/clip labels 1..40.
Video duration <= 180 seconds; positive dimensions, sane selected range and
rotation in 0/90/180/270. Reject malformed IDs, traversal, and invalid JSON.

POST /v1/folders creates a server-generated UUID folder ID and owner credentials;
the Worker routes it internally to the appropriate Durable Object. All mutations
revalidate membership; serialise object mutations across awaited R2 operations to
avoid quota, deletion and revocation races. Rate limit create/join and general API
calls with Workers rate-limit bindings. The limits are guardrails for a small
friends feature, not a complete public-account abuse or billing system.

GET /invite/:folderId returns a static landing page. inviteUrl is
https://<worker>/invite/<folderId>#<inviteToken>. The token stays in a fragment,
out of ordinary HTTP request logs. The landing page builds
otograshi://invite?url=<encoded HTTPS invitation> client-side and offers an app
open action plus a copy-link fallback. Never embed user folder labels into HTML.

## Flutter boundary

New files under lib/sharing/. Use dart:io streamed HTTP, timeouts, no redirects on
authenticated calls, HTTPS origin validation, secure credentials via
flutter_secure_storage. App accepts invitation by paste and iOS custom URL scheme
via app_links. A join action is explicit and displays the invitation server.
Configured service URL comes from OTO_SHARED_API_URL or a locally stored URL.
An unconfigured install can learn the server from the invitation; existing
credentials always stay bound to their origin. No automatic join merely on opening
a link. Startup/onboarding may delay showing the pending invite, but must retain it.

SharedFolderMembership: folderId, memberId, role, title, server Uri (no token in UI).
SharedMember: id, displayName, role.
SharedClip: API clip properties (id, label, memberId, memberName, sha256,
sizeBytes, durationUs, width, height, rotation, selectionStartUs,
selectionDurationUs, audioTrackStartUs, extension, createdAt, hasThumbnail).
SharedFolder: id, title, createdAt, members, clips, limits.

SharedFolderService (concrete service with injectable dependencies):
- Future<List<SharedFolderMembership>> listMemberships()
- Future<Uri?> configuredServer()
- Future<void> configureServer(String url)
- Future<SharedFolder> createFolder(String title, String displayName)
- Future<SharedFolder> joinFolder(String invitation, String displayName)
- Future<SharedFolder> refresh(String folderId)
- Future<Uri> invite(String folderId)
- Future<void> renameFolder(String folderId, String title)
- Future<void> upload(String folderId, ClipAsset asset,
  {Uint8List? thumbnail, void Function(double)? onProgress})
- Future<Uint8List?> thumbnail(String folderId, String clipId)
- Future<ClipAsset> download(String folderId, SharedClip clip,
  {void Function(double)? onProgress})
- Future<void> deleteClip(String folderId, String clipId)
- Future<void> removeMember(String folderId, String memberId)
- Future<void> leaveFolder(String folderId)
- Future<void> deleteFolder(String folderId)
- void close()

The service takes ProjectDatabase, AssetRepository and an injectable secure store/
transport. It exposes no credential tokens in public membership types. Reuse
local assets by SHA-256 when importing; protect the download with expected byte
count + SHA-256 and native media inspection, then asset repository commit; keep
temporary downloads outside originals and clean after failure. Never delete local
originals when a shared folder/clip is removed. Preserve selection defaults for new
imports where valid; do not rewrite an existing local asset's selection globally.

Shared folder screen: create/join, folder list, invite, participant list and role,
refresh, sound cards with contributor, thumbnail, upload progress and download/
use actions. Device-bound membership persists across restarts. Errors must be
readable and leave a retry action. User-visible UI uses existing OtoGrashi tokens;
no infrastructure names in the ordinary sharing flow. Configuration appears only
when service URL is missing. Shared imported clips can go straight to
CreationController.addExistingClips (or existing equivalent).

## Verification and deployment

Focused integration tests against real local Workers/R2/Durable Object runtime:
two members create/join/contribute/fetch; outsider rejection; invite rotation;
permission checks; concurrent quota/idempotency; interrupted/bad hash upload;
delete/revoke behavior. Dart tests for invitation/origin binding, persistence,
download integrity and local deduplication. One UI flow test where useful;
no tests for every decoration. Run Flutter analyze and related existing screens.
No repeated full app builds. Worker dry-run plus one iOS integration/build at the
feature boundary only. No real Cloudflare deployment without an authenticated
account and explicit target information. Document exact dashboard/CLI steps and
distinguish implementation/local verification from live availability.

Sources consulted: Cloudflare R2 Workers API, SQLite Durable Object storage,
Workers rate-limit bindings, pub.dev flutter_secure_storage/app_links official
package documentation (2026-10-05).
