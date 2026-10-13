import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { build } from 'esbuild';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

type Api = { mf: Miniflare; name: string };
type Options = { method?: string; session?: string; body?: unknown; raw?: string; headers?: Record<string, string>; ip?: string };
type Who = { session: string; id: string };
const origin = 'https://sharing.example';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const adminToken = randomBytes(32).toString('hex'), weakToken = 'short-operator-token';
const sha = (value: string) => createHash('sha256').update(value).digest('hex');
// `main` has no ADMIN_TOKEN, `operated` has a proper one, `weak` one that is too short to count.
let main: Api, operated: Api, weak: Api;
let sequence = 0, variant = 0;

before(async () => {
  const compiled = await build({ entryPoints: ['src/index.ts'], bundle: true, write: false, format: 'esm', external: ['cloudflare:workers'], target: 'es2022', loader: { '.txt': 'text' } });
  const start = async (name: string, bindings?: Record<string, string>): Promise<Api> => {
    const mf = new Miniflare({ ...convertV4MiniflareOptions({ name, modules: true, script: compiled.outputFiles[0].text, compatibilityDate: '2025-10-11',
      durableObjects: { AUTH_ACCOUNTS: { className: 'AuthAccounts', useSQLite: true }, FOLDERS: { className: 'SharedFolder', useSQLite: true }, SONGS: { className: 'SongCatalog', useSQLite: true } },
      r2Buckets: ['FILES'], ...(bindings ? { bindings } : {}),
      ratelimits: { API_LIMIT: { namespace_id: '1002', simple: { limit: 120, period: 60 } }, ENTRY_LIMIT: { namespace_id: '1001', simple: { limit: 10, period: 60 } } } }), unsafeInspectDurableObjects: true });
    await mf.ready; return { mf, name };
  };
  // The operated secret ends in a newline, as a pasted one may; a header can never carry that.
  [main, operated, weak] = await Promise.all([start('songs'), start('songs-operated', { ADMIN_TOKEN: `${adminToken}\n` }), start('songs-weak', { ADMIN_TOKEN: weakToken })]);
});
after(async () => { await Promise.all([main, operated, weak].map(api => api?.mf.dispose())); });

// This file compares with assert.equal(…, true) and never assert.ok: for a failed assert.ok Node re-parses the
// source to quote the expression, and against the single long line tsx runs that takes minutes instead of failing.
// Every call comes from its own client address unless `ip` says otherwise, so rate limits stay out of the way.
function call(api: Api, path: string, o: Options = {}) {
  const body = o.raw ?? (o.body === undefined ? undefined : JSON.stringify(o.body));
  return api.mf.dispatchFetch(origin + path, { method: o.method ?? (body === undefined ? 'GET' : 'POST'),
    headers: { 'CF-Connecting-IP': o.ip ?? `songs-${++sequence}`, ...(o.session ? { 'X-Oto-Session': o.session } : {}), ...o.headers },
    ...(body === undefined ? {} : { body }) });
}
async function data(response: any, status = 200) {
  const value = await response.json(); assert.equal(response.status, status, JSON.stringify(value)); return value;
}
async function refused(response: any, status: number, code: string) {
  const value = await data(response, status); assert.equal(value.error.code, code, JSON.stringify(value));
  assert.equal(typeof value.error.message, 'string');
}
async function account(api: Api, displayName = 'Poster'): Promise<Who> {
  const session = randomBytes(32).toString('hex'), id = randomUUID();
  // Verified fixture data is inserted through the test-only inspector, never a public auth bypass.
  const storage = await api.mf.unsafeGetDurableObjectStorage(api.name, 'AuthAccounts', { name: 'accounts' });
  await storage.exec('INSERT INTO auth_records(kind,id,data) VALUES(?,?,?)', 'account', id, JSON.stringify({ id, displayName, plan: 'free', maxOwnedFolders: 1 }));
  await storage.exec('INSERT INTO auth_records(kind,id,data) VALUES(?,?,?)', 'session', sha(session), JSON.stringify({ accountId: id, expires: Date.now() + 86400000 }));
  return { session, id };
}
const catalog = (api: Api) => api.mf.unsafeGetDurableObjectStorage(api.name, 'SongCatalog', { name: 'catalog' });
// Each call is new content: the first melody note gets its own length.
function score(overrides: Record<string, unknown> = {}) {
  return { v: 1, beats: 32, lanes: [[[0, ++variant, 60], [480, 480, 64]], [[0, 960, 36]], []] as number[][][], ...overrides };
}
function post(api: Api, session: string | undefined, overrides: Record<string, unknown> = {}) {
  return call(api, '/v1/songs', { session, body: { title: 'あめのうた', credit: 'trad.', rights: 'own', score: score(), ...overrides } });
}
async function posted(api: Api, who: Who, overrides: Record<string, unknown> = {}) {
  return (await data(await post(api, who.session, overrides), 201)).song;
}
const read = (api: Api, id: string, session?: string) => call(api, `/v1/songs/${id}`, { session });
const remove = (api: Api, id: string, session?: string) => call(api, `/v1/songs/${id}`, { method: 'DELETE', session });
const use = (api: Api, id: string, ip?: string) => call(api, `/v1/songs/${id}/use`, { method: 'POST', ip });
const report = (api: Api, id: string, who?: Who, body: unknown = { reason: 'rights' }) => call(api, `/v1/songs/${id}/report`, { session: who?.session, body });
async function pages(api: Api) {
  const result: any[][] = [];
  for (let path = '/v1/songs'; ;) {
    const page = await data(await call(api, path)); result.push(page.songs);
    if (!('next' in page)) return result;
    assert.match(page.next, /^[0-9a-z]+$/); path = `/v1/songs/after/${page.next}`;
  }
}
const listedIds = async (api: Api) => (await pages(api)).flat().map(song => song.id);
const popularIds = async (api: Api) => (await data(await call(api, '/v1/songs/popular'))).songs.map((song: any) => song.id);

test('posting, the own list, reporting and removing need a session; reading does not', async () => {
  const id = randomUUID(), a = await account(main);
  await refused(await post(main, undefined), 401, 'account_required');
  await refused(await post(main, 'not-a-session'), 401, 'account_required');
  await refused(await post(main, '0'.repeat(64)), 401, 'session_expired');
  // Naming an account in a header is not a login.
  await refused(await call(main, '/v1/songs', { body: { title: 't', rights: 'own', score: score() }, headers: { 'X-Internal-Account': a.id, 'X-Oto-Account': a.id } }), 401, 'account_required');
  await refused(await call(main, '/v1/account/songs'), 401, 'account_required');
  await refused(await call(main, '/v1/account/songs', { method: 'POST', session: a.session, body: {} }), 404, 'not_found');
  await refused(await report(main, id), 401, 'account_required');
  await refused(await remove(main, id), 401, 'account_required');
  assert.deepEqual(await data(await call(main, '/v1/account/songs', { session: a.session })), { songs: [] });
  assert.deepEqual(await data(await call(main, '/v1/songs')), { songs: [] });
  assert.deepEqual(await data(await call(main, '/v1/songs/popular')), { songs: [] });
  await refused(await read(main, id), 404, 'song_not_found');
  await refused(await read(main, id, a.session), 404, 'song_not_found');
  await refused(await use(main, id), 404, 'song_not_found');
  assert.equal((await (await catalog(main)).exec('SELECT id FROM songs')).length, 0);
});

test('title, credit, rights and every rule of the score are enforced with a specific code', async () => {
  const a = await account(main), b = await account(main);
  const melody = (notes: unknown, rest: Record<string, unknown> = {}) => ({ score: { v: 1, beats: 32, lanes: [notes, [], []], ...rest } });
  const run = (length: number) => Array.from({ length }, (_, i) => [i * 20, 10, 40 + (i % 60)]);
  const failures: [Record<string, unknown>, string][] = [
    [{ title: undefined }, 'invalid_text'], [{ title: '' }, 'invalid_text'], [{ title: '   ' }, 'invalid_text'], [{ title: 7 }, 'invalid_text'],
    [{ title: '音'.repeat(41) }, 'invalid_text'], [{ title: 'bell\u0007' }, 'invalid_text'],
    [{ credit: 'c'.repeat(61) }, 'invalid_text'], [{ credit: 7 }, 'invalid_text'], [{ credit: ['x'] }, 'invalid_text'],
    [{ rights: undefined }, 'invalid_rights'], [{ rights: 'cc-by' }, 'invalid_rights'], [{ rights: ['own'] }, 'invalid_rights'],
    [{ score: undefined }, 'invalid_score'], [{ score: null }, 'invalid_score'], [{ score: 'midi' }, 'invalid_score'], [{ score: [1, 32, []] }, 'invalid_score'],
    [{ score: { ...score(), tempo: 120 } }, 'invalid_score'],
    [{ score: { beats: 32, lanes: [[[0, 1, 60]], [], []] } }, 'unsupported_score_version'], [melody([[0, 1, 60]], { v: 2 }), 'unsupported_score_version'],
    [melody([[0, 1, 60]], { v: '1' }), 'unsupported_score_version'],
    [melody([[0, 1, 60]], { beats: 16 }), 'invalid_beats'], [melody([[0, 1, 60]], { beats: 48 }), 'invalid_beats'], [melody([[0, 1, 60]], { beats: '32' }), 'invalid_beats'],
    [melody([[0, 1, 60]], { beats: undefined }), 'invalid_beats'],
    [{ score: { v: 1, beats: 32, lanes: [[[0, 1, 60]], []] } }, 'invalid_lanes'], [{ score: { v: 1, beats: 32, lanes: [[[0, 1, 60]], [], [], []] } }, 'invalid_lanes'],
    [{ score: { v: 1, beats: 32, lanes: { melody: [[0, 1, 60]] } } }, 'invalid_lanes'], [{ score: { v: 1, beats: 32, lanes: [[[0, 1, 60]], 'bass', []] } }, 'invalid_lanes'],
    [{ score: { v: 1, beats: 32 } }, 'invalid_lanes'],
    [melody([]), 'empty_melody'],
    [melody(['note']), 'invalid_note'], [melody([[0, 240]]), 'invalid_note'], [melody([[0, 240, 60, 100]]), 'invalid_note'], [melody([[0.5, 240, 60]]), 'invalid_note'],
    [melody([[0, '240', 60]]), 'invalid_note'], [melody([[0, 240, null]]), 'invalid_note'], [melody([{ 0: 0, 1: 240, 2: 60 }]), 'invalid_note'],
    [{ score: { v: 1, beats: 32, lanes: [[[0, 1, 60]], [[0, 1]], []] } }, 'invalid_note'],
    [melody([[-1, 240, 60]]), 'invalid_note_time'], [melody([[0, 0, 60]]), 'invalid_note_time'], [melody([[0, -5, 60]]), 'invalid_note_time'],
    [melody([[15359, 2, 60]]), 'invalid_note_time'], [melody([[15360, 1, 60]]), 'invalid_note_time'], [melody([[0, 15361, 60]]), 'invalid_note_time'],
    [melody([[30720, 1, 60]], { beats: 64 }), 'invalid_note_time'], [melody([[0, 1e300, 60]]), 'invalid_note_time'],
    [melody([[0, 240, -1]]), 'invalid_pitch'], [melody([[0, 240, 128]]), 'invalid_pitch'],
    [melody([[480, 240, 60], [0, 240, 62]]), 'unsorted_notes'], [{ score: { v: 1, beats: 32, lanes: [[[0, 1, 60]], [], [[10, 1, 40], [9, 1, 40]]] } }, 'unsorted_notes'],
    [melody(run(601)), 'too_many_notes'], [{ score: { v: 1, beats: 32, lanes: [[[0, 1, 60]], [], run(601)] } }, 'too_many_notes'],
  ];
  for (const [overrides, code] of failures) await refused(await post(main, a.session, overrides), 400, code);
  await refused(await call(main, '/v1/songs', { session: a.session, raw: '{' }), 400, 'invalid_json');
  await refused(await call(main, '/v1/songs', { session: a.session, raw: '[]' }), 400, 'invalid_json');
  await refused(await call(main, '/v1/songs', { session: a.session, raw: '"score"' }), 400, 'invalid_json');
  await data(await call(main, '/v1/songs', { session: a.session, method: 'POST' }), 400);
  assert.deepEqual(await data(await call(main, '/v1/account/songs', { session: a.session })), { songs: [] });

  // What the rules allow: ties, notes ending exactly with the song, both lengths, full lanes, the longest texts.
  const ties = [[0, 240, 60], [0, 240, 64], [0, 480, 67], [480, 1, 0]];
  assert.deepEqual((await posted(main, a, melody(ties))).lanes, [ties, [], []]);
  assert.deepEqual((await posted(main, a, melody([[0, 15360, 0], [15359, 1, 127]]))).lanes[0], [[0, 15360, 0], [15359, 1, 127]]);
  assert.equal((await posted(main, a, melody([[30719, 1, 60]], { beats: 64 }))).beats, 64);
  const filled = { v: 1, beats: 32, lanes: [run(600), run(600), run(600)] };
  assert.equal(JSON.stringify(filled).length > 8192, true);
  assert.deepEqual((await posted(main, a, { score: filled })).lanes, filled.lanes);
  const longest = await posted(main, a, { title: '🎵'.repeat(40), credit: '作'.repeat(60), rights: 'public_domain' });
  assert.deepEqual([longest.title, longest.credit, longest.rights], ['🎵'.repeat(40), '作'.repeat(60), 'public_domain']);
  assert.equal((await posted(main, a, { credit: undefined })).credit, '');
  assert.equal((await posted(main, a, { credit: null })).credit, '');
  assert.equal((await posted(main, a, { credit: '' })).credit, '');
  assert.equal((await data(await call(main, '/v1/account/songs', { session: a.session }))).songs.length, 8);

  // The body may reach 64 KiB and not one byte more; other routes keep the 8 KiB limit.
  const sized = (bytes: number) => {
    const body = { title: 'size', rights: 'own', score: score(), pad: '' };
    body.pad = 'x'.repeat(bytes - Buffer.byteLength(JSON.stringify(body))); return JSON.stringify(body);
  };
  assert.equal(Buffer.byteLength(sized(65536)), 65536);
  await data(await call(main, '/v1/songs', { session: b.session, raw: sized(65536) }), 201);
  await refused(await call(main, '/v1/songs', { session: b.session, raw: sized(65537) }), 413, 'body_too_large');
  assert.equal((await data(await call(main, '/v1/account/songs', { session: b.session }))).songs.length, 1);
});

test('post, list, read, one use per client and day, and the popular order', async () => {
  const a = await account(main, 'はる'), draft = score(), storage = await catalog(main);
  const answer = await data(await post(main, a.session, { score: draft }), 201);
  assert.deepEqual(Object.keys(answer), ['song']);
  const song = answer.song, { status, lanes, ...summary } = song;
  assert.match(song.id, UUID); assert.equal(new Date(song.createdAt).toISOString(), song.createdAt);
  assert.deepEqual(song, { id: song.id, title: 'あめのうた', credit: 'trad.', rights: 'own', author: 'はる', beats: 32, uses: 0, createdAt: song.createdAt, status: 'public', lanes: draft.lanes });
  // The content hash is the SHA-256 of the canonical JSON of {beats,lanes}; like the account, it never leaves the object.
  const [row] = await storage.exec('SELECT account_id,content_hash FROM songs WHERE id=?', song.id);
  assert.deepEqual(row, { account_id: a.id, content_hash: sha(JSON.stringify({ beats: 32, lanes: draft.lanes })) });
  assert.equal(JSON.stringify(answer).includes(a.id), false); assert.equal(JSON.stringify(answer).includes(String(row.content_hash)), false);

  const list = await data(await call(main, '/v1/songs'));
  assert.deepEqual(list.songs[0], summary);
  assert.deepEqual(Object.keys(list.songs[0]), ['id', 'title', 'credit', 'rights', 'author', 'beats', 'uses', 'createdAt']);
  const fetched = await read(main, song.id);
  assert.equal(fetched.headers.get('Cache-Control'), 'no-store'); assert.deepEqual(await data(fetched), { song });
  // A session is not needed for a public song, and a broken one does not get in the way.
  assert.deepEqual(await data(await read(main, song.id, 'stale')), { song });
  assert.deepEqual(await data(await read(main, song.id, a.session)), { song });
  assert.deepEqual(await data(await call(main, '/v1/account/songs', { session: a.session })), { songs: [{ ...summary, status: 'public' }] });

  assert.deepEqual(await data(await use(main, song.id, 'listener-1')), { uses: 1 });
  assert.deepEqual(await data(await use(main, song.id, 'listener-1')), { uses: 1 });
  // The client is whoever Cloudflare says connected; no other header changes it.
  assert.deepEqual(await data(await call(main, `/v1/songs/${song.id}/use`, { method: 'POST', ip: 'listener-1', headers: { 'X-Forwarded-For': '203.0.113.9', 'X-Oto-Client': 'somebody-else' } })), { uses: 1 });
  assert.deepEqual(await data(await use(main, song.id, 'listener-2')), { uses: 2 });
  // Two requests of one new client at the same moment are still one use.
  for (const twin of await Promise.all([use(main, song.id, 'listener-3'), use(main, song.id, 'listener-3')])) assert.deepEqual(await data(twin), { uses: 3 });
  assert.equal((await data(await read(main, song.id))).song.uses, 3);
  await refused(await call(main, `/v1/songs/${song.id}/use`), 404, 'not_found');
  // Only the hashed address, the song and the day are kept, and old days are dropped by a counted use.
  assert.deepEqual((await storage.exec('PRAGMA table_info(song_uses)')).map(column => column.name), ['song_id', 'client', 'day']);
  const today = Math.floor(Date.now() / 86400000);
  const kept = await storage.exec('SELECT client,day FROM song_uses WHERE song_id=? ORDER BY client', song.id);
  assert.deepEqual(kept.map(r => r.client), ['listener-1', 'listener-2', 'listener-3'].map(sha).sort());
  assert.equal(kept.every(r => Math.abs(Number(r.day) - today) <= 1), true);
  await storage.exec('INSERT INTO song_uses(song_id,client,day) VALUES(?,?,?),(?,?,?)', song.id, 'a'.repeat(64), today - 10, song.id, 'b'.repeat(64), today - 1);
  assert.deepEqual(await data(await use(main, song.id, 'listener-2')), { uses: 3 });
  assert.deepEqual(await data(await use(main, song.id, 'listener-4')), { uses: 4 });
  assert.deepEqual(await storage.exec('SELECT client FROM song_uses WHERE client IN (?,?)', 'a'.repeat(64), 'b'.repeat(64)), [{ client: 'b'.repeat(64) }]);

  // Most uses first; equal uses put the newer song first; lanes are never part of a list.
  const second = await posted(main, a), third = await posted(main, a), fourth = await posted(main, a), fifth = await posted(main, a);
  for (const ip of ['listener-1', 'listener-2', 'listener-3', 'listener-4']) await data(await use(main, second.id, ip));
  assert.deepEqual(await data(await use(main, third.id, 'listener-1')), { uses: 1 });
  const popular = await data(await call(main, '/v1/songs/popular'));
  assert.deepEqual(Object.keys(popular), ['songs']);
  assert.deepEqual(popular.songs.slice(0, 5).map((s: any) => [s.id, s.uses]), [[second.id, 4], [song.id, 4], [third.id, 1], [fifth.id, 0], [fourth.id, 0]]);
  assert.deepEqual(Object.keys(popular.songs[0]), ['id', 'title', 'credit', 'rights', 'author', 'beats', 'uses', 'createdAt']);
  assert.equal(popular.songs.length <= 30, true);
  assert.equal(popular.songs.slice(3).every((s: any) => s.uses === 0), true);
});

test('the list pages by 30 with an opaque cursor, stays put while songs arrive and refuses malformed cursors', async () => {
  const storage = await catalog(main), ids: string[] = [];
  const present = Number((await storage.exec("SELECT COUNT(*) AS n FROM songs WHERE status='public'"))[0].n);
  // Fill the catalogue to exactly two pages; an account may post ten songs a day.
  for (let who: Who | undefined; present + ids.length < 60;) {
    if (ids.length % 10 === 0) who = await account(main);
    ids.push((await posted(main, who!)).id);
  }
  assert.equal(ids.length > 30, true);
  const newest = [...ids].reverse();
  const first = await data(await call(main, '/v1/songs'));
  assert.deepEqual(first.songs.map((s: any) => s.id), newest.slice(0, 30)); assert.equal(typeof first.next, 'string');
  assert.equal(first.songs.some((s: any) => 'lanes' in s), false);
  const second = await data(await call(main, `/v1/songs/after/${first.next}`));
  assert.deepEqual(Object.keys(second), ['songs']); assert.equal(second.songs.length, 30);
  assert.deepEqual(second.songs.slice(0, ids.length - 30).map((s: any) => s.id), newest.slice(30));
  assert.equal(new Set([...first.songs, ...second.songs].map((s: any) => s.id)).size, 60);

  // A song posted meanwhile moves no page that a cursor already points into.
  const poster = await account(main), late = await posted(main, poster);
  assert.deepEqual(await data(await call(main, `/v1/songs/after/${first.next}`)), second);
  const walk = await pages(main);
  assert.deepEqual(walk.map(page => page.length), [30, 30, 1]); assert.equal(walk[0][0].id, late.id);
  assert.deepEqual(walk.flat().map(s => s.id), [late.id, ...first.songs.map((s: any) => s.id), ...second.songs.map((s: any) => s.id)]);
  // A removed song leaves its page without disturbing the others.
  await data(await remove(main, late.id, poster.session));
  assert.deepEqual((await pages(main)).map(page => page.length), [30, 30]);
  assert.deepEqual(await data(await call(main, '/v1/songs')), first);

  for (const cursor of ['', 'S', 'a b', '-1', '0', '00', '01', 'zzzzzzzzzzz', 'zzzzzzzzzzzz', '1.5', '%31', `${first.next}!`, randomUUID()])
    await refused(await call(main, `/v1/songs/after/${cursor}`), 400, 'invalid_cursor');
  await refused(await call(main, '/v1/songs/after'), 400, 'invalid_id');
  await refused(await call(main, `/v1/songs/after/${first.next}`, { method: 'POST' }), 400, 'invalid_id');
  // A well-formed cursor before the first song is simply the end.
  assert.deepEqual(await data(await call(main, '/v1/songs/after/1')), { songs: [] });
});

test('the same score posted again is the same song; accounts keep 30 songs and post 10 a day', async () => {
  const a = await account(main), b = await account(main), draft = score(), storage = await catalog(main);
  const song = await posted(main, a, { score: draft, title: 'first title' });
  const again = await data(await post(main, a.session, { score: draft, title: 'second title', rights: 'public_domain' }));
  assert.deepEqual(again, { song });
  // Key order and number spelling of the request do not make new content.
  const respelled = `{"rights":"own","score":{"lanes":${JSON.stringify(draft.lanes).replace('[[[0,', '[[[0.0,')},"beats":3.2e1,"v":1},"title":"third"}`;
  assert.deepEqual(await data(await call(main, '/v1/songs', { session: a.session, raw: respelled })), { song });
  const other = await posted(main, b, { score: draft });
  assert.notEqual(other.id, song.id);
  const racing = await Promise.all([1, 2].map(() => post(main, b.session, { score: { ...draft, beats: 64 } })));
  assert.deepEqual(racing.map(r => r.status).sort(), [200, 201]);
  const [x, y] = await Promise.all(racing.map(r => r.json() as Promise<any>)); assert.equal(x.song.id, y.song.id);
  assert.equal((await data(await call(main, '/v1/account/songs', { session: b.session }))).songs.length, 2);
  // Once removed, the same content may be posted again and becomes a new song.
  await data(await remove(main, song.id, a.session));
  const reposted = await posted(main, a, { score: draft });
  assert.notEqual(reposted.id, song.id); await refused(await read(main, song.id), 404, 'song_not_found');

  const c = await account(main), today: any[] = [];
  const yesterday = () => storage.exec("UPDATE songs SET created_at='2001-02-03T04:05:06.007Z' WHERE account_id=?", c.id);
  const live = async () => (await data(await call(main, '/v1/account/songs', { session: c.session }))).songs.length;
  for (let n = 0; n < 10; n++) today.push(await posted(main, c));
  await refused(await post(main, c.session), 429, 'post_limit');
  // A song already posted is still answered, and removing one does not buy another post today.
  assert.equal((await data(await post(main, c.session, { score: { v: 1, beats: 32, lanes: today[3].lanes } }))).song.id, today[3].id);
  await data(await remove(main, today[0].id, c.session));
  await refused(await post(main, c.session), 429, 'post_limit');
  assert.equal(await live(), 9);
  await yesterday();
  for (let n = 0; n < 10; n++) await posted(main, c);
  await refused(await post(main, c.session), 429, 'post_limit');
  await yesterday();
  for (let n = 0; n < 10; n++) await posted(main, c);
  await yesterday();
  await posted(main, c);
  assert.equal(await live(), 30);
  await refused(await post(main, c.session), 409, 'song_limit');
  assert.equal((await data(await post(main, c.session, { score: { v: 1, beats: 32, lanes: today[3].lanes } }))).song.id, today[3].id);
  // Hidden songs still count; only removing one makes room.
  await storage.exec("UPDATE songs SET status='hidden' WHERE id=?", today[1].id);
  await refused(await post(main, c.session), 409, 'song_limit');
  await data(await remove(main, today[1].id, c.session));
  await posted(main, c);
  await refused(await post(main, c.session), 409, 'song_limit');
  assert.equal(await live(), 30);
  assert.equal(Number((await storage.exec('SELECT COUNT(*) AS n FROM songs WHERE account_id=?', c.id))[0].n), 32);
});

test('three different accounts hide a song until the operator decides; its poster still sees it', async () => {
  const poster = await account(main, 'つくった人'), reporters: Who[] = [], storage = await catalog(main);
  for (let n = 0; n < 4; n++) reporters.push(await account(main));
  const [r1, r2, r3, r4] = reporters, song = await posted(main, poster);
  await refused(await report(main, song.id), 401, 'account_required');
  await refused(await report(main, song.id, poster), 400, 'own_song');
  await refused(await report(main, song.id, r1, { reason: 'boring' }), 400, 'invalid_reason');
  await refused(await report(main, song.id, r1, {}), 400, 'invalid_reason');
  await refused(await report(main, song.id, r1, { reason: 'other', note: 'n'.repeat(201) }), 400, 'invalid_text');
  await refused(await report(main, song.id, r1, { reason: 'other', note: 7 }), 400, 'invalid_text');
  await refused(await report(main, song.id, r1, { reason: 'other', pad: 'x'.repeat(9000) }), 413, 'body_too_large');
  await refused(await report(main, randomUUID(), r1), 404, 'song_not_found');
  await refused(await report(main, 'nope', r1), 400, 'invalid_id');
  await refused(await call(main, `/v1/songs/${song.id}/report`, { session: r1.session }), 404, 'not_found');
  assert.equal((await storage.exec('SELECT account_id FROM song_reports WHERE song_id=?', song.id)).length, 0);

  assert.deepEqual(await data(await report(main, song.id, r1, { reason: 'rights', note: 'これは市販の曲です' }), 201), { ok: true });
  // One report per account: a repeat is accepted and changes nothing.
  assert.deepEqual(await data(await report(main, song.id, r1, { reason: 'other', note: 'again' })), { ok: true });
  assert.deepEqual(await storage.exec('SELECT account_id,reason,note FROM song_reports WHERE song_id=?', song.id), [{ account_id: r1.id, reason: 'rights', note: 'これは市販の曲です' }]);
  await data(await report(main, song.id, r2, { reason: 'inappropriate' }), 201);
  assert.equal((await data(await read(main, song.id))).song.status, 'public');
  assert.equal((await listedIds(main)).includes(song.id), true);
  await data(await use(main, song.id, 'reported-listener'));
  assert.equal((await popularIds(main)).includes(song.id), true);
  await data(await report(main, song.id, r3, { reason: 'other', note: 'n'.repeat(200) }), 201);

  // Hidden: gone for everyone but the poster, whose session is the only thing that opens it.
  await refused(await read(main, song.id), 404, 'song_not_found');
  await refused(await read(main, song.id, r1.session), 404, 'song_not_found');
  await refused(await read(main, song.id, 'f'.repeat(64)), 404, 'song_not_found');
  await refused(await read(main, song.id, 'garbage'), 404, 'song_not_found');
  await refused(await call(main, `/v1/songs/${song.id}`, { headers: { 'X-Internal-Account': poster.id } }), 404, 'song_not_found');
  assert.equal((await listedIds(main)).includes(song.id), false); assert.equal((await popularIds(main)).includes(song.id), false);
  await refused(await use(main, song.id), 404, 'song_not_found');
  const own = await data(await read(main, song.id, poster.session));
  assert.deepEqual(own.song, { ...song, uses: 1, status: 'hidden' });
  assert.deepEqual((await data(await call(main, '/v1/account/songs', { session: poster.session }))).songs.map((s: any) => [s.id, s.status]), [[song.id, 'hidden']]);
  // Nobody new can report what they cannot see; an earlier reporter's retry still succeeds.
  await refused(await report(main, song.id, r4), 404, 'song_not_found');
  assert.deepEqual(await data(await report(main, song.id, r1)), { ok: true });
  await refused(await report(main, song.id, poster), 400, 'own_song');
  assert.equal((await storage.exec('SELECT account_id FROM song_reports WHERE song_id=?', song.id)).length, 3);
  // Posting the hidden score again does not put a fresh public copy beside it.
  const again = await data(await post(main, poster.session, { score: { v: 1, beats: song.beats, lanes: song.lanes } }));
  assert.deepEqual([again.song.id, again.song.status], [song.id, 'hidden']);
  // Nobody but the poster can remove it, and to them it does not even exist.
  await refused(await remove(main, song.id, r1.session), 404, 'song_not_found');
  await data(await remove(main, song.id, poster.session));
  assert.equal((await storage.exec('SELECT account_id FROM song_reports WHERE song_id=?', song.id)).length, 0);
  await refused(await report(main, song.id, r1), 404, 'song_not_found');
});

test('only the poster removes a song; the tombstone keeps the id and drops the score', async () => {
  const poster = await account(main), other = await account(main), draft = score(), storage = await catalog(main);
  const song = await posted(main, poster, { score: draft });
  await refused(await remove(main, song.id), 401, 'account_required');
  await refused(await remove(main, song.id, 'f'.repeat(64)), 401, 'session_expired');
  await refused(await remove(main, song.id, other.session), 403, 'poster_required');
  await refused(await call(main, `/v1/songs/${song.id}`, { method: 'DELETE', headers: { 'X-Internal-Account': poster.id } }), 401, 'account_required');
  await refused(await remove(main, randomUUID(), poster.session), 404, 'song_not_found');
  await refused(await remove(main, 'nope', poster.session), 400, 'invalid_id');
  assert.deepEqual(await data(await read(main, song.id)), { song });
  await data(await report(main, song.id, other), 201);
  await data(await use(main, song.id));

  assert.deepEqual(await data(await remove(main, song.id, poster.session)), { ok: true });
  await refused(await read(main, song.id), 404, 'song_not_found');
  await refused(await read(main, song.id, poster.session), 404, 'song_not_found');
  await refused(await remove(main, song.id, poster.session), 404, 'song_not_found');
  await refused(await use(main, song.id), 404, 'song_not_found');
  await refused(await report(main, song.id, other), 404, 'song_not_found');
  assert.equal((await listedIds(main)).includes(song.id), false); assert.equal((await popularIds(main)).includes(song.id), false);
  assert.deepEqual(await data(await call(main, '/v1/account/songs', { session: poster.session })), { songs: [] });
  assert.deepEqual(await storage.exec('SELECT id,status,lanes,uses FROM songs WHERE id=?', song.id), [{ id: song.id, status: 'removed', lanes: null, uses: 1 }]);
  assert.equal((await storage.exec('SELECT account_id FROM song_reports WHERE song_id=?', song.id)).length, 0);
  // The content is free again, under a new id.
  const again = await posted(main, poster, { score: draft });
  assert.notEqual(again.id, song.id); assert.deepEqual(again.lanes, draft.lanes); assert.equal(again.uses, 0);
});

test('operator routes exist only with a long ADMIN_TOKEN and decide reported songs', async () => {
  const admin = (api: Api, path: string, token?: string, method = 'GET', session?: string) =>
    call(api, `/v1/admin/songs/${path}`, { method, session, headers: token === undefined ? {} : { 'X-Oto-Admin': token } });
  const id = randomUUID(), wrong = adminToken.replace(/^./, c => (c === '0' ? '1' : '0'));
  for (const [path, method] of [['reported', 'GET'], [`${id}/hide`, 'POST'], [`${id}/restore`, 'POST'], [`${id}/remove`, 'POST']]) {
    // Without the secret, and with one too short to resist guessing, the routes are not there at all.
    await refused(await admin(main, path, undefined, method), 404, 'not_found');
    await refused(await admin(main, path, adminToken, method), 404, 'not_found');
    await refused(await admin(main, path, '', method), 404, 'not_found');
    await refused(await admin(weak, path, weakToken, method), 404, 'not_found');
    for (const token of [undefined, wrong, `${adminToken}0`, adminToken.slice(1), adminToken.toUpperCase(), weakToken])
      await refused(await admin(operated, path, token, method), 401, 'admin_required');
  }
  const poster = await account(operated, 'とうこう者'), reporters: Who[] = [];
  for (let n = 0; n < 3; n++) reporters.push(await account(operated));
  // A login is not an operator credential.
  await refused(await admin(operated, 'reported', undefined, 'GET', poster.session), 401, 'admin_required');
  assert.deepEqual(await data(await admin(operated, 'reported', adminToken)), { songs: [] });

  const quiet = await posted(operated, poster), song = await posted(operated, poster, { title: 'うたがわしい曲' });
  const { lanes, ...listed } = song;
  await data(await report(operated, song.id, reporters[0], { reason: 'rights', note: 'CDで聞いた曲です' }), 201);
  await data(await report(operated, song.id, reporters[1], { reason: 'other' }), 201);
  const reported = await data(await admin(operated, 'reported', adminToken));
  assert.equal(reported.songs.length, 1);
  assert.deepEqual(reported.songs[0], { ...listed, reports: reported.songs[0].reports });
  assert.deepEqual(reported.songs[0].reports.map((r: any) => [r.reason, r.note]), [['rights', 'CDで聞いた曲です'], ['other', '']]);
  assert.equal(reported.songs[0].reports.every((r: any) => Object.keys(r).join() === 'reason,note,createdAt' && new Date(r.createdAt).toISOString() === r.createdAt), true);
  // No account leaves the object, neither the poster's nor a reporter's.
  for (const who of [poster, ...reporters]) assert.equal(JSON.stringify(reported).includes(who.id), false);

  assert.deepEqual(await data(await admin(operated, `${song.id}/hide`, adminToken, 'POST')), { song: { ...listed, status: 'hidden' } });
  await refused(await read(operated, song.id), 404, 'song_not_found');
  assert.equal((await data(await read(operated, song.id, poster.session))).song.status, 'hidden');
  assert.deepEqual(await listedIds(operated), [quiet.id]);
  assert.deepEqual((await data(await admin(operated, 'reported', adminToken))).songs.map((s: any) => [s.id, s.status, s.reports.length]), [[song.id, 'hidden', 2]]);
  await data(await admin(operated, `${song.id}/hide`, adminToken, 'POST'));

  // Restoring makes it public again and settles the reports so far.
  assert.deepEqual(await data(await admin(operated, `${song.id}/restore`, adminToken, 'POST')), { song: { ...listed, status: 'public' } });
  assert.deepEqual(await data(await read(operated, song.id)), { song });
  assert.deepEqual(await listedIds(operated), [song.id, quiet.id]);
  assert.deepEqual(await data(await admin(operated, 'reported', adminToken)), { songs: [] });
  for (const who of reporters) await data(await report(operated, song.id, who), 201);
  await refused(await read(operated, song.id), 404, 'song_not_found');
  await data(await report(operated, quiet.id, reporters[0], { reason: 'inappropriate', note: 'later' }), 201);
  // Most recently reported first.
  assert.deepEqual((await data(await admin(operated, 'reported', adminToken))).songs.map((s: any) => [s.id, s.status, s.reports.length]), [[quiet.id, 'public', 1], [song.id, 'hidden', 3]]);

  assert.deepEqual(await data(await admin(operated, `${song.id}/remove`, adminToken, 'POST')), { song: { ...listed, status: 'removed' } });
  await refused(await read(operated, song.id), 404, 'song_not_found');
  await refused(await read(operated, song.id, poster.session), 404, 'song_not_found');
  assert.deepEqual((await data(await call(operated, '/v1/account/songs', { session: poster.session }))).songs.map((s: any) => s.id), [quiet.id]);
  assert.deepEqual((await data(await admin(operated, 'reported', adminToken))).songs.map((s: any) => s.id), [quiet.id]);
  assert.deepEqual(await (await catalog(operated)).exec('SELECT status,lanes FROM songs WHERE id=?', song.id), [{ status: 'removed', lanes: null }]);
  for (const action of ['hide', 'restore', 'remove']) {
    await refused(await admin(operated, `${song.id}/${action}`, adminToken, 'POST'), 404, 'song_not_found');
    await refused(await admin(operated, `${id}/${action}`, adminToken, 'POST'), 404, 'song_not_found');
    await refused(await admin(operated, `nope/${action}`, adminToken, 'POST'), 400, 'invalid_id');
    await refused(await admin(operated, `${quiet.id}/${action}`, adminToken, 'GET'), 404, 'not_found');
  }
  await refused(await admin(operated, `${quiet.id}/purge`, adminToken, 'POST'), 404, 'not_found');
  await refused(await admin(operated, 'reported', adminToken, 'POST'), 404, 'not_found');
  await refused(await admin(operated, quiet.id, adminToken), 404, 'not_found');
  await refused(await call(operated, '/v1/admin', { headers: { 'X-Oto-Admin': adminToken } }), 404, 'not_found');
  await refused(await call(operated, '/v1/admin/folders', { headers: { 'X-Oto-Admin': adminToken } }), 404, 'not_found');
  assert.equal((await data(await read(operated, quiet.id))).song.status, 'public');
});

test('folders still work beside the catalogue; unknown routes, queries, origins and entry limits', async () => {
  const a = await account(main), song = await posted(main, a);
  const created = await data(await call(main, '/v1/folders', { session: a.session, body: { title: '音の集まり', displayName: 'Owner', creationId: randomUUID() } }), 201);
  const bearer = { Authorization: `Bearer ${created.membership.token}` };
  assert.equal((await data(await call(main, `/v1/folders/${created.folder.id}`, { headers: bearer }))).folder.title, '音の集まり');
  assert.equal((await data(await call(main, '/v1/account/folders', { session: a.session }))).folders.length, 1);
  assert.equal((await data(await call(main, '/v1/account', { session: a.session }))).account.id, a.id);
  await refused(await call(main, `/v1/folders/${created.folder.id}`), 401, 'unauthorized');

  await refused(await call(main, '/v1/nothing'), 404, 'not_found');
  await refused(await call(main, '/v1/song'), 404, 'not_found');
  await refused(await call(main, '/songs'), 404, 'not_found');
  await refused(await call(main, '/v1/songs', { method: 'PUT', session: a.session, body: {} }), 404, 'not_found');
  await refused(await call(main, `/v1/songs/${song.id}`, { method: 'PATCH', session: a.session, body: { title: 'x' } }), 404, 'not_found');
  await refused(await call(main, `/v1/songs/${song.id}/lanes`), 404, 'not_found');
  await refused(await call(main, `/v1/songs/${song.id}/use/again`, { method: 'POST' }), 404, 'not_found');
  await refused(await call(main, '/v1/songs/popular', { method: 'POST' }), 400, 'invalid_id');
  await refused(await call(main, '/v1/songs/not-a-uuid'), 400, 'invalid_id');
  await refused(await call(main, `/v1/songs/${song.id.toUpperCase()}`), 400, 'invalid_id');
  await refused(await call(main, `/v1/songs/${song.id}/use`, { method: 'POST', session: a.session, headers: { Origin: 'https://outsider.example' } }), 403, 'origin_forbidden');
  await refused(await call(main, '/v1/songs?page=2'), 400, 'invalid_path');
  await refused(await call(main, `/v1/songs/${song.id}?session=${a.session}`), 400, 'invalid_path');
  assert.equal((await data(await read(main, song.id))).song.uses, 0);

  // Posting and reporting share the entry limit of ten a minute per client address; reading and using do not.
  for (let n = 0; n < 10; n++) await refused(await call(main, '/v1/songs', { ip: 'eager-poster', body: {} }), 401, 'account_required');
  await refused(await call(main, '/v1/songs', { ip: 'eager-poster', session: a.session, body: { title: 't', rights: 'own', score: score() } }), 429, 'rate_limited');
  await refused(await call(main, `/v1/songs/${song.id}/report`, { ip: 'eager-poster', session: a.session, body: { reason: 'other' } }), 429, 'rate_limited');
  await data(await call(main, '/v1/songs', { ip: 'eager-poster' }));
  await data(await call(main, `/v1/songs/${song.id}`, { ip: 'eager-poster' }));
  assert.deepEqual(await data(await use(main, song.id, 'eager-poster')), { uses: 1 });
  // The limit belongs to the address, not the account.
  await posted(main, a);
});
