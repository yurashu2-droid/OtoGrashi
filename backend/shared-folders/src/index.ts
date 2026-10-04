import { DurableObject } from 'cloudflare:workers';
import { AuthAccounts, authAsset } from './auth';
export { AuthAccounts };

export interface Env {
  AUTH_ACCOUNTS: DurableObjectNamespace<AuthAccounts>;
  FOLDERS: DurableObjectNamespace<SharedFolder>;
  FILES: R2Bucket;
  ENTRY_LIMIT: RateLimit;
  API_LIMIT: RateLimit;
}
export const LIMITS = { maxClipBytes: 52428800, maxFolderBytes: 1073741824, maxClips: 200, maxMembers: 20 };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const HASH = /^[0-9a-f]{64}$/;
const TEN_MINUTES = 600000;
interface Member { id: string; displayName: string; role: 'owner' | 'member'; hash: string; hashes?: string[]; accountId?: string }
interface Metadata {
  label: string; sha256: string; sizeBytes: number; durationUs: number; width: number; height: number;
  rotation: number; audioTrackStartUs: number; selectionStartUs: number; selectionDurationUs: number; extension: string;
}
interface Clip extends Metadata { id: string; memberId: string; memberName: string; createdAt: string; hasThumbnail: boolean }
interface StoredClip { clip: Clip; key: string; thumbnailKey?: string }
interface Reservation { key: string; size: number; expires: number }
interface FolderState {
  id: string; title: string; createdAt: string; closed: boolean; members: Member[];
  clips: Record<string, StoredClip>; pending: Record<string, Reservation>;
  garbage: string[]; invite?: { hash: string; expiresAt: string };
}
class ApiError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) { super(message); }
}
export function fail(status: number, code: string, message: string): never { throw new ApiError(status, code, message); }
export function json(value: unknown, status = 200): Response {
  return Response.json(value, { status, headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' } });
}
export function errorResponse(error: unknown): Response {
  return error instanceof ApiError ? json({ error: { code: error.code, message: error.message } }, error.status)
    : json({ error: { code: 'internal', message: 'The service could not complete the request. Please retry.' } }, 500);
}
function hex(bytes: Uint8Array): string { return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join(''); }
export function token(): string { return hex(crypto.getRandomValues(new Uint8Array(32))); }
export async function hash(value: string): Promise<string> { return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)))); }
export function text(value: unknown, maximum: number): string {
  if (typeof value !== 'string' || !value.trim() || [...value].length > maximum || /[\u0000-\u001f\u007f]/.test(value))
    fail(400, 'invalid_text', `Text must contain 1 to ${maximum} characters.`);
  return value;
}
function integer(value: unknown, min: number, max: number): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < min || value > max)
    fail(400, 'invalid_metadata', 'Invalid numeric metadata.');
  return value;
}
async function boundedBytes(request: Request, maximum: number): Promise<Uint8Array> {
  if (!request.body) fail(400, 'missing_body', 'A request body is required.');
  const reader = request.body.getReader(); const chunks: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const { done, value } = await timedRead(reader);
      if (done) break;
      size += value.byteLength;
      if (size > maximum) fail(413, 'body_too_large', 'Request body exceeds the limit.');
      chunks.push(value);
    }
  } catch (e) { await reader.cancel().catch(() => {}); throw e; }
  const result = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result;
}
async function timedRead(reader: ReadableStreamDefaultReader<Uint8Array>): Promise<ReadableStreamReadResult<Uint8Array>> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([reader.read(), new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new ApiError(400, 'upload_timeout', 'Upload stalled. Please retry.')), 30000);
    })]);
  } finally { if (timer !== undefined) clearTimeout(timer); }
}
export async function bodyJson(request: Request): Promise<Record<string, unknown>> {
  try {
    const value: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(await boundedBytes(request, 8192)));
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
    return value as Record<string, unknown>;
  } catch (e) { if (e instanceof ApiError) throw e; fail(400, 'invalid_json', 'Invalid JSON object.'); }
}
function metadata(request: Request, id: string): Metadata {
  const encoded = request.headers.get('X-Clip-Metadata') ?? '';
  if (!/^[A-Za-z0-9_-]+$/.test(encoded) || encoded.length > 8192) fail(400, 'invalid_metadata', 'Invalid clip metadata.');
  let m: Record<string, unknown>;
  try {
    const bytes = Uint8Array.from(atob(encoded.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));
    m = JSON.parse(new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(bytes));
    if (!m || typeof m !== 'object' || Array.isArray(m)) throw new Error();
  } catch { fail(400, 'invalid_metadata', 'Invalid clip metadata.'); }
  const contentType = request.headers.get('Content-Type');
  if (!((contentType === 'video/mp4' && m.extension === 'mp4') || (contentType === 'video/quicktime' && m.extension === 'mov')))
    fail(400, 'invalid_media_type', 'Use MP4 or QuickTime with a matching extension.');
  if (m.sha256 !== id) fail(400, 'invalid_hash', 'Clip ID must equal its SHA-256.');
  const sizeBytes = integer(m.sizeBytes, 1, Number.MAX_SAFE_INTEGER);
  if (sizeBytes > LIMITS.maxClipBytes) fail(413, 'clip_too_large', 'Clip exceeds 50 MiB.');
  const durationUs = integer(m.durationUs, 1, 180000000);
  const selectionStartUs = integer(m.selectionStartUs, 0, durationUs - 1);
  const selectionDurationUs = integer(m.selectionDurationUs, 1, durationUs - selectionStartUs);
  const rotation = integer(m.rotation, 0, 270);
  if (![0, 90, 180, 270].includes(rotation)) fail(400, 'invalid_metadata', 'Invalid rotation.');
  const length = request.headers.get('Content-Length');
  if (!length || !/^[0-9]+$/.test(length) || Number(length) !== sizeBytes)
    fail(400, 'invalid_length', 'Content-Length must equal sizeBytes.');
  return { label: text(m.label, 40), sha256: id, sizeBytes, durationUs,
    width: integer(m.width, 1, 32768), height: integer(m.height, 1, 32768), rotation,
    audioTrackStartUs: integer(m.audioTrackStartUs, 0, durationUs), selectionStartUs, selectionDurationUs, extension: m.extension as string };
}
function landing(): Response {
  // No fragment, title, credentials or other untrusted strings are interpolated in HTML.
  return new Response(`<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OtoGrashi invitation</title><body><h1>OtoGrashi の共有フォルダー</h1><p>アプリで招待を確認してから参加してください。</p><a id="open">アプリを開く</a><button id="copy">招待リンクをコピー</button><p id="status"></p><script src="/invite.js"></script></body></html>`, {
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer',
      'Content-Security-Policy': "default-src 'none'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'", 'X-Content-Type-Options': 'nosniff' }
  });
}
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (url.protocol !== 'https:' && url.hostname !== 'localhost' && url.hostname !== '127.0.0.1')
        fail(400, 'https_required', 'Use HTTPS.');
      // Native API only. Reject browser cross-origin requests rather than enabling CORS.
      const origin = request.headers.get('Origin');
      if (origin && origin !== url.origin) fail(403, 'origin_forbidden', 'Cross-origin requests are not permitted.');
      const actor = await hash(request.headers.get('CF-Connecting-IP') ?? 'local');
      if (!(await env.API_LIMIT.limit({ key: actor })).success) fail(429, 'rate_limited', 'Please wait before retrying.');
      if (request.method === 'GET' && url.pathname === '/invite.js') return new Response(
        `const t=location.hash.slice(1);const ok=/^[0-9a-f]{64}$/.test(t);const link=location.href;const a=document.getElementById('open');if(ok){a.href='otograshi://invite?url='+encodeURIComponent(link)}else{a.remove();document.getElementById('status').textContent='招待リンクが正しくありません。'}document.getElementById('copy').onclick=async()=>{try{await navigator.clipboard.writeText(link);document.getElementById('status').textContent='コピーしました。'}catch{document.getElementById('status').textContent=link;}};`,
        { headers: { 'Content-Type': 'application/javascript', 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' } });
      if (request.method === 'GET' && /^\/invite\/[0-9a-f-]+$/.test(url.pathname)) {
        if (!UUID.test(url.pathname.split('/')[2])) fail(400, 'invalid_id', 'Invalid folder ID.');
        return landing();
      }
      if (url.search) fail(400, 'invalid_path', 'Query parameters are not supported.');
      if (request.method === 'GET') { const asset = authAsset(url.pathname); if (asset) return asset; }
      const accountRoute = url.pathname.startsWith('/v1/auth/') || url.pathname === '/v1/account' || url.pathname === '/v1/account/folders';
      if (accountRoute) return await env.AUTH_ACCOUNTS.get(env.AUTH_ACCOUNTS.idFromName('accounts')).fetch(request);
      const create = request.method === 'POST' && url.pathname === '/v1/folders';
      const parts = url.pathname.split('/');
      if (!create && (parts[1] !== 'v1' || parts[2] !== 'folders')) fail(404, 'not_found', 'Route not found.');
      const id = create ? crypto.randomUUID() : parts[3];
      if (!UUID.test(id ?? '')) fail(400, 'invalid_id', 'Invalid folder ID.');
      if (create || (request.method === 'POST' && parts[4] === 'join')) {
        if (!(await env.ENTRY_LIMIT.limit({ key: actor })).success) fail(429, 'rate_limited', 'Please wait before creating or joining another folder.');
      }
      if (create || (request.method === 'POST' && parts[4] === 'join')) return await env.AUTH_ACCOUNTS.get(env.AUTH_ACCOUNTS.idFromName('accounts')).fetch(request);
      if (create) url.pathname = `/v1/folders/${id}/create`;
      // Internal create route cannot be reached by the public API.
      else if (parts[4] === 'create') fail(404, 'not_found', 'Route not found.');
      return await env.FOLDERS.get(env.FOLDERS.idFromName(id)).fetch(new Request(url, request));
    } catch (e) { return errorResponse(e); }
  }
} satisfies ExportedHandler<Env>;

export class SharedFolder extends DurableObject<Env> {
  private queue: Promise<unknown> = Promise.resolve();
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS folder_state (id INTEGER PRIMARY KEY CHECK(id=1), data TEXT NOT NULL)');
  }
  private exclusive<T>(work: () => Promise<T>): Promise<T> {
    const next = this.queue.then(work, work); this.queue = next.catch(() => {}); return next;
  }
  private load(): FolderState | undefined {
    const row = this.ctx.storage.sql.exec<{ data: string }>('SELECT data FROM folder_state WHERE id=1').toArray()[0];
    return row ? JSON.parse(row.data) as FolderState : undefined;
  }
  private save(s: FolderState): void {
    this.ctx.storage.sql.exec('INSERT INTO folder_state (id,data) VALUES (1,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data', JSON.stringify(s));
  }
  private view(s: FolderState) {
    return { id: s.id, title: s.title, createdAt: s.createdAt,
      members: s.members.map(({ id, displayName, role }) => ({ id, displayName, role })),
      clips: Object.values(s.clips).map(c => c.clip), limits: LIMITS };
  }
  async isInitialized(): Promise<boolean> { return this.load() !== undefined; }
  async isClosed(): Promise<boolean> { return this.load()?.closed === true; }
  async accountAccess(input: { accountId: string; displayName: string; create?: {id:string;title:string}; inviteToken?:string }): Promise<{folder: ReturnType<SharedFolder['view']>;membership:{folderId:string;memberId:string;token:string;role:string;title:string}} | {rpcError:{status:number;code:string;message:string}} | null> {
    return this.exclusive(async () => {
      let s=this.load();
      if(!s && input.create) { s={id:input.create.id,title:input.create.title,createdAt:new Date().toISOString(),closed:false,members:[],clips:{},pending:{},garbage:[]}; this.save(s); }
      if(!s || s.closed) return null;
      let m=s.members.find(m=>m.accountId===input.accountId);
      if(!m) {
        if(!input.create) {
          if(typeof input.inviteToken!=='string'||!HASH.test(input.inviteToken)||!s.invite||Date.parse(s.invite.expiresAt)<=Date.now()||await hash(input.inviteToken)!==s.invite.hash) fail(403,'invalid_invite','Invitation has expired or been replaced.');
          if(s.members.length>=LIMITS.maxMembers) fail(409,'member_limit','Folder has reached its member limit.');
        } else if(s.members.length) fail(403,'owner_required','Folder belongs to another account.');
        m={id:crypto.randomUUID(),displayName:input.displayName,role:input.create?'owner':'member',hash:'',accountId:input.accountId};s.members.push(m);
      }
      const t=token();
      const digest=await hash(t); const hashes=m.hashes??(m.hash?[m.hash]:[]); if(!hashes.includes(digest)) hashes.push(digest); m.hashes=hashes.slice(-10);m.hash=m.hashes[0];this.save(s);
      return {folder:this.view(s),membership:{folderId:s.id,memberId:m.id,token:t,role:m.role,title:s.title}};
    }).catch(e => { if(e instanceof ApiError) return {rpcError:{status:e.status,code:e.code,message:e.message}}; throw e; });
  }
  private async member(s: FolderState, request: Request): Promise<Member> {
    const bearer = request.headers.get('Authorization') ?? '';
    if (!/^Bearer [0-9a-f]{64}$/.test(bearer)) fail(401, 'unauthorized', 'Membership credentials are required.');
    const digest = await hash(bearer.slice(7));
    const member = s.members.find(m => m.hash === digest || m.hashes?.includes(digest));
    if (!member) fail(401, 'unauthorized', 'Membership has expired or been revoked.');
    return member;
  }
  private owner(m: Member): void { if (m.role !== 'owner') fail(403, 'owner_required', 'Only the owner can do this.'); }
  private contributor(m: Member, c: StoredClip): void {
    if (m.role !== 'owner' && m.id !== c.clip.memberId) fail(403, 'uploader_required', 'Only the contributor or owner can do this.');
  }
  private async schedule(s: FolderState): Promise<void> {
    const expires = Object.values(s.pending).map(p => p.expires);
    if (s.garbage.length || s.closed) expires.push(Date.now() + 60000);
    if (expires.length) await this.ctx.storage.setAlarm(Math.min(...expires));
    else await this.ctx.storage.deleteAlarm();
  }
  private async cleanup(s: FolderState): Promise<void> {
    for (const [id, p] of Object.entries(s.pending)) {
      if (p.expires <= Date.now()) { s.garbage.push(p.key); delete s.pending[id]; }
    }
    this.save(s);
    if (s.closed) {
      // Tombstone remains permanently; alarm retries deletion after crashes or R2 errors.
      let cursor: string | undefined;
      do {
        const list = await this.env.FILES.list({ prefix: `${s.id}/`, cursor });
        if (list.objects.length) await this.env.FILES.delete(list.objects.map(o => o.key));
        cursor = list.truncated ? list.cursor : undefined;
      } while (cursor);
      s.garbage = [];
    } else if (s.garbage.length) {
      await this.env.FILES.delete(s.garbage); s.garbage = [];
    }
    this.save(s);
    if (s.closed) await this.ctx.storage.deleteAlarm(); else await this.schedule(s);
  }
  async alarm(): Promise<void> {
    await this.exclusive(async () => { const s = this.load(); if (s) await this.cleanup(s); });
  }
  async fetch(request: Request): Promise<Response> {
    return this.exclusive(async () => {
      try { return await this.route(request); } catch (e) { return errorResponse(e); }
    });
  }
  private async route(request: Request): Promise<Response> {
    const url = new URL(request.url); const p = url.pathname.split('/'); const id = p[3];
    let s = this.load();
    if (!s || s.closed) fail(404, 'folder_not_found', 'Folder is unavailable.');
    if (s.id !== id) fail(400, 'invalid_id', 'Invalid folder ID.');
    if (Object.values(s.pending).some(r => r.expires <= Date.now())) await this.cleanup(s);
    const m = await this.member(s, request);
    if (p.length === 4) {
      if (request.method === 'GET') return json({ folder: this.view(s) });
      if (request.method === 'PATCH') { this.owner(m); const b = await bodyJson(request); s.title = text(b.title, 40); this.save(s); return json({ folder: this.view(s) }); }
      if (request.method === 'DELETE') {
        this.owner(m); s.closed = true; s.members = []; delete s.invite; this.save(s); await this.schedule(s);
        await this.cleanup(s); return json({ ok: true });
      }
    }
    if (p.length === 5 && p[4] === 'invite' && request.method === 'POST') {
      this.owner(m); const t = token(); const expiresAt = new Date(Date.now() + 7 * 86400000).toISOString();
      s.invite = { hash: await hash(t), expiresAt }; this.save(s);
      return json({ inviteUrl: `${url.origin}/invite/${id}#${t}`, expiresAt });
    }
    if (p.length === 6 && p[4] === 'members' && request.method === 'DELETE') {
      if (!UUID.test(p[5])) fail(400, 'invalid_id', 'Invalid member ID.');
      if (m.role !== 'owner' && m.id !== p[5]) fail(403, 'owner_required', 'Only the owner can remove other members.');
      const target = s.members.find(x => x.id === p[5]);
      if (!target) fail(404, 'member_not_found', 'Member not found.');
      if (target.role === 'owner') fail(409, 'owner_cannot_leave', 'The owner must close the folder to leave.');
      s.members = s.members.filter(x => x.id !== target.id); this.save(s); return json({ ok: true });
    }
    if (p[4] !== 'clips' || (p.length !== 6 && p.length !== 7)) fail(404, 'not_found', 'Route not found.');
    const clipId = p[5]; if (!HASH.test(clipId)) fail(400, 'invalid_id', 'Invalid clip ID.');
    let stored = s.clips[clipId];
    if (request.method === 'PUT' && p.length === 6) {
      const meta = metadata(request, clipId);
      if (stored) {
        if (stored.clip.sizeBytes !== meta.sizeBytes) fail(409, 'clip_conflict', 'A different clip already exists.');
        // A completed content-addressed clip never gets overwritten, including another member's retry.
        return json({ clip: stored.clip });
      }
      if (s.pending[clipId]) fail(409, 'upload_pending', 'Upload is pending. Please retry later.');
      const reservations = Object.values(s.pending);
      const clips = Object.values(s.clips);
      if (clips.length + reservations.length >= LIMITS.maxClips ||
        clips.reduce((n, c) => n + c.clip.sizeBytes, 0) + reservations.reduce((n, r) => n + r.size, 0) + meta.sizeBytes > LIMITS.maxFolderBytes)
        fail(409, 'folder_limit', 'Folder storage limit reached.');
      const key = `${id}/clips/${clipId}/${crypto.randomUUID()}`;
      s.pending[clipId] = { key, size: meta.sizeBytes, expires: Date.now() + TEN_MINUTES };
      this.save(s); await this.schedule(s);
      try {
        await this.putVideo(request, key, meta);
        stored = { key, clip: { ...meta, id: clipId, memberId: m.id, memberName: m.displayName, createdAt: new Date().toISOString(), hasThumbnail: false } };
        s.clips[clipId] = stored; delete s.pending[clipId]; this.save(s); await this.schedule(s);
        return json({ clip: stored.clip });
      } catch (e) {
        // Remove publication and persist cleanup before attempting R2 deletion.
        delete s.clips[clipId]; delete s.pending[clipId]; s.garbage.push(key); this.save(s); await this.schedule(s);
        await this.cleanup(s).catch(() => {});
        if (e instanceof ApiError) throw e;
        fail(400, 'upload_integrity', 'Upload failed its size or SHA-256 check. Please retry.');
      }
    }
    if (!stored) fail(404, 'clip_not_found', 'Clip not found.');
    if (request.method === 'DELETE' && p.length === 6) {
      this.contributor(m, stored); s.garbage.push(stored.key); if (stored.thumbnailKey) s.garbage.push(stored.thumbnailKey);
      delete s.clips[clipId]; this.save(s); await this.schedule(s); await this.cleanup(s); return json({ ok: true });
    }
    if (p.length === 7 && p[6] === 'thumbnail' && request.method === 'PUT') {
      this.contributor(m, stored);
      const type = request.headers.get('Content-Type');
      if (type !== 'image/jpeg' && type !== 'image/png') fail(400, 'invalid_media_type', 'Use JPEG or PNG.');
      const bytes = await boundedBytes(request, 524288);
      const jpeg = bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255;
      const png = [137, 80, 78, 71, 13, 10, 26, 10].every((b, i) => bytes[i] === b);
      if (!(type === 'image/jpeg' ? jpeg : png)) fail(400, 'invalid_image', 'Image signature does not match Content-Type.');
      const key = `${id}/thumbnails/${clipId}/${crypto.randomUUID()}`;
      // Persist staged object for crash recovery before writing.
      s.garbage.push(key); this.save(s); await this.schedule(s);
      await this.env.FILES.put(key, bytes, { httpMetadata: { contentType: type } });
      if (stored.thumbnailKey) s.garbage.push(stored.thumbnailKey);
      stored.thumbnailKey = key; stored.clip.hasThumbnail = true;
      s.garbage = s.garbage.filter(x => x !== key); this.save(s); await this.schedule(s);
      return json({ clip: stored.clip });
    }
    if (p.length === 7 && request.method === 'GET' && (p[6] === 'file' || p[6] === 'thumbnail')) {
      const key = p[6] === 'file' ? stored.key : stored.thumbnailKey;
      if (!key) fail(404, 'thumbnail_not_found', 'Thumbnail not found.');
      const object = await this.env.FILES.get(key);
      if (!object) fail(404, 'file_not_found', 'File not found.');
      return new Response(object.body, { headers: { 'Content-Type': object.httpMetadata?.contentType ?? 'application/octet-stream',
        'Content-Length': String(object.size), 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
        'Content-Disposition': 'attachment' } });
    }
    fail(404, 'not_found', 'Route not found.');
  }
  private async putVideo(request: Request, key: string, meta: Metadata): Promise<void> {
    if (!request.body) fail(400, 'missing_body', 'Video body required.');
    // FixedLengthStream supplies the known length required by R2 without buffering 50 MiB.
    const fixed = new FixedLengthStream(meta.sizeBytes); const writer = fixed.writable.getWriter();
    const reader = request.body.getReader();
    const put = this.env.FILES.put(key, fixed.readable, { sha256: meta.sha256,
      httpMetadata: { contentType: request.headers.get('Content-Type')! } }).catch(async e => {
        await writer.abort(e).catch(() => {}); await reader.cancel().catch(() => {}); throw e;
      });
    const pump = (async () => {
      let size = 0; const deadline = Date.now() + TEN_MINUTES;
      try {
        while (true) {
          const { done, value } = await timedRead(reader);
          if (done) break;
          size += value.byteLength;
          if (size > meta.sizeBytes || Date.now() >= deadline) fail(400, 'invalid_length', 'Upload exceeds its declared size or time limit.');
          await writer.write(value);
        }
        if (size !== meta.sizeBytes) fail(400, 'invalid_length', 'Upload ended before its declared size.');
        await writer.close();
      } catch (e) { await writer.abort(e).catch(() => {}); await reader.cancel().catch(() => {}); throw e; }
    })();
    const results = await Promise.allSettled([put, pump]);
    for (const result of results) if (result.status === 'rejected') throw result.reason;
  }
}
