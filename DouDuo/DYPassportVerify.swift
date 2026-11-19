import UIKit
import WebKit

/// 抖音「身份验证」（二次验证）——老板 2026-11-19：第一条评论发出，后面几条全失败。
///
/// 真机 12:35–12:36：评论接口回 200 空 body，响应头带 `x-tt-verify-passport-decision`（日志 vp=1）。
/// 官方网页版（client-entry 请求层）遇到这个头：动态加载身份验证 SDK（webpack 块 5747 / 模块 581289），
/// `init({aid:6383, isNewVerifyUI:true})` 后 `verify(JSON.parse(头的值))`，`status` 为真就把同一个请求再发一次。
/// 这里照做：开一个可见的抖音网页（同一份登录、同一个 UA），在里面调官方 SDK 让用户自己完成验证。
/// 验证内容（短信/人脸等）全在抖音自己的页面里，App 不读不存；日志只记阶段和结果。
struct DYCommentNeedsVerify: Error {
    /// 响应头原值，只在内存里转交给官方 SDK，不入日志
    let decision: String
}

@MainActor
enum DYPassportVerify {
    enum Outcome: Equatable { case passed, failed(String), cancelled }

    /// 单元测试目标里没有 DYLiveModel；App 启动时接到 ddlog
    static var log: (String) -> Void = { _ in }

    /// 在抖音网页里加载官方身份验证 SDK 并发起验证。返回 JSON：{ status, stage, msg }
    static let runJS = #"""
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const out = (status, stage, msg) => JSON.stringify({ status: !!status, stage, msg: msg || null });
    for (let i = 0; i < 150 && !self.webpackChunkdouyin_web; i++) await sleep(100);
    const ch = self.webpackChunkdouyin_web;
    if (!ch || typeof ch.push !== 'function') return out(false, 'no-webpack', '抖音网页没加载完');
    let req = null;
    try { ch.push([[Symbol('dd-verify')], {}, r => { req = r; }]); } catch (e) {}
    if (typeof req !== 'function' || typeof req.e !== 'function') return out(false, 'no-require', '抖音网页没加载完');
    let sdk = null;
    try { await req.e('5747'); const m = req(581289); sdk = m && (m.default || m); } catch (e) {}
    if (!sdk || typeof sdk.init !== 'function' || typeof sdk.verify !== 'function') return out(false, 'no-sdk', '抖音网页版本变了，找不到身份验证组件');
    let conf = null;
    try { conf = JSON.parse(decision); } catch (e) { return out(false, 'bad-decision', '抖音给的验证信息无法识别'); }
    try { if (!sdk.isInit) sdk.init({ aid: 6383, isNewVerifyUI: true, newSecondVerificationCall: { reportAppLog() {} } }); } catch (e) { return out(false, 'init-error', '身份验证组件初始化失败'); }
    let res = null;
    try { res = await sdk.verify(conf); } catch (e) { return out(false, 'verify-error', '身份验证出错'); }
    return out(res && res.status, 'done', res && !res.status ? (res.message || '身份验证未通过') : null);
    """#

    /// 弹出验证页，等用户完成。期间同一时刻只允许一个。
    static func run(decision: String) async -> Outcome {
        guard current == nil, let top = topController() else { return .failed("当前无法弹出身份验证页") }
        let vc = VerifyController(decision: decision)
        current = vc
        defer { current = nil }
        log("DDVERIFY phase=present")
        let result = await vc.start(on: top)
        switch result {
        case .passed: log("DDVERIFY phase=passed")
        case .cancelled: log("DDVERIFY phase=cancelled")
        case .failed(let why): log("DDVERIFY phase=failed why=\(why.prefix(40))")
        }
        return result
    }

    private static var current: VerifyController?

    #if DEBUG
    /// 模拟器测试：DOUDUO_VERIFY_DEMO=<decision JSON> 启动 4 秒后弹验证页，结果放进一个可读的标签
    static func runDemoIfRequested() {
        guard let dec = ProcessInfo.processInfo.environment["DOUDUO_VERIFY_DEMO"], !dec.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            let r = await run(decision: dec)
            let text: String
            switch r { case .passed: text = "passed"; case .cancelled: text = "cancelled"; case .failed(let w): text = "failed:" + w }
            guard let top = topController() else { return }
            let a = UIAlertController(title: "VERIFY_RESULT", message: text, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            top.present(a, animated: true)
        }
    }
    #endif

    private static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    final class VerifyController: UIViewController, WKNavigationDelegate {
        let decision: String
        private var web: WKWebView!
        private var cont: CheckedContinuation<Outcome, Never>?
        private var loaded: CheckedContinuation<Void, Never>?
        private var didLoad = false

        init(decision: String) {
            self.decision = decision
            super.init(nibName: nil, bundle: nil)
            modalPresentationStyle = .fullScreen
        }
        required init?(coder: NSCoder) { fatalError() }

        func start(on host: UIViewController) async -> Outcome {
            await withCheckedContinuation { (c: CheckedContinuation<Outcome, Never>) in
                cont = c
                host.present(self, animated: true)
                Task { @MainActor in await self.runVerify() }
            }
        }

        private func finish(_ o: Outcome) {
            guard let c = cont else { return }
            cont = nil
            dismiss(animated: true)
            c.resume(returning: o)
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = .default()
            cfg.allowsInlineMediaPlayback = true
            cfg.mediaTypesRequiringUserActionForPlayback = .all
            cfg.userContentController.addUserScript(WKUserScript(source: DouyinBridge.composerNoMediaJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            DYLogoutBlock.install(in: cfg)
            web = WKWebView(frame: .zero, configuration: cfg)
            web.customUserAgent = DouyinWeb.userAgent
            web.navigationDelegate = self
            web.translatesAutoresizingMaskIntoConstraints = false

            let title = UILabel()
            title.text = "抖音要求身份验证"
            title.font = .preferredFont(forTextStyle: .headline)
            let hint = UILabel()
            hint.text = "按抖音页面提示完成验证，通过后自动重发这条评论；取消则不发，草稿保留。"
            hint.font = .preferredFont(forTextStyle: .footnote)
            hint.textColor = .secondaryLabel
            hint.numberOfLines = 0
            let cancel = UIButton(type: .system, primaryAction: UIAction(title: "取消") { [weak self] _ in self?.finish(.cancelled) })
            cancel.accessibilityIdentifier = "douyin.verify.cancel"
            let head = UIStackView(arrangedSubviews: [title, UIView(), cancel])
            head.axis = .horizontal
            let bar = UIStackView(arrangedSubviews: [head, hint])
            bar.axis = .vertical
            bar.spacing = 4
            bar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bar)
            view.addSubview(web)
            let g = view.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
                bar.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
                bar.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
                web.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
                web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            web.load(URLRequest(url: URL(string: "https://www.douyin.com/jingxuan")!))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didLoad = true
            loaded?.resume(); loaded = nil
        }

        private func runVerify() async {
            if !isViewLoaded { loadViewIfNeeded() }
            if !didLoad {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    loaded = c
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(20))
                        self.loaded?.resume(); self.loaded = nil
                    }
                }
            }
            guard cont != nil else { return }
            let r = try? await web.callAsyncJavaScript(DYPassportVerify.runJS, arguments: ["decision": decision], contentWorld: .page)
            guard let s = r as? String, let d = s.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                finish(.failed("身份验证页没有返回结果")); return
            }
            DYPassportVerify.log("DDVERIFY phase=result stage=\(j["stage"] as? String ?? "-") status=\((j["status"] as? Bool) == true ? 1 : 0)")
            if (j["status"] as? Bool) == true { finish(.passed) }
            else { finish(.failed(j["msg"] as? String ?? "身份验证未通过")) }
        }
    }
}
