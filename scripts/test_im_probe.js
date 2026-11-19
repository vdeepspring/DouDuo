#!/usr/bin/env node
// 只读私信探针回归：执行实际嵌入的 JS，验证只观察不改行为、不泄露正文/ID/URL 查询串。
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const src = fs.readFileSync('DouDuo/DYIMProbe.swift', 'utf8');
const js = src.match(/static let script = #"""\n([\s\S]*?)\n"""#/)[1];

let failures = 0;
const test = (name, fn) => { try { fn(); console.log('PASS', name); } catch (e) { failures++; console.error('FAIL', name, e.stack); } };

function makeEnv(opts = {}) {
  const posts = [], timers = [], listeners = {}, docListeners = {};
  let perfCb = null;
  class FakeWS {
    constructor(url, protocols) { this.url = url; this.protocols = protocols; this.sent = []; this.l = {}; this.readyState = 1; this.protocol = ''; this.binaryType = 'blob'; FakeWS.made.push(this); }
    addEventListener(t, f) { (this.l[t] = this.l[t] || []).push(f); }
    send(d) { this.sent.push(d); return 'native-result'; }
    fire(t, ev) { (this.l[t] || []).forEach(f => f(ev)); }
  }
  FakeWS.made = []; FakeWS.OPEN = 1; FakeWS.CONNECTING = 0; FakeWS.CLOSING = 2; FakeWS.CLOSED = 3;
  const bubbles = opts.bubbles || [];
  const window = {
    WebSocket: FakeWS,
    webkit: { messageHandlers: { ddIMDiag: { postMessage: s => posts.push(JSON.parse(s)) } } },
    addEventListener: (t, f) => { listeners[t] = f; }
  };
  const ctx = {
    window, location: { pathname: opts.path || '/chat', href: 'https://www.douyin.com/chat' },
    navigator: { userAgent: 'Mozilla/5.0 (Macintosh)' },
    document: { visibilityState: 'visible', querySelectorAll: () => bubbles, addEventListener: (t, f) => { docListeners[t] = f; } },
    setInterval: (f, ms) => timers.push({ f, ms }),
    PerformanceObserver: class { constructor(cb) { perfCb = cb; } observe() {} },
    URL, JSON, Object, Math, Date, Map, Set, String, Number, Array, Reflect
  };
  vm.createContext(ctx);
  vm.runInContext(js, ctx);
  return { ctx, posts, timers, FakeWS, perf: entries => perfCb({ getEntries: () => entries }), tick: ms => timers.filter(t => t.ms === ms).forEach(t => t.f()) };
}

const bubble = message => ({ parentElement: null, __reactProps$x: { message } });

test('WebSocket send passes through unchanged and only counts', () => {
  const env = makeEnv();
  const ws = new env.ctx.window.WebSocket('wss://frontier.example.com/ws/v2?token=SECRET&uid=123', ['p']);
  assert.ok(ws instanceof env.FakeWS);
  assert.strictEqual(ws.send('hello-body'), 'native-result');
  assert.deepStrictEqual(ws.sent, ['hello-body']);
  ws.fire('message', { data: '{"cmd":1,"payload":"x"}' });
  env.tick(30000);
  const text = JSON.stringify(env.posts);
  assert(!text.includes('SECRET') && !text.includes('hello-body') && !text.includes('token='));
  const sum = env.posts.find(p => p.k === 'sum-ws');
  assert.strictEqual(sum.outN, 1); assert.strictEqual(sum.inN, 1); assert.strictEqual(sum.keys, 'cmd,payload');
  assert.strictEqual(sum.path, 'frontier.example.com/ws/v2');
});

test('subclassing WebSocket keeps subclass prototype', () => {
  const env = makeEnv();
  const Sub = vm.runInContext('(class Sub extends window.WebSocket { hi() { return 1; } })', env.ctx);
  const s = new Sub('wss://a.example.com/x');
  assert.strictEqual(s.hi(), 1);
  assert.strictEqual(env.posts.filter(p => p.k === 'ws-new').length, 1);
});

test('WebSocket static constants preserved', () => {
  const env = makeEnv();
  assert.strictEqual(env.ctx.window.WebSocket.OPEN, 1);
  assert.strictEqual(env.ctx.window.WebSocket.CLOSED, 3);
});

test('HTTP path drops query and masks long numbers', () => {
  const env = makeEnv();
  env.perf([{ name: 'https://imapi.douyin.com/v1/message/get_by_conversation?cursor=1&sec=TOKEN', initiatorType: 'fetch', duration: 120, transferSize: 300, responseStatus: 200 },
            { name: 'https://www.douyin.com/aweme/v1/web/user/1234567890123/x', initiatorType: 'xmlhttprequest', duration: 5, responseStatus: 403 },
            { name: 'https://x.com/a.js?v=1', initiatorType: 'other', duration: 1 }]);
  const http = env.posts.filter(p => p.k === 'http');
  assert.strictEqual(http.length, 2);
  assert.strictEqual(http[0].path, 'imapi.douyin.com/v1/message/get_by_conversation');
  assert.strictEqual(http[1].path, 'www.douyin.com/aweme/v1/web/user/#/x');
  assert(!JSON.stringify(env.posts).includes('TOKEN'));
});

test('message shape logs field names/types but never content or raw IDs', () => {
  const m = { serverId: '7712345678901234567', clientId: 'abc-uuid-123', content: '{"text":"私密正文"}', conversationId: '0:1:999:888', status: 2, isFromMe: true, createdAt: 1700000000, nickname: '张三' };
  const env = makeEnv({ bubbles: [bubble(m)] });
  env.tick(1000);
  const text = JSON.stringify(env.posts);
  assert(!text.includes('私密正文') && !text.includes('7712345678901234567') && !text.includes('abc-uuid-123') && !text.includes('张三') && !text.includes('999:888'));
  const keys = env.posts.find(p => p.k === 'msg-keys');
  assert(keys.keys.includes('serverId') && keys.keys.includes('status'));
  const fields = env.posts.find(p => p.k === 'msg-fields').fields;
  assert.strictEqual(fields.serverId, 'string:len19:num');
  assert.strictEqual(fields.status, 'number:=2');
  assert.strictEqual(fields.content, undefined);
});

test('status transition of one message is reported with hashed ID', () => {
  const m = { clientId: 'local-1', status: 0, conversationId: 'c1' };
  const env = makeEnv({ bubbles: [bubble(m)] });
  env.tick(1000);
  m.status = 1; m.serverId = '7799999999999999999';
  env.tick(1000);
  const ch = env.posts.find(p => p.k === 'msg-change');
  assert.ok(ch, 'change posted');
  assert.strictEqual(ch.from.status, 0); assert.strictEqual(ch.to.status, 1);
  assert.strictEqual(ch.to.hasServer, 1);
  assert(!JSON.stringify(ch).includes('local-1'));
});

test('new message after settling is reported, initial history is not', () => {
  const list = [bubble({ serverId: '1', status: 1, conversationId: 'c' })];
  const env = makeEnv({ bubbles: list });
  for (let i = 0; i < 3; i++) env.tick(1000);
  assert.strictEqual(env.posts.filter(p => p.k === 'msg-new').length, 0);
  list.push(bubble({ clientId: 'n2', status: 0, isFromMe: true, conversationId: 'c' }));
  env.tick(1000);
  const nw = env.posts.filter(p => p.k === 'msg-new');
  assert.strictEqual(nw.length, 1); assert.strictEqual(nw[0].mine, 1);
});

test('inactive on non-chat pages', () => {
  const env = makeEnv({ path: '/user/self', bubbles: [bubble({ serverId: '1' })] });
  env.tick(1000);
  assert.strictEqual(env.posts.filter(p => p.k.startsWith('msg')).length, 0);
});

test('every post stays below native size cap', () => {
  const big = {}; for (let i = 0; i < 200; i++) big['field' + i + 'Status'] = i;
  big.serverId = '1'; big.conversationId = 'c';
  const env = makeEnv({ bubbles: [bubble(big)] });
  for (let i = 0; i < 20; i++) new env.ctx.window.WebSocket('wss://h.example.com/p' + i);
  env.tick(1000); env.tick(30000);
  const cap = Number(src.match(/static let maxBody = (\d+)/)[1]);
  for (const p of env.posts) {
    const n = Buffer.byteLength(JSON.stringify(p));
    assert(n <= cap, p.k + ' ' + n);
  }
});

if (failures) { console.error(failures + ' failed'); process.exit(1); }
console.log('all passed');
