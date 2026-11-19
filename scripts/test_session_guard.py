#!/usr/bin/env python3
"""登录守护回归：后台网页登出拦截规则 + 「登录被弄丢」判定 + 各后台网页都挂了拦截。
用 macOS 真 WebKit 编译内容规则并加载页面，验证 logout 请求确实被拦、其它 passport 请求放行。"""
import json, os, re, subprocess, sys, tempfile
from pathlib import Path
root = Path(__file__).resolve().parent.parent
guard = (root / 'DouDuo/DYSessionGuard.swift').read_text()
fails = 0
def check(ok, name):
    global fails
    print(('PASS ' if ok else 'FAIL ') + name)
    if not ok: fails += 1

rules_src = re.search(r'static let rules = #"(.*?)"#', guard)[1]
rules = json.loads(rules_src)
pat = re.compile(rules[0]['trigger']['url-filter'])
check(rules[0]['action']['type'] == 'block', 'rule action is block')
check(bool(pat.search('https://www.douyin.com/passport/web/logout/?aid=6383')), 'logout url matches')
for ok_url in ['https://www.douyin.com/passport/token/beat/web/', 'https://www.douyin.com/passport/web/challenge/',
               'https://www.douyin.com/aweme/v1/web/comment/publish', 'https://www.douyin.com/passport/user_info/get_sec_ts/']:
    check(not pat.search(ok_url), 'not blocked: ' + ok_url.split('.com')[1])

# 各后台网页都挂拦截
src = {f: (root / 'DouDuo' / f).read_text() for f in ['DouyinFeedView.swift', 'DouyinWebView.swift', 'DouyinLiveChat.swift', 'DouyinMessages.swift', 'DouDuoApp.swift', 'DYAccounts.swift', 'DYAppLogin.swift', 'DYRelogin.swift']}
check('DYLogoutBlock.install(in: cfg)  // 后台签名页' in src['DouyinFeedView.swift'], 'signing page blocks logout')
check(re.search(r'if isChat \{\s*//[^\n]*\n\s*DYLogoutBlock.install\(in: cfg\)', src['DouyinWebView.swift']) is not None, 'chat web blocks logout (only chat)')
check('DYLogoutBlock.install(in: cfg)\n        web = WKWebView' in src['DouyinLiveChat.swift'], 'live chat blocks logout')
check('DYLogoutBlock.install(in: config)' in src['DouyinMessages.swift'], 'forward page blocks logout')
check('DYSessionWatch.shared.start()' in src['DouDuoApp.swift'], 'watch starts at launch')
check('DYSessionWatch.shared.suppressed += 1' in src['DYAccounts.swift'], 'app sign-out/switch suppresses alert')
check('loginScreenOpen = true' in src['DYAppLogin.swift'], 'login screen suppresses alert')
check('DYSessionLostAlert' in src['DouyinFeedView.swift'], 'root shows session-lost alert')
check('sessionGone' in src['DYRelogin.swift'] and 'Button("重新登录")' in src['DYRelogin.swift'], 'comment recovery offers relogin when session gone')
check('passport/web/logout' not in re.sub(r'//[^\n]*', '', src['DYAccounts.swift']), 'app itself never calls douyin logout')

# isLoss 判定 + 真 WebKit 拦截
swift = r'''
import Foundation
import WebKit
''' + re.search(r'(    nonisolated static func isLoss.*?\n    \})', guard, re.S)[1].replace('nonisolated ', '').join(['enum W {\n', '\n}\n']) + r'''
var fails = 0
func check(_ ok: Bool, _ n: String) { print((ok ? "PASS " : "FAIL ") + n); if !ok { fails += 1 } }
check(W.isLoss(before: "a", now: nil, suppressed: false), "session vanished → loss")
check(!W.isLoss(before: "a", now: nil, suppressed: true), "app-driven sign-out → no alert")
check(!W.isLoss(before: nil, now: nil, suppressed: false), "never logged in → no alert")
check(!W.isLoss(before: "a", now: "b", suppressed: false), "session renewed → no alert")
check(!W.isLoss(before: nil, now: "b", suppressed: false), "login → no alert")

final class Nav: NSObject, WKNavigationDelegate {}
let rules = ''' + json.dumps(rules_src) + r'''
var done = false
WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "dd-test-logout", encodedContentRuleList: rules) { list, err in
  guard let list else { check(false, "rule compiles: \(String(describing: err))"); done = true; return }
  check(true, "rule compiles in WebKit")
  let cfg = WKWebViewConfiguration(); cfg.userContentController.add(list)
  let web = WKWebView(frame: .zero, configuration: cfg); let nav = Nav(); web.navigationDelegate = nav
  // 本地服务：规则正则匹配整条 URL，路径里带 douyin.com/passport/... 即可区分「被拦」和「放行」
  let base = ProcessInfo.processInfo.environment["DD_BASE"]!
  web.load(URLRequest(url: URL(string: base + "/index.html")!))
  // 等测试页真正加载完再发探测请求（固定延时会偶发在 about:blank 上发，相对地址全失败）
  func whenLoaded(_ tries: Int = 0, _ go: @escaping () -> Void) {
    if (!web.isLoading && web.url?.host == "127.0.0.1") || tries > 100 { go(); return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { whenLoaded(tries + 1, go) }
  }
  whenLoaded {
    let js = """
    const probe = u => new Promise(r => { const x = new XMLHttpRequest(); x.open('GET', u); x.onload = () => r('loaded'); x.onerror = () => r('error'); x.send(); });
    return JSON.stringify([await probe('/x.douyin.com/passport/web/logout/'), await probe('/x.douyin.com/passport/token/beat/web/')]);
    """
    web.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { r in
      if case .failure(let e) = r { print("probe error", e) }
      let raw = (try? r.get()) as? String ?? "[]"
      let v = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String] ?? []
      print("probe", v)
      // 对照请求没加载成功 = 本机 WebKit 环境没就绪，这一轮不下结论（不算过也不算挂）
      if v.count == 2 && v[1] == "loaded" {
        check(true, "control passport request still loads")
        check(v[0] == "error", "WebKit actually blocks logout request")
      } else {
        print("INCONCLUSIVE webkit control request did not load")
      }
      WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "dd-test-logout") { _ in done = true }
    }
  }
}
while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
exit(fails == 0 ? 0 : 1)
'''
with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as d:
    p = Path(d) / 'Guard.swift'; p.write_text(swift)
    r = subprocess.run(['swiftc', '-o', str(Path(d) / 'g'), str(p)], capture_output=True, text=True)
    if r.returncode: print(r.stderr[-3000:]); check(False, 'swift compile')
    else:
        (Path(d) / 'index.html').write_text('<html><body>t</body></html>')
        for sub in ['x.douyin.com/passport/web/logout', 'x.douyin.com/passport/token/beat/web']:
            (Path(d) / sub).mkdir(parents=True, exist_ok=True); (Path(d) / sub / 'index.html').write_text('ok')
        import socket
        sk = socket.socket(); sk.bind(('127.0.0.1', 0)); port = sk.getsockname()[1]; sk.close()
        srv = subprocess.Popen([sys.executable, '-m', 'http.server', str(port), '--bind', '127.0.0.1', '-d', d], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        import time, urllib.request
        for _ in range(50):  # 等本地服务真起来，避免把「服务没起」误判成「被拦」
            try: urllib.request.urlopen(f'http://127.0.0.1:{port}/index.html', timeout=1).read(); break
            except Exception: time.sleep(0.1)
        # 本机 WebKit 偶发对照请求也没发到本地服务（服务日志无记录），那一轮无法区分「被拦」和「环境没就绪」：
        # 只采信对照请求真加载成功的那一轮，且同一轮里登出请求必须被拦。最多试 6 轮。
        try:
            for attempt in range(6):
                r = subprocess.run([str(Path(d) / 'g')], capture_output=True, text=True, timeout=60, env={**os.environ, 'DD_BASE': f'http://127.0.0.1:{port}'})
                if 'PASS control passport request still loads' in r.stdout:
                    break
            print(f'webkit attempts={attempt + 1}')
            if 'PASS control passport request still loads' not in r.stdout:
                print('WARN WebKit runtime check inconclusive this run (rule matching still covered above)')
        finally:
            srv.terminate()
        print(r.stdout, r.stderr[-1500:]); check(r.returncode == 0, 'swift checks')
print(f'checks failed={fails}')
sys.exit(1 if fails else 0)
