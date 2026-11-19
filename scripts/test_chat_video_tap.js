// Executes the production resolver against redacted real IM payloads.
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const source = fs.readFileSync('DouDuo/DouyinWebView.swift','utf8');
const hook = source.match(/private let ddVideoTapHookJS = #"""\n([\s\S]*?)\n"""#/)[1];
const resolver = hook.slice(hook.indexOf('  const findID ='),hook.indexOf('  document.addEventListener'));
const ctx = vm.createContext({}); vm.runInContext(resolver + '\nthis.resolve = findID;',ctx);
function element(props = {}, parent = null, attrs = []) {
  return Object.assign({parentElement:parent,attributes:attrs,querySelector(){return null;},querySelectorAll(){return [];}},props);
}
let failures = 0, passed = 0;
function test(name, fn){try{fn();passed++;console.log('PASS',name);}catch(e){failures++;console.error('FAIL',name,e.message);}}
const samples = JSON.parse(fs.readFileSync('scripts/fixtures/chat-shared-videos.json','utf8'));
for(const [i,s] of samples.entries()){
  test(`real IM sample ${i}: parsedContent on parent fiber`,()=>{
    const root=element({__reactFiber_test:{memoizedProps:{},return:{memoizedProps:{message:{parsedContent:s}}}}});
    assert.strictEqual(ctx.resolve(root),s.itemId);
  });
  test(`real IM sample ${i}: content JSON fallback`,()=>{
    const root=element({__reactProps_test:{message:{content:JSON.stringify(s)}}});
    assert.strictEqual(ctx.resolve(root),s.itemId);
  });
}
test('reject unrelated user ID attribute',()=>assert.strictEqual(ctx.resolve(element({},null,[{name:'data-user-id',value:'7559098237669180473'}])),null));
test('reject generic itemId outside shared-video payload',()=>assert.strictEqual(ctx.resolve(element({__reactProps_x:{itemId:'7704206030490512036'}})),null));
test('reject unsafe numeric ID',()=>assert.strictEqual(ctx.resolve(element({__reactProps_x:{message:{parsedContent:{aweType:800,itemId:Number(samples[0].itemId)}}}})),null));
test('malformed content fails closed',()=>assert.strictEqual(ctx.resolve(element({__reactProps_x:{message:{content:'{'}}})),null));
test('do not cross into another message row',()=>{
 const outer=element({__reactProps_x:{message:{parsedContent:samples[0]}}});
 const inner=element({__reactProps_x:{message:{parsedContent:{aweType:7,itemId:samples[1].itemId}}}},outer);
 assert.strictEqual(ctx.resolve(inner),null);
});
function clickThroughHook(payload, pathname='/chat', cardProps={}) {
  let listener; const sent=[]; const ev={prevented:false,stopped:false,
    preventDefault(){this.prevented=true;},stopPropagation(){this.stopped=true;}};
  const pane=element({className:'componentsRightPanelwrapper'});
  const card=element(Object.assign({className:'MessageItemShareAwemecontainer',__reactFiber_test:{memoizedProps:{},return:{memoizedProps:{message:{parsedContent:payload}}}}},cardProps),pane);
  const play=element({className:'MessageItemShareAwemeplayIcon'},card);
  play.closest=selector=>selector.includes('componentsRightPanel')?pane:play;
  ev.target=play;
  vm.runInNewContext(hook,{location:{pathname},document:{addEventListener(_,fn){listener=fn;}},console:{log(){}},window:{webkit:{messageHandlers:{ddMsg:{postMessage(v){sent.push(JSON.parse(v));}}}}}});
  listener(ev);return {ev,sent};
}
test('real play-icon click posts exact video ID and intercepts web playback',()=>{
 const r=clickThroughHook(samples[0]);assert.strictEqual(r.sent[0].id,samples[0].itemId);
 assert.strictEqual(r.sent[0].type,'video');assert(r.ev.prevented&&r.ev.stopped);
});
test('unknown message leaves official click alone',()=>{
 const r=clickThroughHook({aweType:7,itemId:samples[0].itemId});
 assert(!r.ev.prevented&&!r.ev.stopped);assert.strictEqual(r.sent[0].type,'video-miss');
});
test('gallery (note) share opens the post instead of leaving the web toast',()=>{
  // 图文分享：payload 的 aweType 不是 800，靠卡片里的 /note/<id> 链接认出来
  const noteId='7501234567890123456';
  const anchor={getAttribute(n){return n==='href'?'https://www.douyin.com/note/'+noteId:null;}};
  const r=clickThroughHook({aweType:68,itemId:noteId},'/chat',{querySelectorAll:sel=>sel.indexOf('[href]')>=0?[anchor]:[]});
  assert.strictEqual(r.sent[0].type,'video');
  assert.strictEqual(r.sent[0].id,noteId);
  assert(r.ev.prevented&&r.ev.stopped);
});
test('gallery share (aweType 0 + image_count) opens the post',()=>{
  // 真机抓到的图文分享 payload：aweType=0，带 image_count/is_slides，没有 /note/ 链接
  const noteId='7707415688281018091';
  const r=clickThroughHook({aweType:0,itemId:noteId,image_count:3,is_slides:true,awemeType:68},'/chat');
  assert.strictEqual(r.sent[0].type,'video');
  assert.strictEqual(r.sent[0].id,noteId);
  assert(r.ev.prevented&&r.ev.stopped);
});
test('group video card (aweType 11054, item_id) opens the post',()=>{
  const vid='7708057869924972646';
  const r=clickThroughHook({aweType:11054,item_id:vid,aweme_info:{aweme_id:vid}},'/chat');
  assert.strictEqual(r.sent[0].type,'video');assert.strictEqual(r.sent[0].id,vid);
});
test('private-chat video card (aweType 11055, real 11-18 keys) opens the post natively',()=>{
  const vid='7708057869924972646';
  const r=clickThroughHook({aweType:11055,item_id:vid,aweme_info:{aweme_id:vid},cover_url:{},description:'',schema:''},'/chat');
  assert.strictEqual(r.sent[0].type,'video');assert.strictEqual(r.sent[0].id,vid);
  assert(r.ev.prevented&&r.ev.stopped);
});
test('group video card with only aweme_info.aweme_id opens the post',()=>{
  const vid='7708057869924972646';
  const r=clickThroughHook({aweType:11054,aweme_info:{aweme_id:vid}},'/chat');
  assert.strictEqual(r.sent[0].type,'video');assert.strictEqual(r.sent[0].id,vid);
});
test('gallery share without any post link still leaves the web alone',()=>{
  const noteId='7501234567890123456';
  const r=clickThroughHook({aweType:68,itemId:noteId},'/chat',{querySelectorAll:()=>[]});
  assert(!r.ev.prevented);assert.strictEqual(r.sent[0].type,'video-miss');
});
test('non-chat routes are never intercepted',()=>{
 const r=clickThroughHook(samples[0],'/video/123');assert.strictEqual(r.sent.length,0);assert(!r.ev.prevented);
});
console.log({passed,failures});process.exitCode=failures?1:0;
