// Executes the actual embedded Swift JS. All network/DOM seams below are local mocks.
// Live E2E evidence is recorded separately from simulator /webcast/room/chat/ responses.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(path.join(__dirname,'../DouDuo/DouyinLiveChat.swift'),'utf8');
const send=source.match(/static let sendJS = #"""\n([\s\S]*?)\n\s*"""#/)[1];
let failed=0;
async function test(name,fn){try{await fn();console.log('PASS',name);}catch(e){failed++;console.error('FAIL',name,e.message);}}
async function run({input=true,disabled=false,button=false,slate=true,reply={status_code:0,data:{msg_id_str:'SYNTHETIC_ACK_ID'}},respond=true,text='[微笑] TEXT "\\\n',failInsert=false}={}){
 let value='',exec=0,requests=0;
 class FakeEvent{constructor(type,props){this.type=type;Object.assign(this,props);}}
 class XHR{constructor(){this.listeners=[];}addEventListener(t,fn){if(t==='load')this.listeners.push(fn);}send(){requests++;this.status=200;this.responseURL='https://live.douyin.com/webcast/room/chat/';this.responseText=JSON.stringify(reply);if(respond)queueMicrotask(()=>this.listeners.forEach(fn=>fn()));}}
 class Textarea{set value(v){value=v;}get value(){return value;}}
 const box=input?new Textarea():null;
 const submit=()=>new XHR().send();
 if(box)Object.assign(box,{tagName:slate?'DIV':'TEXTAREA',isContentEditable:slate,innerText:'',disabled,readOnly:false,getAttribute(n){return n==='data-slate-editor'&&slate?'true':null;},focus(){},dispatchEvent(e){if(e.type==='keydown'&&e.key==='Enter')submit();}});
 const btn={innerText:'发送',className:'send-btn',disabled,getAttribute(){return null;},click(){if(!disabled)submit();}};
 const context={text,URL,URLSearchParams,location:{href:'https://live.douyin.com/local-test'},XMLHttpRequest:XHR,HTMLTextAreaElement:Textarea,Event:FakeEvent,InputEvent:FakeEvent,KeyboardEvent:FakeEvent,
  setTimeout:(f,ms)=>setTimeout(f,ms>1000?30:1),clearTimeout,queueMicrotask,
  fetch:async()=>({url:'',status:200,clone(){return this;},text:async()=>''}),
  getSelection:()=>({removeAllRanges(){},addRange(){}}),
  document:{querySelector(){return box;},querySelectorAll(){return button?[btn]:[];},createRange(){return{selectNodeContents(){}};},execCommand(cmd,ui,t){exec++;if(!failInsert&&box)box.innerText=t;return !failInsert;}},
 };
 context.window=context;
 const code=send.split('__DD_TEXT_JSON__').join(JSON.stringify(text));
 const raw=await vm.runInNewContext('(async()=>{'+(send.trim().startsWith('return')?code:'return '+code)+'})()',context);
 return{result:typeof raw==='string'&&raw.startsWith('{')?JSON.parse(raw):{state:raw},value,exec,requests,text};
}
(async()=>{
 await test('actual Slate editor uses native editing and Enter without a send button',async()=>{const r=await run();assert.equal(r.result.state,'sent');assert.equal(r.exec,1);assert.equal(r.requests,1);});
 await test('server-disabled comments are preserved as an explicit rejection',async()=>{const r=await run({reply:{status_code:50015,data:{message:'本场直播不支持评论',prompts:'作者已关闭直播间评论功能'}}});assert.equal(r.result.state,'rejected');assert.match(r.result.message,/作者已关闭/);});
 await test('click or Enter without response never counts as sent',async()=>{const r=await run({respond:false});assert.equal(r.result.state,'unconfirmed');assert.equal(r.requests,1);});
 await test('empty HTTP 200 response does not count as success',async()=>{const r=await run({reply:{}});assert.notEqual(r.result.state,'sent');});
 await test('loading DOM cannot send',async()=>{const r=await run({input:false});assert.equal(r.result.state,'loading');assert.equal(r.requests,0);});
 await test('disabled editor cannot send',async()=>{const r=await run({disabled:true});assert.equal(r.result.state,'disabled');assert.equal(r.requests,0);});
 await test('failed native editing never sends',async()=>{const r=await run({failInsert:true});assert.equal(r.result.state,'compose-error');assert.equal(r.requests,0);});
 await test('textarea preserves special characters through native setter',async()=>{const r=await run({slate:false,button:true});assert.equal(r.value,r.text);assert.equal(r.result.state,'sent');assert.equal(r.requests,1);});
 const readiness=source.match(/static let composerReadyJS = #"""\n([\s\S]*?)\n\s*"""#/);
 for(const [name,box,want] of [['loading',null,false],['mounted editor',{disabled:false,readOnly:false,getAttribute:()=>null},true],['disabled editor',{disabled:true,readOnly:false,getAttribute:()=>null},false]]){
  await test('composer readiness: '+name,async()=>{assert(readiness,'missing composer readiness check');const got=vm.runInNewContext(readiness[1],{document:{querySelector:()=>box}});assert.equal(got,want);});
 }
 const extras=fs.readFileSync(path.join(__dirname,'../DouDuo/DouyinExtras.swift'),'utf8');
 const cmap=extras.match(/private static let cmap = #"""\n([\s\S]*?)\n\s*"""#/)[1];
 const publish=extras.match(/static let publishJS = cmap \+ #"""\n([\s\S]*?)\n\s*"""#/)[1];
 for(const [name,payload,kind] of [['empty HTTP200','', 'empty'],['HTML HTTP200','<html>验证</html>','html'],['unrecognized JSON','{"unexpected":true}','json'],['real anonymous GET null-comment shape','{"comment":null,"status_code":0}','json']]){
  await test('video diagnostic: '+name,async()=>{const raw=await vm.runInNewContext('(async()=>{'+cmap+publish+'})()',{sdkReady:async()=>true,URLSearchParams,id:'LOCAL',text:'LOCAL',reply:'0',q:()=>'',req:async()=>({s:200,t:payload}),first:()=>null,parse:t=>{try{return JSON.parse(t);}catch{return null;}}});const d=JSON.parse(raw);assert(d.msg);assert(d.diagnostic.includes('kind='+kind));assert.equal(d.comment,null);});
 }
 // 带图评论：body 多出网页评论框那几个字段；不带图时请求形状不变；回执里的图片要映射出来
 const runPublish=async(extra,payload)=>{let sent=null;const raw=await vm.runInNewContext('(async()=>{'+cmap+publish+'})()',Object.assign({sdkReady:async()=>true,URLSearchParams,id:'LOCAL',text:'',reply:'0',q:()=>'',req:async(m,u,b)=>{sent=new URLSearchParams(b);return {s:200,t:payload};},first:()=>null,parse:t=>{try{return JSON.parse(t);}catch{return null;}}},extra));return {sent,d:JSON.parse(raw)};};
 await test('image comment: body carries web fields',async()=>{const {sent,d}=await runPublish({imgUri:'tos-x/abc',imgW:'640',imgH:'480',imgFmt:'jpeg'},JSON.stringify({status_code:0,comment:{cid:'1',text:'',image_list:[{origin_url:{url_list:['https://e/o'],width:640,height:480},medium_url:{url_list:['https://e/m'],width:320,height:240}}]}}));assert.equal(sent.get('image_uri_list'),'tos-x/abc');assert.equal(sent.get('image_widths'),'640');assert.equal(sent.get('image_heights'),'480');assert.equal(sent.get('image_formats'),'jpeg');assert.equal(sent.get('paste_edit_method'),'non_paste');assert.equal(sent.get('one_level_comment_rank'),'-1');assert.deepEqual(d.comment.images,[{thumb:'https://e/m',full:'https://e/o',w:640,h:480}]);assert(d.diagnostic.includes('img=true'));assert(!d.diagnostic.includes('tos-x'));});
 await test('text comment: no image fields in body',async()=>{const {sent,d}=await runPublish({imgUri:'',imgW:'0',imgH:'0',imgFmt:''},JSON.stringify({status_code:0,comment:{cid:'2',text:'LOCAL'}}));for(const k of ['image_uri_list','image_widths','image_heights','image_formats','paste_edit_method','one_level_comment_rank'])assert.equal(sent.has(k),false,k);assert.deepEqual(d.comment.images,[]);});
 await test('API path: verify headers logged as flags only, never values',async()=>{const raw=await vm.runInNewContext('(async()=>{'+cmap+publish+'})()',{sdkReady:async()=>true,URLSearchParams,id:'LOCAL',text:'LOCAL',reply:'0',q:()=>'',req:async()=>({s:200,t:'',h:'\nx-tt-verify-passport-decision: {"k":"LEAK_ME"}\r\nx-tt-logid: L\r\nbd-ticket-guard-result: 1003'}),first:()=>null,parse:t=>{try{return JSON.parse(t);}catch{return null;}}});const d=JSON.parse(raw);assert.match(d.diagnostic,/ vp=1 bt=0 vc=0 tg=1 shark=0 tgr=1003/);assert(!/LEAK_ME/.test(d.diagnostic));assert.equal(d.comment,null);});
 await test('API path: verify decision handed to app only on empty ack, never in diagnostic',async()=>{const raw=await vm.runInNewContext('(async()=>{'+cmap+publish+'})()',{sdkReady:async()=>true,URLSearchParams,id:'LOCAL',text:'LOCAL',reply:'0',q:()=>'',req:async()=>({s:200,t:'',h:'\nx-tt-logid: L\r\nx-tt-verify-passport-decision: {"verify_from":"verify_center","DEC":"SECRET_DEC"}'}),first:()=>null,parse:t=>{try{return JSON.parse(t);}catch{return null;}}});const d=JSON.parse(raw);assert.equal(d.verify,'{"verify_from":"verify_center","DEC":"SECRET_DEC"}');assert(!/SECRET_DEC/.test(d.diagnostic));assert.equal(d.comment,null);});
 await test('API path: success with comment never asks to verify',async()=>{const raw=await vm.runInNewContext('(async()=>{'+cmap+publish+'})()',{sdkReady:async()=>true,URLSearchParams,id:'LOCAL',text:'LOCAL',reply:'0',q:()=>'',req:async()=>({s:200,t:JSON.stringify({status_code:0,comment:{cid:'9',text:'LOCAL'}}),h:'\nx-tt-verify-passport-decision: {"a":1}'}),first:()=>null,parse:t=>{try{return JSON.parse(t);}catch{return null;}}});const d=JSON.parse(raw);assert.equal(d.verify,null);assert.equal(d.comment.id,'9');});
 await test('API path: no headers → all flags 0',async()=>{const {d}=await runPublish({},JSON.stringify({status_code:0,comment:{cid:'4',text:'LOCAL',status:7}}));assert.match(d.diagnostic,/ vp=0 bt=0 vc=0 tg=0 shark=0 tgr=-/);assert.match(d.diagnostic,/st=7/);});
 await test('text comment: old callers without image args still work',async()=>{const {sent}=await runPublish({},JSON.stringify({status_code:0,comment:{cid:'3',text:'LOCAL'}}));assert.equal(sent.has('image_uri_list'),false);});
 process.exitCode=failed?1:0;
})();
