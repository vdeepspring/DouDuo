import SwiftUI
import WebKit

/// App 内原生登录（老板 2026-11-17）：界面是 App 自己的，背后跑抖音网页的独立登录页
/// （https://www.douyin.com/login_page），手机号 / 验证码 / 二维码都是网页登录组件真发真收：
/// - 「获取验证码」= 网页里的「获取验证码」（它只认 mousedown，不认 click）
/// - 「登录」= 网页里的「登录」
/// - 二维码 = 网页「扫码登录」页的那张图（data:image/png），网页自己会轮询 check_qrconnect；
///   抖音不认相册里的图，只能另一台手机对着屏幕扫
/// 登录态写进 WKWebsiteDataStore.default()，跟签名页共用 cookie；关掉后外层照旧 bridge.reload() 刷新登录态。
/// 网页要人机验证 / 二次验证时，原生界面让位，直接把网页那一层露出来让用户在网页里完成。
struct DYAppLoginScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @StateObject private var page = DYLoginPage()
    @State private var phone = ""
    @State private var code = ""
    @State private var mode: Mode = .code
    @FocusState private var focus: Field?

    enum Mode { case code, qr }
    enum Field { case phone, code }

    var body: some View {
        NavigationStack {
            ZStack {
                // 网页一直在下面跑；要人机验证时把它露出来
                DYLoginWebHost(page: page)
                    .opacity(page.needsWeb ? 1 : 0.011)
                    .allowsHitTesting(page.needsWeb)
                    .accessibilityHidden(!page.needsWeb)
                if !page.needsWeb {
                    form
                        .background(Color.ddBackground)
                }
            }
            .navigationTitle(page.needsWeb ? "抖音安全验证" : "登录抖音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }.accessibilityIdentifier("douyin.login.close")
                }
                if page.needsWeb {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("回到登录") { page.needsWeb = false }
                    }
                }
            }
        }
        .onChange(of: page.loggedIn) { _, ok in if ok { dismiss() } }
        .onChange(of: page.askScan) { _, ask in if ask { mode = .qr } }
        // 登录页里换 cookie 是预期内的，登录守护别弹
        .onAppear { DYSessionWatch.shared.loginScreenOpen = true }
        .onDisappear { DYSessionWatch.shared.loginScreenOpen = false }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("登录方式", selection: $mode) {
                    Text("验证码登录").tag(Mode.code)
                    Text("扫码登录").tag(Mode.qr)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("douyin.login.mode")

                if mode == .code { codeForm } else { qrForm }

                if page.savingTrust {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("登录成功，正在保存登录信息…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("douyin.login.savingTrust")
                }
                if let msg = page.message {
                    Text(msg).font(.footnote).foregroundStyle(theme.status.danger.color(for: scheme))
                        .accessibilityIdentifier("douyin.login.message")
                }
                Text("登录走的是抖音网页版自己的登录，账号密码不经过本 App。登录即代表同意抖音《用户协议》和《隐私政策》。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: mode) { _, m in if m == .qr { page.showQR() } else { page.showCodeTab() } }
    }

    private var codeForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("+86").foregroundStyle(.secondary)
                TextField("手机号", text: $phone)
                    .keyboardType(.numberPad).textContentType(.telephoneNumber)
                    .focused($focus, equals: .phone)
                    .accessibilityIdentifier("douyin.login.phone")
            }
            .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: WuWeiDesign.Spacing.md))

            HStack(spacing: 10) {
                TextField("验证码", text: $code)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .focused($focus, equals: .code)
                    .accessibilityIdentifier("douyin.login.code")
                Button(page.countdown > 0 ? "\(page.countdown)s 后重发" : "获取验证码") {
                    focus = .code
                    page.sendCode(phone: digits(phone))
                }
                .disabled(digits(phone).count != 11 || page.countdown > 0 || page.busy)
                .accessibilityIdentifier("douyin.login.sendcode")
            }
            .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: WuWeiDesign.Spacing.md))

            Button {
                focus = nil
                page.login(phone: digits(phone), code: digits(code))
            } label: {
                Group { if page.busy { ProgressView() } else { Text("登录").bold() } }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(digits(phone).count != 11 || digits(code).count < 4 || page.busy)
            .accessibilityIdentifier("douyin.login.submit")
        }
    }

    private var qrForm: some View {
        VStack(spacing: 14) {
            if let img = page.qr {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 240, height: 240)
                    .padding(10).background(Color.white, in: RoundedRectangle(cornerRadius: WuWeiDesign.Spacing.lg))
                    .accessibilityIdentifier("douyin.login.qr")
                Text(page.askScan ? "抖音要求扫码确认" : (page.qrStatus ?? "用另一台手机扫码登录"))
                    .font(.headline).multilineTextAlignment(.center)
                    .accessibilityIdentifier("douyin.login.qr.status")
                // 抖音不认相册里的二维码图（老板 11-17 实测存相册再扫不通过）：必须另一台设备对着屏幕扫
                Text("拿另一台已登录抖音的手机 → 打开抖音 App → 左上角「扫一扫」→ 对准这块屏幕上的二维码 → 在那台手机上确认登录")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .accessibilityIdentifier("douyin.login.qr.hint")
                Button("刷新二维码", systemImage: "arrow.clockwise") { page.showQR(refresh: true) }
                    .buttonStyle(.bordered)
            } else {
                ProgressView("正在取二维码…").frame(height: 240)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func digits(_ s: String) -> String { s.filter(\.isNumber) }
}

/// 登录态只看共享 cookie 里有没有 sessionid：不依赖签名页有没有加载好
enum DYLoginState {
    @MainActor static func sessionValue() async -> String? {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookies.first { $0.name == "sessionid" && $0.domain.hasSuffix("douyin.com") && !$0.value.isEmpty }?.value
    }
    @MainActor static func hasSession() async -> Bool { await sessionValue() != nil }
}

/// 抖音登录页的驱动：只做「替用户点网页上的按钮」，不自己调登录接口
@MainActor
final class DYLoginPage: NSObject, ObservableObject, WKNavigationDelegate {
    static let url = URL(string: "https://www.douyin.com/login_page?service=https%3A%2F%2Fwww.douyin.com")!

    @Published var qr: UIImage?
    @Published var qrStatus: String?
    @Published var message: String?
    @Published var busy = false
    @Published var countdown = 0
    @Published var loggedIn = false
    /// 已登录、正在等网页的「保存登录信息」弹框
    @Published var savingTrust = false
    /// 网页弹了人机验证 / 二次验证：把网页那层露出来
    @Published var needsWeb = false
    /// 点了「登录」后网页要求扫码确认（新设备第一次登录常见）：界面切到扫码页
    @Published var askScan = false
    private var loginClickedAt: Date?
    /// 打开登录页时已有的 sessionid。抖音那边过期的旧 cookie 不会自己消失——
    /// 只看「有没有」会把它当成已登录、登录页一打开就自己关掉（老板 11-17 实测：点登录框缩回去）。
    /// 所以只认「换了一个新的 sessionid」才是这次登录成功。
    private var baseline: String??

    let web: WKWebView
    private var poll: Timer?
    private var ready = false
    private var pending: [String] = []

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // 跟签名页 / 网页版共用登录态
        DYTrustLogin.install(in: cfg)       // 登录成功后的「是否保存登录信息？」默认点「保存」
        DYKeyStateProbe.install(in: cfg, tag: "login")
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 760), configuration: cfg)
        web.customUserAgent = DouyinWeb.userAgent
        super.init()
        web.navigationDelegate = self
        #if DEBUG
        // 测试用：拦下发码 / 登录请求不真发（DOUDUO_LOGIN_DRYRUN=1），只记录网页确实发起了它
        if ProcessInfo.processInfo.environment["DOUDUO_LOGIN_DRYRUN"] == "1" {
            web.configuration.userContentController.addUserScript(WKUserScript(source: #"""
            (() => {
              const block = u => /passport\/web\/(send_code|sms_login|user\/login)/.test(String(u));
              const oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
              XMLHttpRequest.prototype.open = function (m, u) { this.__u = String(u); return oo.apply(this, arguments); };
              XMLHttpRequest.prototype.send = function () {
                if (block(this.__u)) {
                  window.__ddDry = (window.__ddDry || []).concat(this.__u.split('?')[0]);
                  // 登录请求：照真机那样网页跳走（/jingxuan），但没有 sessionid —— 验证 App 跳走后还能给反馈
                  if (!/send_code/.test(this.__u)) { setTimeout(() => { location.href = 'https://www.douyin.com/jingxuan'; }, 600); return; }
                  // 假装抖音回了「已发送」：让网页照真实流程往下走（倒计时 / 登录后续），但请求没出本机
                  const x = this, body = JSON.stringify({message: 'success', data: {}, error_code: 0});
                  Object.defineProperty(x, 'readyState', {value: 4}); Object.defineProperty(x, 'status', {value: 200});
                  Object.defineProperty(x, 'responseText', {value: body}); Object.defineProperty(x, 'response', {value: body});
                  setTimeout(() => { x.onreadystatechange && x.onreadystatechange(); x.onload && x.onload(); x.dispatchEvent(new Event('load')); x.dispatchEvent(new Event('loadend')); }, 50);
                  return;
                }
                return os.apply(this, arguments);
              };
              const of = window.fetch;
              window.fetch = function (u) {
                if (block(u && u.url || u)) { window.__ddDry = (window.__ddDry || []).concat(String(u && u.url || u).replace(/\?.*/, '')); return new Promise(() => {}); }
                return of.apply(this, arguments);
              };
            })();
            """#, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        #endif
        Task { @MainActor in
            #if DEBUG
            // 测试：造一个过期的旧 sessionid（老板真机就是这种状态：cookie 在、账号未登录）
            if ProcessInfo.processInfo.environment["DOUDUO_STALE_SESSION"] == "1", await DYLoginState.sessionValue() == nil,
               let c = HTTPCookie(properties: [.domain: ".douyin.com", .path: "/", .name: "sessionid", .value: "stale0000",
                                               .expires: Date().addingTimeInterval(86400)]) {
                await WKWebsiteDataStore.default().httpCookieStore.setCookie(c)
            }
            #endif
            let v = await DYLoginState.sessionValue()
            self.baseline = .some(v)
            DYLiveModel.log("DDAPPLOGIN baseline sessionid=\(v == nil ? "none" : "old")")
        }
        web.load(URLRequest(url: Self.url))
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    deinit { poll?.invalidate() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = webView.url?.path.hasPrefix("/login_page") == true
        DYLiveModel.log("DDAPPLOGIN page \(webView.url?.path ?? "-") ready=\(ready)")
        if ready { let p = pending; pending = []; p.forEach { run($0) } }
        // 网页登录成功会跳回 service（/jingxuan 等）：以前这里 ready=false 后轮询就停了，成功没人发现（老板 11-17 实测）
        else { Task { await confirmLogin() } }
    }

    func sendCode(phone: String) {
        message = nil
        run(Self.js(fillPhone: phone) + #"""
        const send = find(/获取验证码|重新发送/);
        if (!send) return 'no-send';
        const r = send.getBoundingClientRect();
        send.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true, view: window, clientX: r.x + 4, clientY: r.y + 4, button: 0}));
        return 'sent';
        """#, tag: "send")
    }

    func login(phone: String, code: String) {
        message = nil; busy = true
        // 网页已经跳走（多半已登录）：不再往登录页塞点击，直接核对登录态
        guard ready else { Task { await confirmLogin() }; return }
        run(Self.js(fillPhone: phone) + #"""
        const ci = [...document.querySelectorAll('input')].find(i => /验证码/.test(i.placeholder || ''));
        if (!ci) return 'no-code-input';
        set(ci, "\#(code)");
        await new Promise(r => setTimeout(r, 300));
        const btn = [...document.querySelectorAll('div,button')].find(e => e.childElementCount === 0 && vis(e) && (e.innerText || '').trim() === '登录');
        if (!btn) return 'no-login';
        btn.click();
        return 'clicked';
        """#, tag: "login")
        loginClickedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.busy = false }
    }

    func showCodeTab() { run(Self.base + "const t = find(/^验证码登录$/); if (t) t.click(); return 'tab';", tag: "tab") }

    func showQR(refresh: Bool = false) {
        if refresh { qr = nil; qrStatus = nil }
        run(Self.base + #"""
        const t = find(/^扫码登录$/); if (t) t.click();
        const again = find(/刷新|重新获取|点击刷新/); if (again) again.click();
        return 'qr';
        """#, tag: "qr")
    }

    /// 每秒读一次：登录态、二维码、倒计时、网页提示、有没有弹验证
    private func tick() {
        guard !loggedIn else { return }
        // 不管网页在哪一页，出现了新的 sessionid 就是登录成功
        Task { if await self.hasNewSession() { await self.confirmLogin() } }
        guard ready else { return }
        web.callAsyncJavaScript(Self.base + #"""
        const qrs = [...document.querySelectorAll('img')].filter(i => String(i.src).startsWith('data:image/png') && i.naturalWidth >= 100);
        const qrImg = qrs.filter(vis).pop() || qrs[0];
        const leaf = [...document.querySelectorAll('*')].filter(e => e.childElementCount === 0 && vis(e) && e.innerText && e.innerText.trim().length < 40).map(e => e.innerText.trim());
        const cd = leaf.map(t => (t.match(/^(\d+)s后重新发送$/) || [])[1]).find(Boolean);
        const tip = leaf.find(t => /错误|有误|频繁|失败|过期|不正确|格式|稍后|上限|异常|风险/.test(t));
        const qrTip = leaf.find(t => /扫码成功|已扫码|确认登录|已失效|二维码已过期|刷新/.test(t));
        const frames = [...document.querySelectorAll('iframe')].filter(f => { const r = f.getBoundingClientRect(); return r.width > 200 && r.height > 150; }).length;
        const scanAsk = leaf.find(t => /扫码验证|扫码确认|请使用抖音.*扫|抖音App扫码|扫一扫验证/.test(t)) || null;
        const verify = !scanAsk && (frames > 0 || leaf.some(t => /安全验证|身份验证|拖动|滑块|请完成验证/.test(t)));
        return JSON.stringify({
          path: location.pathname,
          qr: qrImg ? qrImg.src : null, cd: cd ? Number(cd) : 0, tip: tip || null, qrTip: qrTip || null, verify,
          dry: window.__ddDry || [], scanAsk,
          // 点登录后网页上能看到的字 + 有没有大号方图/弹窗：抖音新设备二次验证页没见过，靠这个从日志还原
          seen: leaf.slice(0, 60).join('|'),
          boxes: [...document.querySelectorAll('img,canvas,iframe')].filter(e => { const r = e.getBoundingClientRect(); return r.width > 100 && r.height > 100; })
                   .map(e => e.tagName + ':' + Math.round(e.getBoundingClientRect().width) + 'x' + Math.round(e.getBoundingClientRect().height) + ':' + String(e.src || '').slice(0, 40)).join(',')
        });
        """#, arguments: [:], in: nil, in: .page) { [weak self] r in
            guard let self, case .success(let v) = r, let s = v as? String,
                  let d = s.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            self.apply(j)
        }
    }

    private func apply(_ j: [String: Any]) {
        let path = j["path"] as? String ?? ""
        // 网页跳走了登录页（登录成功会回 service）：去核对是不是换了新 sessionid。
        // 不再看网页里 document.cookie 有没有 sessionid——过期的旧 cookie 也在，会误判成功、把登录页关掉
        if !path.isEmpty && !path.hasPrefix("/login_page") {
            Task { await self.confirmLogin() }
            return
        }
        #if DEBUG
        if let dry = j["dry"] as? [String], dry.count != lastDry { lastDry = dry.count; DYLiveModel.log("DDAPPLOGIN dry " + dry.joined(separator: ",")) }
        #endif
        if loginClickedAt != nil, let seen = j["seen"] as? String {
            let snap = seen + " ## " + (j["boxes"] as? String ?? "")
            if snap != lastSeen { lastSeen = snap; DYLiveModel.log("DDAPPLOGIN after-login path=\(path) " + String(snap.prefix(900))) }
        }
        countdown = j["cd"] as? Int ?? 0
        if let t = j["tip"] as? String, t != message {
            Task {
                if await self.hasNewSession() { await self.confirmLogin() }
                else { self.message = t; self.busy = false; DYLiveModel.log("DDAPPLOGIN tip " + t) }
            }
        }
        qrStatus = j["qrTip"] as? String
        if let t = j["scanAsk"] as? String, loginClickedAt != nil, !askScan {
            askScan = true; busy = false
            qrStatus = t
            DYLiveModel.log("DDAPPLOGIN scan-ask " + t)
        }
        if (j["verify"] as? Bool) == true, !needsWeb { needsWeb = true; busy = false }
        if let src = j["qr"] as? String, src != lastQR,
           let b64 = src.split(separator: ",").last, let data = Data(base64Encoded: String(b64)),
           let img = UIImage(data: data) {
            lastQR = src
            qr = img
        }
    }
    private var lastQR: String?
    private var lastDry = 0
    private var lastSeen = ""

    /// cookie 里真有 sessionid 才算登录成功（网页跳转不一定代表登录了）
    /// 轮询和网页跳转会同时触发确认：同一时间只跑一份（以前两份并发，日志里确认/保存各记两遍）
    private var confirming = false
    private func confirmLogin() async {
        guard !loggedIn, !savingTrust, !confirming else { return }
        confirming = true
        defer { confirming = false }
        var ok = await hasNewSession()
        // 网页跳走时 cookie 可能晚一点才写进来：再等几轮
        if !ok, web.url?.path.hasPrefix("/login_page") != true {
            for _ in 0..<3 where !ok { try? await Task.sleep(for: .seconds(1)); ok = await hasNewSession() }
        }
        guard !loggedIn else { return }
        DYLiveModel.log("DDAPPLOGIN confirm newSession=\(ok) path=\(web.url?.path ?? "-")")
        if ok {
            poll?.invalidate()
            // 别马上关：登录成功后网页会弹「是否保存登录信息？（5）」，等脚本点完「保存」再关（最多 7 秒）
            message = nil; busy = true; savingTrust = true
            let clicked = await DYTrustLogin.waitClicked(in: web, seconds: 7)
            DYLiveModel.log("DDTRUST login-page clicked=\(clicked) path=\(web.url?.path ?? "-")")
            savingTrust = false; busy = false; loggedIn = true
            DYAccountStore.sessionDidChange()
        }
        else if web.url?.path.hasPrefix("/login_page") != true {
            // 跳走了但没登录上：回登录页，告诉用户再试
            busy = false
            message = "没登录上，请重新获取验证码再试"
            web.load(URLRequest(url: Self.url))
        }
    }

    private func hasNewSession() async -> Bool {
        let now = await DYLoginState.sessionValue()
        guard case .some(let base) = baseline else { return false }   // 还没记下打开时的值
        return now != nil && now != base
    }

    private func run(_ js: String, tag: String = "") {
        guard ready else { pending.append(js); return }
        web.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { r in
            if case .success(let v) = r { DYLiveModel.log("DDAPPLOGIN \(tag) -> \(String(describing: v ?? "nil"))") }
            if case .failure(let e) = r { DYLiveModel.log("DDAPPLOGIN \(tag) err \(e.localizedDescription)") }
        }
    }

    private static let base = #"""
    const vis = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    const find = re => [...document.querySelectorAll('span,div,a,p,button')].find(e => e.childElementCount === 0 && vis(e) && re.test((e.innerText || '').trim()));
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    const set = (i, v) => { i.focus(); setter.call(i, v); i.dispatchEvent(new Event('input', {bubbles: true})); i.dispatchEvent(new Event('change', {bubbles: true})); };

    """#

    private static func js(fillPhone phone: String) -> String {
        base + """
        { const t = find(/^验证码登录$/); if (t) t.click(); }
        await new Promise(r => setTimeout(r, 200));
        const pi = [...document.querySelectorAll('input')].find(i => /手机号/.test(i.placeholder || ''));
        if (!pi) return 'no-phone-input';
        if (pi.value.replace(/\\s/g, '') !== '\(phone)') { set(pi, '\(phone)'); await new Promise(r => setTimeout(r, 300)); }

        """
    }
}

/// 把登录页的 WKWebView 放进界面（隐身时也得在窗口里，网页计时器和渲染才正常跑）
private struct DYLoginWebHost: UIViewRepresentable {
    let page: DYLoginPage
    func makeUIView(context: Context) -> WKWebView { page.web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
