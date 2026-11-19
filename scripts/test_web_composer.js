#!/usr/bin/env node
// 「网页评论框发送」回归：从生产 Swift 抽 DYWebComposer.sendJS，在仿抖音 Draft 评论框的假页面里跑。
// 不连网、不碰真抖音：发送按钮点下去走的是本地假 fetch。
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
const { JSDOM } = (() => {
  const tries = [process.env.DOUDUO_JSDOM, 'jsdom', '/Users/zhanghongsheng/.hermes/hermes-agent/node_modules/jsdom',
                 '/Users/zhanghongsheng/.hermes/hermes-workspace/node_modules/.pnpm/jsdom@27.4.0/node_modules/jsdom'].filter(Boolean);
  for (const t of tries) { try { return require(t); } catch (e) {} }
  throw new Error('jsdom not found; set DOUDUO_JSDOM');
})();
const src = fs.readFileSync(path.join(__dirname, '../DouDuo/DYWebComposer.swift'), 'utf8');
const m = src.match(/static let sendJS = #"""\n([\s\S]*?)\n\s*"""#/);
assert.ok(m, 'production sendJS required');

function page({ loggedOut = false, respond = (u) => ({ status: 200, body: { status_code: 0, comment: { cid: 'c-new', text: 'x', reply_id: '0', reply_to_reply_id: '0' } } }), sendDoesNothing = false, viaXHR = false, captchaOnSend = false, hdrsOnSend = null, signedUrl = false } = {}) {
  const dom = new JSDOM('<!doctype html><body></body>', { runScripts: 'outside-only', url: 'https://www.douyin.com/video/a-1' });
  const w = dom.window, d = w.document;
  Object.defineProperty(w.HTMLElement.prototype, 'innerText', { get() { return this.textContent; }, configurable: true });
  w.HTMLElement.prototype.getBoundingClientRect = function () { return this.hidden ? { width: 0, height: 0 } : { width: 100, height: 20 }; };
  w.HTMLElement.prototype.scrollIntoView = function () {};
  const calls = [];
  const hdrs = r => Object.entries(r.headers || {});
  w.fetch = async (u, init) => { const r = respond(u); calls.push({ u, typed: lastTyped }); return { status: r.status, url: u, headers: { forEach: f => hdrs(r).forEach(([k, v]) => f(v, k)) }, clone: () => ({ text: async () => (r.body == null ? '' : JSON.stringify(r.body)) }) }; };
  // 官方网页版有的接口走 XHR：同样能拿到响应头
  class FakeXHR { constructor() { this.l = []; this.responseType = ''; } open(m, u) { this.u = u; } setRequestHeader() {} addEventListener(t, f) { if (t === 'loadend') this.l.push(f); }
    send() { const r = respond(this.u); calls.push({ u: this.u, typed: lastTyped }); this.status = r.status; this.responseURL = 'https://www.douyin.com' + this.u; this.responseText = r.body == null ? '' : JSON.stringify(r.body);
      this.h = hdrs(r).map(([k, v]) => k + ': ' + v).join('\r\n'); setTimeout(() => this.l.forEach(f => f()), 1); }
    getAllResponseHeaders() { return this.h || ''; } }
  w.XMLHttpRequest = FakeXHR;
  let lastTyped = null;
  const el = (tag, cls, text) => { const e = d.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const composer = () => {
    const bar = el('div', 'comment-input-inner-container');
    const root = el('div', 'DraftEditor-root'), ed = el('div', 'public-DraftEditor-content'); ed.setAttribute('contenteditable', 'true');
    root.appendChild(ed); bar.appendChild(root);
    class CS { constructor(t) { this.t = t; } getPlainText() { return this.t; } static createFromText(t) { return new CS(t); } }
    class ES { constructor(c) { this.c = c; } getCurrentContent() { return this.c; } static push(es, c) { return new ES(c); } static moveFocusToEnd(es) { return es; } }
    const props = { editorState: new ES(new CS('')), onChange(n) { props.editorState = n; ed.textContent = n.getCurrentContent().getPlainText(); } };
    root.__reactFiberT = { memoizedProps: props, return: null };
    const right = el('div', 'commentInput-right-ct');
    for (const name of ['at', 'emoji', 'send']) {
      const s = el('span', name); s.__reactPropsT = { onClick() {} };
      s.addEventListener('click', () => {
        if (name !== 'send' || sendDoesNothing) return;
        lastTyped = ed.textContent;
        const reply = bar.dataset.reply || '0', to = bar.dataset.to || '0';
        const u = '/aweme/v1/web/comment/publish?reply_id=' + reply + '&reply_to_reply_id=' + to + (signedUrl ? '&a_bogus=SIG' : '');
        if (viaXHR) { const x = new w.XMLHttpRequest(); x.open('POST', u); x.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
          for (const [k, v] of Object.entries(hdrsOnSend || {})) x.setRequestHeader(k, v); x.send('a=1'); } else w.fetch(u, { headers: hdrsOnSend || {} });
        if (captchaOnSend) setTimeout(() => { const c = el('div', 'captcha_verify_container'); d.body.appendChild(c); }, 200);
      });
      right.appendChild(s);
    }
    bar.appendChild(right);
    return bar;
  };
  const list = el('div'); list.setAttribute('data-e2e', 'comment-list'); d.body.appendChild(list);
  const item = (cid, parentTop) => {
    const it = el('div'); it.setAttribute('data-e2e', 'comment-item');
    it.__reactFiberT = { memoizedProps: {}, return: { memoizedProps: { commentInfo: { cid } }, return: null } };
    it.appendChild(el('span', '', '内容'));
    // 11-19 真机：「回复」格里带图标、悬停才显示（尺寸为 0）
    const rb = el('div', 'reply-cell'); rb.appendChild(d.createElementNS('http://www.w3.org/2000/svg', 'svg')); const rt = el('span', '', '回复'); rt.hidden = true; rb.appendChild(rt);
    rt.addEventListener('click', () => { const c = composer(); c.dataset.reply = parentTop || cid; c.dataset.to = parentTop ? cid : '0'; it.appendChild(c); });
    it.appendChild(rb);
    return it;
  };
  const top = item('c-top'); list.appendChild(top);
  const more = el('span', '', '展开1条回复'); more.addEventListener('click', () => { top.appendChild(item('c-sub', 'c-top')); more.remove(); }); top.appendChild(more);
  list.appendChild(item('c-other'));
  d.body.appendChild(composer());
  if (loggedOut) d.body.appendChild(el('div', '', '登录后即可参与互动讨论'));
  const fn = w.eval('(async function(text, top, target){\n' + m[1] + '\n})');
  return { run: async (...a) => JSON.parse(await fn(...a)), calls, w };
}

const tests = [];
const test = (name, f) => tests.push([name, f]);

test('一级评论：填进底部评论框、点它的发送、拿到回执', async () => {
  const p = page();
  const r = await p.run('你好 DouDuo', '', '');
  assert.equal(r.state, 'sent'); assert.equal(r.comment.id, 'c-new'); assert.equal(r.comment.parent, null);
  assert.equal(p.calls.length, 1); assert.equal(p.calls[0].typed, '你好 DouDuo');
  assert.match(p.calls[0].u, /reply_id=0&reply_to_reply_id=0/);
  assert.match(r.diagnostic, /via=web-ui/);
});
test('楼中楼：先展开、点那条的「回复」，用它自己的回复框发', async () => {
  const p = page({ respond: () => ({ status: 200, body: { status_code: 0, comment: { cid: 'c-r2', reply_id: 'c-top', reply_to_reply_id: 'c-sub' } } }) });
  const r = await p.run('回复楼中楼', 'c-top', 'c-sub');
  assert.equal(r.state, 'sent'); assert.equal(r.comment.parent, 'c-top'); assert.equal(r.comment.replyTo, 'c-sub');
  assert.equal(p.calls.length, 1); assert.match(p.calls[0].u, /reply_id=c-top&reply_to_reply_id=c-sub/);
});
test('回复一级评论', async () => {
  const p = page();
  const r = await p.run('回复一级', 'c-other', 'c-other');
  assert.equal(r.state, 'sent'); assert.match(p.calls[0].u, /reply_id=c-other&reply_to_reply_id=0/);
});
test('403：报 blocked，交给恢复页', async () => {
  const p = page({ respond: () => ({ status: 403, body: null }) });
  const r = await p.run('x', '', ''); assert.equal(r.state, 'blocked'); assert.equal(r.status, 403);
});
test('业务拒绝：带回抖音的 code', async () => {
  const p = page({ respond: () => ({ status: 200, body: { status_code: 2150, status_msg: '太快了' } }) });
  const r = await p.run('x', '', ''); assert.equal(r.state, 'rejected'); assert.equal(r.code, 2150);
});
test('网页未登录：不点发送', async () => {
  const p = page({ loggedOut: true });
  const r = await p.run('x', '', ''); assert.equal(r.state, 'logged-out'); assert.equal(p.calls.length, 0);
});
test('找不到要回复的那条：不发，App 可以退回接口方式', async () => {
  const p = page();
  const r = await p.run('x', 'c-nope', 'c-nope'); assert.equal(r.state, 'not-found'); assert.equal(p.calls.length, 0);
});
test('点了发送但网页没发请求：报 not-sent，并清空网页框', async () => {
  const p = page({ sendDoesNothing: true });
  const r = await p.run('x', '', ''); assert.equal(r.state, 'not-sent'); assert.equal(p.calls.length, 0);
  assert.equal(p.w.document.querySelector('body > .comment-input-inner-container .public-DraftEditor-content').textContent, '');
});
test('验证诊断：空回执带验证头 → 记 vp=1，不当成功、不泄露头的值', async () => {
  const p = page({ respond: () => ({ status: 200, body: null, headers: { 'x-tt-verify-passport-decision': '{"secret":"SHOULD_NOT_LEAK"}', 'x-tt-logid': 'L' } }) });
  const r = await p.run('x', '', ''); assert.notEqual(r.state, 'sent');
  assert.match(r.diagnostic, /vp=1 bt=0 vc=0/); assert.match(r.diagnostic, /chars=0/); assert.doesNotMatch(r.diagnostic, /SHOULD_NOT_LEAK|secret/);
});
test('验证诊断：XHR 路径同样读到验证头（bdturing-verify）', async () => {
  const p = page({ viaXHR: true, respond: () => ({ status: 200, body: null, headers: { 'bdturing-verify': 'VAL_SHOULD_NOT_LEAK' } }) });
  const r = await p.run('x', '', ''); assert.notEqual(r.state, 'sent');
  assert.match(r.diagnostic, /vp=0 bt=1/); assert.doesNotMatch(r.diagnostic, /VAL_SHOULD_NOT_LEAK/);
});
test('验证诊断：body 里 shark_decision_conf → shark=1', async () => {
  const p = page({ respond: () => ({ status: 200, body: { status_code: 0, data: { shark_decision_conf: 'S_SHOULD_NOT_LEAK' } } }) });
  const r = await p.run('x', '', ''); assert.notEqual(r.state, 'sent');
  assert.match(r.diagnostic, /shark=1/); assert.doesNotMatch(r.diagnostic, /S_SHOULD_NOT_LEAK/);
});
test('验证诊断：发送后页面弹出验证框 → cap=1', async () => {
  const p = page({ captchaOnSend: true, respond: () => ({ status: 200, body: null }) });
  const r = await p.run('x', '', ''); assert.notEqual(r.state, 'sent'); assert.match(r.diagnostic, /cap=1/);
});
test('验证诊断：正常成功 → 全 0，并带评论状态', async () => {
  const p = page({ respond: () => ({ status: 200, body: { status_code: 0, comment: { cid: 'c9', status: 7, reply_id: '0', reply_to_reply_id: '0' } } }) });
  const r = await p.run('x', '', ''); assert.equal(r.state, 'sent');
  assert.match(r.diagnostic, /vp=0 bt=0 vc=0 tg=0 tgs=0 tgr=- tgsr=- shark=0 cap=0 signed=0 reqHdrs=none keys=000 kh=- ch=- wd=0 code=0 got=0\/0 st=7/);
});
test('凭证诊断：403 带校验结论码 → 记 tgr/tgsr 数字，非数字记 x，不泄露', async () => {
  const p = page({ respond: () => ({ status: 403, body: null, headers: { 'bd-ticket-guard-result': '1003', 'bd-ticket-guard-sec-result': 'LEAK_TOKEN_abc' } }) });
  const r = await p.run('x', '', ''); assert.equal(r.state, 'blocked');
  assert.match(r.diagnostic, /tg=1 tgs=0 tgr=1003 tgsr=x/); assert.doesNotMatch(r.diagnostic, /LEAK_TOKEN/);
});
test('凭证诊断：记录发出的签名头名字与 a_bogus 有无，不记值', async () => {
  const p = page({ viaXHR: true, hdrsOnSend: { 'bd-ticket-guard-client-data': 'CD_LEAK', 'bd-ticket-guard-version': '2', 'x-secsdk-csrf-token': 'CSRF_LEAK', 'Cookie-ish': 'nope' }, signedUrl: true });
  const r = await p.run('x', '', ''); assert.equal(r.state, 'sent');
  assert.match(r.diagnostic, /signed=1 reqHdrs=content-type,tg:client-data,tg:version,x-secsdk-csrf-token /);
  assert.doesNotMatch(r.diagnostic, /CD_LEAK|CSRF_LEAK|cookie-ish/i);
});
test('凭证诊断：本页密钥状态只记有无与哈希', async () => {
  const p = page();
  p.w.localStorage.setItem('security-sdk/s_sdk_crypt_sdk', 'PRIVATE_KEY_MATERIAL');
  p.w.localStorage.setItem('security-sdk/s_sdk_sign_data_key/web_protect', 'TICKET_MATERIAL');
  p.w.document.cookie = 'bd_ticket_guard_client_data=CLIENTDATA_MATERIAL; path=/';
  const r = await p.run('x', '', ''); assert.equal(r.state, 'sent');
  assert.match(r.diagnostic, /keys=101 kh=[0-9a-f]{8} ch=[0-9a-f]{8} wd=0/);
  assert.doesNotMatch(r.diagnostic, /MATERIAL/);
});
test('XHR 路径：发送后 XMLHttpRequest 原型恢复原样', async () => {
  const p = page({ viaXHR: true }); const P = p.w.XMLHttpRequest.prototype, o = P.open, s0 = P.send;
  const r = await p.run('x', '', ''); assert.equal(r.state, 'sent'); assert.equal(P.open, o); assert.equal(P.send, s0);
});
test('发送后 fetch 恢复原样', async () => {
  const p = page(); const orig = p.w.fetch;
  await p.run('x', '', ''); assert.equal(p.w.fetch, orig); assert.equal(p.w.__ddComposing, false);
});

(async () => {
  let fail = 0;
  for (const [n, f] of tests) { try { await f(); console.log('PASS', n); } catch (e) { fail++; console.log('FAIL', n, '\n ', e.message); } }
  console.log(fail ? `${fail} failed` : `all ${tests.length} passed`);
  process.exit(fail ? 1 : 0);
})();
