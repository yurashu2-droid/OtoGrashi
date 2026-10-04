import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

let mf: Miniflare;
let sequence = 0;
const origin = 'https://sharing.example';
const digest = (data: Uint8Array) => createHash('sha256').update(data).digest('hex');
before(async () => {
  // Runtime-only subclass injects an interrupted transport after the HTTP boundary.
  // It is bundled only in tests, never exported from the deployment entry point.
  const compiled = await build({ stdin: { resolveDir: process.cwd(), contents: `
    import worker, { SharedFolder as Base } from './src/index.ts';
    export default worker;
    export class SharedFolder extends Base {
      fetch(request) {
        if (request.headers.get('X-Test-Truncated') === 'yes') {
          request = new Request(request, { body: new ReadableStream({ start(c) { c.enqueue(new Uint8Array([1])); c.close(); } }) });
        }
        return super.fetch(request);
      }
    }` }, bundle: true, write: false, format: 'esm', external: ['cloudflare:workers'], target: 'es2022' });
  mf = new Miniflare({ ...convertV4MiniflareOptions({ name: 'sharing', modules: true, script: compiled.outputFiles[0].text, compatibilityDate: '2025-10-11',
    durableObjects: { FOLDERS: { className: 'SharedFolder', useSQLite: true } }, r2Buckets: ['FILES'],
    ratelimits: { API_LIMIT: { namespace_id: '1002', simple: { limit: 120, period: 60 } }, ENTRY_LIMIT: { namespace_id: '1001', simple: { limit: 10, period: 60 } } } }), unsafeInspectDurableObjects: true });
  await mf.ready;
});
after(async () => { await mf?.dispose(); });
async function call(path: string, method = 'GET', token?: string, body?: unknown, headers: Record<string, string> = {}) {
  return mf.dispatchFetch(origin + path, { method, headers: { 'CF-Connecting-IP': `test-${++sequence}`, ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
}
async function data(response: Response | any, status = 200) {
  const value = await response.json(); assert.equal(response.status, status, JSON.stringify(value)); return value;
}
async function folder() { return data(await call('/v1/folders', 'POST', undefined, { title: '音の集まり', displayName: 'Owner' }), 201); }
async function invite(id: string, owner: string) { return data(await call(`/v1/folders/${id}/invite`, 'POST', owner)); }
async function join(id: string, invitation: string) { return data(await call(`/v1/folders/${id}/join`, 'POST', undefined, { inviteToken: new URL(invitation).hash.slice(1), displayName: 'Friend' })); }
function upload(id: string, token: string, bytes: Uint8Array, overrides = {}, declaredHash = digest(bytes), extraHeaders = {}) {
  const metadata = { label: 'Rain', sha256: declaredHash, sizeBytes: bytes.length, durationUs: 2000000, width: 640, height: 480,
    rotation: 0, audioTrackStartUs: 0, selectionStartUs: 0, selectionDurationUs: 2000000, extension: 'mp4', ...overrides };
  return mf.dispatchFetch(`${origin}/v1/folders/${id}/clips/${declaredHash}`, { method: 'PUT', body: bytes,
    headers: { 'CF-Connecting-IP': `test-${++sequence}`, Authorization: `Bearer ${token}`, 'Content-Type': 'video/mp4',
      'Content-Length': String(bytes.length), 'X-Clip-Metadata': Buffer.from(JSON.stringify(metadata)).toString('base64url'), ...extraHeaders } });
}
test('two members contribute, private download and thumbnail, owner-only permissions and revocation', async () => {
  const f = await folder(); const id = f.folder.id; const owner = f.membership.token;
  assert.match(owner, /^[0-9a-f]{64}$/);
  const member = await join(id, (await invite(id, owner)).inviteUrl); const friend = member.membership.token;
  const a = new Uint8Array([1, 2, 3, 4]); const b = new Uint8Array([5, 6, 7]);
  const ca = await data(await upload(id, owner, a)); const cb = await data(await upload(id, friend, b));
  assert.equal(cb.clip.memberId, member.membership.memberId);
  await data(await call(`/v1/folders/${id}`), 401);
  await data(await call(`/v1/folders/${id}`, 'GET', '0'.repeat(64)), 401);
  await data(await call(`/v1/folders/${id}`, 'PATCH', friend, { title: 'Other' }), 403);
  await data(await call(`/v1/folders/${id}/invite`, 'POST', friend), 403);
  await data(await call(`/v1/folders/${id}/clips/${ca.clip.id}`, 'DELETE', friend), 403);
  const download = await call(`/v1/folders/${id}/clips/${cb.clip.id}/file`, 'GET', owner);
  assert.equal(download.headers.get('Cache-Control'), 'no-store'); assert.deepEqual(new Uint8Array(await download.arrayBuffer()), b);
  await data(await call(`/v1/folders/${id}/clips/${cb.clip.id}/file`), 401);
  const png = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 1]);
  await data(await mf.dispatchFetch(`${origin}/v1/folders/${id}/clips/${cb.clip.id}/thumbnail`, { method: 'PUT', body: png, headers: { Authorization: `Bearer ${friend}`, 'Content-Type': 'image/png' } }));
  const thumb = await call(`/v1/folders/${id}/clips/${cb.clip.id}/thumbnail`, 'GET', owner);
  assert.deepEqual(new Uint8Array(await thumb.arrayBuffer()), png);
  await data(await call(`/v1/folders/${id}/members/${f.membership.memberId}`, 'DELETE', owner), 409);
  await data(await call(`/v1/folders/${id}/members/${member.membership.memberId}`, 'DELETE', owner));
  await data(await call(`/v1/folders/${id}/clips/${cb.clip.id}/file`, 'GET', friend), 401);
  await data(await upload(id, friend, new Uint8Array([9])), 401);
  assert.equal((await data(await call(`/v1/folders/${id}`, 'GET', owner))).folder.clips.length, 2);
});
test('invitation rotation invalidates old invite while existing membership survives; hashes only in SQLite', async () => {
  const f = await folder(); const id = f.folder.id; const owner = f.membership.token;
  const first = await invite(id, owner); const member = await join(id, first.inviteUrl); const second = await invite(id, owner);
  await data(await call(`/v1/folders/${id}/join`, 'POST', undefined, { inviteToken: new URL(first.inviteUrl).hash.slice(1), displayName: 'Late' }), 403);
  await data(await call(`/v1/folders/${id}`, 'GET', member.membership.token));
  const storage = await mf.unsafeGetDurableObjectStorage('sharing', 'SharedFolder', { name: id });
  const rows = await storage.exec('SELECT data FROM folder_state'); const state = String(rows[0].data);
  assert.ok(!state.includes(owner)); assert.ok(!state.includes(member.membership.token)); assert.ok(!state.includes(new URL(second.inviteUrl).hash.slice(1)));
  const s = JSON.parse(state); s.invite.expiresAt = new Date(0).toISOString();
  await storage.exec('UPDATE folder_state SET data=?', JSON.stringify(s));
  await data(await call(`/v1/folders/${id}/join`, 'POST', undefined, { inviteToken: new URL(second.inviteUrl).hash.slice(1), displayName: 'Late' }), 403);
});
test('concurrent retry is idempotent and never overwrites contributor metadata', async () => {
  const f = await folder(); const id = f.folder.id; const t = f.membership.token; const bytes = new Uint8Array([11, 22, 33]);
  const results = await Promise.all([upload(id, t, bytes), upload(id, t, bytes, { label: 'Other' })]);
  const clips = await Promise.all(results.map(r => data(r))); assert.equal(clips[0].clip.label, clips[1].clip.label);
  const member = await join(id, (await invite(id, t)).inviteUrl);
  const retry = await data(await upload(id, member.membership.token, bytes)); assert.equal(retry.clip.memberId, f.membership.memberId);
  assert.equal((await data(await call(`/v1/folders/${id}`, 'GET', t))).folder.clips.length, 1);
  assert.equal((await (await mf.getR2Bucket('FILES')).list({ prefix: `${id}/` })).objects.length, 1);
});
test('quota includes pending reservations; concurrent uploads cannot cross remaining quota', async () => {
  const f = await folder(); const id = f.folder.id; const t = f.membership.token;
  const storage = await mf.unsafeGetDurableObjectStorage('sharing', 'SharedFolder', { name: id });
  const s = JSON.parse(String((await storage.exec('SELECT data FROM folder_state'))[0].data));
  // Near-quota fixture avoids transferring a GiB merely to test accounting.
  s.pending['a'.repeat(64)] = { key: `${id}/reservation`, size: 1073741824 - 4, expires: Date.now() + 600000 };
  await storage.exec('UPDATE folder_state SET data=?', JSON.stringify(s));
  const results = await Promise.all([upload(id, t, new Uint8Array([1, 1, 1, 1])), upload(id, t, new Uint8Array([2, 2, 2, 2]))]);
  assert.deepEqual(results.map(r => r.status).sort(), [200, 409]);
  assert.equal((await data(await call(`/v1/folders/${id}`, 'GET', t))).folder.clips.length, 1);
});
test('bad hash, oversize and malformed metadata never publish; expired reservation cleans R2', async () => {
  const f = await folder(); const id = f.folder.id; const t = f.membership.token; const bytes = new Uint8Array([1, 3, 5]);
  await data(await upload(id, t, bytes, {}, '0'.repeat(64)), 400);
  await data(await upload(id, t, bytes, {}, digest(bytes), { 'X-Test-Truncated': 'yes' }), 400);
  await data(await upload(id, t, bytes, { sizeBytes: 52428801 }), 413);
  await data(await upload(id, t, bytes, { rotation: 45 }), 400);
  await data(await upload(id, t, bytes, { selectionDurationUs: 3000000 }), 400);
  await data(await upload(id, t, bytes, { extension: '../mp4' }), 400);
  assert.equal((await data(await call(`/v1/folders/${id}`, 'GET', t))).folder.clips.length, 0);
  const bucket = await mf.getR2Bucket('FILES'); assert.equal((await bucket.list({ prefix: `${id}/` })).objects.length, 0);
  const storage = await mf.unsafeGetDurableObjectStorage('sharing', 'SharedFolder', { name: id });
  const s = JSON.parse(String((await storage.exec('SELECT data FROM folder_state'))[0].data));
  const key = `${id}/interrupted`; await bucket.put(key, 'incomplete');
  s.pending['b'.repeat(64)] = { key, size: 30, expires: Date.now() - 1 };
  await storage.exec('UPDATE folder_state SET data=?', JSON.stringify(s));
  await data(await call(`/v1/folders/${id}`, 'GET', t)); assert.equal(await bucket.get(key), null);
  await data(await upload(id, t, bytes));
});
test('concurrent upload and member revocation or folder close cannot resurrect access/files', async () => {
  const f = await folder(); const id = f.folder.id; const t = f.membership.token;
  const member = await join(id, (await invite(id, t)).inviteUrl); const bytes = new Uint8Array([40, 50]);
  const [uploadResult, revoked] = await Promise.all([
    upload(id, member.membership.token, bytes), call(`/v1/folders/${id}/members/${member.membership.memberId}`, 'DELETE', t)
  ]);
  assert.ok([200, 401].includes(uploadResult.status)); await data(revoked);
  await data(await call(`/v1/folders/${id}/clips/${digest(bytes)}/file`, 'GET', member.membership.token), 401);
  const [secondUpload, closed] = await Promise.all([upload(id, t, new Uint8Array([60, 70])), call(`/v1/folders/${id}`, 'DELETE', t)]);
  assert.ok([200, 404].includes(secondUpload.status)); await data(closed);
  assert.equal((await (await mf.getR2Bucket('FILES')).list({ prefix: `${id}/` })).objects.length, 0);
});
test('clip deletion frees storage and close removes private objects permanently', async () => {
  const f = await folder(); const id = f.folder.id; const t = f.membership.token;
  const bytes = new Uint8Array([10, 20]); const clipId = digest(bytes); await data(await upload(id, t, bytes));
  await data(await call(`/v1/folders/${id}/clips/${clipId}`, 'DELETE', t));
  await data(await call(`/v1/folders/${id}/clips/${clipId}/file`, 'GET', t), 404);
  await data(await upload(id, t, bytes));
  const member = await join(id, (await invite(id, t)).inviteUrl);
  await data(await call(`/v1/folders/${id}`, 'DELETE', member.membership.token), 403);
  await data(await call(`/v1/folders/${id}`, 'DELETE', t));
  await data(await call(`/v1/folders/${id}`, 'GET', t), 404);
  await data(await upload(id, t, bytes), 404);
  assert.equal((await (await mf.getR2Bucket('FILES')).list({ prefix: `${id}/` })).objects.length, 0);
});
test('origin, IDs, internal initialization and secret-free fragment landing', async () => {
  const f = await folder(); const id = f.folder.id; const t = f.membership.token;
  await data(await call(`/v1/folders/${id}`, 'GET', t, undefined, { Origin: 'https://outsider.example' }), 403);
  await data(await call('/v1/folders/not-a-uuid', 'GET', t), 400);
  await data(await call(`/v1/folders/${id}/clips/%2e%2e%2ffile`, 'GET', t), 400);
  await data(await call(`/v1/folders/${id}/create`, 'POST'), 404);
  await data(await call(`/v1/folders/${id}?token=${t}`, 'GET', t), 400);
  const i = await invite(id, t); assert.equal(new URL(i.inviteUrl).search, '');
  const response = await call(`/invite/${id}`); const html = await response.text();
  assert.ok(!html.includes(new URL(i.inviteUrl).hash.slice(1))); assert.ok(!html.includes(f.folder.title));
  assert.equal(response.headers.get('Referrer-Policy'), 'no-referrer');
  assert.match(await (await call('/invite.js')).text(), /location.hash/);
});
test('real rate-limit bindings enforce entry and general limits', async () => {
  const req = (path: string, method = 'GET', body?: string) => mf.dispatchFetch(origin + path, {
    method, headers: { 'CF-Connecting-IP': 'rate-limit-test' }, ...(body ? { body } : {}) });
  for (let n = 0; n < 10; n++) assert.equal((await req('/v1/folders', 'POST', JSON.stringify({ title: 'test', displayName: 'test' }))).status, 201);
  await data(await req('/v1/folders', 'POST', '{}'), 429);
  for (let n = 0; n < 109; n++) assert.equal((await req('/missing')).status, 404);
  await data(await req('/missing'), 429);
});
