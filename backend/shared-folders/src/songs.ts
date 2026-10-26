import { DurableObject } from 'cloudflare:workers';
import { ApiError, bodyJson, fail, hash, json, text, type Env } from './index';

const SONG_LIMITS = { bodyBytes: 65536, notesPerLane: 600, songs: 30, postsPerDay: 10, page: 30, reportsToHide: 3, reported: 100, adminTokenLength: 32 };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const HASH = /^[0-9a-f]{64}$/;
const CURSOR = /^[0-9a-z]{1,11}$/;
const TICKS_PER_BEAT = 480;
const DAY = 86400000;
const FIELDS = 'seq,id,account_id,author,title,credit,rights,beats,created_at,uses,status';
type Rights = 'own' | 'public_domain';
type Status = 'public' | 'hidden' | 'removed';
type Reason = 'rights' | 'inappropriate' | 'other';
type Note = [startTick: number, durationTicks: number, pitch: number];
type Draft = { title: string; credit: string; rights: Rights; beats: 32 | 64; lanes: Note[][] };
type Row = { seq: number; id: string; account_id: string; author: string; title: string; credit: string; rights: string; beats: number; created_at: string; uses: number; status: string };
type Stored = Row & { lanes: string | null };
// A row about to leave the object carries its poster key instead of anything that names the account.
type Keyed<T extends Row = Row> = T & { poster: string };
type Failure = { rpcError: { status: number; code: string; message: string } };

// Account IDs and content hashes stay inside the object; these three views are all that leaves it.
const summary = (r: Keyed) => ({ id: r.id, title: r.title, credit: r.credit, rights: r.rights as Rights, author: r.author, poster: r.poster, beats: r.beats, uses: r.uses, createdAt: r.created_at });
const owned = (r: Keyed) => ({ ...summary(r), status: r.status as Status });
const full = (r: Keyed<Stored>) => ({ ...owned(r), lanes: JSON.parse(r.lanes ?? '[]') as Note[][] });
// The poster key lets an app hide everything one account posted without learning who that is:
// the first 32 hex digits of SHA-256('poster:' + account ID), worked out when a row leaves.
// A deleted account's rows carry a random stand-in ID, so they can never give its old key again.
export const posterKey = async (accountId: string) => (await hash(`poster:${accountId}`)).slice(0, 32);
async function keyed<T extends Row>(rows: T[]): Promise<Keyed<T>[]> {
  const keys = new Map<string, Promise<string>>();
  const key = (id: string) => { let k = keys.get(id); if (!k) keys.set(id, k = posterKey(id)); return k; };
  return Promise.all(rows.map(async r => ({ ...r, poster: await key(r.account_id) })));
}
const one = async <T extends Row>(row: T) => (await keyed([row]))[0];

export const catalog = (env: Env) => env.SONGS.get(env.SONGS.idFromName('catalog'));
function notFound(): never { fail(404, 'not_found', 'Route not found.'); }
function songId(value: string | undefined): string {
  if (!value || !UUID.test(value)) fail(400, 'invalid_id', 'Invalid song ID.');
  return value;
}
// Optional free text: absent, null and '' all mean none.
function optional(value: unknown, maximum: number): string {
  return value === undefined || value === null || value === '' ? '' : text(value, maximum);
}
// A cursor is the insertion number of the last song already sent, in base 36, and only in its one spelling.
function cursorSeq(cursor: string): number {
  const seq = CURSOR.test(cursor) ? parseInt(cursor, 36) : 0;
  if (!Number.isSafeInteger(seq) || seq < 1 || seq.toString(36) !== cursor) fail(400, 'invalid_cursor', 'Invalid paging cursor.');
  return seq;
}
function unwrap<T extends object>(result: T): Exclude<T, { rpcError: unknown }> {
  if ('rpcError' in result) { const e = (result as unknown as Failure).rpcError; fail(e.status, e.code, e.message); }
  return result as Exclude<T, { rpcError: unknown }>;
}
function reply<T extends object>(result: T, status = 200): Response { return json(unwrap(result), status); }
async function sameSecret(given: string, expected: string): Promise<boolean> {
  // Digests have one length, so the comparison takes the same time whatever was sent.
  const digest = (value: string) => crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return crypto.subtle.timingSafeEqual(await digest(given), await digest(expected));
}

// The app turns a MIDI file into this small three-lane score. Nothing else is stored or served,
// so every field is checked here, before anything crosses to the catalogue object.
export function songDraft(b: Record<string, unknown>): Draft {
  const title = text(b.title, 40), credit = optional(b.credit, 60), rights = b.rights, s = b.score;
  if (rights !== 'own' && rights !== 'public_domain') fail(400, 'invalid_rights', "Rights must be 'own' or 'public_domain'.");
  if (!s || typeof s !== 'object' || Array.isArray(s) || Object.keys(s).some(k => k !== 'v' && k !== 'beats' && k !== 'lanes'))
    fail(400, 'invalid_score', 'A score is an object with exactly v, beats and lanes.');
  const { v, beats, lanes } = s as Record<string, unknown>;
  if (v !== 1) fail(400, 'unsupported_score_version', 'Score version must be 1.');
  if (beats !== 32 && beats !== 64) fail(400, 'invalid_beats', 'Beats must be 32 or 64.');
  if (!Array.isArray(lanes) || lanes.length !== 3 || !lanes.every(Array.isArray))
    fail(400, 'invalid_lanes', 'A score has exactly three lanes: melody, bass and chords.');
  if (!lanes[0].length) fail(400, 'empty_melody', 'The melody lane must not be empty.');
  const end = beats * TICKS_PER_BEAT;
  return { title, credit, rights, beats, lanes: (lanes as unknown[][]).map(lane => {
    if (lane.length > SONG_LIMITS.notesPerLane) fail(400, 'too_many_notes', `A lane holds at most ${SONG_LIMITS.notesPerLane} notes.`);
    let previous = 0;
    return lane.map((n): Note => {
      if (!Array.isArray(n) || n.length !== 3 || !n.every(Number.isInteger))
        fail(400, 'invalid_note', 'A note is [startTick, durationTicks, pitch] in integers.');
      const [start, duration, pitch] = n as Note;
      if (start < 0 || duration < 1 || start + duration > end)
        fail(400, 'invalid_note_time', 'A note starts at tick 0 or later, lasts at least one tick and ends inside the song.');
      if (pitch < 0 || pitch > 127) fail(400, 'invalid_pitch', 'Pitch must be 0 to 127.');
      if (start < previous) fail(400, 'unsorted_notes', 'Notes of a lane must be sorted by start tick.');
      previous = start;
      return [start, duration, pitch];
    });
  }) };
}

// Worker side of the catalogue. Whatever needs an account continues to AuthAccounts, which alone
// verifies sessions; the catalogue object has no fetch handler and is reached by RPC only.
export async function songRoute(request: Request, env: Env, p: string[], actor: string): Promise<Response> {
  const get = request.method === 'GET', post = request.method === 'POST', songs = catalog(env);
  const account = () => env.AUTH_ACCOUNTS.get(env.AUTH_ACCOUNTS.idFromName('accounts')).fetch(request);
  const entry = async () => {
    if (!(await env.ENTRY_LIMIT.limit({ key: actor })).success) fail(429, 'rate_limited', 'Please wait before posting or reporting another song.');
  };
  if (p[2] === 'admin') {
    // Operator routes do not exist until ADMIN_TOKEN is set to something too long to guess.
    // A header value never carries outer whitespace, so a pasted trailing newline must not lock the operator out.
    const secret = typeof env.ADMIN_TOKEN === 'string' ? env.ADMIN_TOKEN.trim() : '', action = p[5];
    if (secret.length < SONG_LIMITS.adminTokenLength) notFound();
    if (!(await sameSecret(request.headers.get('X-Oto-Admin') ?? '', secret))) fail(401, 'admin_required', 'Operator credentials are required.');
    if (get && p.length === 5 && p[4] === 'reported') return reply(await songs.reported());
    if (post && p.length === 6 && (action === 'hide' || action === 'restore' || action === 'remove')) return reply(await songs.moderate(songId(p[4]), action));
    notFound();
  }
  if (p.length === 3) {
    if (get) return reply(await songs.list());
    if (!post) notFound();
    await entry(); return account();
  }
  if (get && p.length === 4 && p[3] === 'popular') return reply(await songs.popular());
  if (get && p.length === 5 && p[3] === 'after') return reply(await songs.list(p[4]));
  const id = songId(p[3]);
  if (get && p.length === 4) {
    const found = await songs.read(id);
    // Public reads never touch the account object. Only a refused read that carries a session
    // goes there, because it may be the poster asking for their own hidden song.
    return 'rpcError' in found && request.headers.has('X-Oto-Session') ? account() : reply(found);
  }
  if (request.method === 'DELETE' && p.length === 4) return account();
  if (post && p.length === 5 && p[4] === 'use') return reply(await songs.use(id, actor));
  if (post && p.length === 5 && p[4] === 'report') { await entry(); return account(); }
  notFound();
}

// AuthAccounts side. `verify` is its own session check, so the catalogue only ever hears of an
// account that AuthAccounts has just verified, and only over RPC.
export async function accountSongRoute(request: Request, env: Env, p: string[], verify: () => Promise<{ id: string; displayName: string }>): Promise<Response> {
  const get = request.method === 'GET', post = request.method === 'POST', songs = catalog(env);
  if (get && p[2] === 'songs' && p.length === 4) {
    // Reading stays public: a stale or foreign session sees exactly what anyone sees.
    const reader = await verify().catch(e => { if (e instanceof ApiError) return undefined; throw e; });
    return reply(await songs.read(songId(p[3]), reader?.id));
  }
  const account = await verify();
  if (p[2] === 'account') { if (!get) notFound(); return reply(await songs.mine(account.id)); }
  if (post && p.length === 3) {
    const draft = songDraft(await bodyJson(request, SONG_LIMITS.bodyBytes));
    const made = unwrap(await songs.post({ ...draft, accountId: account.id, author: account.displayName }));
    return json({ song: made.song }, made.created ? 201 : 200);
  }
  const id = songId(p[3]);
  if (request.method === 'DELETE' && p.length === 4) return reply(await songs.remove(id, account.id));
  if (post && p.length === 5 && p[4] === 'report') {
    const b = await bodyJson(request), reason = b.reason;
    if (reason !== 'rights' && reason !== 'inappropriate' && reason !== 'other') fail(400, 'invalid_reason', "Reason must be 'rights', 'inappropriate' or 'other'.");
    const made = unwrap(await songs.report({ id, accountId: account.id, reason, note: optional(b.note, 200) }));
    return json({ ok: true }, made.created ? 201 : 200);
  }
  notFound();
}

// One instance holds the whole public catalogue. Its callers pass values they have verified
// themselves (the account, the hashed client address); no request or header ever reaches it.
export class SongCatalog extends DurableObject<Env> {
  private queue: Promise<unknown> = Promise.resolve();
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const sql = ctx.storage.sql;
    // A removed song keeps its row without lanes: its id is never reused and its post still counts for its day.
    sql.exec(`CREATE TABLE IF NOT EXISTS songs (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, account_id TEXT NOT NULL,
      author TEXT NOT NULL, title TEXT NOT NULL, credit TEXT NOT NULL, rights TEXT NOT NULL, beats INTEGER NOT NULL, lanes TEXT,
      content_hash TEXT NOT NULL, created_at TEXT NOT NULL, uses INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'public')`);
    sql.exec("CREATE UNIQUE INDEX IF NOT EXISTS songs_content ON songs(account_id, content_hash) WHERE status!='removed'");
    sql.exec('CREATE INDEX IF NOT EXISTS songs_account ON songs(account_id, seq)');
    sql.exec('CREATE INDEX IF NOT EXISTS songs_newest ON songs(status, seq)');
    sql.exec('CREATE INDEX IF NOT EXISTS songs_popular ON songs(status, uses, seq)');
    sql.exec('CREATE TABLE IF NOT EXISTS song_reports (song_id TEXT NOT NULL, account_id TEXT NOT NULL, reason TEXT NOT NULL, note TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY(song_id, account_id))');
    // Counting a use remembers a hashed client address, the song and the UTC day, and nothing else.
    sql.exec('CREATE TABLE IF NOT EXISTS song_uses (song_id TEXT NOT NULL, client TEXT NOT NULL, day INTEGER NOT NULL, PRIMARY KEY(song_id, client, day))');
    sql.exec('CREATE INDEX IF NOT EXISTS song_uses_day ON song_uses(day)');
  }
  private exclusive<T>(work: () => Promise<T>): Promise<T> {
    const next = this.queue.then(work, work); this.queue = next.catch(() => {}); return next;
  }
  // An error loses its class across RPC, so API errors travel as data, as in SharedFolder.accountAccess.
  private run<T>(work: () => T | Promise<T>): Promise<T | Failure> {
    return this.exclusive(async () => work()).catch(e => {
      if (e instanceof ApiError) return { rpcError: { status: e.status, code: e.code, message: e.message } };
      throw e;
    });
  }
  private find<T extends Row = Row>(id: string, columns = FIELDS): T | undefined {
    return this.ctx.storage.sql.exec<T>(`SELECT ${columns} FROM songs WHERE id=?`, id).toArray()[0];
  }
  // Removed songs are visible to nobody, hidden ones only to their poster.
  private visible<T extends Row = Row>(id: string, accountId?: string, columns = FIELDS): T {
    const song = this.find<T>(id, columns);
    if (!song || (song.status !== 'public' && (song.status !== 'hidden' || song.account_id !== accountId))) fail(404, 'song_not_found', 'Song not found.');
    return song;
  }
  // The tombstone keeps the id and the posting day, but neither the score nor the reports.
  private bury(song: Row): void {
    const sql = this.ctx.storage.sql;
    this.ctx.storage.transactionSync(() => {
      sql.exec("UPDATE songs SET status='removed', lanes=NULL WHERE seq=?", song.seq);
      sql.exec('DELETE FROM song_reports WHERE song_id=?', song.id);
    });
  }
  list(cursor?: string) {
    return this.run(async () => {
      const before = cursor === undefined ? Number.MAX_SAFE_INTEGER : cursorSeq(cursor);
      // One row more than a page tells whether another page follows.
      const rows = this.ctx.storage.sql.exec<Row>(`SELECT ${FIELDS} FROM songs WHERE status='public' AND seq<? ORDER BY seq DESC LIMIT ${SONG_LIMITS.page + 1}`, before).toArray();
      const page = rows.slice(0, SONG_LIMITS.page);
      return { songs: (await keyed(page)).map(summary), ...(rows.length > page.length ? { next: page[page.length - 1].seq.toString(36) } : {}) };
    });
  }
  popular() {
    return this.run(async () => ({ songs: (await keyed(this.ctx.storage.sql.exec<Row>(
      `SELECT ${FIELDS} FROM songs WHERE status='public' ORDER BY uses DESC, seq DESC LIMIT ${SONG_LIMITS.page}`).toArray())).map(summary) }));
  }
  read(id: string, accountId?: string) {
    return this.run(async () => ({ song: full(await one(this.visible<Stored>(id, accountId, `${FIELDS},lanes`))) }));
  }
  mine(accountId: string) {
    return this.run(async () => ({ songs: (await keyed(this.ctx.storage.sql.exec<Row>(
      `SELECT ${FIELDS} FROM songs WHERE account_id=? AND status!='removed' ORDER BY seq DESC`, accountId).toArray())).map(owned) }));
  }
  post(input: Draft & { accountId: string; author: string }) {
    return this.run(async () => {
      const sql = this.ctx.storage.sql, lanes = JSON.stringify(input.lanes);
      // Canonical JSON of {beats,lanes}: this key order, integers only, no whitespace.
      const contentHash = await hash(`{"beats":${input.beats},"lanes":${lanes}}`);
      // Nothing below awaits, so the checks and the insert cannot interleave with another post.
      const same = sql.exec<Stored>(`SELECT ${FIELDS},lanes FROM songs WHERE account_id=? AND content_hash=? AND status!='removed'`, input.accountId, contentHash).toArray()[0];
      if (same) return { created: false, song: full(await one(same)) };
      const now = new Date().toISOString();
      // Removed songs still count for the day they were posted, so deleting does not buy more posts.
      const today = sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM (SELECT created_at FROM songs WHERE account_id=? ORDER BY seq DESC LIMIT ${SONG_LIMITS.postsPerDay}) WHERE created_at>=?`,
        input.accountId, now.slice(0, 10)).one().n;
      if (today >= SONG_LIMITS.postsPerDay) fail(429, 'post_limit', `Accounts can post ${SONG_LIMITS.postsPerDay} songs a day. Please try again tomorrow.`);
      const kept = sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM songs WHERE account_id=? AND status!='removed'", input.accountId).one().n;
      if (kept >= SONG_LIMITS.songs) fail(409, 'song_limit', `Accounts can keep ${SONG_LIMITS.songs} songs. Remove one to post another.`);
      const id = crypto.randomUUID();
      sql.exec('INSERT INTO songs (id,account_id,author,title,credit,rights,beats,lanes,content_hash,created_at) VALUES (?,?,?,?,?,?,?,?,?,?)',
        id, input.accountId, input.author, input.title, input.credit, input.rights, input.beats, lanes, contentHash, now);
      return { created: true, song: full(await one(this.find<Stored>(id, `${FIELDS},lanes`)!)) };
    });
  }
  use(id: string, client: string) {
    return this.run(() => {
      // Only the Worker's own digest of the client address may be kept, never an address or a header.
      if (!HASH.test(client)) throw new TypeError('The client key must be a SHA-256 digest.');
      const sql = this.ctx.storage.sql, song = this.find(id), day = Math.floor(Date.now() / DAY);
      if (!song || song.status !== 'public') fail(404, 'song_not_found', 'Song not found.');
      if (sql.exec('SELECT 1 FROM song_uses WHERE song_id=? AND client=? AND day=?', id, client, day).toArray().length) return { uses: song.uses };
      this.ctx.storage.transactionSync(() => {
        sql.exec('DELETE FROM song_uses WHERE day<?', day - 2);
        sql.exec('INSERT INTO song_uses (song_id,client,day) VALUES (?,?,?)', id, client, day);
        sql.exec('UPDATE songs SET uses=uses+1 WHERE seq=?', song.seq);
      });
      return { uses: song.uses + 1 };
    });
  }
  report(input: { id: string; accountId: string; reason: Reason; note: string }) {
    return this.run(() => {
      const sql = this.ctx.storage.sql, song = this.find(input.id);
      if (!song || song.status === 'removed') fail(404, 'song_not_found', 'Song not found.');
      if (song.account_id === input.accountId) fail(400, 'own_song', 'You cannot report your own song.');
      // A repeated report changes nothing, also after the song has been hidden.
      if (sql.exec('SELECT 1 FROM song_reports WHERE song_id=? AND account_id=?', song.id, input.accountId).toArray().length) return { created: false };
      if (song.status !== 'public') fail(404, 'song_not_found', 'Song not found.');
      this.ctx.storage.transactionSync(() => {
        sql.exec('INSERT INTO song_reports (song_id,account_id,reason,note,created_at) VALUES (?,?,?,?,?)', song.id, input.accountId, input.reason, input.note, new Date().toISOString());
        const reports = sql.exec<{ n: number }>('SELECT COUNT(*) AS n FROM song_reports WHERE song_id=?', song.id).one().n;
        if (reports >= SONG_LIMITS.reportsToHide) sql.exec("UPDATE songs SET status='hidden' WHERE seq=?", song.seq);
      });
      return { created: true };
    });
  }
  remove(id: string, accountId: string) {
    return this.run(() => {
      const song = this.visible(id, accountId);
      if (song.account_id !== accountId) fail(403, 'poster_required', 'Only the poster can remove a song.');
      this.bury(song); return { ok: true };
    });
  }
  reported() {
    return this.run(async () => {
      const sql = this.ctx.storage.sql;
      const songs = await keyed(sql.exec<Row>(`SELECT ${FIELDS} FROM songs JOIN (SELECT song_id, MAX(rowid) AS latest FROM song_reports GROUP BY song_id) r ON r.song_id=songs.id
        WHERE status!='removed' ORDER BY r.latest DESC LIMIT ${SONG_LIMITS.reported}`).toArray());
      // Reports leave without the reporting account: the operator judges the song, not the reporter.
      return { songs: songs.map(song => ({ ...owned(song), reports: sql.exec<{ reason: string; note: string; created_at: string }>(
        'SELECT reason,note,created_at FROM song_reports WHERE song_id=? ORDER BY rowid', song.id).toArray()
        .map(r => ({ reason: r.reason as Reason, note: r.note, createdAt: r.created_at })) })) };
    });
  }
  moderate(id: string, action: 'hide' | 'restore' | 'remove') {
    return this.run(async () => {
      const sql = this.ctx.storage.sql, song = this.find(id);
      if (!song || song.status === 'removed') fail(404, 'song_not_found', 'Song not found.');
      const status: Status = action === 'hide' ? 'hidden' : action === 'restore' ? 'public' : 'removed';
      if (status === 'removed') this.bury(song);
      else this.ctx.storage.transactionSync(() => {
        sql.exec('UPDATE songs SET status=? WHERE seq=?', status, song.seq);
        // Restoring settles the reports made so far; later ones start from zero.
        if (status === 'public') sql.exec('DELETE FROM song_reports WHERE song_id=?', song.id);
      });
      return { song: { ...owned(await one(song)), status } };
    });
  }
  // A deleted account takes its songs with it: each one still listed becomes the same tombstone its
  // poster's DELETE leaves, and every row of the account, old tombstones too, loses the display name,
  // the words and the score hash, and gets a random stand-in for the account ID. Reports the account
  // made go as well; a song they hid stays hidden for the operator. Running it again changes nothing.
  removeAccount(accountId: string) {
    return this.run(() => {
      const sql = this.ctx.storage.sql;
      this.ctx.storage.transactionSync(() => {
        for (const song of sql.exec<{ seq: number; id: string; status: string }>('SELECT seq,id,status FROM songs WHERE account_id=?', accountId).toArray()) {
          if (song.status !== 'removed') sql.exec('DELETE FROM song_reports WHERE song_id=?', song.id);
          sql.exec("UPDATE songs SET status='removed', lanes=NULL, account_id=?, author='', title='', credit='', content_hash='' WHERE seq=?",
            `deleted:${crypto.randomUUID()}`, song.seq);
        }
        sql.exec('DELETE FROM song_reports WHERE account_id=?', accountId);
      });
      return { ok: true as const };
    });
  }
}
