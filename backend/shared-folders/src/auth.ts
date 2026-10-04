import { DurableObject } from 'cloudflare:workers';
import { generateRegistrationOptions, generateAuthenticationOptions, verifyRegistrationResponse, verifyAuthenticationResponse, type RegistrationResponseJSON, type AuthenticationResponseJSON } from '@simplewebauthn/server';
import { bodyJson, fail, hash, token, text, json, errorResponse, type Env } from './index';
import browser from './passkey-browser.txt';

const HEX = /^[0-9a-f]{64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
type Account = { id: string; displayName: string; plan: 'free'; maxOwnedFolders: 1 };
type Flow = { state: string; challengeHash: string; origin: string; expires: number; mode?: string; challenge?: string; account?: Account; verified?: string };
type Credential = { accountId: string; id: string; publicKey: number[]; counter: number };
type Session = { accountId: string; expires: number };
type Quota = { creationId: string; folderId: string; title: string };

export function authAsset(path: string): Response | undefined {
  const headers = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' };
  if (path === '/passkey-browser.js') return new Response(browser, { headers: { ...headers, 'Content-Type': 'application/javascript' } });
  if (path === '/auth.js') return new Response(`const requestId=new URLSearchParams(location.hash.slice(1)).get('request');history.replaceState(null,'','/auth');const status=document.getElementById('status');async function post(path,body){const r=await fetch('/v1/auth/'+path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});const b=await r.json();if(!r.ok)throw Error(b.error.message);return b;}async function run(mode){document.querySelectorAll('button').forEach(b=>b.disabled=true);try{if(!/^[a-f0-9]{64}$/.test(requestId||''))throw Error('アプリからログインを開始してください。');status.textContent='パスキーを確認しています…';const {options}=await post('options',{requestId,mode,displayName:document.getElementById('name').value});const response=mode==='register'?await SimpleWebAuthnBrowser.startRegistration({optionsJSON:options}):await SimpleWebAuthnBrowser.startAuthentication({optionsJSON:options});const {callbackUrl}=await post('verify',{requestId,mode,response});location.href=callbackUrl;status.textContent='アプリに戻ってください。';}catch(e){status.textContent=e.name==='NotAllowedError'?'パスキーの確認がキャンセルされました。':e.message.includes('expired')||e.message.includes('again')?'アプリに戻り、もう一度ログインしてください。':e.message.includes('Text must')?'表示名を1〜30文字で入力してください。':'ログインできませんでした。もう一度お試しください。';}finally{document.querySelectorAll('button').forEach(b=>b.disabled=false);}}document.getElementById('register').onclick=()=>run('register');document.getElementById('login').onclick=()=>run('login');`, { headers: { ...headers, 'Content-Type': 'application/javascript' } });
  if (path === '/auth.css') return new Response(`*{box-sizing:border-box}body{margin:0;background:#fff9ef;color:#423b34;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;line-height:1.65}.card{width:min(100% - 32px,440px);margin:8vh auto;padding:30px 26px;background:#fffdf8;border:1px solid #eee2d5;border-radius:24px;box-shadow:0 12px 40px #6c49300c}h1{margin:0;color:#e77d69;font-size:30px;letter-spacing:-1px}h2{font-size:22px;line-height:1.4;margin:22px 0 10px}.intro,.hint{color:#766b60;font-size:14px}.hint{font-size:12px}label{display:block;font-size:14px;font-weight:600;margin:22px 0 8px}input{display:block;width:100%;padding:13px 14px;border:1px solid #ddcfc2;border-radius:12px;background:white;font:inherit;color:inherit}input:focus-visible,button:focus-visible{outline:3px solid #e8b5a5;outline-offset:3px}.actions{display:grid;gap:12px;margin-top:22px}button{width:100%;min-height:50px;padding:12px;border:1px solid #ddcfc2;border-radius:13px;background:#fffdf8;color:inherit;font:inherit;font-weight:600;cursor:pointer}#register{background:#e98571;border-color:#e98571;color:#fff}button:disabled{opacity:.6;cursor:wait}#status{font-size:14px;min-height:24px;color:#99604f;margin-bottom:0}@media(max-width:380px){.card{padding:24px 20px;margin-top:24px}}`, {headers:{...headers,'Content-Type':'text/css; charset=utf-8'}});
  if (path === '/auth') return new Response(`<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OtoGrashi ログイン</title><link rel="stylesheet" href="/auth.css"><body><main class="card"><h1>OtoGrashi</h1><h2>音の思い出を、いつものアカウントで。</h2><p class="intro">パスキーでログインすると、共有フォルダーを別の端末でも復元できます。Face IDや端末の画面ロックで、かんたんに本人確認できます。</p><label for="name">共有フォルダーで使う表示名</label><input id="name" maxlength="30" autocomplete="nickname" placeholder="例：はる"><p class="hint">表示名はアカウント作成・フォルダー参加時に使います。</p><div class="actions"><button id="register">パスキーでアカウントを作成</button><button id="login">登録済みのパスキーでログイン</button></div><p class="hint">パスキーはこのサービスのアドレスに保存されます。</p><p id="status" role="status" aria-live="polite"></p></main><script src="/passkey-browser.js"></script><script src="/auth.js"></script></body></html>`, { headers: { ...headers, 'Content-Type': 'text/html; charset=utf-8', 'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'", 'Permissions-Policy': 'publickey-credentials-get=(self), publickey-credentials-create=(self)' } });
}

// One namespace instance coordinates credential discovery and serializes account quotas.
// Only private DO RPC reaches folder account methods; public headers confer no authority.
export class AuthAccounts extends DurableObject<Env> {
  private queue: Promise<unknown> = Promise.resolve();
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS auth_records (kind TEXT NOT NULL, id TEXT NOT NULL, data TEXT NOT NULL, expires INTEGER, PRIMARY KEY(kind,id))');
    if (!ctx.storage.sql.exec<{name:string}>('PRAGMA table_info(auth_records)').toArray().some(column => column.name === 'expires')) {
      ctx.storage.sql.exec('ALTER TABLE auth_records ADD COLUMN expires INTEGER');
      ctx.storage.sql.exec("UPDATE auth_records SET expires=json_extract(data,'$.expires') WHERE kind IN ('flow','code','session')");
    }
    ctx.storage.sql.exec('CREATE INDEX IF NOT EXISTS auth_expiry ON auth_records(expires) WHERE expires IS NOT NULL');
  }
  private get<T>(kind: string, id: string): T | undefined { const row = this.ctx.storage.sql.exec<{data:string}>('SELECT data FROM auth_records WHERE kind=? AND id=?', kind, id).toArray()[0]; return row ? JSON.parse(row.data) : undefined; }
  private set(kind: string, id: string, data: unknown) {
    const expiry=(data as {expires?:unknown})?.expires;
    const expires=['flow','code','session'].includes(kind) && typeof expiry==='number' ? expiry : null;
    this.ctx.storage.sql.exec('INSERT INTO auth_records(kind,id,data,expires) VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET data=excluded.data,expires=excluded.expires', kind, id, JSON.stringify(data), expires);
  }
  private remove(kind: string, id: string) { this.ctx.storage.sql.exec('DELETE FROM auth_records WHERE kind=? AND id=?', kind, id); }
  private exclusive<T>(work: () => Promise<T>): Promise<T> { const next=this.queue.then(work,work); this.queue=next.catch(()=>{}); return next; }
  private async scheduleExpiry(): Promise<void> {
    const expires=this.ctx.storage.sql.exec<{expires:number|null}>('SELECT MIN(expires) AS expires FROM auth_records WHERE expires IS NOT NULL').toArray()[0].expires;
    const alarm=await this.ctx.storage.getAlarm();
    if(expires===null) { if(alarm!==null) await this.ctx.storage.deleteAlarm(); }
    else if(alarm!==expires) await this.ctx.storage.setAlarm(expires);
  }
  async alarm(): Promise<void> {
    await this.exclusive(async()=>{
      this.ctx.storage.sql.exec("DELETE FROM auth_records WHERE expires IS NOT NULL AND expires<=? AND kind IN ('flow','code','session')",Date.now());
      await this.scheduleExpiry();
    });
  }
  async fetch(request: Request): Promise<Response> { return this.exclusive(async()=>{ try { return await this.route(request); } catch(e) { return errorResponse(e); } finally { await this.scheduleExpiry(); } }); }
  private async account(request: Request): Promise<Account> {
    const raw=request.headers.get('X-Oto-Session'); if(!raw || !HEX.test(raw)) fail(401,'account_required','Log in with a passkey.');
    const s=this.get<Session>('session',await hash(raw)); if(!s || s.expires<=Date.now()) fail(401,'session_expired','Please log in again.');
    const a=this.get<Account>('account',s.accountId); if(!a) fail(401,'session_expired','Please log in again.'); return a;
  }
  private async route(request: Request): Promise<Response> {
    const url=new URL(request.url), p=url.pathname, post=request.method==='POST';
    if(post && p==='/v1/auth/start') {
      const b=await bodyJson(request); if(typeof b.state!=='string'||!HEX.test(b.state)||typeof b.codeChallenge!=='string'||!HEX.test(b.codeChallenge)) fail(400,'invalid_auth_request','Invalid state or PKCE challenge.');
      const id=token(); this.set('flow',await hash(id),{state:b.state,challengeHash:b.codeChallenge,origin:url.origin,expires:Date.now()+300000} satisfies Flow);
      return json({authorizeUrl:`${url.origin}/auth#request=${id}`});
    }
    if(post && (p==='/v1/auth/options'||p==='/v1/auth/verify')) {
      const b=await bodyJson(request); if(typeof b.requestId!=='string'||!HEX.test(b.requestId)) fail(400,'invalid_auth_request','Invalid login request.');
      const id=await hash(b.requestId), f=this.get<Flow>('flow',id); if(!f||f.expires<=Date.now()||f.verified||f.origin!==url.origin) fail(401,'auth_expired','Start login again.');
      if(b.mode!=='register'&&b.mode!=='login') fail(400,'invalid_auth_request','Invalid passkey operation.');
      if(p.endsWith('/options')) {
        if(f.challenge) fail(409,'challenge_exists','Start login again.');
        f.mode=b.mode;
        const options=b.mode==='register' ? await generateRegistrationOptions({rpName:'OtoGrashi',rpID:url.hostname,userName:crypto.randomUUID(),userDisplayName:text(b.displayName,30),attestationType:'none',authenticatorSelection:{residentKey:'required',userVerification:'required'},extensions:{credProps:true}}) : await generateAuthenticationOptions({rpID:url.hostname,userVerification:'required'});
        if(b.mode==='register') f.account={id:crypto.randomUUID(),displayName:text(b.displayName,30),plan:'free',maxOwnedFolders:1};
        f.challenge=options.challenge; this.set('flow',id,f); return json({options});
      }
      if(!f.challenge||f.mode!==b.mode) fail(401,'auth_expired','Start login again.');
      const challenge=f.challenge; delete f.challenge; this.set('flow',id,f); // consume even failed verifications
      let accountId: string;
      try {
        if(b.mode==='register') {
          const response=b.response as RegistrationResponseJSON;
          const v=await verifyRegistrationResponse({response,expectedChallenge:challenge,expectedOrigin:f.origin,expectedRPID:url.hostname,requireUserVerification:true});
          if(!v.verified || !f.account || response.clientExtensionResults?.credProps?.rk!==true) throw Error();
          const c=v.registrationInfo.credential;
          if(this.get('credential',c.id)) throw Error();
          accountId=f.account.id;
          this.set('account',accountId,f.account); this.set('credential',c.id,{accountId,id:c.id,publicKey:Array.from(c.publicKey),counter:c.counter} satisfies Credential);
        } else {
          const response=b.response as AuthenticationResponseJSON;
          const c=this.get<Credential>('credential',response.id); if(!c) throw Error();
          const v=await verifyAuthenticationResponse({response,expectedChallenge:challenge,expectedOrigin:f.origin,expectedRPID:url.hostname,requireUserVerification:true,credential:{id:c.id,publicKey:new Uint8Array(c.publicKey),counter:c.counter}});
          if(!v.verified) throw Error(); c.counter=v.authenticationInfo.newCounter; this.set('credential',c.id,c); accountId=c.accountId;
        }
      } catch { fail(401,'passkey_invalid','Passkey verification failed. Start login again.'); }
      const code=token(); f.verified=accountId; this.set('flow',id,f); this.set('code',await hash(code),{...f,flowId:id});
      return json({callbackUrl:`otograshi://auth?state=${f.state}&code=${code}`});
    }
    if(post && p==='/v1/auth/exchange') {
      const b=await bodyJson(request); if(typeof b.code!=='string'||!HEX.test(b.code)||typeof b.codeVerifier!=='string'||!HEX.test(b.codeVerifier)) fail(400,'invalid_auth_request','Invalid callback.');
      const key=await hash(b.code), f=this.get<Flow & {flowId:string}>('code',key);
      if(!f||f.expires<=Date.now()||f.origin!==url.origin||f.state!==b.state||await hash(b.codeVerifier)!==f.challengeHash||!f.verified) fail(401,'auth_expired','Callback verification failed.');
      this.remove('code',key); this.remove('flow',f.flowId);
      const t=token(),expires=Date.now()+30*86400000; this.set('session',await hash(t),{accountId:f.verified,expires} satisfies Session);
      return json({token:t,expiresAt:new Date(expires).toISOString(),account:this.get('account',f.verified)});
    }
    const a=await this.account(request);
    if(request.method==='GET' && p==='/v1/account') return json({account:a});
    if(post&&p==='/v1/auth/logout') { this.remove('session',await hash(request.headers.get('X-Oto-Session')!)); return json({ok:true}); }
    if(request.method==='GET'&&p==='/v1/account/folders') {
      const ids=this.get<string[]>('memberships',a.id)??[],folders=[];
      for(const id of ids) { const result=await this.env.FOLDERS.get(this.env.FOLDERS.idFromName(id)).accountAccess({accountId:a.id,displayName:a.displayName}); if(result && !('rpcError' in result)) folders.push(result); }
      return json({folders});
    }
    if(post&&p==='/v1/folders') {
      const b=await bodyJson(request); if(typeof b.creationId!=='string'||!UUID.test(b.creationId)) fail(400,'invalid_creation_id','A UUID v4 creationId is required.');
      let q=this.get<Quota>('quota',a.id);
      if(q) {
        const folder=this.env.FOLDERS.get(this.env.FOLDERS.idFromName(q.folderId));
        if(await folder.isClosed()) q=undefined;
        else if(q.creationId!==b.creationId) {
          if(await folder.isInitialized()) fail(409,'owned_folder_limit','Free accounts can own one open shared folder.');
          q={...q,creationId:b.creationId,title:text(b.title,40)}; this.set('quota',a.id,q);
        }
      }
      if(!q) { q={creationId:b.creationId,folderId:crypto.randomUUID(),title:text(b.title,40)}; this.set('quota',a.id,q); }
      const result=await this.env.FOLDERS.get(this.env.FOLDERS.idFromName(q.folderId)).accountAccess({accountId:a.id,displayName:text(b.displayName,30),create:{id:q.folderId,title:q.title}});
      if(result && 'rpcError' in result) fail(result.rpcError.status,result.rpcError.code,result.rpcError.message);
      if(!result) fail(404,'folder_not_found','Folder is unavailable.'); this.remember(a.id,q.folderId); return json(result,201);
    }
    const m=p.match(/^\/v1\/folders\/([0-9a-f-]+)\/join$/);
    if(post&&m&&UUID.test(m[1])) {
      const b=await bodyJson(request); const result=await this.env.FOLDERS.get(this.env.FOLDERS.idFromName(m[1])).accountAccess({accountId:a.id,displayName:text(b.displayName,30),inviteToken:b.inviteToken as string});
      if(result && 'rpcError' in result) fail(result.rpcError.status,result.rpcError.code,result.rpcError.message);
      if(!result) fail(404,'folder_not_found','Folder is unavailable.'); this.remember(a.id,m[1]); return json(result);
    }
    fail(404,'not_found','Route not found.');
  }
  private remember(accountId:string,id:string) { const ids=this.get<string[]>('memberships',accountId)??[]; if(!ids.includes(id)) { ids.push(id); this.set('memberships',accountId,ids); } }
}
