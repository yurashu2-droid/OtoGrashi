import {before,after,test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash,randomBytes,randomUUID,generateKeyPairSync,sign} from 'node:crypto';
import {encodeCBOR} from '@levischuck/tiny-cbor';
import {build} from 'esbuild';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
let mf:Miniflare,sequence=0;
const origin='https://sharing.example', sha=(s:string|Buffer)=>createHash('sha256').update(s).digest();
before(async()=>{
  const compiled=await build({entryPoints:['src/index.ts'],bundle:true,write:false,format:'esm',external:['cloudflare:workers'],target:'es2022',loader:{'.txt':'text'}});
  mf=new Miniflare({...convertV4MiniflareOptions({name:'passkeys',modules:true,script:compiled.outputFiles[0].text,compatibilityDate:'2025-10-11',durableObjects:{FOLDERS:{className:'SharedFolder',useSQLite:true},AUTH_ACCOUNTS:{className:'AuthAccounts',useSQLite:true}},r2Buckets:['FILES'],ratelimits:{API_LIMIT:{namespace_id:'1002',simple:{limit:120,period:60}},ENTRY_LIMIT:{namespace_id:'1001',simple:{limit:10,period:60}}}}),unsafeInspectDurableObjects:true});await mf.ready;
});
after(async()=>{await mf?.dispose();});
async function req(path:string,body?:unknown,session?:string,method=body===undefined?'GET':'POST',headers={}) {if(method==='POST'&&(path==='/v1/folders'||path.endsWith('/join')))body={displayName:'共有名',...(body as object)};return mf.dispatchFetch(origin+path,{method,headers:{'CF-Connecting-IP':`auth-${++sequence}`,...(session?{'X-Oto-Session':session}:{}),...headers},...(body===undefined?{}:{body:JSON.stringify(body)})});}
async function ok(r:any,status=200){const b=await r.json();assert.equal(r.status,status,JSON.stringify(b));return b;}
async function flow(mode='register'){const state=randomBytes(32).toString('hex'),codeVerifier=randomBytes(32).toString('hex');const a=await ok(await req('/v1/auth/start',{state,codeChallenge:sha(codeVerifier).toString('hex')}));const requestId=new URLSearchParams(new URL(a.authorizeUrl).hash.slice(1)).get('request')!;const {options}=await ok(await req('/v1/auth/options',{requestId,mode,displayName:'テスト'}));return {state,codeVerifier,requestId,mode,options};}
const pair=generateKeyPairSync('ec',{namedCurve:'prime256v1'}),credentialId=randomBytes(32).toString('base64url');
function authData(flags:number,counter=0){const n=Buffer.alloc(4);n.writeUInt32BE(counter);return Buffer.concat([sha('sharing.example'),Buffer.from([flags]),n]);}
function registration(f:any,flags=0x45,webOrigin=origin){const jwk=pair.publicKey.export({format:'jwk'});const cose=encodeCBOR(new Map<any,any>([[1,2],[3,-7],[-1,1],[-2,Buffer.from(jwk.x!,'base64url')],[-3,Buffer.from(jwk.y!,'base64url')]]));const id=Buffer.from(credentialId,'base64url'),length=Buffer.alloc(2);length.writeUInt16BE(id.length);const data=Buffer.concat([authData(flags),Buffer.alloc(16),length,id,Buffer.from(cose)]);return {id:credentialId,rawId:credentialId,type:'public-key',clientExtensionResults:{credProps:{rk:true}},response:{clientDataJSON:Buffer.from(JSON.stringify({type:'webauthn.create',challenge:f.options.challenge,origin:webOrigin})).toString('base64url'),attestationObject:Buffer.from(encodeCBOR(new Map<any,any>([['fmt','none'],['attStmt',new Map()],['authData',data]]))).toString('base64url'),transports:['internal']}};}
function assertion(f:any,counter=1,flags=5,webOrigin=origin){const client=Buffer.from(JSON.stringify({type:'webauthn.get',challenge:f.options.challenge,origin:webOrigin})),data=authData(flags,counter);return {id:credentialId,rawId:credentialId,type:'public-key',clientExtensionResults:{},response:{clientDataJSON:client.toString('base64url'),authenticatorData:data.toString('base64url'),signature:sign('sha256',Buffer.concat([data,sha(client)]),pair.privateKey).toString('base64url')}};}
async function verify(f:any,response:any){return req('/v1/auth/verify',{requestId:f.requestId,mode:f.mode,response});}
async function exchange(f:any,result:any,overrides={}){const code=new URL(result.callbackUrl).searchParams.get('code');return req('/v1/auth/exchange',{state:f.state,code,codeVerifier:f.codeVerifier,...overrides});}
let session:string,accountId:string;
test('real WebAuthn registration and signed login; PKCE, callback replay and logout',async()=>{
  const f=await flow(),response=registration(f),v=await ok(await verify(f,response));
  await ok(await verify(f,response),401);await ok(await exchange(f,v,{codeVerifier:'0'.repeat(64)}),401);
  const result=await ok(await exchange(f,v));session=result.token;accountId=result.account.id;assert.deepEqual(result.account,{id:accountId,displayName:'テスト',plan:'free',maxOwnedFolders:1});await ok(await exchange(f,v),401);
  const login=await flow('login'),signed=assertion(login);const lv=await ok(await verify(login,signed));const l=await ok(await exchange(login,lv));assert.equal(l.account.id,accountId);await ok(await req('/v1/account',undefined,l.token));await ok(await req('/v1/auth/logout',{},l.token));await ok(await req('/v1/account',undefined,l.token),401);
});
test('wrong origin, user verification, forged signature and assertion replay fail',async()=>{
  for(const make of [(f:any)=>assertion(f,2,5,'https://evil.example'),(f:any)=>assertion(f,2,1),(f:any)=>({...assertion(f,2),response:{...assertion(f,2).response,signature:randomBytes(70).toString('base64url')}}),(f:any)=>assertion(f,1)]){const f=await flow('login');await ok(await verify(f,make(f)),401);await ok(await verify(f,assertion(f,3)),401);}
  const f=await flow();await ok(await verify(f,registration(f,0x41)),401);
});
test('authoritative quota, concurrent creation, retry, closure and restored multi-device permissions',async()=>{
  const creationId=randomUUID(),body={title:'音',creationId};const first=await ok(await req('/v1/folders',body,session),201);const retry=await ok(await req('/v1/folders',body,session),201);assert.equal(retry.folder.id,first.folder.id);assert.equal(retry.membership.memberId,first.membership.memberId);assert.notEqual(retry.membership.token,first.membership.token);assert.equal(first.folder.members[0].displayName,'共有名');
  await ok(await req('/v1/folders',{title:'別',creationId:randomUUID()},session),409);
  const restores=[];for(let i=0;i<8;i++){const r=await ok(await req('/v1/account/folders',undefined,session));assert.equal(r.folders[0].membership.memberId,first.membership.memberId);restores.push(r.folders[0].membership.token);}
  await ok(await req(`/v1/folders/${first.folder.id}`,undefined,undefined,'GET',{Authorization:`Bearer ${first.membership.token}`}));
  await ok(await req(`/v1/folders/${first.folder.id}`,undefined,undefined,'DELETE',{Authorization:`Bearer ${restores[0]}`}));
  // Device A retained the original creationId after losing its response; device B closed it.
  const replacement=await ok(await req('/v1/folders',body,session),201);assert.notEqual(replacement.folder.id,first.folder.id);
  const replacementRetry=await ok(await req('/v1/folders',body,session),201);assert.equal(replacementRetry.membership.memberId,replacement.membership.memberId);
  await ok(await req(`/v1/folders/${replacement.folder.id}`,undefined,undefined,'DELETE',{Authorization:`Bearer ${replacement.membership.token}`}));
  const responses=await Promise.all([req('/v1/folders',{title:'新',creationId:randomUUID()},session),req('/v1/folders',{title:'別',creationId:randomUUID()},session)]);assert.deepEqual(responses.map(r=>r.status).sort(),[201,409]);
  await ok(await req('/v1/folders',{title:'不正',creationId:randomUUID()},undefined,'POST',{'X-Internal-Account':accountId}),401);
  await ok(await req('/v1/account',undefined,'0'.repeat(64)),401);
});
test('persisted candidate survives interruption before private folder creation and lost response',async()=>{
  const accountId=randomUUID(),t=randomBytes(32).toString('hex'),creationId=randomUUID(),folderId=randomUUID();
  const storage=await mf.unsafeGetDurableObjectStorage('passkeys','AuthAccounts',{name:'accounts'});
  for(const [kind,id,value] of [['account',accountId,{id:accountId,displayName:'復元',plan:'free',maxOwnedFolders:1}],['session',sha(t).toString('hex'),{accountId,expires:Date.now()+86400000}],['quota',accountId,{creationId,folderId,title:'中断'}]] as const) await storage.exec('INSERT INTO auth_records(kind,id,data) VALUES(?,?,?)',kind,id,JSON.stringify(value));
  const replacementId=randomUUID();
  const result=await ok(await req('/v1/folders',{creationId:replacementId,title:'再試行'},t),201);assert.equal(result.folder.id,folderId);assert.equal(result.folder.title,'再試行');
  const retry=await ok(await req('/v1/folders',{creationId:replacementId,title:'再試行',displayName:'変更'},t),201);assert.equal(retry.folder.id,result.folder.id);assert.equal(retry.membership.memberId,result.membership.memberId);assert.equal(retry.folder.members[0].displayName,'共有名');assert.notEqual(retry.membership.token,result.membership.token);
  await ok(await req(`/v1/folders/${folderId}`,undefined,undefined,'GET',{Authorization:`Bearer ${result.membership.token}`}));
  // Join consumes no ownership slot and remains the same contributor on another device.
  const invitation=await ok(await req(`/v1/folders/${folderId}/invite`,{},undefined,'POST',{Authorization:`Bearer ${result.membership.token}`}));
  const joined=await ok(await req(`/v1/folders/${folderId}/join`,{inviteToken:new URL(invitation.inviteUrl).hash.slice(1)},session));
  assert.equal(joined.membership.role,'member');const restored=await ok(await req('/v1/account/folders',undefined,session));assert.equal(restored.folders.find((x:any)=>x.folder.id===folderId).membership.memberId,joined.membership.memberId);
});
test('actual expiry alarm removes only expired flows/codes/sessions and keeps valid durable records',async()=>{
  const storage=await mf.unsafeGetDurableObjectStorage('passkeys','AuthAccounts',{name:'accounts'});
  const retainedBefore=await storage.exec("SELECT kind,id,data FROM auth_records WHERE kind IN ('account','credential','quota','memberships') ORDER BY kind,id");
  const now=Date.now(),ids=[];
  for(const kind of ['flow','code','session']) {
    for(const expires of [now-1000,now+600000]) {
      const id=randomBytes(32).toString('hex');ids.push({kind,id,expires});
      await storage.exec('INSERT INTO auth_records(kind,id,data,expires) VALUES(?,?,?,?)',kind,id,JSON.stringify({expires}),expires);
    }
  }
  // A normal request schedules the earliest indexed expiry; workerd invokes the real alarm.
  await ok(await req('/v1/account',undefined,session));
  let expiredRemaining=3;
  for(let attempt=0;attempt<50 && expiredRemaining;attempt++) {
    expiredRemaining=0;
    for(const item of ids.filter(item=>item.expires<now)) expiredRemaining+=(await storage.exec('SELECT id FROM auth_records WHERE kind=? AND id=?',item.kind,item.id)).length;
    if(expiredRemaining) await new Promise(resolve=>setTimeout(resolve,50));
  }
  assert.equal(expiredRemaining,0,'workerd alarm must delete expired records');
  for(const item of ids.filter(item=>item.expires>now)) assert.equal((await storage.exec('SELECT id FROM auth_records WHERE kind=? AND id=?',item.kind,item.id)).length,1);
  assert.deepEqual(await storage.exec("SELECT kind,id,data FROM auth_records WHERE kind IN ('account','credential','quota','memberships') ORDER BY kind,id"),retainedBefore);
  await ok(await req('/v1/account',undefined,session));
});
test('legacy token still authenticates; hashed expired sessions/flows and own-origin assets',async()=>{
  const id=randomUUID(),t=randomBytes(32).toString('hex'),storage=await mf.unsafeGetDurableObjectStorage('passkeys','SharedFolder',{name:id});
  await storage.exec('INSERT INTO folder_state(id,data) VALUES(1,?)',JSON.stringify({id,title:'Legacy',createdAt:new Date().toISOString(),closed:false,members:[{id:randomUUID(),displayName:'旧',role:'owner',hash:sha(t).toString('hex')}],clips:{},pending:{},garbage:[]}));
  await ok(await req(`/v1/folders/${id}`,undefined,undefined,'GET',{Authorization:`Bearer ${t}`}));
  const auth=await mf.unsafeGetDurableObjectStorage('passkeys','AuthAccounts',{name:'accounts'});const rows=await auth.exec('SELECT data FROM auth_records WHERE kind=?','session');assert.ok(!JSON.stringify(rows).includes(session));
  await auth.exec('UPDATE auth_records SET data=? WHERE kind=? AND id=?',JSON.stringify({accountId,expires:0}),'session',sha(session).toString('hex'));await ok(await req('/v1/account',undefined,session),401);
  const f=await flow();await auth.exec('UPDATE auth_records SET data=? WHERE kind=? AND id=?',JSON.stringify({state:f.state,challengeHash:sha(f.codeVerifier).toString('hex'),origin,expires:0}),'flow',sha(f.requestId).toString('hex'));await ok(await verify(f,registration(f)),401);
  const html=await (await req('/auth')).text();assert.ok(html.includes('/passkey-browser.js'));assert.ok(!html.includes('https://'));assert.ok(html.includes('/auth.css'));assert.match(await (await req('/auth.css')).text(),/#e98571/);assert.match(await (await req('/passkey-browser.js')).text(),/startAuthentication/);
});
