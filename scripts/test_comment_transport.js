// Executes production embedded JS with local XHR seams; no real network.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const read=f=>fs.readFileSync(path.join(__dirname,'../DouDuo',f),'utf8');
const extras=read('DouyinExtras.swift'), feed=read('DouyinFeedView.swift');
const block=(s,n)=>s.match(new RegExp('(?:private )?static let '+n+' = (?:cmap \\+ )?#"""\\n([\\s\\S]*?)\\n\\s*"""#'))[1];
const cmap=block(extras,'cmap'),publish=block(extras,'publishJS'),request=block(feed,'requestJS');
let failures=0;
async function test(n,f){try{await f();console.log('PASS',n);}catch(e){failures++;console.error('FAIL',n,e.message);}}
async function run(ready){let writes=0;const result=JSON.parse(await vm.runInNewContext('(async()=>{'+cmap+publish+'})()',{
 URLSearchParams,id:'synthetic-video',text:'PRIVATE_BODY',reply:'0',replyTo:'0',q:()=>'',sdkReady:async()=>ready,
 req:async()=>{writes++;return{s:200,t:JSON.stringify({status_code:0,comment:{cid:'123',text:'PRIVATE_BODY'}})};},
 parse:t=>{try{return JSON.parse(t);}catch{return null;}},first:()=>null
}));return{result,writes};}
(async()=>{
 await test('SDK false prevents POST with no automatic retry',async()=>{const r=await run(false);assert.equal(r.writes,0);assert.equal(r.result.comment,null);assert.match(r.result.diagnostic,/sdk=false/);});
 await test('SDK true sends once and diagnostic is redacted',async()=>{const r=await run(true);assert.equal(r.writes,1);assert(!r.result.diagnostic.includes('PRIVATE_BODY'));});
 await test('actual shared req sets supplied fourth headers, keeps defaults and GET behavior',async()=>{
  const calls=[];
  class XHR{constructor(){this.headers={};calls.push(this);}open(m,u){this.method=m;this.url=u;}setRequestHeader(k,v){this.headers[k]=v;}send(b){this.body=b;this.status=200;this.responseText='{}';this.onload();}abort(){}}
  await vm.runInNewContext('(async()=>{'+request+"await req('POST','/local','body',{'x-secsdk-csrf-token':'DOWNGRADE','X-Extra':'ok'});await req('GET','/read');})()",{XMLHttpRequest:XHR,URLSearchParams,setTimeout:()=>0});
  assert.equal(calls.length,2);assert.equal(calls[0].headers['x-secsdk-csrf-token'],'DOWNGRADE');assert.equal(calls[0].headers['X-Extra'],'ok');assert.match(calls[0].headers['Content-Type'],/urlencoded/);assert.match(calls[0].headers.Accept,/json/);assert.equal(calls[0].body,'body');assert.equal(calls[1].headers['Content-Type'],undefined);assert.equal(calls[1].body,null);
 });
 await test('missing cid stays empty, not fabricated undefined',async()=>{
  const raw=await vm.runInNewContext('(async()=>{'+cmap+'return JSON.stringify(cmap({text:"x"}));})()',{first:()=>null});assert.equal(JSON.parse(raw).id,'');
 });
 await test('explicit headers override defaults case-insensitively without XHR appending',async()=>{
  const headers={};class XHR{open(){}setRequestHeader(k,v){k=k.toLowerCase();headers[k]=headers[k]?headers[k]+', '+v:v;}send(){this.status=200;this.responseText='{}';this.onload();}abort(){}}
  await vm.runInNewContext('(async()=>{'+request+"await req('POST','/local','{}',{'content-type':'application/json','accept':'text/plain'});})()",{XMLHttpRequest:XHR,URLSearchParams,setTimeout:()=>0});
  assert.equal(headers['content-type'],'application/json');assert.equal(headers.accept,'text/plain');
 });
 await test('list and reply mappings preserve stable IDs and exact floor metadata',async()=>{
  for(const [s,n] of [[feed,'commentJS'],[extras,'replyJS']]){
   const script=block(s,n);
   const comment={cid:'123',text:'x',user:{uid:'100',sec_uid:'self'},reply_id:'111',reply_to_reply_id:'222',create_time:100};
   const out=JSON.parse(await vm.runInNewContext('(async()=>{'+script+'})()',{URLSearchParams,base:{},id:'v',cid:'111',cursor:'0',ins:'',q:()=>'',req:async()=>({s:200,t:JSON.stringify({comments:[comment]})}),parse:JSON.parse,first:()=>null}));
   assert.equal(out.items[0].uid,'100');assert.equal(out.items[0].parent,'111');assert.equal(out.items[0].replyTo,'222');
   const unsafe={cid:9007199254740992,text:'x',user:{uid:9007199254740992},reply_id:9007199254740992,reply_to_reply_id:9007199254740992};
   const bad=JSON.parse(await vm.runInNewContext('(async()=>{'+script+'})()',{URLSearchParams,base:{},id:'v',cid:'111',cursor:'0',ins:'',q:()=>'',req:async()=>({s:200,t:JSON.stringify({comments:[unsafe]})}),parse:JSON.parse,first:()=>null}));
   assert.equal(bad.items[0].id,'');assert.equal(bad.items[0].uid,null);assert.equal(bad.items[0].parent,null);assert.equal(bad.items[0].replyTo,null);
  }
 });
 process.exitCode=failures?1:0;
})();
