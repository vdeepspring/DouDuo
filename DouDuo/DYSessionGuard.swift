import Foundation
import SwiftUI
import WebKit

/// 登录态守护（老板 2026-11-18：评论发不出 = 被退出登录了，而且 App 没有任何提示）。
///
/// 真机日志实证（19:04:37–39）：App 启动后，后台停着的私信网页（/chat）在打开 2 秒内由网页自己的脚本
/// 发了 `www.douyin.com/passport/web/logout/`；DouDuo 原生代码没有调用任何登出（无 DDACCOUNT sign-out）。
/// 随后评论 code 8、信息页账号核对发现身份 cookie 变了。网页为什么要登出（服务端先吊销 / 页面自身逻辑）暂未查明。
///
/// 两件事：
/// 1. 后台网页（签名页、私信页、直播评论区、转发页）一律拦下 `passport/web/logout` 请求——
///    DouDuo 的「退出登录」本来就只清本机 cookie、从不调抖音登出接口（见 DYAccountStore），
///    后台页面无人操作却去登出，只会作废这份凭据，存着的账号也切不回来。
/// 2. 本机 sessionid 从「有」变「没有」且不是 App 自己退出/切换时，弹「抖音登录已失效」，可直接去重新登录。
enum DYLogoutBlock {
    static let identifier = "dd-block-web-logout-v1"
    /// WebKit 内容规则：url-filter 是正则，JSON 里 `\\.` 即正则的字面点
    static let rules = #"[{"trigger":{"url-filter":"douyin\\.com/passport/web/logout"},"action":{"type":"block"}}]"#

    @MainActor private static var list: WKContentRuleList?
    @MainActor private static var waiting: [WeakController] = []
    private final class WeakController { weak var value: WKUserContentController?; init(_ v: WKUserContentController) { value = v } }

    /// App 启动就编译（有缓存时几毫秒），后台网页开页前基本已就绪
    @MainActor static func prepare() {
        guard list == nil else { return }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { compiled, error in
            Task { @MainActor in
                guard let compiled else {
                    DYLiveModel.log("DDSESSION logout-block compile failed \(error?.localizedDescription ?? "-")")
                    return
                }
                list = compiled
                let pending = waiting.compactMap(\.value)
                waiting = []
                pending.forEach { $0.add(compiled) }
                DYLiveModel.log("DDSESSION logout-block ready late=\(pending.count)")
            }
        }
    }

    /// 后台网页的配置里挂上拦截；规则还没编译完就记下来，编译完补挂
    @MainActor static func install(in cfg: WKWebViewConfiguration) {
        if let list { cfg.userContentController.add(list); return }
        waiting.append(WeakController(cfg.userContentController))
        prepare()
    }
}

@MainActor
final class DYSessionWatch: NSObject, WKHTTPCookieStoreObserver {
    static let shared = DYSessionWatch()
    private var last: String??
    private var started = false
    /// App 自己在退出 / 切换账号 / 登录页里：这时 sessionid 消失是预期内的，不弹
    var suppressed = 0
    var loginScreenOpen = false

    func start() {
        guard !started else { return }
        started = true
        WKWebsiteDataStore.default().httpCookieStore.add(self)
        Task { last = .some(await DYLoginState.sessionValue()) }
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in await self.check() }
    }

    private func check() async {
        let now = await DYLoginState.sessionValue()
        defer { last = .some(now) }
        guard case .some(let before) = last else { return }
        if Self.isLoss(before: before, now: now, suppressed: suppressed > 0 || loginScreenOpen) {
            DYLiveModel.log("DDSESSION lost sessionid (not by app) → prompt relogin")
            NotificationCenter.default.post(name: .dySessionLost, object: nil)
        } else if (before == nil) != (now == nil) {
            DYLiveModel.log("DDSESSION sessionid \(now == nil ? "gone" : "present") suppressed=\(suppressed > 0 || loginScreenOpen)")
        }
    }

    /// 只有「原来有登录、现在没了、又不是 App 自己做的」才算登录被弄丢
    nonisolated static func isLoss(before: String?, now: String?, suppressed: Bool) -> Bool {
        before != nil && now == nil && !suppressed
    }
}

extension Notification.Name {
    /// 本机抖音登录被清掉（不是 App 自己退出 / 切换）
    static let dySessionLost = Notification.Name("douduo.sessionLost")
}

/// 根界面挂一次：登录丢了弹提示，可直接去登录
struct DYSessionLostAlert: ViewModifier {
    var onRelogin: () -> Void
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .dySessionLost)) { _ in show = true }
            .alert("抖音登录已失效", isPresented: $show) {
                Button("重新登录") { onRelogin() }
                Button("稍后", role: .cancel) {}
            } message: {
                Text("本机的抖音登录被清掉了，评论、私信、关注要重新登录后才能用。未发出的评论草稿还在。")
            }
    }
}
