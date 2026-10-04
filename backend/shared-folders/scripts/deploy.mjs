import { spawn } from 'node:child_process';
import { appendFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import ts from 'typescript';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const accountPattern = /^[a-f0-9]{32}$/i;

// Never surface response bodies, fetch errors or child output: they can contain credentials.
export class ApiError extends Error {
  constructor(status) {
    super(`Cloudflare API request failed (HTTP ${status}). Check token permissions, account selection and R2 activation in the dashboard.`);
    this.status = status;
  }
}

export function createApi(token, fetchImpl = fetch) {
  if (!token?.trim()) throw new Error('Set CLOUDFLARE_API_TOKEN to a Cloudflare management API token.');
  return async (endpoint, { method = 'GET', body, jurisdiction } = {}) => {
    let response;
    try {
      response = await fetchImpl(`https://api.cloudflare.com/client/v4${endpoint}`, {
        method, redirect: 'error', signal: AbortSignal.timeout(30_000),
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json',
          ...(jurisdiction ? { 'cf-r2-jurisdiction': jurisdiction } : {}) },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      });
    } catch { throw new Error('Cloudflare API connection failed. Check network connectivity and retry.'); }
    let data;
    try { data = await response.json(); } catch { throw new ApiError(response.status); }
    if (!response.ok || data.success !== true) throw new ApiError(response.status);
    return data;
  };
}

export async function selectAccount(api, requested) {
  if (requested) {
    if (!accountPattern.test(requested)) throw new Error('CLOUDFLARE_ACCOUNT_ID must be a 32-character hexadecimal account ID.');
    const { result } = await api(`/accounts/${requested}`);
    if (result?.id !== requested) throw new Error('The selected Cloudflare account could not be verified.');
    return requested;
  }
  const ids = new Set();
  for (let page = 1; ; page++) {
    const data = await api(`/accounts?page=${page}&per_page=50`);
    if (!Array.isArray(data.result)) throw new Error('Unexpected Cloudflare account response.');
    for (const account of data.result) {
      if (!accountPattern.test(account.id)) throw new Error('Unexpected Cloudflare account ID.');
      ids.add(account.id);
    }
    if (ids.size > 1) throw new Error('Multiple Cloudflare accounts are accessible. Set CLOUDFLARE_ACCOUNT_ID explicitly.');
    const totalPages = data.result_info?.total_pages;
    if (totalPages !== undefined ? page >= totalPages : data.result.length < 50) break;
  }
  if (ids.size !== 1) throw new Error('No accessible Cloudflare account found. Check token account scope and Account Settings Read permission.');
  return [...ids][0];
}

export async function ensurePrivateBucket(api, accountId, binding) {
  const name = binding.bucket_name;
  if (typeof name !== 'string' || !/^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$/.test(name)) {
    throw new Error('Each configured R2 binding needs a valid bucket_name.');
  }
  const base = `/accounts/${accountId}/r2/buckets`;
  const endpoint = `${base}/${encodeURIComponent(name)}`;
  const options = { jurisdiction: binding.jurisdiction };
  let created = false;
  try { await api(endpoint, options); }
  catch (error) {
    if (!(error instanceof ApiError) || error.status !== 404) throw error;
    await api(base, { ...options, method: 'POST', body: { name } });
    created = true;
  }
  const managed = (await api(`${endpoint}/domains/managed`, options)).result;
  const custom = (await api(`${endpoint}/domains/custom`, options)).result;
  if (typeof managed?.enabled !== 'boolean' || !Array.isArray(custom?.domains)) {
    throw new Error('R2 privacy could not be verified; deployment stopped.');
  }
  // Reject any attached custom domain, including disabled/pending ones.
  if (managed.enabled || custom.domains.length > 0) {
    throw new Error('Configured R2 bucket has an r2.dev or custom public domain. Use a private bucket or remove public exposure in Cloudflare before deploying.');
  }
  return { name, created };
}

export function deploymentConfig(source, sourceRoot, accountId) {
  if (typeof source.main !== 'string' || typeof source.name !== 'string' || !/^[a-z0-9][a-z0-9-]*$/.test(source.name)) {
    throw new Error('Wrangler config needs a valid Worker name and main entrypoint.');
  }
  if (source.workers_dev !== true) throw new Error('This deployment helper requires workers_dev: true to return the service URL.');
  return { ...source, $schema: path.join(sourceRoot, 'node_modules/wrangler/config-schema.json'),
    main: path.resolve(sourceRoot, source.main), ...(accountId ? { account_id: accountId } : {}) };
}

export function wranglerCommand(configPath, dryRun, sourceRoot = root, env = process.env) {
  const childEnv = { ...env, CI: 'true', WRANGLER_SEND_METRICS: 'false' };
  // Dry-run must stay usable without management credentials, even when a shell has them.
  if (dryRun) for (const key of Object.keys(childEnv)) {
    if (/^(CLOUDFLARE_|CF_)/.test(key)) delete childEnv[key];
  }
  return { command: process.execPath,
    args: [path.join(sourceRoot, 'node_modules/wrangler/bin/wrangler.js'), 'deploy', '--config', configPath,
      ...(dryRun ? ['--dry-run', '--outdir', path.join(sourceRoot, '.wrangler/deploy-dist')] : [])],
    options: { cwd: sourceRoot, env: childEnv, shell: false, stdio: 'ignore' } };
}

export function runWrangler(spec) {
  return new Promise((resolve, reject) => {
    const child = spawn(spec.command, spec.args, spec.options);
    child.once('error', () => reject(new Error('Could not start installed Wrangler. Run npm ci first.')));
    child.once('exit', (code) => code === 0 ? resolve() : reject(new Error(`Wrangler deployment failed (exit ${code ?? 'unknown'}). Check Cloudflare permissions, R2 activation and Workers configuration. No child logs are printed to protect credentials.`)));
  });
}

export async function deploy({ sourceRoot = root, env = process.env, dryRun = false, fetchImpl = fetch, run = runWrangler } = {}) {
  const sourcePath = path.join(sourceRoot, 'wrangler.jsonc');
  const parsed = ts.parseConfigFileTextToJson(sourcePath, await readFile(sourcePath, 'utf8'));
  if (parsed.error) throw new Error('Could not parse wrangler.jsonc.');
  const source = parsed.config;
  let api, accountId, buckets = [];
  if (!dryRun) {
    api = createApi(env.CLOUDFLARE_API_TOKEN, fetchImpl);
    accountId = await selectAccount(api, env.CLOUDFLARE_ACCOUNT_ID || source.account_id);
  }
  // Validate the final config before provisioning anything.
  const config = deploymentConfig(source, sourceRoot, accountId);
  if (!Array.isArray(source.r2_buckets) || source.r2_buckets.length === 0) throw new Error('No R2 bucket bindings configured.');
  if (!dryRun) for (const binding of source.r2_buckets) buckets.push(await ensurePrivateBucket(api, accountId, binding));
  const outputDir = path.join(sourceRoot, '.wrangler');
  await mkdir(outputDir, { recursive: true });
  const configPath = path.join(outputDir, 'deploy-config.json');
  await writeFile(configPath, `${JSON.stringify(config, null, 2)}\n`);
  await run(wranglerCommand(configPath, dryRun, sourceRoot, { ...env, ...(accountId ? { CLOUDFLARE_ACCOUNT_ID: accountId } : {}) }));
  if (dryRun) return { dryRun: true };
  const { result } = await api(`/accounts/${accountId}/workers/subdomain`);
  if (typeof result?.subdomain !== 'string' || !/^[a-z0-9][a-z0-9-]*$/.test(result.subdomain)) {
    throw new Error('Worker deployed, but its workers.dev URL could not be verified. Check Workers in the Cloudflare dashboard.');
  }
  const info = { worker: config.name, accountId, url: `https://${config.name}.${result.subdomain}.workers.dev`, buckets,
    deployedAt: new Date().toISOString() };
  await writeFile(path.join(outputDir, 'deployment-info.json'), `${JSON.stringify(info, null, 2)}\n`);
  if (env.GITHUB_STEP_SUMMARY) await appendFile(env.GITHUB_STEP_SUMMARY, `Shared folders deployed: [${info.url}](${info.url})\n`);
  return info;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  if (args.some((arg) => arg !== '--dry-run')) {
    console.error('Usage: node scripts/deploy.mjs [--dry-run]');
    process.exitCode = 1;
  } else {
    deploy({ dryRun: args.includes('--dry-run') }).then((info) => {
      console.log(info.dryRun ? 'Wrangler dry-run completed. No Cloudflare resources were changed.' : `Deployed: ${info.url}`);
    }).catch((error) => { console.error(error.message); process.exitCode = 1; });
  }
}
