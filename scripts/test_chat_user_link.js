// 私信网页点头像/昵称 → 原生作者主页：执行生产脚本 ddUserLinkHookJS，断言三条跳转路径都被拦下改发 ddMsg。
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const source = fs.readFileSync('DouDuo/DouyinWebView.swift', 'utf8');
const js = source.match(/private let ddUserLinkHookJS = #"""\n([\s\S]*?)\n"""#/)[1];
const SEC = 'MS4wLjABAAAAlOh3TQp4lkvJqlJfsQUuxpZbFo2MHAB5wcuK_TNUdPY';
let failures = 0, passed = 0;
function test(name, fn) { try { fn(); passed++; console.log('PASS', name); } catch (e) { failures++; console.error('FAIL', name, e.message); } }

function env(path) {
  const posted = [], pushed = [], opened = [];
  let clickHandler;
  const ctx = {
    URL, JSON, String,
    location: { pathname: path, href: 'https://www.douyin.com' + path },
    document: { addEventListener: (t, h) => { if (t === 'click') clickHandler = h; } },
    history: { pushState: (...a) => pushed.push(a[2]), replaceState: (...a) => pushed.push(a[2]) },
    window: { webkit: { messageHandlers: { ddMsg: { postMessage: m => posted.push(JSON.parse(m)) } } } },
  };
  ctx.window.open = u => { opened.push(u); return {}; };
  vm.createContext(ctx);
  vm.runInContext('var window = this.window; window.open = this.window.open;' + js.replace(/window\.open\s*=/, 'window.open =') , ctx);
  const click = href => {
    let prevented = false;
    const a = { getAttribute: () => href };
    clickHandler({ target: { closest: () => a }, preventDefault: () => { prevented = true; }, stopPropagation() {}, stopImmediatePropagation() {} });
    return prevented;
  };
  return { ctx, posted, pushed, opened, click };
}

test('a 链接点击在聊天页被拦并发 user', () => {
  const e = env('/chat');
  assert.strictEqual(e.click('/user/' + SEC + '?from_tab_name=main'), true);
  assert.deepStrictEqual(e.posted, [{ type: 'user', sec: SEC }]);
});
test('pushState 到 /user/<sec> 被拦，不改路由', () => {
  const e = env('/chat');
  e.ctx.history.pushState({}, '', '/user/' + SEC);
  assert.deepStrictEqual(e.pushed, []);
  assert.deepStrictEqual(e.posted, [{ type: 'user', sec: SEC }]);
});
test('window.open 绝对地址被拦', () => {
  const e = env('/chat');
  e.ctx.window.open('https://www.douyin.com/user/' + SEC);
  assert.deepStrictEqual(e.opened, []);
  assert.strictEqual(e.posted.length, 1);
});
test('/user/self 与非用户链接照常放行', () => {
  const e = env('/chat');
  assert.strictEqual(e.click('/user/self'), false);
  assert.strictEqual(e.click('/video/7312345678901234567'), false);
  e.ctx.history.pushState({}, '', '/chat?conversation=1');
  assert.deepStrictEqual(e.pushed, ['/chat?conversation=1']);
  assert.deepStrictEqual(e.posted, []);
});
test('非聊天页不拦', () => {
  const e = env('/');
  assert.strictEqual(e.click('/user/' + SEC), false);
  assert.deepStrictEqual(e.posted, []);
});
test('非抖音域名不拦', () => {
  const e = env('/chat');
  assert.strictEqual(e.click('https://example.com/user/' + SEC), false);
});
test('Swift 导航层兜底 + 只装在私信网页', () => {
  assert.match(source, /if let onUserLink, action\.targetFrame\?\.isMainFrame != false, let sec = Self\.userSecUid/);
  const chatBlock = source.slice(source.indexOf('        if isChat {'), source.indexOf('cfg.userContentController.add(DDAppMessageHandler'));
  assert.ok(chatBlock.includes('ddUserLinkHookJS'), 'hook 必须在 isChat 块里');
  const msgs = fs.readFileSync('DouDuo/DouyinMessages.swift', 'utf8');
  assert.match(msgs, /chatModel\.onUserLink = /);
  assert.match(msgs, /case "user":/);
});
console.log(`passed=${passed} failed=${failures}`);
process.exit(failures ? 1 : 0);
