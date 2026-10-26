import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

type Options = { method?: string; session?: string; token?: string; body?: unknown; ip?: string };
type Who = { session: string; id: string };
const origin = 'https://sharing.example', name = 'account';
const sha = (value: string | Uint8Array) => createHash('sha256').update(value).digest('hex');
const posterOf = (accountId: string) => sha(`poster:${accountId}`).slice(0, 32);
let mf: Miniflare, sequence = 0, variant = 0;

before(async () => {
  const compiled = await build({ entryPoints: ['src/index.ts'], bundle: true, write: false, format: 'esm', external: ['cloudflare:workers'], target: 'es2022', loader: { '.txt': 'text' } });
  mf = new Miniflare({ ...convertV4MiniflareOptions({ name, modules: true, script: compiled.outputFiles[0].text, compatibilityDate: '2025-10-11',
    durableObjects: { AUTH_ACCOUNTS: { className: 'AuthAccounts', useSQLite: true }, FOLDERS: { className: 'SharedFolder', useSQLite: true }, SONGS: { className: 'SongCatalog', useSQLite: true } },
    r2Buckets: ['FILES'],
    ratelimits: { API_LIMIT: { namespace_id: '1002', simple: { limit: 120, period: 60 } }, ENTRY_LIMIT: { namespace_id: '1001', simple: { limit: 10, period: 60 } } } }), unsafeInspectDurableObjects: true });
  await mf.ready;
});
after(async () => { await mf?.dispose(); });

// As in songs.test.ts: assert.equal(…, true) and never assert.ok, whose failure makes Node re-parse the
// single long line tsx runs and take minutes. Every call has its own client address unless `ip` says otherwise.
function call(path: string, o: Options = {}) {
  const body = o.body === undefined ? undefined : JSON.stringify(o.body);
  return mf.dispatchFetch(origin + path, { method: o.method ?? (body === undefined ? 'GET' : 'POST'),
    headers: { 'CF-Connecting-IP': o.ip ?? `account-${++sequence}`, ...(o.session ? { 'X-Oto-Session': o.session } : {}), ...(o.token ? { Authorization: `Bearer ${o.token}` } : {}) },
    ...(body === undefined ? {} : { body }) });
}
async function data(response: any, status = 200) {
  const value = await response.json(); assert.equal(response.status, status, JSON.stringify(value)); return value;
}
async function refused(response: any, status: number, code: string) {
  const value = await data(response, status); assert.equal(value.error.code, code, JSON.stringify(value));
}
const auth = () => mf.unsafeGetDurableObjectStorage(name, 'AuthAccounts', { name: 'accounts' });
const catalog = () => mf.unsafeGetDurableObjectStorage(name, 'SongCatalog', { name: 'catalog' });
async function account(displayName: string): Promise<Who> {
  const session = randomBytes(32).toString('hex'), id = randomUUID(), storage = await auth();
  // Verified fixture data is inserted through the test-only inspector, never a public auth bypass.
  await storage.exec('INSERT INTO auth_records(kind,id,data) VALUES(?,?,?)', 'account', id, JSON.stringify({ id, displayName, plan: 'free', maxOwnedFolders: 1 }));
  await storage.exec('INSERT INTO auth_records(kind,id,data) VALUES(?,?,?)', 'session', sha(session), JSON.stringify({ accountId: id, expires: Date.now() + 86400000 }));
  // What a passkey registration and a login that was never exchanged leave behind.
  const credential = randomBytes(16).toString('base64url'), flow = randomBytes(32).toString('hex');
  await storage.exec('INSERT INTO auth_records(kind,id,data) VALUES(?,?,?)', 'credential', credential, JSON.stringify({ accountId: id, id: credential, publicKey: [1, 2, 3], counter: 0 }));
  await storage.exec('INSERT INTO auth_records(kind,id,data,expires) VALUES(?,?,?,?)', 'flow', flow, JSON.stringify({ state: 'x', expires: Date.now() + 300000, verified: id }), Date.now() + 300000);
  await storage.exec('INSERT INTO auth_records(kind,id,data,expires) VALUES(?,?,?,?)', 'code', sha(flow), JSON.stringify({ state: 'x', expires: Date.now() + 300000, verified: id, flowId: flow }), Date.now() + 300000);
  return { session, id };
}
// Every auth record that names the account, by key or anywhere in its data.
const records = async (who: Who) => (await (await auth()).exec('SELECT kind FROM auth_records WHERE id=? OR id=? OR instr(data,?)>0 ORDER BY kind', who.id, sha(who.session), who.id)).map(r => r.kind);
const deleteAccount = (session?: string, ip?: string) => call('/v1/account', { method: 'DELETE', session, ip });

async function ownFolder(who: Who) {
  return data(await call('/v1/folders', { session: who.session, body: { title: '音の集まり', displayName: 'Owner', creationId: randomUUID() } }), 201);
}
async function join(folderId: string, ownerToken: string, who: Who, displayName: string) {
  const { inviteUrl } = await data(await call(`/v1/folders/${folderId}/invite`, { method: 'POST', token: ownerToken }));
  return data(await call(`/v1/folders/${folderId}/join`, { session: who.session, body: { inviteToken: new URL(inviteUrl).hash.slice(1), displayName } }));
}
function upload(folderId: string, token: string, bytes: Uint8Array) {
  const metadata = { label: 'Rain', sha256: sha(bytes), sizeBytes: bytes.length, durationUs: 2000000, width: 640, height: 480,
    rotation: 0, audioTrackStartUs: 0, selectionStartUs: 0, selectionDurationUs: 2000000, extension: 'mp4' };
  return mf.dispatchFetch(`${origin}/v1/folders/${folderId}/clips/${sha(bytes)}`, { method: 'PUT', body: bytes,
    headers: { 'CF-Connecting-IP': `account-${++sequence}`, Authorization: `Bearer ${token}`, 'Content-Type': 'video/mp4',
      'Content-Length': String(bytes.length), 'X-Clip-Metadata': Buffer.from(JSON.stringify(metadata)).toString('base64url') } });
}
async function post(who: Who) {
  const score = { v: 1, beats: 32, lanes: [[[0, ++variant, 60]], [], []] };
  return (await data(await call('/v1/songs', { session: who.session, body: { title: 'あめのうた', rights: 'own', score } }), 201)).song;
}
const report = (id: string, who: Who) => call(`/v1/songs/${id}/report`, { session: who.session, body: { reason: 'rights' } });
async function listed() {
  const ids: string[] = [];
  for (let path = '/v1/songs'; ;) {
    const page = await data(await call(path)); ids.push(...page.songs.map((s: any) => s.id));
    if (!('next' in page)) return ids;
    path = `/v1/songs/after/${page.next}`;
  }
}

test('deleting an account needs a valid session', async () => {
  await refused(await deleteAccount(), 401, 'account_required');
  await refused(await deleteAccount('not-a-session'), 401, 'account_required');
  await refused(await deleteAccount('0'.repeat(64)), 401, 'session_expired');
  // Other methods on the account route are still not routes.
  const a = await account('Someone');
  await refused(await call('/v1/account', { method: 'PATCH', session: a.session }), 404, 'not_found');
  assert.equal((await data(await call('/v1/account', { session: a.session }))).account.id, a.id);
});

test('poster is a stable opaque key per account', async () => {
  const a = await account('Ａ'), b = await account('Ｂ');
  const [a1, a2, b1] = [await post(a), await post(a), await post(b)];
  assert.match(a1.poster, /^[0-9a-f]{32}$/);
  assert.equal(a1.poster, posterOf(a.id)); assert.equal(a2.poster, a1.poster);
  assert.notEqual(b1.poster, a1.poster); assert.equal(b1.poster, posterOf(b.id));
  assert.notEqual(a1.poster, a.id); assert.equal(a.id.replace(/-/g, '').includes(a1.poster), false);
  // Every view carries the same key: the lists, one song, the account's own list.
  const newest = (await data(await call('/v1/songs'))).songs, popular = (await data(await call('/v1/songs/popular'))).songs;
  assert.equal(newest.find((s: any) => s.id === a2.id).poster, a1.poster);
  assert.equal(popular.find((s: any) => s.id === b1.id).poster, b1.poster);
  assert.equal((await data(await call(`/v1/songs/${a1.id}`))).song.poster, a1.poster);
  assert.deepEqual((await data(await call('/v1/account/songs', { session: a.session }))).songs.map((s: any) => s.poster), [a1.poster, a1.poster]);
  for (const view of [newest, popular]) assert.equal(JSON.stringify(view).includes(a.id) || JSON.stringify(view).includes(b.id), false);
});

test('deleting an account closes its folder, leaves the others, takes its songs and reports, and logs it out', async () => {
  const a = await account('Leaving'), b = await account('Staying'), c = await account('Reporter'), d = await account('Another');
  const other = await account('Untouched');
  // a owns a folder that b joined and that holds a clip; a joined b's folder.
  const owned = await ownFolder(a), ownedId = owned.folder.id;
  const bInA = await join(ownedId, owned.membership.token, b, 'B in A');
  await data(await upload(ownedId, owned.membership.token, new Uint8Array([1, 2, 3])));
  const theirs = await ownFolder(b), theirsId = theirs.folder.id;
  const aInB = await join(theirsId, theirs.membership.token, a, 'A in B');
  const bucket = await mf.getR2Bucket('FILES');
  assert.equal((await bucket.list({ prefix: `${ownedId}/` })).objects.length, 1);
  // In b's folder: a clip of a's with a thumbnail, an unfinished upload of a's, and a clip and an unfinished upload of b's.
  const aClip = (await data(await upload(theirsId, aInB.membership.token, new Uint8Array([7, 7])))).clip;
  const bClip = (await data(await upload(theirsId, theirs.membership.token, new Uint8Array([8, 8])))).clip;
  await data(await mf.dispatchFetch(`${origin}/v1/folders/${theirsId}/clips/${aClip.id}/thumbnail`, { method: 'PUT', body: new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 1]),
    headers: { 'CF-Connecting-IP': `account-${++sequence}`, Authorization: `Bearer ${aInB.membership.token}`, 'Content-Type': 'image/png' } }));
  const folderStorage = await mf.unsafeGetDurableObjectStorage(name, 'SharedFolder', { name: theirsId });
  const state = JSON.parse(String((await folderStorage.exec('SELECT data FROM folder_state'))[0].data));
  const aPending = `${theirsId}/clips/${'a'.repeat(64)}/unfinished`, bPending = `${theirsId}/clips/${'b'.repeat(64)}/unfinished`;
  state.pending['a'.repeat(64)] = { key: aPending, size: 2, expires: Date.now() + 600000, memberId: aInB.membership.memberId };
  state.pending['b'.repeat(64)] = { key: bPending, size: 2, expires: Date.now() + 600000, memberId: theirs.membership.memberId };
  await folderStorage.exec('UPDATE folder_state SET data=?', JSON.stringify(state));
  await bucket.put(aPending, 'partial'); await bucket.put(bPending, 'partial');
  const theirKeys = async () => (await bucket.list({ prefix: `${theirsId}/` })).objects.map(o => o.key).sort();
  const before = await theirKeys();
  assert.equal(before.length, 5);
  assert.deepEqual((await records(a)).sort(), ['account', 'code', 'credential', 'flow', 'memberships', 'quota', 'session']);

  // a's songs: one public, one already removed by a, one hidden by reports. b's songs: one a reported, one a helped hide.
  const kept = await post(a), gone = await post(a), hidden = await post(a);
  await data(await call(`/v1/songs/${gone.id}`, { method: 'DELETE', session: a.session }));
  for (const who of [b, c, d]) await data(await report(hidden.id, who), 201);
  const bSong = await post(b), bHidden = await post(b);
  for (const who of [a, c]) await data(await report(bSong.id, who), 201);
  for (const who of [a, c, d]) await data(await report(bHidden.id, who), 201);
  const songs = await catalog();
  assert.equal((await songs.exec("SELECT status FROM songs WHERE id=?", bHidden.id))[0].status, 'hidden');
  const oldPoster = kept.poster;

  assert.deepEqual(await data(await deleteAccount(a.session)), { ok: true });

  // Logged out everywhere: the session, the passkey credential, flows, codes, quota and memberships are gone.
  await refused(await call('/v1/account', { session: a.session }), 401, 'session_expired');
  await refused(await deleteAccount(a.session), 401, 'session_expired');
  assert.deepEqual(await records(a), []);
  for (const who of [b, other]) assert.deepEqual((await records(who)).sort(), ['account', 'code', 'credential', 'flow', ...(who === b ? ['memberships', 'quota'] : []), 'session']);
  assert.equal((await data(await call('/v1/account', { session: b.session }))).account.id, b.id);

  // The owned folder is closed for everyone and its objects are deleted; a left b's folder, which stays open.
  await refused(await call(`/v1/folders/${ownedId}`, { token: owned.membership.token }), 404, 'folder_not_found');
  await refused(await call(`/v1/folders/${ownedId}`, { token: bInA.membership.token }), 404, 'folder_not_found');
  assert.equal((await bucket.list({ prefix: `${ownedId}/` })).objects.length, 0);
  await refused(await call(`/v1/folders/${theirsId}`, { token: aInB.membership.token }), 401, 'unauthorized');
  const left = await data(await call(`/v1/folders/${theirsId}`, { token: theirs.membership.token }));
  assert.deepEqual(left.folder.members.map((m: any) => [m.displayName, m.role]), [['Owner', 'owner']]);
  // a's clip, its thumbnail and a's unfinished upload are deleted; b's clip and b's unfinished upload stay.
  assert.deepEqual(left.folder.clips.map((c: any) => c.id), [bClip.id]);
  await refused(await call(`/v1/folders/${theirsId}/clips/${aClip.id}/file`, { token: theirs.membership.token }), 404, 'clip_not_found');
  assert.deepEqual(new Uint8Array(await (await call(`/v1/folders/${theirsId}/clips/${bClip.id}/file`, { token: theirs.membership.token })).arrayBuffer()), new Uint8Array([8, 8]));
  const after = await theirKeys();
  assert.equal(after.length, 2); assert.equal(after.includes(bPending), true);
  assert.equal(after.every(key => before.includes(key)) && after.some(key => key.includes(`/clips/${bClip.id}/`)), true);
  assert.deepEqual(Object.keys(JSON.parse(String((await folderStorage.exec('SELECT data FROM folder_state'))[0].data)).pending), ['b'.repeat(64)]);
  assert.deepEqual((await data(await call('/v1/account/folders', { session: b.session }))).folders.map((f: any) => f.folder.id), [theirsId]);

  // a's songs are gone from every list and read; their rows keep nothing that names a.
  const ids = await listed();
  for (const song of [kept, gone, hidden]) {
    assert.equal(ids.includes(song.id), false);
    await refused(await call(`/v1/songs/${song.id}`), 404, 'song_not_found');
  }
  assert.equal((await data(await call('/v1/songs/popular'))).songs.some((s: any) => s.id === kept.id), false);
  assert.deepEqual(await songs.exec('SELECT id FROM songs WHERE account_id=?', a.id), []);
  const rows = await songs.exec(`SELECT account_id,author,title,credit,lanes,content_hash,status FROM songs WHERE id IN (?,?,?)`, kept.id, gone.id, hidden.id);
  assert.equal(rows.length, 3);
  for (const row of rows) {
    assert.match(String(row.account_id), /^deleted:[0-9a-f-]{36}$/);
    assert.deepEqual([row.author, row.title, row.credit, row.lanes, row.content_hash, row.status], ['', '', '', null, '', 'removed']);
    assert.notEqual(posterOf(String(row.account_id)), oldPoster);
  }
  assert.equal(new Set(rows.map(r => r.account_id)).size, 3);
  // Reports on a's songs and by a are gone; c's and d's on b's songs stay, and b's hidden song stays hidden.
  assert.deepEqual(await songs.exec('SELECT song_id FROM song_reports WHERE account_id=? OR song_id IN (?,?,?)', a.id, kept.id, gone.id, hidden.id), []);
  assert.deepEqual((await songs.exec('SELECT song_id,account_id FROM song_reports WHERE song_id IN (?,?)', bSong.id, bHidden.id)).map(r => `${r.song_id}/${r.account_id}`).sort(),
    [`${bSong.id}/${c.id}`, `${bHidden.id}/${c.id}`, `${bHidden.id}/${d.id}`].sort());
  assert.equal((await songs.exec('SELECT status FROM songs WHERE id=?', bHidden.id))[0].status, 'hidden');
  assert.equal((await data(await call(`/v1/songs/${bSong.id}`))).song.poster, posterOf(b.id));
});

test('deleting again after a partial run, and deleting a fresh account, both work', async () => {
  const a = await account('Halfway'), b = await account('Host');
  const owned = await ownFolder(a), theirs = await ownFolder(b);
  const aInB = await join(theirs.folder.id, theirs.membership.token, a, 'A in B');
  await data(await upload(theirs.folder.id, aInB.membership.token, new Uint8Array([9, 9])));
  const song = await post(a), removed = await post(a), bSong = await post(b);
  await data(await report(bSong.id, a), 201);
  // As if an earlier DELETE stopped after its folder and song steps: the owned folder is closed, b's folder
  // is left, one song is already a scrubbed tombstone. The account also remembers a folder that never existed.
  await data(await call(`/v1/folders/${owned.folder.id}`, { method: 'DELETE', token: owned.membership.token }));
  await data(await call(`/v1/folders/${theirs.folder.id}/members/${aInB.membership.memberId}`, { method: 'DELETE', token: aInB.membership.token }));
  // Leaving the ordinary way keeps the member's clips in the folder.
  assert.equal((await data(await call(`/v1/folders/${theirs.folder.id}`, { token: theirs.membership.token }))).folder.clips.length, 1);
  const songs = await catalog();
  await songs.exec("UPDATE songs SET status='removed', lanes=NULL, author='', account_id=? WHERE id=?", `deleted:${randomUUID()}`, removed.id);
  const storage = await auth(), memberships = JSON.parse(String((await storage.exec("SELECT data FROM auth_records WHERE kind='memberships' AND id=?", a.id))[0].data));
  await storage.exec("UPDATE auth_records SET data=? WHERE kind='memberships' AND id=?", JSON.stringify([...memberships, randomUUID()]), a.id);

  assert.deepEqual(await data(await deleteAccount(a.session)), { ok: true });
  assert.deepEqual(await records(a), []);
  await refused(await call(`/v1/songs/${song.id}`), 404, 'song_not_found');
  assert.deepEqual(await songs.exec('SELECT 1 FROM songs WHERE account_id=?', a.id), []);
  assert.deepEqual(await songs.exec('SELECT 1 FROM song_reports WHERE account_id=?', a.id), []);
  assert.equal((await data(await call(`/v1/folders/${theirs.folder.id}`, { token: theirs.membership.token }))).folder.members.length, 1);

  // The same person registering again gets a new account, which can delete itself too.
  const again = await account('Halfway');
  assert.deepEqual(await data(await deleteAccount(again.session)), { ok: true });
  assert.deepEqual(await records(again), []);
  assert.equal((await data(await call('/v1/account', { session: b.session }))).account.id, b.id);
});

test('deleting an account shares the entry rate limit', async () => {
  for (let n = 0; n < 10; n++) await refused(await deleteAccount(undefined, 'delete-rate-test'), 401, 'account_required');
  await refused(await deleteAccount(undefined, 'delete-rate-test'), 429, 'rate_limited');
});
