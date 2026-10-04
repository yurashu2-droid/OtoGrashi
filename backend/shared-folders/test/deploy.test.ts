import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { ApiError, createApi, deploy, deploymentConfig, ensurePrivateBucket, selectAccount, wranglerCommand } from '../scripts/deploy.mjs';

const account = 'a'.repeat(32);
const otherAccount = 'b'.repeat(32);
const token = 'test-token-must-never-appear';
const source = { name: 'otograshi-shared-folders', main: 'src/index.ts', workers_dev: true,
  durable_objects: { bindings: [{ name: 'ACCOUNTS', class_name: 'SharingAccount' }] },
  migrations: [{ tag: 'v2', new_sqlite_classes: ['SharingAccount'] }],
  r2_buckets: [{ binding: 'FILES', bucket_name: 'private-media' }] };
const success = (result: unknown, result_info?: unknown) => ({ success: true, result, result_info });

test('selects one account, verifies explicit selection, rejects none and ambiguity including pagination', async () => {
  assert.equal(await selectAccount(async () => success([{ id: account }]), undefined), account);
  assert.equal(await selectAccount(async (endpoint: string) => {
    assert.equal(endpoint, `/accounts/${otherAccount}`);
    return success({ id: otherAccount });
  }, otherAccount), otherAccount);
  await assert.rejects(selectAccount(async () => success([]), undefined), /No accessible/);
  await assert.rejects(selectAccount(async () => success([{ id: account }, { id: otherAccount }]), undefined), /Multiple/);
  await assert.rejects(selectAccount(async (endpoint: string) => success([{ id: endpoint.includes('page=1&') ? account : otherAccount }], { total_pages: 2 }), undefined), /Multiple/);
  await assert.rejects(selectAccount(async () => { throw Error('must not call'); }, 'invalid'), /hexadecimal/);
});

test('reuses private bucket, creates missing bucket, checks jurisdiction and never modifies public domains', async () => {
  for (const missing of [false, true]) {
    const calls: { endpoint: string; options: any }[] = [];
    const result = await ensurePrivateBucket(async (endpoint: string, options: any) => {
      calls.push({ endpoint, options });
      assert.equal(options.jurisdiction, 'eu');
      if (endpoint.endsWith('/domains/managed')) return success({ enabled: false });
      if (endpoint.endsWith('/domains/custom')) return success({ domains: [] });
      if (missing && !options.method) throw new ApiError(404);
      return success({ name: 'private-media' });
    }, account, { bucket_name: 'private-media', jurisdiction: 'eu' });
    assert.deepEqual(result, { name: 'private-media', created: missing });
    assert.equal(calls.filter((call) => call.options.method === 'POST').length, missing ? 1 : 0);
    if (missing) assert.deepEqual(calls[1].options.body, { name: 'private-media' });
    assert.ok(calls.every((call) => !call.options.method || call.options.method === 'POST'));
  }
});

test('fails closed for public exposure, unverifiable privacy and permission errors', async () => {
  for (const [managed, custom] of [[{ enabled: true }, { domains: [] }], [{ enabled: false }, { domains: [{ enabled: true }] }],
    [{ enabled: false }, { domains: [{ enabled: false }] }], [{}, { domains: [] }]]) {
    await assert.rejects(ensurePrivateBucket(async (endpoint: string) => success(endpoint.endsWith('/managed') ? managed : endpoint.endsWith('/custom') ? custom : {}), account, source.r2_buckets[0]), /public domain|privacy/);
  }
  let calls = 0;
  await assert.rejects(ensurePrivateBucket(async () => { calls++; throw new ApiError(403); }, account, source.r2_buckets[0]), /HTTP 403/);
  assert.equal(calls, 1);
});

test('API transport uses bearer token and safe errors omit all server and network error text', async () => {
  const api = createApi(token, async (url: string, options: any) => {
    assert.ok(url.startsWith('https://api.cloudflare.com/client/v4/'));
    assert.equal(options.headers.Authorization, `Bearer ${token}`);
    assert.equal(options.redirect, 'error');
    return new Response(JSON.stringify({ success: false, errors: [{ message: token }] }), { status: 403 });
  });
  await assert.rejects(api('/accounts'), (error: Error) => error.message.includes('HTTP 403') && !error.message.includes(token));
  await assert.rejects(createApi(token, async () => { throw Error(token); })('/accounts'), (error: Error) => !error.message.includes(token));
  await assert.rejects(createApi(token, async () => new Response(token, { status: 502 }))('/accounts'), /HTTP 502/);
  assert.throws(() => createApi(''), /CLOUDFLARE_API_TOKEN/);
});

test('generated config preserves bindings/migrations and resolves main from original directory', () => {
  const config = deploymentConfig(source, path.resolve('backend'), account);
  assert.equal(config.main, path.resolve('backend/src/index.ts'));
  assert.equal(config.account_id, account);
  assert.deepEqual(config.durable_objects, source.durable_objects);
  assert.deepEqual(config.migrations, source.migrations);
  assert.deepEqual(config.r2_buckets, source.r2_buckets);
  assert.equal('account_id' in source, false);
});

test('dry-run requires no secrets or API and uses installed Wrangler with shell disabled', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'oto-deploy-'));
  try {
    await writeFile(path.join(dir, 'wrangler.jsonc'), `// current bindings\n${JSON.stringify(source)}`);
    const result = await deploy({ sourceRoot: dir, dryRun: true,
      env: { CLOUDFLARE_API_TOKEN: token, CLOUDFLARE_ACCOUNT_ID: account, CF_API_KEY: token },
      fetchImpl: async () => { throw Error('dry-run must not call API'); },
      run: async (spec: any) => {
        assert.equal(spec.command, process.execPath);
        assert.ok(spec.args[0].endsWith(path.join('wrangler', 'bin', 'wrangler.js')));
        assert.ok(spec.args.includes('--dry-run'));
        assert.equal(spec.options.shell, false);
        assert.equal(JSON.stringify(spec).includes(token), false);
      } });
    assert.deepEqual(result, { dryRun: true });
    const config = JSON.parse(await readFile(path.join(dir, '.wrangler/deploy-config.json'), 'utf8'));
    assert.equal(config.main, path.join(dir, 'src/index.ts'));
    assert.equal(JSON.stringify(config).includes(token), false);
    assert.deepEqual(config.migrations, source.migrations);
    assert.ok(wranglerCommand('config with spaces.json', false, dir, {}).args.includes('config with spaces.json'));
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('deployment writes safe URL artifact and summary after provisioning and child success', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'oto-deploy-'));
  const calls: string[] = [];
  try {
    await writeFile(path.join(dir, 'wrangler.jsonc'), JSON.stringify(source));
    const summary = path.join(dir, 'summary.md');
    const info = await deploy({ sourceRoot: dir, env: { CLOUDFLARE_API_TOKEN: token, GITHUB_STEP_SUMMARY: summary },
      fetchImpl: async (url: string) => {
        calls.push(url);
        let result: any = {};
        if (url.includes('/accounts?')) result = [{ id: account }];
        if (url.endsWith('/domains/managed')) result = { enabled: false };
        if (url.endsWith('/domains/custom')) result = { domains: [] };
        if (url.endsWith('/workers/subdomain')) result = { subdomain: 'my-account' };
        return new Response(JSON.stringify(success(result)));
      }, run: async (spec: any) => {
        assert.equal(spec.options.env.CLOUDFLARE_API_TOKEN, token);
        assert.equal(spec.options.env.CLOUDFLARE_ACCOUNT_ID, account);
        assert.ok(calls.some((call) => call.endsWith('/domains/custom')));
        calls.push('deploy');
      } });
    assert.equal(info.url, 'https://otograshi-shared-folders.my-account.workers.dev');
    assert.ok(calls.indexOf('deploy') < calls.findIndex((call) => call.endsWith('/workers/subdomain')));
    for (const file of ['deployment-info.json', 'deploy-config.json']) {
      assert.equal((await readFile(path.join(dir, '.wrangler', file), 'utf8')).includes(token), false);
    }
    assert.ok((await readFile(summary, 'utf8')).includes(info.url));
  } finally { await rm(dir, { recursive: true, force: true }); }
});
