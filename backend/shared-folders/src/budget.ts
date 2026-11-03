import { DurableObject } from 'cloudflare:workers';
import type { Env } from './index';

// What the shared folders may use of R2. Cloudflare's free allowance is 10 GB stored, 1 million
// Class A operations (writes and lists) and 10 million Class B operations (reads) a month, and past it
// R2 bills; the folders stop a fifth short of each instead, so the bucket never costs anything.
export const BUDGET = { bytes: 8_000_000_000, writes: 800_000, reads: 8_000_000 };

export const budget = (env: Env) => env.BUDGET.get(env.BUDGET.idFromName('budget'));

// One object for the whole service: every folder asks it before writing or reading R2. Each method
// runs its SQL without awaiting, so two folders can never both take the last room.
export class StorageBudget extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS stored (key TEXT PRIMARY KEY, bytes INTEGER NOT NULL)');
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS totals (name TEXT PRIMARY KEY, value INTEGER NOT NULL)');
  }
  private total(name: string): number {
    return this.ctx.storage.sql.exec<{ value: number }>('SELECT value FROM totals WHERE name=?', name).toArray()[0]?.value ?? 0;
  }
  private add(name: string, amount: number): void {
    this.ctx.storage.sql.exec('INSERT INTO totals (name,value) VALUES (?,?) ON CONFLICT(name) DO UPDATE SET value=value+excluded.value', name, amount);
  }
  // Operations are counted per UTC month, as R2 counts them; earlier months are forgotten.
  private operation(kind: 'writes' | 'reads', limit?: number): boolean {
    const month = new Date().toISOString().slice(0, 7), name = `${kind}:${month}`;
    if (limit !== undefined && this.total(name) >= limit) return false;
    this.ctx.storage.sql.exec("DELETE FROM totals WHERE name LIKE ? AND name<>?", `${kind}:%`, name);
    this.add(name, 1);
    return true;
  }
  // Room for an object about to be written, and the write itself. False when either would pass the budget.
  async store(key: string, bytes: number): Promise<boolean> {
    const before = this.ctx.storage.sql.exec<{ bytes: number }>('SELECT bytes FROM stored WHERE key=?', key).toArray()[0]?.bytes ?? 0;
    if (this.total('bytes') - before + bytes > BUDGET.bytes || !this.operation('writes', BUDGET.writes)) return false;
    this.ctx.storage.sql.exec('INSERT INTO stored (key,bytes) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET bytes=excluded.bytes', key, bytes);
    this.add('bytes', bytes - before);
    return true;
  }
  async read(): Promise<boolean> { return this.operation('reads', BUDGET.reads); }
  // Listing a closed folder to empty it is a Class A operation too, but deleting must never be refused.
  async listed(): Promise<void> { this.operation('writes'); }
  // Deleted objects give their room back; keys that were never stored are ignored.
  async release(keys: string[]): Promise<void> {
    let freed = 0;
    for (const key of keys) freed += this.ctx.storage.sql.exec<{ bytes: number }>('DELETE FROM stored WHERE key=? RETURNING bytes', key).toArray()[0]?.bytes ?? 0;
    if (freed) this.add('bytes', -freed);
  }
  // Every key of a folder starts with its id and a slash; '0' is the character after '/'.
  async releaseFolder(folderId: string): Promise<void> {
    const freed = this.ctx.storage.sql.exec<{ bytes: number }>('DELETE FROM stored WHERE key>=? AND key<? RETURNING bytes', `${folderId}/`, `${folderId}0`)
      .toArray().reduce((n, row) => n + row.bytes, 0);
    if (freed) this.add('bytes', -freed);
  }
  async usage(): Promise<{ bytes: number; writes: number; reads: number }> {
    const month = new Date().toISOString().slice(0, 7);
    return { bytes: this.total('bytes'), writes: this.total(`writes:${month}`), reads: this.total(`reads:${month}`) };
  }
}
