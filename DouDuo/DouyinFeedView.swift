// DouDuo：抖音第三方客户端。数据走抖音网页端接口，界面 / 播放全原生。
// 源自 無為 App 的「抖音原生模式」。
// - 一个看不见的 WKWebView（电脑版 UA）挂在抖音页面上，只当「签名代理」：在页面里发 XHR，
//   抖音自己的安全 SDK 自动补 a_bogus 等签名，签名算法跟着官方更新走，我们不用逆向。
// - 登录态与「网页版」共用 WKWebsiteDataStore.default()，在网页版登录后原生模式即带账号。
// - 推荐流：GET /aweme/v1/web/tab/feed/（网页首页「推荐」竖屏流，不用精选 module/feed）；
//   播放用 /aweme/v1/play/ 链接（302 到 CDN mp4，不需要 cookie，系统播放器直接播）。
// - 评论：GET /aweme/v1/web/comment/list/。
import SwiftUI
import Combine
import WebKit
import AVFoundation

// MARK: - 数据

struct DYAweme: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let desc: String
    let width: Double
    let height: Double
    let duration: Double
    let play: String?
    /// 抖音默认清晰度的地址（play 选了更高一档时才有）；高清起不来时备用
    var playAlt: String? = nil
    /// 秒开用的低码率地址（冷启动先放它，高清好了再换）
    var playFast: String? = nil
    /// 选中的清晰度说明（调试日志用）
    var q: String? = nil
    let cover: String?
    let images: [String]
    let author: Author
    let stats: Stats
    let music: String
    /// 该视频在你账号里是否已点赞 / 已收藏（未登录时一般没有这些字段）
    let userDigged: Int?
    let isCollect: Int?
    /// 0=视频 68=图文；上报观看时要带
    var awemeType: Int? = nil
    /// 作品原始发布时间（Unix 秒）；可选以兼容已保存的旧播放会话。
    var publishedAt: TimeInterval? = nil
    /// 保留平台返回的 AI 声明原文；没有标记不代表非 AI。
    var aiDeclaration: String? = nil
    /// Optional for compatibility with sessions saved before hashtag support.
    var hashtagNames: [String]? = nil

    func publicationText(now: Date = Date()) -> String? {
        guard let publishedAt, publishedAt.isFinite, publishedAt > 0,
              publishedAt <= now.timeIntervalSince1970 else { return nil }
        let age = now.timeIntervalSince1970 - publishedAt
        if age < 60 { return "刚刚发布" }
        if age < 3600 { return "\(Int(age / 60))分钟前发布" }
        if age < 86400 { return "\(Int(age / 3600))小时前发布" }
        if age < 604800 { return "\(Int(age / 86400))天前发布" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: publishedAt)) + " 发布"
    }

    func metadataText(now: Date = Date()) -> String? {
        let parts = [publicationText(now: now), aiDeclaration?.trimmingCharacters(in: .whitespacesAndNewlines)]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    struct Author: Codable, Hashable { let name: String; let avatar: String?; let secUid: String?; var uid: String? = nil; var follow: Int? = nil }
    struct Stats: Codable, Equatable { let digg: Int; let comment: Int; let collect: Int; let share: Int; var play: Int? = nil }

    /// 视频画面高宽比，不是界面方向。界面布局看容器尺寸 / size class。
    var isTallFrame: Bool { height > width * 1.05 }
    var webURL: URL { URL(string: "https://www.douyin.com/video/\(id)")! }
}

/// 点赞/收藏的结果：成功 / 没登录 / 其它失败（带原因）
enum DYActionResult {
    case ok
    case notLoggedIn
    case failed(String)
}

struct DYActionResp: Decodable {
    let status: Int
    let statusCode: Int?
    let msg: String?
    enum CodingKeys: String, CodingKey { case status, statusCode = "statusCode", msg }
}

struct DYComment: Identifiable, Decodable, Equatable {
    let id: String
    let text: String
    let name: String
    let avatar: String?
    let digg: Int
    let time: Double
    let replies: Int
    let ip: String?
    /// 这条评论在账号里是否已赞。缺字段当未赞。
    var userDigged: Int? = nil
    /// 评论配图（image_list）与表情包贴纸（sticker），缺字段为空
    var images: [DYCommentImage]? = nil
    var sticker: DYCommentImage? = nil
    /// 定位评论时接口随一级评论一起带回的楼中楼（只在 insert_ids 请求里有）
    var pinned: [DYComment]? = nil
    /// 楼中楼被 insert_ids 直接顶到一级列表时，它所属的一级评论 cid（回复它要用）
    var parent: String? = nil
}

/// 评论里的一张图：缩略图用于列表，原图用于点开全屏
struct DYCommentImage: Decodable, Equatable, Hashable {
    let thumb: String
    let full: String
    let w: Double
    let h: Double
}

struct DYLiveRoom: Identifiable, Decodable, Equatable {
    let id: String
    let webRid: String
    let title: String
    let owner: String
    let avatar: String?
    let cover: String?
    let viewers: String
    let hls: [String: String]      // FULL_HD1 / HD1 / SD1 / SD2
    var flv: [String: String]? = nil
    let portrait: Bool
    var def: String? = nil

    var bestHLS: URL? {
        for k in ["HD1", "FULL_HD1", "SD2", "SD1"] { if let s = hls[k], let u = URL(string: s) { return u } }
        return hls.values.first.flatMap(URL.init(string:))
    }
    var webURL: URL { URL(string: "https://live.douyin.com/\(webRid)")! }
}

extension DYLiveRoom {
    var followMetadata: DYFollowMetadata {
        DYFollowMetadata(id: id, webRid: webRid, title: title, owner: owner, avatar: avatar, cover: cover, viewers: viewers, portrait: portrait)
    }

    init(_ metadata: DYFollowMetadata) {
        self.init(id: metadata.id, webRid: metadata.webRid, title: metadata.title, owner: metadata.owner,
                  avatar: metadata.avatar, cover: metadata.cover, viewers: metadata.viewers, hls: [:], portrait: metadata.portrait)
    }

    init(playback resolved: DYLiveRoom, fallback: DYLiveRoom) {
        let meta = resolved.followMetadata.fillingEmpty(from: fallback.followMetadata)
        self.init(id: meta.id, webRid: meta.webRid, title: meta.title, owner: meta.owner, avatar: meta.avatar,
                  cover: meta.cover, viewers: meta.viewers, hls: resolved.hls, flv: resolved.flv, portrait: meta.portrait, def: resolved.def)
    }
}

private struct DYLiveResp: Decodable { let status: Int; let items: [DYLiveRoom] }

struct DYFollowLiveResult: Equatable {
    var kind: DYFollowLiveKind
    var items: [DYLiveRoom]
    var status: Int
    var stats: DYFollowLiveStats?
    var fromCache = false
    var stale = false
}

private struct DYFollowLivePayload: Decodable {
    let status: Int
    let items: [DYLiveRoom]
    let stats: DYFollowLiveStats?
}

/// 直播专区（网页版「游戏」下的专区；id 取自 live.douyin.com/categorynew/4_103_1_<id>）
/// shortcut: 写死网页版游戏页上的几个专区，网页改版/要别的分类时再从页面里抓
struct DYLiveZone: Hashable {
    let id: String, type: String, name: String
    static let all: [DYLiveZone] = [
        ("1010017", "无畏契约"), ("1011032", "三角洲行动"), ("1010045", "王者荣耀"), ("1010014", "英雄联盟"),
        ("1010032", "和平精英"), ("1010037", "穿越火线"), ("1010026", "绝地求生"), ("1010146", "QQ飞车端游"),
    ].map { DYLiveZone(id: $0.0, type: "1", name: $0.1) }
}

private struct DYFeedPage: Decodable { let status: Int; let items: [DYAweme]; let hasMore: Bool; let msg: String?; var diag: String? = nil }
private struct DYCommentPage: Decodable { let status: Int; let items: [DYComment]; let cursor: Int; let hasMore: Bool; let total: Int; let msg: String? }

enum DYError: LocalizedError {
    case notReady, blocked(String), bad(String)
    var errorDescription: String? {
        switch self {
        case .notReady: "抖音页面还没加载好"
        case .blocked(let m): "抖音拦截了请求（\(m)），在「网页版」里过一下验证或登录后重试"
        case .bad(let m): m
        }
    }
}

// MARK: - 签名代理（隐藏网页）

@MainActor
final class DouyinBridge: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var ready = false
    /// 只在 `reload` 推进。界面用它清掉上一账号的关注直播，不代表登录态本身。
    @Published private(set) var followSession = 0
    @Published private(set) var authorFollowStates: [String: Bool] = [:]

    func rememberFollow(_ author: DYAweme.Author, followed: Bool) {
        if let sec = author.secUid, !sec.isEmpty { authorFollowStates[sec] = followed }
        if let uid = author.uid, !uid.isEmpty { authorFollowStates[uid] = followed }
    }
    let web: WKWebView
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    private let startURL: URL
    private var liveContext: DouyinBridge?

    override convenience init() {
        self.init(startURL: URL(string: "https://www.douyin.com/jingxuan")!)
    }

    init(startURL: URL) {
        self.startURL = startURL
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        // 隐藏签名页只要接口，不要视频：⚠️ 不能设 allowsInlineMediaPlayback=false——
        // 抖音页自动播放时会弹系统全屏播放器盖住整个原生界面（UI 测试实测）。改成允许内联 + 脚本禁掉所有媒体播放
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = false
        cfg.userContentController.addUserScript(WKUserScript(source: Self.noMediaJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), configuration: cfg)
        web.customUserAgent = DouyinWeb.userAgent
        super.init()
        web.navigationDelegate = self
        reload()
    }

    func reload() {
        #if DEBUG
        // Layout fixtures must not bootstrap the live website or share its request budget.
        if ProcessInfo.processInfo.environment["DOUDUO_HASHTAG_FIXTURE"] == "1" {
            ready = true
            return
        }
        #endif
        authorFollowStates = [:]
        followSessionCache.invalidate()
        followSession = followSessionCache.generation
        ready = false
        web.load(URLRequest(url: startURL))
        liveContext?.reload()
    }

    /// 直播专区请求在 live.douyin.com 的网页 SDK 中发出，共享真实登录态，避免跨域签名/请求被拒。
    private func callLive(_ body: String, args: [String: Any]) async throws -> Data {
        if liveContext == nil {
            let context = DouyinBridge(startURL: URL(string: "https://live.douyin.com/")!)
            context.web.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
            web.superview?.addSubview(context.web)
            liveContext = context
        }
        guard let context = liveContext, context.web.superview != nil else { throw DYError.notReady }
        return try await context.call(body, args: args, attempts: 1)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 安全 SDK 在 load 之后还要初始化一小会儿
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.ready = true
            self.readyWaiters.forEach { $0.resume() }
            self.readyWaiters.removeAll()
            // 签名 SDK 完全挂好（XHR + fetch 都被接管）后再把整页 DOM 清空：隐藏页面不再持续渲染
            // （真机上 WebContent 曾占约 43% 一个核，手机发烫）。
            // 以前固定 1.2 秒就清：SDK 的 fetch 挂钩还没装上就被清掉，之后评论 POST 一律 200 空回执（发不出去）。
            Task { @MainActor in
                #if DEBUG
                if ProcessInfo.processInfo.environment["DOUDUO_HOOKPROBE"] == "1" {
                    DYLiveModel.log("DDHOOK start \(await self.writeHookState())")
                    if self.startURL.host == "www.douyin.com", !Self.hookProbeStarted {
                        Self.hookProbeStarted = true
                        Task { @MainActor in try? await Task.sleep(nanoseconds: 3_000_000_000); _ = await self.ensureWriteReady() }
                    }
                }
                #endif
                let hooked = await self.waitWriteHooks(seconds: 10)
                let state = await self.writeHookState()
                self.web.evaluateJavaScript(Self.quietPageJS) { r, _ in
                    DYLiveModel.log("DDQUIET \(r.map { String(describing: $0) } ?? "nil") hooked=\(hooked) \(state) \(self.startURL.host ?? "")")
                }
            }
        }
    }

    #if DEBUG
    private static var hookProbeStarted = false
    #endif

    /// 页面安全 SDK 是否已同时接管 XHR 和 fetch（写接口签名靠它）
    private static let hookStateJS = #"""
    (() => { const n = f => { try { return !/native code/.test(f().toString()) } catch (e) { return false } };
      return 'a' + (typeof window.byted_acrawler !== 'undefined' ? 1 : 0) + 'x' + (n(() => XMLHttpRequest.prototype.send) ? 1 : 0)
        + 'f' + (n(() => window.fetch) ? 1 : 0); })()
    """#

    /// a1x1f1 = SDK 对象在、XHR 与 fetch 都已被接管
    func writeHookState() async -> String {
        ((try? await web.evaluateJavaScript(Self.hookStateJS)) as? String) ?? "?"
    }

    func writeHooksReady() async -> Bool { await writeHookState() == "a1x1f1" }

    @discardableResult
    func waitWriteHooks(seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await writeHooksReady() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// 写操作（发评论）前确认签名页完整：抖音安全 SDK 在 WKWebView 里每次加载不一定把 fetch 挂钩装上，
    /// 没装上的那一轮发评论会被抖音 200 空回执静默丢弃（真机日志：成功的发送全是 fetchHooked=true，失败的全是 false）。
    /// 这里只在发送前检查，没装全就重开签名页再等，最多 3 轮；不会重发已经发出的请求，所以不会重复评论。
    @discardableResult
    func ensureWriteReady() async -> Bool {
        await waitReady()
        if await waitWriteHooks(seconds: 2) { return true }
        for round in 1...3 {
            DYLiveModel.log("DDSEND rearm round=\(round) state=\(await writeHookState())")
            // 只重开签名页本身：不动直播页、不清关注缓存（reload() 会让界面以为换了账号）
            ready = false
            web.load(URLRequest(url: startURL))
            await waitReady()
            if await waitWriteHooks(seconds: 8) {
                DYLiveModel.log("DDSEND rearm ok round=\(round)")
                return true
            }
        }
        DYLiveModel.log("DDSEND rearm gave-up state=\(await writeHookState())")
        return false
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let s = action.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob", "data"].contains(s) ? .allow : .cancel)
    }

    private func waitReady() async {
        if ready { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    /// 在抖音页面里发请求（页面 SDK 自动签名），JS 端把大 JSON 裁成精简结构再回传
    func call(_ body: String, args: [String: Any], attempts: Int = 3) async throws -> Data {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_HASHTAG_FIXTURE"] == "1" {
            throw DYError.bad("本地标签回归已禁用网络请求")
        }
        #endif
        await waitReady()
        var lastErr: Error = DYError.notReady
        for attempt in 0..<attempts {
            do {
                // 大响应（如消息列表 ~150KB）冷网络下求值慢，失败时记录真实错误码便于定位
                let r = try await web.callAsyncJavaScript(Self.requestJS + body, arguments: args, contentWorld: .page)
                guard let s = r as? String, let d = s.data(using: .utf8) else { throw DYError.bad("返回为空") }
                return d
            } catch {
                lastErr = error
                #if DEBUG
                DYLiveModel.log("DDCALL err code=\(String(describing: (error as? WKError)?.code)) \(error.localizedDescription) attempt=\(attempt)")
                #endif
                try? await Task.sleep(nanoseconds: UInt64(600_000_000 * (attempt + 1)))
            }
        }
        throw lastErr
    }

    private var refreshIndex = 1
    /// 首次安装时间要固定：以前每次请求都用「现在-15分钟」，服务端会当成刚装的新设备，推荐偏冷启动内容
    static let installTime: Int = {
        let k = "douyin_install_time_v1"
        let v = UserDefaults.standard.integer(forKey: k)
        if v > 0 { return v }
        let now = Int(Date().timeIntervalSince1970)
        UserDefaults.standard.set(now, forKey: k)
        return now
    }()

    /// 观看上报：跟网页版一样，起播时报播放(aweme/stats)、登录时写观看历史(history/write)。
    /// 不上报，账号就学不到你在DouDuo里看了什么，推荐会和 App 越走越远。
    func reportWatch(_ a: DYAweme, preID: String?, preSeen: Bool) async {
        let d = try? await call(Self.watchJS, args: [
            "id": a.id, "type": String(a.awemeType ?? 0), "author": a.author.uid ?? "",
            "pre": preID ?? "", "seen": preSeen ? "1" : "0"], attempts: 1)
        #if DEBUG
        DYLiveModel.log("DDWATCH \(a.id) \(d.flatMap { String(data: $0, encoding: .utf8) } ?? "fail")")
        #endif
    }
    /// 自己的 sec_uid（拉「喜欢」列表要用）
    var selfSecCache: String?

    private static let noMediaJS = """
    (() => {
      const P = HTMLMediaElement.prototype;
      P.play = function () { try { this.muted = true; this.pause(); } catch (e) {} return Promise.resolve(); };
      const V = HTMLVideoElement.prototype;
      // 签名页绝不能占用原生全屏播放器；部分网站会直接请求全屏而不调用 play()。
      V.webkitEnterFullscreen = V.webkitEnterFullScreen = function () {};
      for (const key of ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']) {
        Element.prototype[key] = function () { return Promise.resolve(); };
      }
      const kill = () => document.querySelectorAll('video,audio').forEach(v => { try {
        v.muted = true; v.pause(); v.removeAttribute('autoplay'); v.preload = 'none';
        v.playsInline = true; v.setAttribute('playsinline', ''); v.setAttribute('webkit-playsinline', '');
      } catch (e) {} });
      const observe = () => {
        kill();
        if (document.documentElement) new MutationObserver(kill).observe(document.documentElement, { childList: true, subtree: true });
      };
      document.addEventListener('DOMContentLoaded', observe);
      if (document.documentElement) observe();
    })();
    """

    func fetchFeed() async throws -> (items: [DYAweme], hasMore: Bool) {
        refreshIndex += 1
        let args: [String: Any] = ["refresh": String(refreshIndex), "install": String(Self.installTime),
                                   "pull": refreshIndex <= 2 ? "0" : "2"]
        let p = try JSONDecoder().decode(DYFeedPage.self, from: try await call(Self.tabFeedJS, args: args))
        DYLiveModel.log("DDFEED idx=\(refreshIndex) \(p.diag ?? "-") more=\(p.hasMore) msg=\(p.msg ?? "-")")
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        if p.items.isEmpty, let m = p.msg, !m.isEmpty { throw DYError.blocked(m) }
        return (p.items, p.hasMore)
    }

    /// 真点赞（走网页端同一个接口，页面 SDK 自动签名）
    func digg(_ id: String, like: Bool) async throws -> DYActionResult {
        let d = try await call(Self.diggJS, args: ["id": id, "type": like ? "1" : "0"])
        let r = try JSONDecoder().decode(DYActionResp.self, from: d)
        #if DEBUG
        ddWrite("DDACT digg id=\(id) like=\(like) status=\(r.status) code=\(r.statusCode ?? -1) msg=\(r.msg ?? "-")")
        #endif
        return Self.interpret(r)
    }

    /// 不感兴趣：网页版同一个接口（commit/dislike/item），抖音据此减少同类推荐
    func dislike(_ id: String) async throws -> DYActionResult {
        let d = try await call(Self.dislikeJS, args: ["id": id], attempts: 2)
        let r = try JSONDecoder().decode(DYActionResp.self, from: d)
        #if DEBUG
        ddWrite("DDACT dislike id=\(id) status=\(r.status) code=\(r.statusCode ?? -1) msg=\(r.msg ?? "-")")
        #endif
        return Self.interpret(r)
    }

    /// 统一解读：status_code 8 = 用户未登录；0 = 成功
    private static func interpret(_ r: DYActionResp) -> DYActionResult {
        if r.status == 200, (r.statusCode ?? 0) == 0 { return .ok }
        if r.statusCode == 8 || (r.msg ?? "").contains("未登录") { return .notLoggedIn }
        return .failed(r.msg?.isEmpty == false ? r.msg! : "HTTP \(r.status) / code \(r.statusCode ?? -1)")
    }

    /// 真收藏 / 取消收藏
    func favorite(_ id: String, add: Bool) async throws -> DYActionResult {
        #if DEBUG
        ddWrite("DDACT fav start id=\(id) add=\(add)")
        #endif
        let d = try await call(Self.favJS, args: ["id": id, "action": add ? "1" : "0"])
        #if DEBUG
        ddWrite("DDACT fav raw \(String(data: d, encoding: .utf8)?.prefix(200) ?? "-")")
        #endif
        let r = try JSONDecoder().decode(DYActionResp.self, from: d)
        #if DEBUG
        ddWrite("DDACT fav id=\(id) add=\(add) status=\(r.status) code=\(r.statusCode ?? -1) msg=\(r.msg ?? "-")")
        #endif
        return Self.interpret(r)
    }

    #if DEBUG
    /// 模拟器扫码登录：直接走抖音 SSO 的二维码接口，二维码存 Documents/qr.png，扫完自动跳 redirect 落 cookie
    func debugQRLogin() async {
        await waitReady()
        let getJS = #"""
        const r = await fetch('https://sso.douyin.com/get_qrcode/?service=' + encodeURIComponent('https://www.douyin.com') + '&need_logo=false&need_short_url=false&aid=6383&account_sdk_source=sso&language=zh', { credentials: 'include' });
        const t = await r.text();
        return t;
        """#
        guard let raw = try? await web.callAsyncJavaScript(getJS, arguments: [:], contentWorld: .page) as? String,
              let d = raw.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let data = j["data"] as? [String: Any],
              let b64 = data["qrcode"] as? String, let token = data["token"] as? String,
              let png = Data(base64Encoded: b64) else {
            DYLiveModel.log("DDQR get 失败 \((try? await web.callAsyncJavaScript(getJS, arguments: [:], contentWorld: .page)) as? String ?? "nil")")
            return
        }
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("qr.png")
        try? png.write(to: u)
        DYLiveModel.log("DDQR 二维码已生成 token=\(token.prefix(8))")
        let checkJS = #"""
        const r = await fetch('https://sso.douyin.com/check_qrconnect/?service=' + encodeURIComponent('https://www.douyin.com') + '&token=' + token + '&need_logo=false&aid=6383&account_sdk_source=sso&language=zh', { credentials: 'include' });
        return await r.text();
        """#
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let s = try? await web.callAsyncJavaScript(checkJS, arguments: ["token": token], contentWorld: .page) as? String,
                  let cd = s.data(using: .utf8), let cj = try? JSONSerialization.jsonObject(with: cd) as? [String: Any],
                  let dd = cj["data"] as? [String: Any] else { continue }
            let st = "\(dd["status"] ?? "?")"
            DYLiveModel.log("DDQR status=\(st)")
            if let redirect = dd["redirect_url"] as? String, let ru = URL(string: redirect), !redirect.isEmpty {
                DYLiveModel.log("DDQR 已确认，跳转落 cookie")
                web.load(URLRequest(url: ru))
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                reload()
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if let me = try? await selfProfile() { DYLiveModel.log("DDQR 登录成功 \(me.name)") }
                else { DYLiveModel.log("DDQR 跳转后仍未登录") }
                return
            }
            if st == "5" || st == "4" { DYLiveModel.log("DDQR 二维码过期"); return }
        }
    }

    /// 调试：把真机登录态导出 / 导入到模拟器（只在 DEBUG，本机两台设备之间搬，不上传）
    func debugExportCookies() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cs = await store.allCookies().filter { $0.domain.contains("douyin") }
        let arr: [[String: Any]] = cs.map { c in
            var p: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path,
                                    "secure": c.isSecure, "httpOnly": c.isHTTPOnly]
            if let e = c.expiresDate { p["expires"] = e.timeIntervalSince1970 }
            return p
        }
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dd-cookies.json")
        if let d = try? JSONSerialization.data(withJSONObject: arr) { try? d.write(to: u) }
        DYLiveModel.log("DDCK export \(arr.count) sessionid=\(cs.contains { $0.name == "sessionid" })")
    }

    func debugImportCookies() async {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dd-cookies.json")
        guard let d = try? Data(contentsOf: u), let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else {
            DYLiveModel.log("DDCK import 没有文件"); return
        }
        let store = WKWebsiteDataStore.default().httpCookieStore
        var n = 0
        for p in arr {
            var props: [HTTPCookiePropertyKey: Any] = [.name: p["name"] ?? "", .value: p["value"] ?? "",
                                                      .domain: p["domain"] ?? "", .path: p["path"] ?? "/"]
            if (p["secure"] as? Bool) == true { props[.secure] = "TRUE" }
            if (p["httpOnly"] as? Bool) == true { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let e = p["expires"] as? Double { props[.expires] = Date(timeIntervalSince1970: e) }
            if let c = HTTPCookie(properties: props) { await store.setCookie(c); n += 1 }
        }
        try? FileManager.default.removeItem(at: u)
        DYLiveModel.log("DDCK import \(n)")
        reload()
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        if let me = try? await selfProfile() { DYLiveModel.log("DDCK 登录成功 \(me.name)") } else { DYLiveModel.log("DDCK 导入后仍未登录") }
    }

    /// 探针：在签名页里跑一段 JS（可用 req/base/parse/first），返回字符串
    func probe(_ body: String) async -> String {
        (try? await call(body, args: [:])).flatMap { String(data: $0, encoding: .utf8) } ?? "ERR"
    }
    #endif

    /// 是否已登录（登录后推荐流才跟着账号走）
    func isLoggedIn() async -> Bool {
        let r = try? await web.callAsyncJavaScript(Self.loginJS, arguments: [:], contentWorld: .page)
        let s = (r as? String) ?? ""
        #if DEBUG
        ddWrite("DDACT login check -> \(s)")
        #endif
        return s.contains("sessionid") || s == "1"
    }

    /// insert：要「插到最前」的评论 cid（逗号分隔，一级评论在前、楼中楼在后）。网页从消息点评论跳视频就是这么定位的，
    /// 实测传楼中楼 cid 时会把它的一级评论顶到第一条，并把那条回复放进 reply_comment。
    func fetchComments(_ id: String, cursor: Int, insert: String? = nil) async throws -> (items: [DYComment], cursor: Int, hasMore: Bool, total: Int) {
        let d = try await call(Self.commentJS, args: ["id": id, "cursor": String(cursor), "ins": insert ?? ""])
        let p = try JSONDecoder().decode(DYCommentPage.self, from: d)
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        let withImg = p.items.filter { !($0.images ?? []).isEmpty }.count
        let withStk = p.items.filter { $0.sticker != nil }.count
        if withImg + withStk > 0 { DYLiveModel.log("DDCOMMENTIMG aweme=\(id) n=\(p.items.count) images=\(withImg) stickers=\(withStk)") }
        return (p.items, p.cursor, p.hasMore, p.total)
    }

    private var liveMaxTime = "0"
    private var liveOffset = 0
    private var liveCursorGeneration = UUID()

    /// 关注的主播里正在直播的。列表只带展示信息；播放地址等选中单个主播再解析。
    func fetchFollowLive() async throws -> [DYLiveRoom] {
        let result = await followLiveResult()
        switch result.kind {
        case .rooms:
            return result.items
        case .nobodyLive, .filtered:
            return []
        case .notLoggedIn:
            throw DYError.blocked("HTTP 401")
        case .decodeFailed, .unexpectedShape:
            throw DYError.bad("直播数据无法解析")
        case .requestFailed:
            throw DYError.blocked(result.status == 200 ? "连接失败" : "HTTP \(result.status)")
        }
    }

    /// 同一次关注直播请求的分类结果。空列表不会一律当成没人直播。
    /// `ignoreCache` 用于手动刷新。15 秒内的缓存只有主播信息，没有播放地址。
    func followLiveResult(ignoreCache: Bool = false) async -> DYFollowLiveResult {
        let generation = followSessionCache.generation
        if !ignoreCache, let cached = followSessionCache.cachedItems(now: Date()) {
            let rooms = DYFollowLiveIdentity.unique(cached.map { DYLiveRoom($0) }, id: \.id, webRid: \.webRid)
            DYLiveModel.log("DDFOLLOWLIVE outcome=rooms source=cache n=\(rooms.count) listRequests=0 detailRequests=0")
            return DYFollowLiveResult(kind: .rooms, items: rooms, status: 200, stats: nil, fromCache: true)
        }
        let joining = followSessionCache.beginList(generation: generation)
        let epoch = followSessionCache.listEpoch
        if joining, let followLiveTask {
            let result = await followLiveTask.value
            return scopedFollowResult(result, generation: generation, epoch: epoch)
        }
        followLiveTicket += 1
        let ticket = followLiveTicket
        let task = Task { await self.performFollowLive(generation: generation, epoch: epoch) }
        followLiveTask = task
        let result = await task.value
        if followLiveTicket == ticket {
            followLiveTask = nil
            followSessionCache.finishList(generation: generation)
        }
        return scopedFollowResult(result, generation: generation, epoch: epoch)
    }

    /// 只解析当前这一间。已有可播地址时不再请求。同一个 webRid、同一代际的进行中请求会合并。
    func resolveFollowRoom(webRid: String) async -> DYFollowLiveResult {
        let generation = followSessionCache.generation
        let epoch = followSessionCache.listEpoch
        let result: DYFollowLiveResult
        if followSessionCache.beginRoom(webRid: webRid), let current = followRoomTask, current.rid == webRid {
            result = await current.task.value
        } else {
            followRoomTicket += 1
            let ticket = followRoomTicket
            let task = Task { await self.performFollowRoom(webRid) }
            followRoomTask = (webRid, ticket, task)
            result = await task.value
            if followRoomTask?.ticket == ticket {
                followRoomTask = nil
                followSessionCache.finishRoom(webRid: webRid, generation: generation)
            }
        }
        if result.kind == .notLoggedIn {
            followSessionCache.noteNotLoggedIn(generation: generation, epoch: epoch)
        }
        return scopedFollowResult(result, generation: generation, epoch: epoch)
    }

    private var followLiveTask: Task<DYFollowLiveResult, Never>?
    private var followLiveTicket = 0
    private var followSessionCache = DYFollowSessionCache(ttl: 15)
    private var followRoomTask: (rid: String, ticket: Int, task: Task<DYFollowLiveResult, Never>)?
    private var followRoomTicket = 0

    private func scopedFollowResult(_ result: DYFollowLiveResult, generation: Int, epoch: Int) -> DYFollowLiveResult {
        if result.kind == .notLoggedIn, followSessionCache.generation == generation, followSessionCache.listEpoch == epoch {
            var visible = result
            visible.items = []
            visible.stale = false
            return visible
        }
        guard followSessionCache.accepts(generation: generation, epoch: epoch) else {
            var hidden = result
            hidden.items = []
            hidden.stale = true
            return hidden
        }
        return result
    }

    private func performFollowLive(generation: Int, epoch: Int) async -> DYFollowLiveResult {
        let started = ProcessInfo.processInfo.systemUptime
        let data: Data
        do { data = try await call(DYFollowLiveScripts.list, args: [:], attempts: 2) }
        catch {
            DYLiveModel.log("DDFOLLOWLIVE outcome=request_failed listRequests=1 detailRequests=0 elapsed=\(Self.elapsed(since: started))")
            return DYFollowLiveResult(kind: .requestFailed, items: [], status: -1, stats: nil)
        }
        do {
            let page = try JSONDecoder().decode(DYFollowLivePayload.self, from: data)
            let items = DYFollowLiveIdentity.unique(page.items, id: \.id, webRid: \.webRid)
            let kind = DYFollowLiveClassify.kind(status: page.status, itemCount: items.count, stats: page.stats)
            let stats = page.stats
            if kind == .rooms, !items.isEmpty {
                followSessionCache.store(items: items.map(\.followMetadata), generation: generation, epoch: epoch, now: Date())
            } else if kind == .notLoggedIn {
                followSessionCache.noteNotLoggedIn(generation: generation, epoch: epoch)
            }
            DYLiveModel.log("DDFOLLOWLIVE outcome=\(kind.rawValue) status=\(page.status) http=\(stats?.http ?? -1) code=\(stats?.code.map(String.init) ?? "-") list=\(stats?.list ?? -1) kept=\(items.count) dropped=\(stats?.dropped ?? -1) listRequests=1 detailRequests=0 elapsed=\(Self.elapsed(since: started))")
            return DYFollowLiveResult(kind: kind, items: kind == .rooms ? items : [], status: page.status, stats: stats)
        } catch {
            DYLiveModel.log("DDFOLLOWLIVE outcome=decode_failed listRequests=1 detailRequests=0 elapsed=\(Self.elapsed(since: started))")
            return DYFollowLiveResult(kind: .decodeFailed, items: [], status: -1, stats: nil)
        }
    }

    private func performFollowRoom(_ webRid: String) async -> DYFollowLiveResult {
        let started = ProcessInfo.processInfo.systemUptime
        let data: Data
        do { data = try await call(DYFollowLiveScripts.room, args: ["rid": webRid], attempts: 1) }
        catch {
            DYLiveModel.log("DDFOLLOWROOM outcome=request_failed detailRequests=1 elapsed=\(Self.elapsed(since: started))")
            return DYFollowLiveResult(kind: .requestFailed, items: [], status: -1, stats: nil)
        }
        do {
            let page = try JSONDecoder().decode(DYFollowLivePayload.self, from: data)
            let decoded = DYFollowLiveClassify.kind(status: page.status, itemCount: page.items.count, stats: page.stats)
            let playable = page.items.filter { !$0.liveStreams.isEmpty }
            let kind: DYFollowLiveKind = decoded == .rooms && playable.isEmpty ? .filtered : decoded
            DYLiveModel.log("DDFOLLOWROOM outcome=\(kind.rawValue) status=\(page.status) detailRequests=1 elapsed=\(Self.elapsed(since: started))")
            return DYFollowLiveResult(kind: kind, items: kind == .rooms ? playable : [], status: page.status, stats: page.stats)
        } catch {
            DYLiveModel.log("DDFOLLOWROOM outcome=decode_failed detailRequests=1 elapsed=\(Self.elapsed(since: started))")
            return DYFollowLiveResult(kind: .decodeFailed, items: [], status: -1, stats: nil)
        }
    }

    private static func elapsed(since started: TimeInterval) -> String {
        String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started)
    }

    func fetchLive(reset: Bool, zone: DYLiveZone? = nil) async throws -> [DYLiveRoom] {
        if reset { liveMaxTime = "0"; liveOffset = 0; liveCursorGeneration = UUID() }
        let generation = liveCursorGeneration
        if let zone {
            let d = try await callLive(Self.zoneJS, args: ["partition": zone.id, "ptype": zone.type, "offset": String(liveOffset)])
            guard liveCursorGeneration == generation else { return [] }
            let p = try JSONDecoder().decode(DYLiveResp.self, from: d)
            guard p.status == 200 else {
                throw DYError.bad("专区连接失败（HTTP \(p.status)），可打开网页版检查或返回推荐直播")
            }
            liveOffset += 15
            return p.items
        }
        let d = try await call(Self.liveJS, args: ["maxtime": liveMaxTime])
        guard liveCursorGeneration == generation else { return [] }
        let p = try JSONDecoder().decode(DYLiveResp.self, from: d)
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        liveMaxTime = String(Int(Date().timeIntervalSince1970))
        return p.items
    }

    // 直播专区（网页版 live.douyin.com/categorynew/4_103_1_<id> 同一接口）：一页 15 个，按 offset 翻页
    private static let zoneJS = #"""
    const P = { aid: '6383', app_name: 'douyin_web', live_id: '1', device_platform: 'web', language: 'zh-CN', enter_from: 'page_refresh',
      cookie_enabled: 'true', screen_width: '1440', screen_height: '900', browser_language: 'zh-CN', browser_platform: 'MacIntel',
      browser_name: 'Safari', browser_version: '26.0', os_name: 'Mac OS', os_version: '10.15.7',
      count: '15', offset: offset, partition: partition, partition_type: ptype, req_from: '2' };
    const r = await req('GET', 'https://live.douyin.com/webcast/web/partition/detail/room/v2/?' + new URLSearchParams(P).toString());
    const d = parse(r.t);
    const arr = d && d.data && Array.isArray(d.data.data) ? d.data.data : null;
    if (!arr) return JSON.stringify({ status: r.s === 200 ? 403 : r.s, items: [] });
    const items = arr.filter(it => it && it.room && it.room.stream_url).map(it => {
      const room = it.room, su = room.stream_url || {}, o = room.owner || {};
      return { id: String(room.id_str || room.id), webRid: String(it.web_rid || o.web_rid || ''), title: room.title || '',
        owner: o.nickname || '', avatar: first(o.avatar_thumb), cover: first(room.cover),
        viewers: (room.stats && room.stats.user_count_str) || room.user_count_str || (room.user_count ? String(room.user_count) : ''),
        hls: su.hls_pull_url_map || {}, flv: compatibleLiveFLV(su), portrait: su.stream_orientation !== 2, def: su.default_resolution || null };
    }).filter(x => Object.keys(x.hls).length > 0 || Object.keys(x.flv).length > 0);
    return JSON.stringify({ status: r.s, items });
    """#

    // 直播推荐：live.douyin.com/webcast/feed/（跨子域 XHR 同样被页面 SDK 签名，实测 200 / 20 条）
    private static let liveJS = #"""
    const P = { aid: '6383', app_name: 'douyin_web', live_id: '1', device_platform: 'web', language: 'zh-CN', enter_from: 'link_share',
      cookie_enabled: 'true', screen_width: '1440', screen_height: '900', browser_language: 'zh-CN', browser_platform: 'MacIntel',
      browser_name: 'Safari', browser_version: '26.0', os_name: 'Mac OS', os_version: '10.15.7', channel: 'channel_pc_web',
      request_tag_from: 'web', need_map: '1', liveid: '1', is_draw: '1', inner_from_drawer: '0', custom_count: '20',
      action: 'load_more', action_type: 'loadmore', enter_source: 'web_homepage_hot_web_live_card',
      source_key: 'web_homepage_hot_web_live_card', is_ssr: 'true', maxtime: maxtime };
    const r = await req('GET', 'https://live.douyin.com/webcast/feed/?' + new URLSearchParams(P).toString());
    const d = parse(r.t);
    if (!d || !Array.isArray(d.data)) return JSON.stringify({ status: r.s === 200 ? 403 : r.s, items: [] });
    const items = d.data.filter(it => it && it.type === 1 && it.data && it.data.stream_url).map(it => {
      const room = it.data, su = room.stream_url || {}, o = room.owner || {};
      return { id: String(room.id_str || room.id), webRid: String(it.web_rid || o.web_rid || ''), title: room.title || '',
        owner: o.nickname || '', avatar: first(o.avatar_thumb), cover: first(room.cover),
        viewers: (room.stats && room.stats.user_count_str) || room.user_count_str || '',
        hls: su.hls_pull_url_map || {}, flv: compatibleLiveFLV(su), portrait: su.stream_orientation !== 2, def: su.default_resolution || null };
    }).filter(x => Object.keys(x.hls).length > 0 || Object.keys(x.flv).length > 0);
    return JSON.stringify({ status: r.s, items });
    """#

    private static let diggJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const P = Object.assign({}, base, { aweme_id: id, type: type, item_type: '0' });
    const u = '/aweme/v1/web/commit/item/digg/?' + new URLSearchParams(P).toString();
    const r = await req('POST', u, '');
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code, msg: d.status_msg || (r.s === 200 ? '' : r.t.slice(0, 120)) });
    """#

    private static let dislikeJS = #"""
    const r = await req('POST', '/aweme/v1/web/commit/dislike/item/?' + q({ aweme_id: id }),
      new URLSearchParams({ aweme_id: id }).toString());
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code, msg: d.status_msg || (r.s === 200 ? '' : (r.t || '').slice(0, 120)) });
    """#

    private static let favJS = #"""
    const P = Object.assign({}, base, { aweme_id: id, action: action });
    const tries = ['/aweme/v1/web/commit/item/collect/', '/aweme/v1/web/aweme/collect/'];
    let last = { status: -1 };
    for (const u of tries) {
      const r = await req('POST', u + '?' + new URLSearchParams(P).toString(), '');
      const d = parse(r.t) || {};
      if (r.s === 200 && (d.status_code === 0 || d.status_code === undefined)) return JSON.stringify({ status: 200, statusCode: 0 });
      last = { status: r.s, statusCode: d.status_code, msg: (d.status_msg || r.t.slice(0, 120)) };
    }
    return JSON.stringify(last);
    """#

    /// SDK 就绪后清空隐藏页：停媒体、清 body 与样式表，之后新增元素（脚本除外）也移除。
    /// 清空后签名请求照常（热搜、观看上报、作品列表都验证过）。
    private static let quietPageJS = #"""
    (() => { try {
      document.querySelectorAll('video,audio').forEach(v => { try { v.pause(); v.removeAttribute('src'); v.load(); } catch (e) {} });
      if (document.body) {
        document.body.replaceChildren();
        new MutationObserver(ms => ms.forEach(m => m.addedNodes.forEach(n => { if (n.nodeType === 1 && n.tagName !== 'SCRIPT' && n.tagName !== 'IFRAME') n.remove(); })))
          .observe(document.body, { childList: true });
      }
      document.querySelectorAll('style,link[rel=stylesheet]').forEach(e => e.remove());
      return 'quiet';
    } catch (e) { return 'err ' + e; } })()
    """#

    private static let loginJS = #"""
    return (document.cookie || '').includes('sessionid') ? 'sessionid' : '0';
    """#

    // 共用：在页面世界里发 XHR（被抖音 SDK hook，自动加签名）
    static let requestJS = #"""
    // VLCKit 3 能播 AVC-FLV，但部分 HEVC-FLV 会一直等首帧；先读网页 SDK 明确给出的编码，不能盲试 6 秒。
    const compatibleLiveFLV = su => {
      const raw = su.live_core_sdk_data && su.live_core_sdk_data.pull_data && su.live_core_sdk_data.pull_data.stream_data;
      const sdk = typeof raw === 'string' ? parse(raw) : raw;
      const streams = [];
      for (const [name, group] of Object.entries((sdk && sdk.data) || {})) {
        if (name === 'ao') continue; // ao 是纯音频，不能拿它的 h264 标记判定同路径视频流。
        for (const stream of Object.values(group || {})) {
          if (!stream || !stream.flv || stream.enableEncryption) continue;
          const params = typeof stream.sdk_params === 'string' ? parse(stream.sdk_params) : stream.sdk_params;
          const codec = String((params && params.VCodec) || '').toLowerCase();
          if ((codec === 'h264' || codec === 'avc') && Number(params.vbitrate) > 0) streams.push(stream.flv);
        }
      }
      const urls = new Set(streams);
      return Object.fromEntries(Object.entries(su.flv_pull_url || {}).filter(([_, u]) => urls.has(u)));
    };
    const req = (method, path, body) => new Promise(ok => {
      const x = new XMLHttpRequest();
      let done = false;
      const fin = r => { if (!done) { done = true; ok(r) } };
      x.timeout = 12000;
      x.ontimeout = () => fin({ s: -2, t: '' });
      // 硬超时：页面安全 SDK 会接管 XHR，部分接口它压着不放、x.timeout 也不触发 → Promise 永远挂死
      setTimeout(() => { try { x.abort() } catch (e) {} fin({ s: -3, t: '' }) }, 14000);
      x.open(method, path); x.withCredentials = true;
      x.setRequestHeader('Accept', 'application/json, text/plain, */*');
      if (method === 'POST') x.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
      x.onload = () => fin({ s: x.status, t: x.responseText, u: String(x.responseURL || '') }); x.onerror = () => fin({ s: -1, t: '' });
      x.send(body || null);
    });
    const base = { device_platform: 'webapp', aid: '6383', channel: 'channel_pc_web', pc_client_type: '1', pc_libra_divert: 'Mac',
      update_version_code: '170400', support_h265: '1', support_dash: '0', version_code: '170400', version_name: '17.4.0',
      cookie_enabled: 'true', screen_width: '1440', screen_height: '900', browser_language: 'zh-CN', browser_platform: 'MacIntel',
      browser_name: 'Safari', browser_version: '26.0', browser_online: 'true', engine_name: 'WebKit', engine_version: '605.1.15',
      os_name: 'Mac OS', os_version: '10.15.7', cpu_core_num: '8', device_memory: '8', platform: 'PC', downlink: '10',
      effective_type: '4g', round_trip_time: '50' };
    const parse = t => { try { return JSON.parse(t) } catch (e) { return null } };
    // 抖音安全 SDK 在 load 之后还要一会儿才接管 XHR；没接管就发写请求会不带 a_bogus 签名，
    // 服务端直接丢弃（200 空 body 或 403），而读接口不受影响。写接口一律先等它就绪。
    const sdkReady = async (ms) => {
      const t0 = Date.now();
      while (Date.now() - t0 < (ms || 6000)) {
        let hooked = false;
        try { hooked = !/native code/.test(XMLHttpRequest.prototype.send.toString()) && !/native code/.test(window.fetch.toString()) } catch (e) {}
        if (typeof window.byted_acrawler !== 'undefined' && hooked) return true;
        await new Promise(r => setTimeout(r, 150));
      }
      return false;
    };
    const first = o => (o && o.url_list && o.url_list[0]) || null;
    const q = s => new URLSearchParams(Object.assign({}, base, s)).toString();
    // 直连 CDN（douyinvod）优先：实测首字节 0.27–0.30s；www.douyin.com/aweme/v1/play/ 多跳一次 0.95–1.85s
    const pickPlay = l => (l || []).find(u => !u.includes('/aweme/v1/play/')) || (l && l[0]) || null;
    const pickRedirect = l => (l || []).find(u => u.includes('/aweme/v1/play/')) || null;
    // 清晰度：按「有效码率」挑最高一档（H.265 同码率约等于 H.264 的 1.4 倍），跳过弱网档
    const resOf = r => {
      const pa = r.play_addr || {}, w = pa.width || 0, h = pa.height || 0;
      if (w && h) return Math.min(w, h);
      const m = /_(\d{3,4})_/.exec(r.gear_name || ''); return m ? +m[1] : 0;
    };
    const bestRate = v => {
      const rs = (v.bit_rate || []).filter(r => r && r.play_addr && r.play_addr.url_list && r.play_addr.url_list.length)
        .filter(r => !/adapt_lowest|lower/i.test(r.gear_name || ''));
      rs.sort((a, b) => ((b.bit_rate || 0) * (b.is_h265 ? 1.4 : 1)) - ((a.bit_rate || 0) * (a.is_h265 ? 1.4 : 1)));
      return rs[0] || null;
    };
    const fastRate = v => {
      const rs = (v.bit_rate || []).filter(r => r && r.play_addr && r.play_addr.url_list && r.play_addr.url_list.length && resOf(r) >= 540);
      rs.sort((a, b) => (a.bit_rate || 0) - (b.bit_rate || 0));
      return rs[0] || null;
    };
    // 抖音作品 → 精简结构（推荐 / 关注 / 搜索 / 喜欢 / 收藏 / 历史 / 作品 共用）
    const mapA = a => {
      const v = a.video || {}, urls = (v.play_addr && v.play_addr.url_list) || [];
      const st = a.statistics || {};
      const def = pickPlay(urls), br = bestRate(v), best = br ? pickPlay(br.play_addr.url_list) : null;
      const fr = fastRate(v), fast = fr ? pickPlay(fr.play_addr.url_list) : null;
      const pd = v.play_addr || {};
      return {
        id: String(a.aweme_id), desc: a.desc || '',
        hashtagNames: [...new Set([...(a.text_extra || []).map(t => t.hashtag_name), ...(a.cha_list || []).map(t => t.cha_name)].filter(t => typeof t === 'string' && t.trim()))], width: v.width || 0, height: v.height || 0, duration: (v.duration || 0) / 1000,
        play: best || def,
        playAlt: pickRedirect(br ? br.play_addr.url_list : urls) || (best && def && best !== def ? def : null),
        playFast: fast && fast !== (best || def) ? fast : null,
        q: (br ? (br.gear_name || '?') + ' ' + resOf(br) + 'p h265=' + (br.is_h265 ? 1 : 0) + ' ' + Math.round((br.bit_rate || 0) / 1000) + 'k' : 'nolist')
          + ' | def ' + (pd.width || 0) + 'x' + (pd.height || 0) + ' | gears ' + (v.bit_rate || []).map(r => (r.gear_name || '?') + ':' + Math.round((r.bit_rate || 0) / 1000) + 'k' + (r.is_h265 ? 'h' : '')).join(','),
        cover: first(v.cover) || first(v.origin_cover) || (a.images && a.images[0] && first(a.images[0])) || null,
        images: (a.images || []).map(i => first(i)).filter(Boolean),
        author: { name: (a.author && a.author.nickname) || '', avatar: a.author && first(a.author.avatar_thumb), secUid: a.author && a.author.sec_uid, uid: a.author && a.author.uid ? String(a.author.uid) : null, follow: a.author ? (a.author.follow_status || 0) : 0 },
        awemeType: a.aweme_type || 0,
        publishedAt: typeof a.create_time === 'number' && Number.isFinite(a.create_time) && a.create_time > 0 ? a.create_time : null,
        aiDeclaration: a.risk_infos && typeof a.risk_infos.content === 'string' && /(?:\bAI\b|人工智能)/i.test(a.risk_infos.content) ? (a.risk_infos.content.trim() || null) : null,
        stats: { digg: st.digg_count || 0, comment: st.comment_count || 0, collect: st.collect_count || 0, share: st.share_count || 0, play: st.play_count == null ? null : Number(st.play_count) },
        music: (a.music && a.music.title) || '',
        userDigged: a.user_digged ? 1 : 0,
        isCollect: (a.is_collect || a.is_collected || (a.collect_stat === 1)) ? 1 : 0
      };
    };
    """#

    /// 推荐流：网页版首页「推荐」竖屏流（tab/feed）。
    /// 不用 module/feed（module_id=3003101）：那是网页「精选」，横屏长视频多、偏大众，跟 App 推荐差很远（2026-11 老板实测确认）。
    private static let tabFeedJS = #"""
    const P = Object.assign({}, base, { count: '10', refresh_index: refresh, video_type_select: '1',
      aweme_pc_rec_raw_data: JSON.stringify({ is_client: false, ff_danmaku_status: 0, danmaku_switch_status: 0 }),
      globalwid: '', pull_type: pull, min_window: '0', free_right: '0', ug_source: '', creative_id: '' });
    const r = await req('GET', '/aweme/v1/web/tab/feed/?' + new URLSearchParams(P).toString());
    const d = parse(r.t);
    if (!d) return JSON.stringify({ status: r.s, items: [], hasMore: false, msg: (r.t || '').replace(/[^\u4e00-\u9fa5A-Za-z0-9 ]/g, '').slice(-20),
      diag: 'tab s=' + r.s + ' signed=' + /a_bogus=/.test(r.u || '') + ' len=' + (r.t || '').length });
    const raw = d.aweme_list || [];
    const items = raw.filter(a => a && a.video && !a.is_ads && !(a.raw_ad_data)).map(mapA);
    const tall = raw.filter(a => a && a.video && a.video.height > a.video.width * 1.05).length;
    const fol = raw.filter(a => a && a.author && a.author.follow_status).length;
    return JSON.stringify({ status: r.s, items, hasMore: !!d.has_more, msg: d.status_msg || null,
      diag: 'tab s=' + r.s + ' code=' + d.status_code + ' signed=' + /a_bogus=/.test(r.u || '') + ' raw=' + raw.length + ' kept=' + items.length + ' tall=' + tall + ' follow=' + fol });
    """#


    private static let watchJS = #"""
    const s = await req('POST', '/aweme/v2/web/aweme/stats/?' + q({}),
      new URLSearchParams({ aweme_type: type, item_id: id, source: '0', play_delta: '1' }).toString());
    const ds = parse(s.t) || {};
    let h = { s: 0 }, dh = {};
    if (author) {
      h = await req('POST', '/aweme/v1/web/history/write/?' + q({}),
        new URLSearchParams({ aweme_id: id, author_id: author, pre_item_seen: seen, pre_item_id: pre }).toString());
      dh = parse(h.t) || {};
    }
    return JSON.stringify({ stats: [s.s, ds.status_code], history: [h.s, dh.status_code] });
    """#

    private static let commentJS = #"""
    const P = Object.assign({}, base, { aweme_id: id, cursor: cursor, count: '20', item_type: '0', whale_cut_token: '', cut_version: '1', rcFT: '' });
    if (ins) P.insert_ids = ins;
    const r = await req('GET', '/aweme/v1/web/comment/list/?' + new URLSearchParams(P).toString());
    const d = parse(r.t);
    if (!d) return JSON.stringify({ status: r.s, items: [], cursor: 0, hasMore: false, total: 0, msg: 'blocked' });
    const ddImg = o => { const u = o && o.url_list && o.url_list[0]; return u ? { u, w: o.width || 0, h: o.height || 0 } : null; };
    const ddImages = c => (c.image_list || []).map(x => {
      const m = ddImg(x.medium_url) || ddImg(x.thumb_url) || ddImg(x.crop_url) || ddImg(x.origin_url);
      const o = ddImg(x.origin_url) || m;
      return m ? { thumb: m.u, full: o.u, w: o.w || m.w, h: o.h || m.h } : null;
    }).filter(Boolean);
    const ddSticker = c => {
      const s = c.sticker; if (!s) return null;
      const st = ddImg(s.static_url) || ddImg(s.animate_url); if (!st) return null;
      const an = ddImg(s.animate_url) || st;
      return { thumb: st.u, full: an.u, w: s.width || st.w, h: s.height || st.h };
    };
    const one = c => ({
      id: String(c.cid), text: c.text || '', name: (c.user && c.user.nickname) || '', avatar: c.user && first(c.user.avatar_thumb),
      digg: c.digg_count || 0, time: c.create_time || 0, replies: c.reply_comment_total || 0, ip: c.ip_label || null, userDigged: c.user_digged ? 1 : 0,
      images: ddImages(c), sticker: ddSticker(c),
      parent: (c.reply_id && String(c.reply_id) !== '0') ? String(c.reply_id) : null
    });
    // insert_ids 定位楼中楼时，那条回复挂在一级评论的 reply_comment 里
    const items = (d.comments || []).map(c => Object.assign(one(c), (ins && c.reply_comment && c.reply_comment.length) ? { pinned: c.reply_comment.map(r => Object.assign(one(r), { replies: 0 })) } : {}));
    return JSON.stringify({ status: r.s, items, cursor: d.cursor || 0, hasMore: !!d.has_more, total: d.total || 0, msg: null });
    """#
}

/// 隐藏网页要挂进窗口里，JS 定时器 / 网络才不被系统节流
private struct DouyinBridgeHost: UIViewRepresentable {
    let bridge: DouyinBridge
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.isUserInteractionEnabled = false
        v.accessibilityElementsHidden = true
        v.alpha = 0.01
        v.clipsToBounds = true
        bridge.web.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        v.addSubview(bridge.web)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct DYPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?
    let gravity: AVLayerVideoGravity
    /// 首帧出来前透明（露出封面），出来后填底色盖住封面——封面是 4:3 裁图，和视频比例不一致
    let readyFill: UIColor
    final class V: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var pl: AVPlayerLayer { layer as! AVPlayerLayer }
        var fill: UIColor = .clear
        private var obs: NSKeyValueObservation?
        func watch() {
            obs = pl.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] l, _ in
                let ready = l.isReadyForDisplay
                DispatchQueue.main.async { self?.backgroundColor = ready ? self?.fill : .clear }
            }
        }
    }
    func makeUIView(context: Context) -> V {
        let v = V(); v.isUserInteractionEnabled = false; v.fill = readyFill; v.watch(); return v
    }
    func updateUIView(_ v: V, context: Context) {
        v.fill = readyFill
        if v.pl.player !== player { v.pl.player = player }
        if v.pl.videoGravity != gravity { v.pl.videoGravity = gravity }
    }
}

// MARK: - 预加载（抖音同款：提前缓冲后面几条）

/// 当前条后面 N 条提前建好 AVPlayer 并缓冲开头几秒（不出声、不播放），滑到时页面直接接管 → 秒开。
/// 封面同时预取。窗口外的立即释放（硬解码会话有限，不能无限开）。
@MainActor
final class DYPreloader {
    static let ahead = 3   // 提前暖 3 条；微热降到 2、烫了 1
    private var players: [String: AVPlayer] = [:]
    private var handedOut: Set<String> = []
    private var obs: [String: NSKeyValueObservation] = [:]
    #if DEBUG
    var disabled = ProcessInfo.processInfo.environment["WUWEI_DEBUG_DOUYIN_NOPRELOAD"] == "1"
    #else
    let disabled = false
    #endif

    func update(_ items: [DYAweme], current index: Int) {
        guard !disabled, items.indices.contains(index) else { return }
        let th = ProcessInfo.processInfo.thermalState
        let ahead = th == .nominal ? Self.ahead : (th == .fair ? 2 : 1)
        let lo = index + 1, hi = min(items.count - 1, index + ahead)
        let window = lo <= hi ? Array(items[lo...hi]) : []
        let ids = Set(window.map(\.id))
        // 离开窗口的：释放没被领走的；已领走的只要离当前 ≥2 条就不再记账（页面已经销毁）
        for (id, p) in players where !ids.contains(id) { release(id, p) }
        let near = Set(items[max(0, index - 1)...min(items.count - 1, index + 1)].map(\.id))
        handedOut = handedOut.filter { near.contains($0) || ids.contains($0) }
        for a in window where players[a.id] == nil && !handedOut.contains(a.id) {
            guard a.images.isEmpty, let s = a.play, let url = URL(string: s) else {
                if let c = a.images.first.flatMap(URL.init(string:)) { Task { _ = await ImageCache.shared.load(c) } }
                continue
            }
            let asset = DYMedia.asset(DYVideoCache.localURL(a.id) ?? url)
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 6
            let p = AVPlayer(playerItem: item)
            p.isMuted = true
            p.automaticallyWaitsToMinimizeStalling = true
            players[a.id] = p
            DDAudioPreloadPool.shared.prewarm(id: a.id, asset: asset, item: item)
            // ready 后 preroll：把开头的数据和首帧解码好
            obs[a.id] = item.observe(\.status, options: [.new]) { [weak p] it, _ in
                guard it.status == .readyToPlay else { return }
                DispatchQueue.main.async { p?.preroll(atRate: 1) { _ in } }
            }
            if let c = a.cover.flatMap(URL.init(string:)) { Task { _ = await ImageCache.shared.load(c) } }
        }
    }

    /// 页面起播时来领；领走后由页面负责释放
    func take(_ id: String) -> AVPlayer? {
        guard let p = players.removeValue(forKey: id) else { return nil }
        obs.removeValue(forKey: id)?.invalidate()
        handedOut.insert(id)
        return p
    }

    func clear() {
        for (id, p) in players { release(id, p) }
        DDAudioPreloadPool.shared.clear()
        handedOut.removeAll()
    }

    private func release(_ id: String, _ p: AVPlayer) {
        obs.removeValue(forKey: id)?.invalidate()
        DDAudioPreloadPool.shared.discard(id: id)
        p.pause()
        p.replaceCurrentItem(with: nil)
        players[id] = nil
    }
}

// MARK: - 推荐流

@MainActor
final class DYFeedModel: ObservableObject {
    @Published var items: [DYAweme] = []
    @Published var error: String?
    @Published var loading = false
    @Published var liked: Set<String> = []
    @Published var collected: Set<String> = []
    @Published var toast: String?
    /// 是否已登录抖音（登录后推荐流才按账号个性化，点赞/收藏才能进账号）
    @Published var isLoggedIn = false
    private var hasMore = true
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func allowedRecommendations(_ candidates: [DYAweme]) -> [DYAweme] {
        let filter = DYHashtagFilter(rawValue: defaults.string(forKey: DYHashtagFilter.storageKey) ?? "")
        return candidates.filter { !filter.blocks(description: $0.desc, knownNames: $0.hashtagNames ?? []) }
    }

    /// Keep the active video when possible; otherwise prefer the next surviving recommendation.
    @discardableResult
    func applyHashtagFilter(currentID: String?) -> String? {
        let previous = items
        let index = currentID.flatMap { id in previous.firstIndex { $0.id == id } } ?? 0
        items = allowedRecommendations(items)
        pool = allowedRecommendations(pool)
        if let currentID, items.contains(where: { $0.id == currentID }) { return currentID }
        let survivingIDs = Set(items.map(\.id))
        let next = previous.dropFirst(index).first { survivingIDs.contains($0.id) }?.id
        if items.isEmpty { fill(6, relaxed: true); return items.first?.id }
        return currentID == nil ? items.first?.id : (next ?? items.last?.id)
    }

    /// 竖着看时按约 70% 竖屏均匀穿插（网页推荐接口本身竖屏只占 1～3 成，原序播放几乎全是横屏）；
    /// 「横着看 + 只放横屏内容」时只取横屏。暂时没排进去的留在候选池，保持推荐原顺序。
    /// 横着看（屏幕/播放区比高宽）时只放横屏视频
    @AppStorage("douyin_wide_landscape_v1") var landscapeWhenWide = true
    /// 竖着看时只放短视频：网页推荐接口长视频（十几分钟到几十分钟）很多，竖着刷不合适；
    /// 长的留在候选池，横过来再放。
    @AppStorage("douyin_tall_short_v1") var shortWhenTall = true
    /// 「短视频」上限（秒）。图集没有时长，算短。
    static let shortMaxSeconds: Double = 180
    static func isShort(_ a: DYAweme) -> Bool { a.duration <= shortMaxSeconds }
    var shortOnlyActive: Bool { !screenWide && shortWhenTall }
    /// 当前方向下能不能放：横屏限定只要横屏，竖着看限定只要短视频。
    func eligible(_ a: DYAweme) -> Bool {
        if landscapeOnlyActive { return !Self.isPortrait(a) }
        if shortOnlyActive { return Self.isShort(a) }
        return true
    }
    /// 视频比屏幕窄（左右黑边）时自动放大铺满宽度；菜单里可关
    @AppStorage("douyin_autofit_v1") var autoFit = true
    /// 当前播放区是不是横的（宽 > 高），由页面布局同步
    var screenWide = false
    /// 候选池：拉到了但横屏限定下暂时不放的（保持推荐原顺序），以及启动时本地已缓存没看过的
    var pool: [DYAweme] = []
    static let poolCap = 80

    static func isPortrait(_ a: DYAweme) -> Bool { !a.images.isEmpty || a.isTallFrame }

    /// 竖着看（或关掉横屏限定）时的竖屏目标占比。
    static let portraitTarget = 0.7
    /// 穿插额度（类似 Bresenham）：初值 1 - 目标，保证每次重排后第一条先放竖屏。
    private var mixCredit = 1 - DYFeedModel.portraitTarget

    /// 横屏限定时只要横屏。
    var landscapeOnlyActive: Bool { screenWide && landscapeWhenWide }
    /// 当前竖屏目标：横屏限定 0，其余 70%。
    var targetRatio: Double { landscapeOnlyActive ? 0 : Self.portraitTarget }

    /// 从候选池往列表里排最多 maxN 条：竖横按目标比例均匀穿插（70% → 竖横竖竖横竖竖…），
    /// 同方向内保持推荐原顺序；横屏限定时只取横屏。
    /// relaxed = 比例凑不齐时照原顺序放（别让列表断粮）；横屏限定不放宽。
    @discardableResult
    func fill(_ maxN: Int, relaxed: Bool = false) -> Int {
        pool = allowedRecommendations(pool)
        let r = targetRatio
        var n = 0
        while n < maxN, !pool.isEmpty {
            let idx: Int?
            if r <= 0 || relaxed {
                idx = pool.firstIndex { eligible($0) }
            } else {
                let wantPortrait = mixCredit + r >= 1 - 1e-9
                idx = pool.firstIndex { eligible($0) && Self.isPortrait($0) == wantPortrait }
            }
            guard let i = idx else { break }
            let a = pool.remove(at: i)
            items.append(a)
            if r > 0 { mixCredit = (mixCredit + r - (Self.isPortrait(a) ? 1 : 0)).clamped(-1, 1) }
            n += 1
        }
        return n
    }

    /// 横屏限定开关 / 方向变了：当前条之后的重新排（当前这条不动，不打断播放）
    func remix(after index: Int?) {
        let keep = (index ?? -1) + 1
        guard keep <= items.count else { return }
        let upcoming = Array(items[keep...])
        items.removeSubrange(keep...)
        pool = upcoming + pool
        mixCredit = 1 - Self.portraitTarget
        fill(max(upcoming.count, 6))
        trimPool()
    }

    /// 启动时把本地已缓存、没看过、又不在列表里的放到候选池最前（秒开）
    func seedPool(_ cached: [DYAweme]) {
        let have = Set(items.map(\.id)).union(pool.map(\.id))
        pool = allowedRecommendations(cached).filter { !have.contains($0.id) } + pool
    }

    private func trimPool() {
        // 超上限：先丢当前用得少的那一类里最早的（横屏限定丢竖屏；竖着看丢横屏，接口横屏本来就多）
        while pool.count > Self.poolCap {
            let dropPortrait = landscapeOnlyActive
            if let i = pool.firstIndex(where: { !eligible($0) }) { pool.remove(at: i) }
            else if let i = pool.firstIndex(where: { Self.isPortrait($0) == dropPortrait }) { pool.remove(at: i) }
            else { pool.removeFirst() }
        }
    }

    func loadMore(_ bridge: DouyinBridge) async {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_HASHTAG_FIXTURE"] == "1" {
            error = items.isEmpty ? "暂时没有符合标签过滤条件的推荐" : nil
            return
        }
        #endif
        guard !loading, hasMore || items.isEmpty || !pool.isEmpty else { return }
        loading = true
        defer { loading = false }
        let want = 6
        var added = fill(want)
        do {
            var pages = 0
            while added < want && pages < 8 && (hasMore || items.isEmpty) {
                let r = try await bridge.fetchFeed()
                guard !Task.isCancelled else { return }
                pages += 1
                let seen = Set(items.map(\.id)).union(pool.map(\.id))
                let fresh = allowedRecommendations(r.items).filter { a in !seen.contains(a.id) && (a.play != nil || !a.images.isEmpty) }
                // 账号里已点赞/已收藏的，进页面就是选中态
                for a in fresh {
                    if a.userDigged == 1 { liked.insert(a.id) }
                    if a.isCollect == 1 { collected.insert(a.id) }
                }
                pool.append(contentsOf: fresh)
                hasMore = r.hasMore || !r.items.isEmpty
                added += fill(want - added)
            }
            // 竖横凑不齐（如接口连着几页没竖屏）时按原顺序补，横屏限定不放宽
            if added == 0, !landscapeOnlyActive { added += fill(want, relaxed: true) }
            // 连拉几页一条短的都没有：按原顺序放长的，宁可刷到长视频也不要卡住没得刷
            if added == 0, shortOnlyActive {
                let n = min(want, pool.count)
                items.append(contentsOf: pool.prefix(n)); pool.removeFirst(n); added += n
            }
            trimPool()
            DYLiveModel.log("DDMIX added=\(added) pool=\(pool.count) ratio=\(String(format: "%.2f", targetRatio)) landscapeOnly=\(landscapeOnlyActive) wide=\(screenWide) recent=\(items.suffix(20).filter(Self.isPortrait).count)/\(min(20, items.count))")
            error = (items.isEmpty && added == 0) ? (DYHashtagFilter(rawValue: defaults.string(forKey: DYHashtagFilter.storageKey) ?? "").tags.isEmpty
                ? "暂时没刷到推荐，登录后或稍后再试" : "暂时没有符合标签过滤条件的推荐，可调整屏蔽标签或稍后重试") : nil
        } catch {
            if items.isEmpty { self.error = error.localizedDescription }
        }
    }

    func reset() { items = []; hasMore = true; error = nil; pool = []; mixCredit = 1 - Self.portraitTarget }
}

private struct DYFeedHostFrameKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > value.width { value = next }
    }
}

extension EnvironmentValues {
    @Entry var duoSystemBars = false
    @Entry var duoInlineVideoNavigation = false
    @Entry var duoContentInsets = EdgeInsets()
    @Entry var duoVisibleVideo: Binding<DYAweme?> = .constant(nil)
    @Entry var duoCleanScreen = false
}

struct DYUpstreamFeedScreen: View {
    @State private var followCommentItem: DYAweme?
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var bridge = DouyinBridge()
    @StateObject private var feed = DYFeedModel()
    @AppStorage(DYHashtagFilter.storageKey) private var blockedHashtags = ""
    @Environment(\.dyHashtagFilterPresented) private var hashtagFilterPresented
    @State private var insets = EdgeInsets()
    @State private var preloader = DYPreloader()
    @State private var resume: [String: Double] = [:]
    @State private var currentID: String?
    @State private var scrollID: String?
    @State private var userScrolling = false
    @State private var scrollEndTask: Task<Void, Never>?
    @State private var focusTask: Task<Void, Never>?
    @State private var initialized = false
    @State private var refreshing = false
    @State private var showComments = false
    @State private var web: DYWebTarget?
    @State private var showSettings = false
    @State private var tab: DYTab = {
        let e = ProcessInfo.processInfo.environment
        if e["DOUDUO_STARTLIVE"] == "1" { return .live }
        if e["DOUDUO_STARTFOLLOW"] == "1" { return .follow }
        return .recommend
    }()
    @StateObject private var live = DYLiveModel()
    @State private var searchSession: DYSearchSession?
    @State private var searchIsSplit = false
    private var showSearch: Bool { searchSession != nil }
    private func openSearch() {
        DYSearchSession.transition { showComments = false; searchSession = DYSearchSession() }
    }
    @State private var lastFeedPull = Date.distantPast
    @AppStorage(DYVideoCache.countKey) private var cacheCount = DYVideoCache.defaultCount
    @State private var showMine = false
    /// 顶栏「我的」按钮用的账号头像
    @State private var myUser: DYUser?
    @State private var authorTarget: DYAweme.Author?
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var pendingUpdate: DDUpdate?
    @State private var showMessages = false
    /// 盖在视频上的页面（我的/信息/搜索/作者）打开时，所有视频和直播都停
    private var overlayOpen: Bool { hashtagFilterPresented || (showSearch && (!searchIsSplit || searchSession?.presentsVideo == true)) || showMine || showMessages || authorTarget != nil }
    @AppStorage(DDChromeMode.key) private var chromeModeRaw = DDChromeMode.classic.rawValue
    private var chromeMode: DDChromeMode { DDChromeMode(rawValue: chromeModeRaw) ?? .classic }
    /// 半折叠/合屏：顶栏要整体左移躲开前摄挖孔，间距也收紧（默认模式用）
    @State private var topNudge: CGFloat = 0
    /// 默认模式顶栏的垂直位置：
    /// - Duo 内屏：0，与系统时间同一行；Duo 外屏：-80，贴物理屏顶（外屏窗口内容区比物理顶端低约 80pt）
    /// - 其他 iPhone / iPad：放到顶部安全区下沿，避开状态栏和灵动岛（issue #16）
    private var topBarTopPadding: CGFloat {
        if DYDuoMetrics.isDuoHardware { return hSize == .regular ? 0 : -80 }
        // 紧凑宽度下顶栏自带约 80pt 的下沉（Duo 外屏用 -80 抵消贴顶）；
        // 其他手机先抵消这 80，再让到顶部安全区下沿，避开状态栏和灵动岛。
        // 这一层忽略了顶部安全区，GeometryProxy 量到的 top 是 0，直接读窗口的安全区。
        let safeTop = DYDuoMetrics.windowSafeTop
        return hSize == .regular ? safeTop : safeTop - 80
    }
    /// 顶栏可用宽度：评论栏从右侧滑出时 = 视频区宽度，顶栏跟着视频居中、自适应收紧（默认模式用）
    @State private var topBarWidth: CGFloat?
    @State private var topChrome = CGRect.zero
    /// 直播视图报上来的布局 A 下窗格，坐标在 `douduo.feed`。
    @State private var layoutAModuleAnchor = DYLiveModuleAnchor()
    /// 本视图在 `douduo.feed` 里的框，用来把窗格坐标换成 overlay 的本地坐标。
    @State private var feedHost = CGRect.zero
    @State private var railInputActive = false
    /// 极简模式：长按模块入口时显示当前视频的作者和标题，松开消失
    private let peek = DDPeekInfo.shared
    /// 播放速度（更多 → 倍速）：全局速度，长按锁定只作用于单条视频，不写这里
    @AppStorage("douyin_playback_rate_v1") private var playbackRate = 1.0
    @State private var noticeUnread = 0
    @State private var wideToken = UUID()

    private var currentIndex: Int? { currentID.flatMap { id in feed.items.firstIndex { $0.id == id } } }
    private var current: DYAweme? { currentIndex.map { feed.items[$0] } }

    private var chrome: some View {
        let railMode = chromeMode.usesRail
        return ZStack(alignment: .top) {
            layoutRoot
                .ignoresSafeArea(edges: [.top, .horizontal])
                .environment(\.dyRootRailTab, (railMode && tab != .live) ? tab : nil)
            if !railMode, !(tab == .live && (live.clean || live.entered)) {
                VStack(spacing: 6) {
                    topBar
                }
                .padding(.top, topBarTopPadding)
                // 评论栏展开：顶栏只占视频那一块，跟着视频缩到左边。直播预览仍量这块的下沿。
                .frame(width: topBarWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: DYTopChromeFrameKey.self, value: proxy.frame(in: .named("douduo.feed")))
                    }
                }
            }
        }
        .overlayPreferenceValue(DYFeedRailPreference.self) { entries in
            if railMode {
                let entry = entries.first { $0.tab == tab && (tab != .recommend || $0.id == currentID) }
                rootActionRail(entry, selector: false)
            }
        }
        .overlay {
            if railMode, !(tab == .live && (live.clean || live.entered)) {
                if tab == .live, layoutAModuleAnchor.active, feedHost.width > 1 {
                    layoutAModuleButton.modifier(DYRailInputLock())
                } else {
                    rootActionRail(nil, selector: true)
                }
            }
        }
        // 放在全部菜单栏 overlay 之后，确保发送键视觉和触摸层级都在最前。
        .overlayPreferenceValue(DYFeedComposerPreference.self) { entries in
            if let composer = entries.first(where: { $0.tab == tab && (tab != .recommend || $0.id == currentID) }) {
                composer.content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .onPreferenceChange(DYFeedInputActivePreference.self) { railInputActive = $0 }
        .environment(\.dyRailInputActive, railInputActive)
        .onPreferenceChange(DYTopChromeFrameKey.self) { next in
            guard abs(next.maxY - topChrome.maxY) > 0.5 || abs(next.minY - topChrome.minY) > 0.5 else { return }
            topChrome = next
        }
        .onPreferenceChange(DYLiveModuleAnchorKey.self) { next in
            let current = layoutAModuleAnchor
            guard next.active != current.active || next.compact != current.compact
                    || abs(next.safeBottom - current.safeBottom) > 0.5
                    || abs(next.safeTrailing - current.safeTrailing) > 0.5
                    || abs(next.pane.minX - current.pane.minX) > 0.5
                    || abs(next.pane.minY - current.pane.minY) > 0.5
                    || abs(next.pane.width - current.pane.width) > 0.5
                    || abs(next.pane.height - current.pane.height) > 0.5 else { return }
            layoutAModuleAnchor = next
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: DYFeedHostFrameKey.self, value: proxy.frame(in: .named("douduo.feed")))
            }
            .allowsHitTesting(false)
        }
        .onPreferenceChange(DYFeedHostFrameKey.self) { next in
            guard abs(next.minX - feedHost.minX) > 0.5 || abs(next.minY - feedHost.minY) > 0.5
                    || abs(next.width - feedHost.width) > 0.5 || abs(next.height - feedHost.height) > 0.5 else { return }
            feedHost = next
        }
        // 默认模式：顶栏要从物理屏最上沿开始排（外屏/内屏都贴顶），所以整层忽略顶部安全区——和 PR #12 之前完全一致。
        // 简洁/极简模式的 ignoresSafeArea 已在 layoutRoot 上，这里不重复加，避免影响侧边栏的安全区测量。
        .modifier(DDClassicTopInset(active: !railMode))
        .coordinateSpace(.named("douduo.feed"))
        // 直播间返回键只保留 DYLiveRoomPage 里那一颗画面内「返回」胶囊：
        // 主视图不挂 NavigationStack / toolbar，避免 Duo 系统侧栏再渲染一个重复的返回按钮。
    }

    private var loadedFeed: some View {
        chrome.background(DouyinBridgeHost(bridge: bridge).frame(width: 1, height: 1).allowsHitTesting(false))
        .task {
            guard !initialized else { return }
            initialized = true
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_HASHTAG_FIXTURE"] == "1" {
                feed.items = feed.allowedRecommendations(DYFeedModel.hashtagFixtures)
                currentID = feed.items.first?.id
                scrollID = currentID
                return
            }
            #endif
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_SELFTEST"] == "1" { Task { await DDSelfTest.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_APITEST"] == "1" { Task { await DDApiProbe.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_LIVEPROBE"] == "1" { Task { await DDFeatureProbe.run(bridge, live: live) } }
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_APISCAN"] == "1" { Task { await DYApiScanner.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_CPROBE"] == "1" { Task { await DYCommentApiProbe.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_LOGINPROBE"] == "1" { Task { await DYLoginProbe.run(bridge) } }
            #endif
            if ProcessInfo.processInfo.environment["DOUDUO_EXPORTTEST"] == "1" { Task { await DDFeatureProbe.exportHeadProbe(bridge) } }
            // 真机验收用：DOUDUO_STARTLIVE=1 + DOUDUO_AUTOLIVEROOM=1 直接进房，省去手点。
            if ProcessInfo.processInfo.environment["DOUDUO_AUTOLIVEROOM"] == "1" {
                Task { @MainActor in
                    var waited = 0
                    while live.rooms.isEmpty, waited < 24 {
                        try? await Task.sleep(for: .milliseconds(500))
                        waited += 1
                    }
                    try? await Task.sleep(for: .milliseconds(800))
                    if !live.entered, !live.rooms.isEmpty { live.enterRoom() }
                }
            }
            #endif
            Task { myUser = try? await bridge.selfProfile() }
            if tab == .live { return }   // 起手就是直播页（调试）时别把推荐流的播放器都拉起来
            // 秒开：先播上次缓存好、还没看过的；连接抖音 / 拉推荐在后台接着往后补（两套界面共用 DYFeedModel.restoreForLaunch）
            if let restored = feed.restoreForLaunch() {
                resume = restored.positions
                currentID = restored.currentID
                scrollID = currentID
            }
            // 恢复的会话里「当前条之后」是上次的排法：按现在的方向 / 比例重排（当前这条不动）
            if currentIndex != nil { feed.remix(after: currentIndex) }
            await feed.loadMore(bridge)
            if currentID == nil { currentID = feed.items.first?.id }
            focusCurrent()
            #if DEBUG
            // 用真实作品详情复验元数据显示，不造预览数据、不做账号互动。
            if let id = ProcessInfo.processInfo.environment["DOUDUO_VIDEO_ID"],
               let item = try? await bridge.awemeDetail(id) {
                feed.items = [item]; currentID = item.id; scrollID = item.id
                focusCurrent()
            }
            let env0 = ProcessInfo.processInfo.environment
            if let d = env0["DOUDUO_LIVEDELAY"], let sec = Double(d) {
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) { tab = .live }
            }
            let env = ProcessInfo.processInfo.environment
            if let o = env["DOUDUO_OPEN"] {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                switch o {
                case "search": openSearch()
                case "mine": showMine = true
                case "follow": tab = .follow
                case "author": authorTarget = current?.author
                case "comments": showComments = true
                case "messages": showMessages = true
                case "login": web = DYWebTarget(url: URL(string: "https://www.douyin.com/?recommend=1")!)
                case "qr": Task { await bridge.debugQRLogin() }
                case "export": Task { await bridge.debugExportCookies() }
                case "import": Task { await bridge.debugImportCookies() }
                default: break
                }
            }
            if env["WUWEI_DEBUG_DOUYIN_ADVANCE"] == "1" {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if feed.items.count > 1 { withAnimation { currentID = feed.items[1].id } }
            }
            if env["WUWEI_DEBUG_DOUYIN_LIVE"] == "1" { tab = .live }
            if env["WUWEI_DEBUG_DOUYIN_COMMENTS"] == "1" {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                showComments = true
            }
            #endif
        }
        .task(id: currentID) {
            // 旧会话没有新增字段：只补当前作品元数据，不换播放地址、不丢进度。
            guard let id = currentID, feed.items.contains(where: { $0.id == id && $0.publishedAt == nil }),
                  let detail = try? await bridge.awemeDetail(id), !Task.isCancelled,
                  let index = feed.items.firstIndex(where: { $0.id == id }) else { return }
            feed.items[index].publishedAt = detail.publishedAt
            feed.items[index].aiDeclaration = detail.aiDeclaration
            saveSession()
        }
        .onChange(of: currentID) { old, new in
            // ⚠️ 宽屏（Duo 内屏）首次布局时 ScrollView 会把 scrollPosition 回写成 nil → 没有「当前条」→ 全部不播、上滑也不认。
            // 列表非空时把 nil 顶回上一个；刷新 / 重载会先清空列表再置 nil，不受影响。
            if new == nil, let old, feed.items.contains(where: { $0.id == old }) { currentID = old; return }
            scrollID = new
            // 手滑换条发生在滑动途中：预加载器要销毁 / 新建播放器，是主线程同步的重活，砸在滑动帧上会顿一下。
            // 起播不依赖它，所以等手停下来（0.3s 没再换条）再做；点按钮 / 自动连播等非手滑的换条照旧立刻做。
            focusTask?.cancel()
            if userScrolling {
                focusTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if !Task.isCancelled { focusCurrent() }
                }
            } else {
                focusCurrent()
            }
            saveSession()
            reportWatch(old: old, new: new)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            saveSession()
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if DDPlayback.shared.appIsActive { saveSession() }
        }
        .onChange(of: cacheCount) { _, _ in focusCurrent() }
        .task(id: blockedHashtags) { await applyHashtagFilter() }
        .onChange(of: feed.landscapeWhenWide) { _, _ in remixUpcoming() }
        .onChange(of: feed.shortWhenTall) { _, _ in remixUpcoming() }
        .onDisappear { live.stop(); preloader.clear() }
    }

    var body: some View {
        loadedFeed
        .modifier(DYSearchPresentation(bridge: bridge, session: $searchSession, isSplit: $searchIsSplit,
                                      onOpen: { showComments = false }))
        .onChange(of: showComments) { _, shown in if shown { searchSession = nil } }
        .environment(\.dyOpenSettings, { showSettings = true })
        .sheet(isPresented: $showSettings) {
            DYSettingsScreen(onOpenWeb: { web = DYWebTarget(url: DouyinWeb.home) },
                             onRefresh: { Task { await refreshRecommendations() } },
                             onCacheCleared: { focusCurrent() })
        }
        .fullScreenCover(item: $web, onDismiss: {
            // 网页里可能登录 / 过了验证：重开签名页，先重新读登录态，再刷推荐
            live.reset(); preloader.clear(); feed.reset(); currentID = nil; bridge.reload()
            Task {
                await feed.loadMore(bridge)
                currentID = feed.items.first?.id
                focusCurrent()
            }
            if tab == .live { Task { await live.load(bridge, reset: true) } }
        }) { t in
            DouyinWebScreen(start: t.url)
        }
        .fullScreenCover(isPresented: $showMessages) {
            DYMessagesScreen(bridge: bridge, onClose: { showMessages = false }, onWeb: { u in
                showMessages = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { web = DYWebTarget(url: u) }
            })
        }
        .task { await refreshNoticeUnread() }
        .task {
            #if DEBUG
            // 模拟器无触摸输入：DOUDUO_MSGTEST=1 → 起播后自动打开消息页
            if ProcessInfo.processInfo.environment["DOUDUO_MSGTEST"] == "1" {
                try? await Task.sleep(for: .seconds(8))
                showMessages = true
                DYLiveModel.log("DDMSGTEST auto-open messages")
            }
            #endif
        }
        .task {
            // 只预取一页直播元数据，不拉流、不进房；用户点直播时不必再从零等列表。
            guard tab != .live else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard live.rooms.isEmpty, !Task.isCancelled else { return }
            await live.load(bridge, reset: true)
        }
        .onChange(of: showMessages) { _, open in
            if !open { Task { await refreshNoticeUnread() } }
        }
        .task {
            // 启动查一次新版本；关掉后同一版本不再提示
            if let u = await DDUpdateChecker.check() { pendingUpdate = u }
        }
        .alert("有新版本", isPresented: Binding(get: { pendingUpdate != nil }, set: { if !$0 { if let u = pendingUpdate { DDUpdateChecker.dismiss(u) }; pendingUpdate = nil } })) {
            Button("去 GitHub 更新") {
                if let u = pendingUpdate { DDUpdateChecker.dismiss(u); DDUpdateChecker.open(u) }
                pendingUpdate = nil
            }
            Button("关闭", role: .cancel) {
                if let u = pendingUpdate { DDUpdateChecker.dismiss(u) }
                pendingUpdate = nil
            }
        } message: {
            Text("新版本 \(pendingUpdate?.version ?? "")（当前 \(DDUpdateChecker.currentVersion)）\n去 GitHub 下载新版，重新签名安装即可，登录态会保留。")
        }
    }

    @ViewBuilder
    private var layoutRoot: some View {
        GeometryReader { geo in
            let wide = Self.playAreaIsWide(geo)
            let panelW = sidePanelWidth(geo)
            // 右侧有评论栏时前摄落在评论栏上，顶栏不用再躲（默认模式的顶栏用）
            let nudge = panelW > 0 ? 0 : DYDuoMetrics.topBarLeftShift(geo)
            let barW: CGFloat? = panelW > 0 ? geo.size.width - panelW : nil
            flatArrangement(geo)
                .onAppear { topNudge = nudge; topBarWidth = barW }
                .onChange(of: nudge) { _, n in topNudge = n }
                .onChange(of: barW) { _, v in withAnimation(.snappy) { topBarWidth = v } }
                .onAppear { feed.screenWide = wide }
                .onChange(of: wide) { _, w in
                    // 转屏过程中尺寸会抖几下，稳定 0.4 秒再重排
                    let token = UUID(); wideToken = token
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard wideToken == token, feed.screenWide != w else { return }
                        feed.screenWide = w
                        remixUpcoming()
                    }
                }
        }
    }

    /// 播放区是不是横的：平放/单屏看整个窗口；半折叠看视频实际占的那块
    private static func playAreaIsWide(_ geo: GeometryProxy) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_FORCEWIDE"] == "1" { return true }
        #endif
        let w = geo.size.width, h = geo.size.height
        guard DYDuoMetrics.foldIsActive(geo) else { return w > h }
        // 选片方向沿用 1.3.13 的口径：按整屏形状判断，不按半折叠后视频那一块。
        // 1.3.14 曾改成按视频块判断：竖着拿的桌面半折叠，视频块约 669x455 被判成「横屏」，
        // 推荐流只放横屏视频，竖屏短视频几乎刷不到（老板反馈「短视频减少了」），已撤回。
        return w > h ? (w * 0.55 > h) : false
    }

    /// 半折叠按真实折痕切分（同直播 Layout A/B）：视频占折痕前一块，评论占折痕后一块，折痕本身留空。
    /// 拿不到折痕几何（旧系统 / DOUDUO_FOLD 模拟）时返回 nil，调用方回退到比例切分。
    private func foldPanes(_ geo: GeometryProxy) -> (video: CGRect, panel: CGRect, book: Bool)? {
        tab == .recommend ? DYDuoMetrics.hingeSplit(geo) : nil
    }

    /// 当前条之后按新的方向/比例重排；不够就接着拉
    private func remixUpcoming() {
        guard tab == .recommend || !feed.items.isEmpty else { return }
        feed.remix(after: currentIndex)
        DYLiveModel.log("DDMIX remix wide=\(feed.screenWide) upcoming=\(feed.items.count - (currentIndex ?? -1) - 1)")
        if currentID == nil { currentID = feed.items.first?.id; scrollID = currentID }
        lastFeedPull = .distantPast
        focusCurrent()
    }

    /// 一套布局通吃所有状态，且**不换容器**（换容器会重建播放器 → 黑屏 / 重播）：
    /// - 平放/外屏：视频铺满；够宽时评论从右侧滑出（视频缩窄），窄屏走底部 sheet
    /// - 半折叠：视频自动缩到一多半，另一半常驻评论（宽>高→左右分；高>宽→上下分）
    /// 右侧评论栏宽度（没有右侧栏 = 0）；布局和顶栏共用同一算法
    private var commentItem: DYAweme? { tab == .follow ? followCommentItem : current }

    private func sidePanelWidth(_ geo: GeometryProxy) -> CGFloat {
        guard !showSearch else { return 0 }
        let fold = tab == .recommend && DYDuoMetrics.foldIsActive(geo)
        let w = geo.size.width, h = geo.size.height
        if let p = foldPanes(geo) { return p.book ? max(0, w - p.video.width) : 0 }
        let bookFold = fold && w > h
        let sideBySide = w >= DYDuoMetrics.legacyWideMin || bookFold
        let showPanel = fold || (showComments && sideBySide && tab != .live)
        return showPanel && sideBySide ? (bookFold ? w * 0.45 : min(380, w * 0.42)) : 0
    }

    private func flatArrangement(_ geo: GeometryProxy) -> some View {
        let fold = !showSearch && tab == .recommend && DYDuoMetrics.foldIsActive(geo)
        let wide = geo.size.width >= DYDuoMetrics.legacyWideMin
        let w = geo.size.width, h = geo.size.height
        let hinge = showSearch ? nil : foldPanes(geo)
        let bookFold = fold && (hinge.map { $0.book } ?? (w > h))   // 书本姿态：左右分
        let tableFold = fold && !bookFold     // 桌面姿态：上下分
        let sideBySide = wide || bookFold
        let showPanel = !showSearch && (fold || (showComments && sideBySide && tab != .live))

        let panelW = hinge?.panel.width ?? sidePanelWidth(geo)
        let panelH = hinge.map { $0.panel.height } ?? (tableFold ? h * 0.45 : 0)
        let videoW = hinge?.video.width ?? (sideBySide && panelW > 0 ? w - panelW : w)
        let videoH = hinge?.video.height ?? (tableFold ? h - panelH : h)
        let panelX = hinge?.panel.minX ?? (sideBySide ? videoW : 0)
        let panelY = hinge?.panel.minY ?? (tableFold ? videoH : 0)
        // 评论栏在右侧（书本半折叠 / 展开平放）时：右边让开系统状态栏（时间/信号）用内缩。
        // 否则 DYCommentPanel 里的 DYRailReservedNudge 会把整块面板往左平移约 84pt：
        // 压回折痕或盖住视频，右侧还空出一条缝（issue #15「评论右侧与竖栏距离太大」）。
        let panelInset: CGFloat = {
            guard sideBySide, panelW > 0 else { return 0 }
            let pane = CGRect(x: panelX, y: panelY, width: panelW, height: h)
            return DYDuoMetrics.trailingOcclusionInset(geo, pane: pane)
        }()

        return ZStack(alignment: .topLeading) {
            feedArea
                .frame(width: videoW, height: videoH, alignment: .topLeading)
            if showPanel, let cur = commentItem {
                DYCommentPanel(bridge: bridge, aweme: cur,
                               onClose: fold ? nil : { withAnimation(.snappy) { showComments = false } })
                    .frame(width: sideBySide ? max(0, panelW - panelInset) : w,
                           height: tableFold ? panelH : h)
                    .dyDeskLight(tableFold)
                    .environment(\.dyCommentTrailingCleared, panelInset > 0)
                    .offset(x: panelX, y: panelY)
                    .id(cur.id)
            }
        }
        .background(theme.media.strongScrim.color(for: scheme).ignoresSafeArea())
        .animation(.snappy, value: fold)
        .animation(showSearch ? nil : .snappy, value: showComments)
        .sheet(isPresented: Binding(get: { !showSearch && showComments && !sideBySide && !fold }, set: { showComments = $0 })) {
            if let cur = commentItem {
                DYCommentPanel(bridge: bridge, aweme: cur, onClose: { showComments = false })
                    // 竖屏锁死半屏：不给 .large，上滑不能把评论区撑满整屏
                    .presentationDetents([.fraction(0.62)])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func refreshNoticeUnread() async {
        guard let groups = try? await bridge.noticeCounts() else { return }
        noticeUnread = DYMessagesScreen.badge(groups)
    }

    /// 换条时：上一条看完没有（≥95%，网页版同口径）+ 新一条起播 1.5 秒后上报
    private func reportWatch(old: String?, new: String?) {
        guard let new, let item = feed.items.first(where: { $0.id == new }) else { return }
        var seen = false
        if let old, let prev = feed.items.first(where: { $0.id == old }), prev.duration > 0,
           DDNowPlaying.id == old { seen = DDNowPlaying.time / prev.duration >= 0.95 }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard currentID == new else { return }
            await bridge.reportWatch(item, preID: old, preSeen: seen)
        }
    }

    private func saveSession() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_HASHTAG_FIXTURE"] == "1" { return }
        #endif
        guard let id = currentID, feed.items.contains(where: { $0.id == id }) else { return }
        var positions = resume
        if DDNowPlaying.id == id, DDNowPlaying.time.isFinite {
            positions[id] = max(0, DDNowPlaying.time)
        }
        DYFeedSession(items: feed.items, currentID: id, positions: positions).save()
    }

    /// 自动连播：播完滑到下一条；快到底时先补一页
    private func playNext(after id: String) {
        guard let i = feed.items.firstIndex(where: { $0.id == id }) else { return }
        if i + 1 < feed.items.count {
            withAnimation { currentID = feed.items[i + 1].id }
        } else {
            Task {
                await feed.loadMore(bridge)
                if let j = feed.items.firstIndex(where: { $0.id == id }), j + 1 < feed.items.count {
                    withAnimation { currentID = feed.items[j + 1].id }
                }
            }
        }
    }

    /// 点页签只切页，不再顺手刷新（点顶部会误触成「刷新视频」）。
    /// 要换一批推荐走「更多 → 刷新推荐」。
    private func selectTab(_ target: DYTab) {
        guard tab != target else { return }
        if target != .live {
            queuedLiveAction = nil
            liveModuleRequest = nil
        }
        tab = target
    }

    /// 先拉到新一批再替换，失败不清空当前画面；与预取互斥，避免旧请求覆盖刷新结果。
    @MainActor private func refreshRecommendations() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; focusCurrent() }
        showToast("正在刷新推荐…")
        while feed.loading {
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        let previous = Set(feed.items.map(\.id))
        let replacement = DYFeedModel()
        replacement.screenWide = feed.screenWide
        await replacement.loadMore(bridge)
        guard !Task.isCancelled else { return }
        let fresh = replacement.items.filter { !previous.contains($0.id) }
        guard !fresh.isEmpty else {
            showToast(replacement.error ?? "暂时没有新的推荐，已保留当前视频")
            DYLiveModel.log("DDREFRESH failed kept=\(currentID ?? "-")")
            return
        }
        showComments = false
        scrollEndTask?.cancel(); userScrolling = false
        preloader.clear()
        feed.reset()
        feed.items = fresh
        feed.pool = replacement.pool
        feed.liked.formUnion(replacement.liked)
        feed.collected.formUnion(replacement.collected)
        resume = [:]
        currentID = fresh.first?.id
        scrollID = currentID
        lastFeedPull = Date()
        saveSession()
        showToast("推荐已刷新")
        DYLiveModel.log("DDREFRESH ok n=\(fresh.count) first=\(currentID ?? "-")")
    }

    private func applyHashtagFilter() async {
        let previousID = currentID
        currentID = feed.applyHashtagFilter(currentID: currentID)
        if previousID != currentID {
            scrollEndTask?.cancel()
            userScrolling = false
            showComments = false
            scrollID = currentID
            preloader.clear()
        }
        saveSession()
        guard initialized else { return }
        while feed.loading {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        if feed.items.isEmpty { await feed.loadMore(bridge) }
        guard !Task.isCancelled else { return }
        if currentID == nil { currentID = feed.items.first?.id; scrollID = currentID }
        focusCurrent()
        saveSession()
    }

    private func focusCurrent() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_HASHTAG_FIXTURE"] == "1" { return }
        #endif
        guard !refreshing, let i = currentIndex else { return }
        preloader.update(feed.items, current: i)
        let curID = feed.items[i].id
        let ahead = Array(feed.items.dropFirst(i + 1))
        let currentItem = feed.items[i]
        Task {
            await DYVideoCache.shared.markWatched(curID)
            await DYVideoCache.shared.focus(current: currentItem, ahead: ahead)
        }
        // 后面不足「缓存条数」就继续拉推荐（至少保证 6 条，节流 4 秒一次）
        let want = max(6, min(DYVideoCache.limit, 60))
        if feed.items.count - i - 1 < want, Date().timeIntervalSince(lastFeedPull) > 4 {
            lastFeedPull = Date()
            Task {
                await feed.loadMore(bridge)
                if let j = currentIndex {
                    preloader.update(feed.items, current: j)
                    await DYVideoCache.shared.focus(current: feed.items[j], ahead: Array(feed.items.dropFirst(j + 1)))
                    if feed.items.count - j - 1 < want { focusCurrent() }
                }
            }
        }
    }

    @ViewBuilder
    private var feedArea: some View {
        ZStack(alignment: .top) {
            if tab == .live {
                DYLiveFeed(bridge: bridge, model: live, onWeb: { u in web = DYWebTarget(url: u) }, active: web == nil && !overlayOpen,
                           topChrome: chromeMode.usesRail ? .zero : topChrome, screenInsets: insets,
                           moduleRequest: liveModuleRequest, classicPreviewChrome: !chromeMode.usesRail)
            } else if tab == .follow {
                DYFollowFeed(bridge: bridge, insets: insets, active: tab == .follow && web == nil && !overlayOpen,
                             onAuthor: { a in authorTarget = a.author },
                             onLogin: { web = DYWebTarget(url: DouyinWeb.home) },
                             onToast: { showToast($0) }, onComments: { item in
                                 followCommentItem = item; showComments = true
                             })
            } else {
                recommendArea
            }
            if let t = feed.toast {
                Text(t).font(.footnote.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.62)))
                    .frame(maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("douyin.toast")
            }
            #if DEBUG
            // UI 测试锚点：当前视频 id / 当前锁定倍速
            Text(currentID ?? "-").font(.caption2).opacity(0.01)
                .accessibilityIdentifier("douyin.currentID")
                .allowsHitTesting(false)
            Text(String(format: "%g", playbackRate)).font(.caption2).opacity(0.01)
                .accessibilityIdentifier("douyin.rate")
                .allowsHitTesting(false)
            #endif
        }
        // 顶栏要压在系统状态栏那一行，所以整块忽略顶部安全区；
        // 外屏左右有侧边控制区，安全区会把顶栏整行往左挤，所以水平方向也忽略（视频本来就铺满）
        .ignoresSafeArea(edges: [.top, .horizontal])
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { insets = geo.safeAreaInsets
                    }
                    .onChange(of: geo.safeAreaInsets) { _, v in insets = v }
            }
        }
        .onChange(of: tab) { _, t in
            if t == .recommend { focusCurrent() } else { preloader.clear() }
            if t != .live { live.stop() }
        }
        .fullScreenCover(isPresented: $showMine) {
            DYMineScreen(bridge: bridge,
                         onLogin: { showMine = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { web = DYWebTarget(url: DouyinWeb.home) } },
                         onAuthor: { a in authorTarget = a.author })
        }
        .sheet(item: $authorTarget) { a in
            NavigationStack {
                DYAuthorScreen(bridge: bridge, author: a, onWeb: { u in web = DYWebTarget(url: u) })
            }
                .presentationDetents([.medium, .large])
                .presentationBackground(.black)
        }

    }

    /// 顶部一排：左菜单，中间 关注/推荐/直播，右边 搜索 / 我的
    /// 顶栏：只留「关注 / 推荐 / 直播」三个纯文字页签，不用胶囊，与状态栏时间/信号同一行。
    /// 自适应仅收紧间距；消息与头像入口始终保留最小触摸区。
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            topBarRow(spacing: topNudge > 0 ? 5 : 14, hPad: 16)
            topBarRow(spacing: 0, hPad: 10)
            topBarRow(spacing: 0, hPad: 8)
            topBarRow(spacing: 0, hPad: 5)
        }
        .themeShadow(.mediaLabel)
        .frame(maxWidth: .infinity, alignment: .center)
        // 整行可点区域随内容高度撑开，避免点在文字上方的极窄条带时落空
        .frame(minHeight: 54)
        // 合屏避让：用右侧内缩把居中点推左（small move），绝不把左边的「关注」推出屏幕
        .padding(.trailing, topNudge)
        // 外屏（compact）状态区更深：外屏时间约 85pt，内屏（regular）约 39pt
        // 注意用 size class 判断，不能用容器宽度——评论栏打开时视频区会变窄。
        .padding(.top, hSize == .regular ? 23 : 76)
    }

    private func topBarRow(spacing: CGFloat, hPad: CGFloat) -> some View {
        // 触摸区左右各扩 hPad、上下各扩 14（图标与字号不动）
        HStack(spacing: spacing) {
            ForEach(DYTab.allCases, id: \.self) { t in
                Button { selectTab(t) } label: {
                    VStack(spacing: 3) {
                        Text(t.title)
                            .font(.headline.weight(tab == t ? .bold : .medium))
                            .foregroundStyle(theme.media.onMedia.color(for: scheme).opacity(tab == t ? 1 : 0.62))
                            .lineLimit(1).fixedSize()
                        Capsule()
                            .fill(theme.media.onMedia.color(for: scheme))
                            .frame(width: 16, height: 3)
                            .opacity(tab == t ? 1 : 0)
                    }
                    // 文字本身小，撑开触摸区，避免点不中/误判成下拉
                    .padding(.horizontal, hPad)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // 消息只留图标，未读红点仍独立显示。
            Button { showMessages = true } label: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(theme.media.onMedia.color(for: scheme).opacity(0.62))
                .padding(.horizontal, hPad)
                .padding(.vertical, 14)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if noticeUnread > 0 {
                        Circle().fill(theme.status.danger.color(for: scheme))
                            .frame(width: 7, height: 7)
                            .offset(x: -(hPad - 2), y: 10)
                            .allowsHitTesting(false)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("消息")
            .accessibilityIdentifier("douyin.messages.top")

            // 「我的」：独立按钮（不属于 tab 切换）
            Button { showMine = true } label: {
                HStack(spacing: 5) {
                    CachedAsyncImage(url: myUser?.avatar.flatMap(URL.init(string:))) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 19))
                            .foregroundStyle(theme.media.onMedia.color(for: scheme).opacity(0.62))
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                }
                .padding(.horizontal, max(hPad - 2, 4))
                .padding(.vertical, 12)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("我的")
            .accessibilityIdentifier("douyin.mine.top")
        }
        .fixedSize()
    }

    /// The selector and current video actions share the same outer-column geometry.
    /// Empty and live pages reserve the same slots, so changing modules never moves the selector.
    private func rootActionRail(_ entry: DYFeedRailEntry?, selector: Bool) -> some View {
        let groupHeight = 3 * CGFloat(50) + 44 + 3 * theme.media.actionItemSpacing + 16
        let railHeight = 50 + theme.media.actionGroupSpacing + groupHeight + theme.media.actionGroupSpacing + 50
        return DYAdaptiveActionRail { edge in
            // Read the current container's inset before expanding into the outer column.
            // A size class does not describe the width of the system's vertical bar.
            GeometryReader { safeGeometry in
                let columnInset = edge == .leading ? safeGeometry.safeAreaInsets.leading : safeGeometry.safeAreaInsets.trailing
                // Preserve the theme's optical inset so the circles align with system status glyphs.
                let outerPadding = columnInset > 0 ? max(0, (columnInset - 54) / 2 + theme.media.expandedRailOpticalInset) : 12
                GeometryReader { geometry in
                    // 长按加速时整列淡出（入口 + 按钮 + 进度环），和默认模式一致（issue #4）
                    DDBoostFade {
                        VStack(spacing: theme.media.actionGroupSpacing) {
                            if selector {
                                moduleMenu(edge: edge)
                            } else {
                                Color.clear.frame(height: 50).allowsHitTesting(false)
                            }
                            if let entry {
                                entry.actions.id("\(entry.tab)-\(entry.id)")
                            }
                        }
                    }
                    .frame(width: 54, height: railHeight, alignment: .top)
                    .modifier(DYRailReservedNudge(railEdge: edge, verticalSpace: (-max(0, geometry.size.height - railHeight - 92))...92))
                    .padding(.horizontal, outerPadding)
                    .padding(.bottom, 92)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: edge == .leading ? .bottomLeading : .bottomTrailing)
                }
                // Only the rail extends into the system column; reserved-region avoidance remains active.
                .ignoresSafeArea(edges: .horizontal)
            }
            // 菜单栏不参与键盘避让：输入弹幕/回复评论只抬输入区，不能把整列顶上去或向左挤。
            // 仅忽略 keyboard，保留 container 安全区和分屏窗格，避免破坏信号栏对齐。
            .ignoresSafeArea(.keyboard)
        }
        .modifier(DYRailInputLock())
    }

    /// 极简模式：视频进度画成包住圆形入口的外圈。从 12 点方向顺时针走；拖动进度时变粗变亮。
    /// 进度每 0.25 秒更新一次：只让这颗小视图订阅 DDRailProgress，别挂在根视图上（否则整屏跟着重算，1.3.13 卡顿主因）。
    private var railProgressRing: some View {
        DDRailProgressRing(show: chromeMode.usesRail && tab != .live,
                           fg: theme.media.onMedia.color(for: scheme))
    }

    /// 模块菜单的内容（单击圆形入口时弹出）。
    @ViewBuilder
    private var moduleMenuContent: some View {
        Section("切换模块") {
            Picker("当前模块", selection: Binding(get: { tab }, set: { selectTab($0) })) {
                ForEach(DYTab.allCases, id: \.self) { target in
                    Label(target.title, systemImage: target.symbol)
                        .tag(target)
                }
            }
            .pickerStyle(.inline)
        }
        if tab == .live {
            Section {
                Button("我的关注", systemImage: "person.2") {
                    queuedLiveAction = .followedLive
                    publishQueuedLiveModule()
                }
                .accessibilityIdentifier("douyin.module.live.follow")
                Button("发现更多", systemImage: "square.grid.2x2") {
                    queuedLiveAction = .discover
                    publishQueuedLiveModule()
                }
                .accessibilityIdentifier("douyin.module.live.discover")
            }
        }
        Section {
            Button("搜索", systemImage: "magnifyingglass") { openSearch() }
                .accessibilityIdentifier("douyin.module.search")
            Button("消息", systemImage: "bubble.left.and.bubble.right") { showMessages = true }
            Button("我的", systemImage: "person.crop.circle") { showMine = true }
        }
    }

    /// 圆形模块入口（简洁 / 极简共用）。
    /// 系统 Menu 在长按时也会弹出菜单，没法做到「长按只看作者标题、不弹菜单」，所以统一自己处理：
    /// 单击（按下不满 0.35 秒）弹菜单，长按（满 0.35 秒）显示作者标题，松手消失，不弹菜单。
    @ViewBuilder
    private func moduleMenu(edge: HorizontalEdge, opensUpward: Bool = false) -> some View {
        minimalModuleButton(edge: edge, opensUpward: opensUpward)
    }

    /// 布局 A：同一颗模块圆钮改到下窗格右下。清空层不接点击，只有圆钮自己可点。
    private var layoutAModuleButton: some View {
        let place = DYLiveLayoutToggle.layoutAModuleFrame(
            interaction: layoutAModuleAnchor.pane,
            button: CGSize(width: 54, height: DDRailMetrics.entryDiameter),
            compact: layoutAModuleAnchor.compact,
            safeBottom: layoutAModuleAnchor.safeBottom,
            safeTrailing: layoutAModuleAnchor.safeTrailing)
        return ZStack {
            Color.clear.allowsHitTesting(false)
            moduleMenu(edge: .trailing, opensUpward: true)
                .position(x: place.midX - feedHost.minX, y: place.midY - feedHost.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var moduleCircleLabel: some View {
        let ringOn = chromeMode.usesRail && tab != .live
        // 有进度环时，玻璃圆缩进环里面（环内侧留 4pt）；没有环（直播）时保持原来的 50pt 圆。
        let glass: CGFloat = ringOn ? DDRailMetrics.entryDiameter - 8 : DDRailMetrics.entryDiameter
        return ZStack {
            Image(systemName: tab.symbol)
                .font(.system(size: theme.media.moduleGlyphSize, weight: .regular, design: .rounded))
                .foregroundStyle(theme.media.onMedia.color(for: scheme))
                .frame(width: glass, height: glass)
                .contentShape(Circle())
                .ddGlassCircle()
            railProgressRing
        }
        // 占位固定：入口总高 50 + 下方间距，让入口到胶囊的距离和「胶囊到更多」一致（见 DDRailMetrics）
        .frame(width: DDRailMetrics.entryDiameter, height: DDRailMetrics.entryDiameter)
        .frame(width: 54)
    }

    /// 入口按钮：
    /// - 一按下就显示作者标题（不用等），抬手后消失；
    /// - 按下不满 0.35 秒就抬手 = 单击，弹出菜单，菜单打开期间标题保持显示，菜单收起后才消失；
    /// - 按满 0.35 秒 = 长按，只看标题，不弹菜单。
    @State private var minimalMenuOpen = false
    @State private var queuedLiveAction: DYLiveModuleRequest.Action?
    @State private var liveModuleRequest: DYLiveModuleRequest?

    private func queueLiveModule(_ action: DYLiveModuleRequest.Action) {
        queuedLiveAction = action
    }

    private func publishQueuedLiveModule() {
        guard let action = queuedLiveAction else { return }
        queuedLiveAction = nil
        let token = (liveModuleRequest?.token ?? 0) + 1
        liveModuleRequest = DYLiveModuleRequest(token: token, action: action)
    }

    private func minimalModuleButton(edge: HorizontalEdge, opensUpward: Bool = false) -> some View {
        moduleCircleLabel
            .contentShape(Circle())
            .modifier(DDPressHold(
                // 圆形入口的长按只用来看作者标题（极简模式），不加速——这是原设计，别再接加速。
                threshold: 0.35,
                onPressChanged: { pressing in
                    guard chromeMode.hidesInfo else { return }
                    // 抬手时若是单击，菜单会随后打开，标题由菜单状态接管，这里不先关
                    if pressing { withAnimation(.easeOut(duration: 0.1)) { peek.on = true } }
                    else if !minimalMenuOpen { withAnimation(.easeOut(duration: 0.15)) { peek.on = false } }
                },
                onTap: {
                    minimalMenuOpen = true
                    if chromeMode.hidesInfo { peek.on = true }
                }))
            .popover(isPresented: $minimalMenuOpen,
                     attachmentAnchor: .point(opensUpward ? .top : (edge == .trailing ? .leading : .trailing)),
                     arrowEdge: opensUpward ? .bottom : (edge == .trailing ? .trailing : .leading)) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(DYTab.allCases, id: \.self) { target in
                        minimalMenuRow(target.title, target.symbol, selected: tab == target, id: "douyin.module.item.\(target)") {
                            selectTab(target)
                        }
                    }
                    if tab == .live {
                        Divider().padding(.vertical, 4)
                        minimalMenuRow("我的关注", "person.2", id: "douyin.module.live.follow") {
                            queueLiveModule(.followedLive)
                        }
                        minimalMenuRow("发现更多", "square.grid.2x2", id: "douyin.module.live.discover") {
                            queueLiveModule(.discover)
                        }
                    }
                    Divider().padding(.vertical, 4)
                    minimalMenuRow("搜索", "magnifyingglass", id: "douyin.module.search") { openSearch() }
                    minimalMenuRow("消息", "bubble.left.and.bubble.right", badge: noticeUnread > 0, id: "douyin.module.messages") { showMessages = true }
                    minimalMenuRow("我的", "person.crop.circle", id: "douyin.module.mine") { showMine = true }
                }
                .padding(.vertical, 8)
                .frame(minWidth: 170)
                .presentationCompactAdaptation(.popover)
            }
            .onChange(of: minimalMenuOpen) { _, open in
                if !open, chromeMode.hidesInfo { withAnimation(.easeOut(duration: 0.15)) { peek.on = false } }
                if !open { publishQueuedLiveModule() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("切换模块，当前\(tab.title)")
            .accessibilityIdentifier("douyin.module.menu")
            .accessibilityAction { minimalMenuOpen = true }
    }

    private func minimalMenuRow(_ title: String, _ symbol: String, selected: Bool = false, badge: Bool = false, id: String, action: @escaping () -> Void) -> some View {
        Button {
            minimalMenuOpen = false
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 22)
                Text(title)
                if badge {
                    Circle().fill(theme.status.danger.color(for: scheme))
                        .frame(width: 8, height: 8)
                        .accessibilityIdentifier("douyin.module.messages.badge")
                }
                Spacer(minLength: 12)
                if selected { Image(systemName: "checkmark") }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private var recommendArea: some View {
        ZStack(alignment: .topLeading) {
            if feed.items.isEmpty {
                VStack(spacing: WuWeiDesign.Spacing.md) {
                    if let e = feed.error {
                        Text(e).font(.footnote).multilineTextAlignment(.center)
                            .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                        HStack {
                            Button("重试") { Task { await feed.loadMore(bridge); currentID = feed.items.first?.id } }
                                .buttonStyle(.borderedProminent)
                            Button("打开网页版") { web = DYWebTarget(url: DouyinWeb.home) }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        ProgressView().tint(theme.media.onMedia.color(for: scheme))
                        Text(bridge.ready ? "加载推荐…" : "连接抖音…").font(.footnote)
                            .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                    }
                    DYHashtagFilterButton(tags: []).buttonStyle(.bordered)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 四种界面共用同一个分页器（含「更快」收尾），见 DYFeedPager.swift
                DYFeedPager(items: feed.items, currentID: $currentID, scrollID: $scrollID,
                            userScrolling: $userScrolling, scrollEndTask: $scrollEndTask) { item in
                    page(for: item)
                }
            }
        }
    }

    /// 单页构造拆成独立函数：参数太多，写在 ForEach 里会让类型检查超时。
    private func page(for item: DYAweme) -> some View {
        let extras = AnyView(moreExtrasMenu(item))
        let active = item.id == currentID && web == nil && tab == .recommend && !overlayOpen
        return DYVideoPage(item: item,
                           isCurrent: active,
                           insets: insets,
                           resume: resume[item.id],
                           liked: feed.liked.contains(item.id),
                           collected: feed.collected.contains(item.id),
                           onLike: { toggleLike(item.id, force: nil) },
                           onCollect: { toggleCollect(item.id) },
                           onDoubleTap: { toggleLike(item.id, force: true) },
                           onComments: { withAnimation(.snappy) { showComments.toggle() } },
                           onSearch: { openSearch() },
                           onAuthor: { authorTarget = item.author },
                           onSavePosition: { resume[item.id] = $0; saveSession() },
                           preloader: preloader,
                           bridge: bridge,
                           onToast: { showToast($0) },
                           onDislike: { dislike(item.id) },
                           moreExtras: extras,
                           onEnded: { playNext(after: item.id) })
    }

    /// 点赞：先本地乐观更新，再调抖音网页接口，按服务端返回决定成败
    /// （不用 cookie 判断登录态：sessionid 是 HttpOnly，document.cookie 读不到，会误判成未登录）
    private func toggleLike(_ id: String, force: Bool?) { feed.toggleLike(id, force: force, bridge: bridge) }


    /// 不感兴趣：立刻从列表拿掉并切到下一条，后台告诉抖音（失败只提示，不把视频塞回来）
    private func dislike(_ id: String) {
        guard let i = feed.items.firstIndex(where: { $0.id == id }) else { return }
        let next = i + 1 < feed.items.count ? feed.items[i + 1].id : (i > 0 ? feed.items[i - 1].id : nil)
        scrollEndTask?.cancel(); userScrolling = false
        showComments = false
        if currentID == id { currentID = next; scrollID = next }
        feed.items.remove(at: i)
        resume[id] = nil
        saveSession()
        showToast("将减少此类推荐")
        Task {
            await DYVideoCache.shared.markWatched(id)
            do {
                switch try await bridge.dislike(id) {
                case .ok: break
                case .notLoggedIn: showToast("抖音未登录，「不感兴趣」没同步到账号")
                case .failed(let why): showToast("「不感兴趣」同步失败：\(why)")
                }
            } catch {
                showToast("「不感兴趣」同步失败：\(error.localizedDescription)")
            }
        }
        if next == nil { Task { await feed.loadMore(bridge); currentID = feed.items.first?.id; scrollID = currentID } }
    }

    /// 收藏 / 取消收藏（同步到抖音账号的「收藏」）
    private func toggleCollect(_ id: String) { feed.toggleCollect(id, bridge: bridge) }


    private func rateTitle(_ r: Double) -> String { r == 1 ? "正常速度" : String(format: "%g 倍速", r) }

    private func showToast(_ s: String) { feed.showToast(s) }


    /// 「更多」最后一节：设置（点进完整设置页）。刷新推荐 / 弹幕 / 界面都在设置页里。
    @ViewBuilder
    private func moreExtrasMenu(_ item: DYAweme) -> some View {
        Section { DYSettingsButton() }
    }

}


struct DYWebTarget: Identifiable { let id = UUID(); let url: URL }

/// 右侧功能栏的几何：进度环外径 = 玻璃胶囊宽（50pt）；入口到胶囊的间距沿用胶囊到「更多」的间距（actionGroupSpacing）。
/// 简洁/极简入口外圈的视频进度环。独立订阅 DDRailProgress，进度变化只重画这颗环。
private struct DDRailProgressRing: View {
    @Environment(\.appTheme) private var theme
    let show: Bool
    let fg: Color
    @ObservedObject private var railProgress = DDRailProgress.shared

    var body: some View {
        // 简洁 / 极简的推荐页、关注页画进度环；直播没有进度，不画——但占位恒定，切模块时入口位置不动。
        let d = DDRailMetrics.entryDiameter
        let lw = theme.media.progressRingWidth
        return ZStack {
            if show {
                Circle().stroke(fg.opacity(theme.media.progressRingTrackOpacity), lineWidth: lw)
                Circle()
                    .trim(from: 0, to: max(railProgress.fraction, 0.004))
                    .stroke(fg, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lw / 2)
        .frame(width: d, height: d)
        .animation(.linear(duration: 0.25), value: railProgress.fraction)
        .allowsHitTesting(false)
        .accessibilityIdentifier("douyin.module.ring")
        .accessibilityValue(show ? "\(Int(railProgress.fraction * 100))%" : "")
        .accessibilityHidden(!show)
    }
}

enum DDRailMetrics {
    static let entryDiameter: CGFloat = 50
}

/// 按住 ≥ threshold 秒算「长按」，抬手前一直保持；不满 threshold 抬手算「单击」。
/// 用 DragGesture(minimumDistance: 0) 自己计时：系统的 onLongPressGesture 达到时长后会自动结束，
/// 无法做到「按住期间一直显示、抬手才消失」。
struct DDPressHold: ViewModifier {
    let threshold: Double
    /// 按满 threshold 秒进入长按（true），长按后抬起（false）
    var onHoldChanged: (Bool) -> Void = { _ in }
    /// 按下 / 抬起（按下立即回调 true，抬起回调 false）
    let onPressChanged: (Bool) -> Void
    /// 按下不满 threshold 秒就抬起（且基本没移动）
    let onTap: () -> Void
    @State private var startedAt: Date?
    @State private var holding = false
    @State private var timer: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard startedAt == nil else { return }
                    startedAt = Date()
                    onPressChanged(true)
                    timer = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(threshold * 1_000_000_000))
                        guard !Task.isCancelled, startedAt != nil else { return }
                        holding = true
                        onHoldChanged(true)
                    }
                }
                .onEnded { value in
                    timer?.cancel(); timer = nil
                    let wasHolding = holding
                    let moved = abs(value.translation.width) >= 20 || abs(value.translation.height) >= 20
                    startedAt = nil; holding = false
                    if wasHolding { onHoldChanged(false) }
                    if !wasHolding, !moved {
                        onTap()          // 先开菜单（它会接管标题的显示），再回调抬起
                    }
                    onPressChanged(false)
                })
    }
}

/// 默认模式的顶栏贴物理屏最上沿：整层忽略顶部和左右安全区（与 PR #12 之前一致）。
struct DDClassicTopInset: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.ignoresSafeArea(edges: [.top, .horizontal]) } else { content }
    }
}

/// 界面模式（更多 → 界面模式）：
/// - classic 默认：顶部「关注/推荐/直播」文字页签 + 原有右侧按钮栏（PR #12 之前的样子）
/// - rail 简洁：页签收进右侧功能栏的圆形模块入口，搜索进该入口的菜单
/// - minimal 极简：同简洁，并且隐藏作者和标题
enum DDChromeMode: String, CaseIterable, Identifiable {
    case classic, rail, minimal, duoClassic
    static let key = "douyin_chrome_mode_v1"
    var id: String { rawValue }
    var title: String {
        switch self { case .classic: "默认"; case .rail: "简洁"; case .minimal: "极简"; case .duoClassic: "经典" }
    }
    var symbol: String {
        switch self { case .classic: "rectangle.topthird.inset.filled"; case .rail: "sidebar.right"; case .minimal: "rectangle"; case .duoClassic: "play.rectangle.on.rectangle" }
    }
    var usesRail: Bool { self == .rail || self == .minimal }
    static var availableCases: [Self] {
        if #available(iOS 27.1, *) { return allCases }
        return [.classic, .rail, .minimal]
    }
    var hidesInfo: Bool { self == .minimal }
}

/// 当前安装的版本号与构建号，读自 Info.plist。
enum DDAppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

enum DYTab: CaseIterable { case follow, recommend, live
    var symbol: String {
        switch self {
        case .follow: "heart.fill"
        case .recommend: "play.rectangle"
        case .live: "dot.radiowaves.left.and.right"
        }
    }

    var title: String {
        switch self {
        case .follow: "关注"
        case .recommend: "推荐"
        case .live: "直播"
        }
    }
}

// MARK: - classic-channel-navigation

/// 关注流回来时按作品 ID 恢复，ID 不在当前列表里才落到第一条。
enum DYFollowFeedSelection {
    static func restored(preserved: String?, ids: [String]) -> String? {
        if let preserved, ids.contains(preserved) { return preserved }
        return ids.first
    }
}

/// 经典频道横向拖动。fraction 相对当前页宽度：负值是顺序中的下一频道，正值是上一频道。
struct DYClassicChannelDrag: Equatable {
    var fraction: CGFloat
    var neighbor: DYTab?
    var authorEdge: Bool

    /// 只给经典模式用。枚举本身仍是关注、推荐、直播，避免改到简洁和极简。
    static let order: [DYTab] = [.live, .follow, .recommend]

    static func update(tab: DYTab, translation: CGFloat, width: CGFloat, order: [DYTab] = DYClassicChannelDrag.order) -> DYClassicChannelDrag {
        let width = max(width, 1)
        let raw = translation / width
        let neighbor = Self.neighbor(of: tab, toward: raw, order: order)
        let authorEdge = neighbor == nil && tab == order.last && raw < 0
        let fraction = neighbor == nil ? raw * 0.2 : min(1, max(-1, raw))
        return DYClassicChannelDrag(fraction: fraction, neighbor: neighbor, authorEdge: authorEdge)
    }

    static func neighbor(of tab: DYTab, toward fraction: CGFloat, order: [DYTab] = DYClassicChannelDrag.order) -> DYTab? {
        guard let index = order.firstIndex(of: tab) else { return nil }
        if fraction < 0, index + 1 < order.count { return order[index + 1] }
        if fraction > 0, index > 0 { return order[index - 1] }
        return nil
    }

    /// 位移或预测落点过半才切页。预测落点用来接快速轻扫。
    static func commits(translation: CGFloat, predicted: CGFloat, width: CGFloat) -> Bool {
        let width = max(width, 1)
        return abs(translation) / width >= 0.5 || abs(predicted) / width >= 0.5
    }

    /// 推荐页右缘的左滑过半才打开作者。没过半或被取消时保持原页。
    static func opensAuthor(authorEdge: Bool, translation: CGFloat, predicted: CGFloat, width: CGFloat, cancelled: Bool) -> Bool {
        !cancelled && authorEdge && translation < 0 && commits(translation: translation, predicted: predicted, width: width)
    }
}

// MARK: - classic-channel-navigation-end

// MARK: - 单页

struct DYVideoPage: View {
    @AppStorage(DDChromeMode.key) private var chromeModeRaw = DDChromeMode.classic.rawValue
    @Environment(\.dySearchCoversVideo) private var searchCoversVideo
    @Environment(\.dyHashtagFilterPresented) private var filterPresented
    @Environment(\.dyStandaloneBack) private var standaloneBack
    let onSearch: () -> Void
    var moreExtras: AnyView
    var onBack: (() -> Void)?
    let item: DYAweme
    let isCurrent: Bool
    let insets: EdgeInsets
    let resume: Double?
    let liked: Bool
    let collected: Bool
    let onLike: () -> Void
    let onCollect: () -> Void
    let onDoubleTap: () -> Void
    let onComments: () -> Void
    let onAuthor: () -> Void
    let onSavePosition: (Double) -> Void
    let preloader: DYPreloader
    let bridge: DouyinBridge?
    let onToast: ((String) -> Void)?
    /// 只有推荐流传：关注 / 搜索 / 我的 里不显示「不感兴趣」
    let onDislike: (() -> Void)?
    /// 播完切下一条（「自动连播」打开才生效）
    var onEnded: (() -> Void)? = nil
    var onShowFollowing: (() -> Void)? = nil
    var onNavigateLeft: (() -> Void)? = nil
    var onChannelDrag: ((CGFloat, CGFloat) -> Void)? = nil
    var onChannelDragEnd: ((CGFloat, CGFloat, CGFloat, Bool) -> Void)? = nil
    init(item: DYAweme, isCurrent: Bool, insets: EdgeInsets, resume: Double?, liked: Bool, collected: Bool,
         onLike: @escaping () -> Void, onCollect: @escaping () -> Void, onDoubleTap: @escaping () -> Void,
         onComments: @escaping () -> Void, onSearch: @escaping () -> Void = {}, onAuthor: @escaping () -> Void, onSavePosition: @escaping (Double) -> Void,
         preloader: DYPreloader, bridge: DouyinBridge? = nil, onToast: ((String) -> Void)? = nil,
         onDislike: (() -> Void)? = nil, moreExtras: AnyView = AnyView(EmptyView()),
         onEnded: (() -> Void)? = nil,
         onShowFollowing: (() -> Void)? = nil, onNavigateLeft: (() -> Void)? = nil, onBack: (() -> Void)? = nil,
         onChannelDrag: ((CGFloat, CGFloat) -> Void)? = nil,
         onChannelDragEnd: ((CGFloat, CGFloat, CGFloat, Bool) -> Void)? = nil) {
        self.item = item; self.isCurrent = isCurrent; self.insets = insets; self.resume = resume
        self.liked = liked; self.collected = collected
        self.onLike = onLike; self.onCollect = onCollect; self.onDoubleTap = onDoubleTap
        self.onComments = onComments; self.onAuthor = onAuthor; self.onSavePosition = onSavePosition
        self.preloader = preloader; self.bridge = bridge; self.onToast = onToast
        self.onDislike = onDislike
        self.onEnded = onEnded
        self.onShowFollowing = onShowFollowing
        self.onNavigateLeft = onNavigateLeft
        self.onSearch = onSearch; self.moreExtras = moreExtras; self.onBack = onBack
        self.onChannelDrag = onChannelDrag
        self.onChannelDragEnd = onChannelDragEnd
    }

    var body: some View {
        Group {
            if #available(iOS 27.1, *), chromeModeRaw == DDChromeMode.duoClassic.rawValue {
                DYClassicVideoPage(item: item, isCurrent: isCurrent && !searchCoversVideo && !filterPresented, insets: insets, resume: resume,
                    liked: liked, collected: collected, onLike: onLike, onCollect: onCollect,
                    onDoubleTap: onDoubleTap, onComments: onComments, onAuthor: onAuthor,
                    onSavePosition: onSavePosition, preloader: preloader, bridge: bridge, onToast: onToast,
                    onDislike: onDislike, onEnded: onEnded, onShowFollowing: onShowFollowing, onNavigateLeft: onNavigateLeft,
                    onChannelDrag: onChannelDrag, onChannelDragEnd: onChannelDragEnd)
            } else {
                DYUpstreamVideoPage(item: item, isCurrent: isCurrent && !searchCoversVideo && !filterPresented, insets: insets, resume: resume,
                    liked: liked, collected: collected, onLike: onLike, onCollect: onCollect,
                    onDoubleTap: onDoubleTap, onComments: onComments, onSearch: onSearch, onAuthor: onAuthor,
                    onSavePosition: onSavePosition, preloader: preloader, bridge: bridge, onToast: onToast,
                    onDislike: onDislike, moreExtras: moreExtras, onEnded: onEnded, onBack: onBack ?? standaloneBack)
            }
        }
        .modifier(DYForwardFeedbackPresentation(bottomInset: insets.bottom, isCurrent: isCurrent))
    }
}

struct DouyinFeedScreen: View {
    @AppStorage(DDChromeMode.key) private var chromeModeRaw = DDChromeMode.classic.rawValue
    var body: some View {
        Group {
            if #available(iOS 27.1, *), chromeModeRaw == DDChromeMode.duoClassic.rawValue {
                DYClassicFeedScreen()
            } else {
                DYUpstreamFeedScreen()
            }
        }
        .modifier(DYHashtagFilterPresentation())
    }
}

extension EnvironmentValues {
    @Entry var dyStandaloneBack: (() -> Void)? = nil
}

@available(iOS 27.1, *)
struct DYClassicFeedScreen: View {
    @AppStorage("douyin_muted_v1") private var muted = false
    @AppStorage("douyin_bg_play_v1") private var bgPlay = false
    @AppStorage("douyin_autoplay_v1") private var autoNext = false
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @StateObject private var bridge = DouyinBridge()
    @StateObject private var feed = DYFeedModel()
    @AppStorage(DYHashtagFilter.storageKey) private var blockedHashtags = ""
    @Environment(\.dyHashtagFilterPresented) private var hashtagFilterPresented
    @State private var insets = EdgeInsets()
    @State private var preloader = DYPreloader()
    @State private var resume: [String: Double] = [:]
    @State private var currentID: String?
    @State private var scrollID: String?
    @State private var userScrolling = false
    @State private var scrollEndTask: Task<Void, Never>?
    @State private var focusTask: Task<Void, Never>?
    @State private var initialized = false
    @State private var refreshing = false
    @State private var showComments = false
    @State private var web: DYWebTarget?
    @State private var showSettings = false
    @State private var tab: DYTab = {
        let e = ProcessInfo.processInfo.environment
        if e["DOUDUO_STARTLIVE"] == "1" { return .live }
        if e["DOUDUO_STARTFOLLOW"] == "1" { return .follow }
        return .recommend
    }()
    @StateObject private var live = DYLiveModel()
    @State private var searchSession: DYSearchSession?
    @State private var searchIsSplit = false
    private var showSearch: Bool { searchSession != nil }
    private func openSearch() {
        DYSearchSession.transition { showComments = false; searchSession = DYSearchSession() }
    }
    @State private var lastFeedPull = Date.distantPast
    @AppStorage(DYVideoCache.countKey) private var cacheCount = DYVideoCache.defaultCount
    @State private var mainTab: DYMainTab = .home
    @State private var forwardedChat: DYForwardReceipt?
    @State private var visibleVideo: DYAweme?
    @State private var cleanScreen = false
    private var showMine: Bool {
        get { mainTab == .mine }
        nonmutating set { mainTab = newValue ? .mine : .home }
    }
    @State private var authorTarget: DYAweme.Author?
    @State private var authorWorkOpen = false
    /// 跟手切换的进度，相对当前内容宽度。负值推向下一频道。
    @State private var channelFraction: CGFloat = 0
    @State private var channelNeighbor: DYTab?
    @State private var channelAuthorEdge = false
    @State private var channelWidth: CGFloat = 0
    @State private var channelSettling = false
    @State private var playbackSuspended = false
    @StateObject private var followList = DYPagedModelHolder()
    @State private var followCurrentID: String?
    @State private var pendingUpdate: DDUpdate?
    private var showMessages: Bool {
        get { mainTab == .messages }
        nonmutating set { mainTab = newValue ? .messages : .home }
    }
    /// A side-by-side author pane leaves the current video visible and playing.
    private var overlayOpen: Bool { hashtagFilterPresented || (showSearch && (!searchIsSplit || searchSession?.presentsVideo == true)) || showMine || showMessages || authorWorkOpen || (authorTarget != nil && !supportsSidePanel) }
    /// 全局播放速度；长按临时倍速不修改持久化偏好。
    @AppStorage("douyin_playback_rate_v1") private var playbackRate = 1.0
    @State private var noticeUnread = 0
    @State private var wideToken = UUID()
    @State private var topChrome = CGRect.zero
    @State private var supportsSidePanel = false
    @State private var residentComments = false
    private var liveRoomOpen: Bool { tab == .live && live.entered }
    private var sidePanelOpen: Bool { !showSearch && (residentComments || (supportsSidePanel && (authorTarget != nil || showComments))) }
    private var hidesVideoChrome: Bool { (!showSearch && (showComments || residentComments || authorTarget != nil)) || liveRoomOpen }
    private var headerTopInset: CGFloat {
        // NavigationStack's inset includes a horizontal toolbar after rotation.
        // The fixed video header needs only the physical window's safe area.
        let physicalTop = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.safeAreaInsets.top ?? 0
        return max(physicalTop, 8)
    }

    private var currentIndex: Int? { currentID.flatMap { id in feed.items.firstIndex { $0.id == id } } }
    private var current: DYAweme? { currentIndex.map { feed.items[$0] } }
    private var commentAweme: DYAweme? { tab == .follow ? visibleVideo : current }

    var body: some View {
        systemTabs
        .modifier(DYSearchPresentation(bridge: bridge, session: $searchSession, isSplit: $searchIsSplit,
                                      onOpen: { showComments = false }))
        .onChange(of: showComments) { _, shown in if shown { searchSession = nil } }
        .background(DouyinBridgeHost(bridge: bridge).frame(width: 1, height: 1).allowsHitTesting(false))
        .task {
            guard !initialized else { return }
            initialized = true
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_HASHTAG_FIXTURE"] == "1" {
                feed.items = feed.allowedRecommendations(DYFeedModel.hashtagFixtures)
                currentID = feed.items.first?.id
                scrollID = currentID
                return
            }
            #endif
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_SELFTEST"] == "1" { Task { await DDSelfTest.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_APITEST"] == "1" { Task { await DDApiProbe.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_LIVEPROBE"] == "1" { Task { await DDFeatureProbe.run(bridge, live: live) } }
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_APISCAN"] == "1" { Task { await DYApiScanner.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_CPROBE"] == "1" { Task { await DYCommentApiProbe.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_LOGINPROBE"] == "1" { Task { await DYLoginProbe.run(bridge) } }
            #endif
            if ProcessInfo.processInfo.environment["DOUDUO_EXPORTTEST"] == "1" { Task { await DDFeatureProbe.exportHeadProbe(bridge) } }
            // 真机验收用：DOUDUO_STARTLIVE=1 + DOUDUO_AUTOLIVEROOM=1 直接进房，省去手点。
            if ProcessInfo.processInfo.environment["DOUDUO_AUTOLIVEROOM"] == "1" {
                Task { @MainActor in
                    var waited = 0
                    while live.rooms.isEmpty, waited < 24 {
                        try? await Task.sleep(for: .milliseconds(500))
                        waited += 1
                    }
                    try? await Task.sleep(for: .milliseconds(800))
                    if !live.entered, !live.rooms.isEmpty { live.enterRoom() }
                }
            }
            #endif
            if tab == .live { return }   // 起手就是直播页（调试）时别把推荐流的播放器都拉起来
            // 秒开：先播上次缓存好、还没看过的；连接抖音 / 拉推荐在后台接着往后补（两套界面共用 DYFeedModel.restoreForLaunch）
            if let restored = feed.restoreForLaunch() {
                resume = restored.positions
                currentID = restored.currentID
                scrollID = currentID
            }
            // 恢复的会话里「当前条之后」是上次的排法：按现在的方向 / 比例重排（当前这条不动）
            if currentIndex != nil { feed.remix(after: currentIndex) }
            await feed.loadMore(bridge)
            if currentID == nil { currentID = feed.items.first?.id }
            focusCurrent()
            #if DEBUG
            // 用真实作品详情复验元数据显示，不造预览数据、不做账号互动。
            if let id = ProcessInfo.processInfo.environment["DOUDUO_VIDEO_ID"],
               let item = try? await bridge.awemeDetail(id) {
                feed.items = [item]; currentID = item.id; scrollID = item.id
                focusCurrent()
            }
            let env0 = ProcessInfo.processInfo.environment
            if let d = env0["DOUDUO_LIVEDELAY"], let sec = Double(d) {
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) { tab = .live }
            }
            let env = ProcessInfo.processInfo.environment
            if let o = env["DOUDUO_OPEN"] {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                switch o {
                case "search": openSearch()
                case "mine": showMine = true
                case "follow": tab = .follow
                case "author": authorTarget = current?.author
                case "comments": showComments = true
                case "messages": showMessages = true
                case "login": web = DYWebTarget(url: URL(string: "https://www.douyin.com/?recommend=1")!)
                case "qr": Task { await bridge.debugQRLogin() }
                case "export": Task { await bridge.debugExportCookies() }
                case "import": Task { await bridge.debugImportCookies() }
                default: break
                }
            }
            if env["WUWEI_DEBUG_DOUYIN_ADVANCE"] == "1" {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if feed.items.count > 1 { withAnimation { currentID = feed.items[1].id } }
            }
            if env["WUWEI_DEBUG_DOUYIN_LIVE"] == "1" { tab = .live }
            if env["WUWEI_DEBUG_DOUYIN_COMMENTS"] == "1" {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                showComments = true
            }
            #endif
        }
        .task(id: currentID) {
            // 旧会话没有新增字段：只补当前作品元数据，不换播放地址、不丢进度。
            guard let id = currentID, feed.items.contains(where: { $0.id == id && $0.publishedAt == nil }),
                  let detail = try? await bridge.awemeDetail(id), !Task.isCancelled,
                  let index = feed.items.firstIndex(where: { $0.id == id }) else { return }
            feed.items[index].publishedAt = detail.publishedAt
            feed.items[index].aiDeclaration = detail.aiDeclaration
            saveSession()
        }
        .onChange(of: currentID) { old, new in
            // ⚠️ 宽屏（Duo 内屏）首次布局时 ScrollView 会把 scrollPosition 回写成 nil → 没有「当前条」→ 全部不播、上滑也不认。
            // 列表非空时把 nil 顶回上一个；刷新 / 重载会先清空列表再置 nil，不受影响。
            if new == nil, let old, feed.items.contains(where: { $0.id == old }) { currentID = old; return }
            scrollID = new
            // 手滑换条发生在滑动途中：预加载器要销毁 / 新建播放器，是主线程同步的重活，砸在滑动帧上会顿一下。
            // 起播不依赖它，所以等手停下来（0.3s 没再换条）再做；点按钮 / 自动连播等非手滑的换条照旧立刻做。
            focusTask?.cancel()
            if userScrolling {
                focusTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if !Task.isCancelled { focusCurrent() }
                }
            } else {
                focusCurrent()
            }
            saveSession()
            reportWatch(old: old, new: new)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            saveSession()
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if DDPlayback.shared.appIsActive { saveSession() }
        }
        .onChange(of: cacheCount) { _, _ in focusCurrent() }
        .task(id: blockedHashtags) { await applyHashtagFilter() }
        .onChange(of: feed.landscapeWhenWide) { _, _ in remixUpcoming() }
        .onChange(of: feed.shortWhenTall) { _, _ in remixUpcoming() }
        .onDisappear { live.stop(); preloader.clear() }
        .environment(\.dyOpenSettings, { showSettings = true })
        .sheet(isPresented: $showSettings) {
            DYSettingsScreen(onOpenWeb: { web = DYWebTarget(url: DouyinWeb.home) },
                             onRefresh: { Task { await refreshRecommendations() } },
                             onCacheCleared: { focusCurrent() })
        }
        .fullScreenCover(item: $web, onDismiss: {
            // 网页里可能登录 / 过了验证：重开签名页，先重新读登录态，再刷推荐
            live.reset(); preloader.clear(); feed.reset(); currentID = nil
            followList.resetModel(); followCurrentID = nil
            bridge.reload()
            Task {
                await feed.loadMore(bridge)
                currentID = feed.items.first?.id
                focusCurrent()
            }
            if tab == .live { Task { await live.load(bridge, reset: true) } }
        }) { t in
            DouyinWebScreen(start: t.url)
        }
        .onChange(of: bridge.followSession) { _, _ in
            followList.resetModel()
            followCurrentID = nil
        }
        .task { await refreshNoticeUnread() }
        .task {
            #if DEBUG
            // 模拟器无触摸输入：DOUDUO_MSGTEST=1 → 起播后自动打开消息页
            if ProcessInfo.processInfo.environment["DOUDUO_MSGTEST"] == "1" {
                try? await Task.sleep(for: .seconds(8))
                showMessages = true
                DYLiveModel.log("DDMSGTEST auto-open messages")
            }
            #endif
        }
        .task {
            // 只预取一页直播元数据，不拉流、不进房；用户点直播时不必再从零等列表。
            guard tab != .live else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard live.rooms.isEmpty, !Task.isCancelled else { return }
            await live.load(bridge, reset: true)
        }
        .onChange(of: showMessages) { _, open in
            if !open { Task { await refreshNoticeUnread() } }
        }
        .task {
            // 启动查一次新版本；关掉后同一版本不再提示
            if let u = await DDUpdateChecker.check() { pendingUpdate = u }
        }
        .alert("有新版本", isPresented: Binding(get: { pendingUpdate != nil }, set: { if !$0 { if let u = pendingUpdate { DDUpdateChecker.dismiss(u) }; pendingUpdate = nil } })) {
            Button("去 GitHub 更新") {
                if let u = pendingUpdate { DDUpdateChecker.dismiss(u); DDUpdateChecker.open(u) }
                pendingUpdate = nil
            }
            Button("关闭", role: .cancel) {
                if let u = pendingUpdate { DDUpdateChecker.dismiss(u) }
                pendingUpdate = nil
            }
        } message: {
            Text("新版本 \(pendingUpdate?.version ?? "")（当前 \(DDUpdateChecker.currentVersion)）\n去 GitHub 下载新版，重新签名安装即可，登录态会保留。")
        }
    }

    private var systemTabs: some View {
        TabView(selection: $mainTab) {
            Tab("我的", systemImage: "person.crop.circle", value: DYMainTab.mine) {
                DYMineScreen(bridge: bridge,
                             onLogin: { mainTab = .home; web = DYWebTarget(url: DouyinWeb.home) },
                             onAuthor: { item in
                                 mainTab = .home
                                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { authorTarget = item.author }
                             },
                             onMessages: { mainTab = .messages })
                    .tint(nil)
            }
            Tab("消息", systemImage: "bubble.left.and.bubble.right", value: DYMainTab.messages) {
                DYMessagesScreen(bridge: bridge, onWeb: { url in
                    mainTab = .home
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { web = DYWebTarget(url: url) }
                }, forwardedShare: forwardedChat)
                .tint(nil)
            }
            .badge(noticeUnread)
            Tab("首页", systemImage: "house", value: DYMainTab.home) {
                NavigationStack {
                    layoutRoot
                        .coordinateSpace(.named("douduo.feed"))
                        .environment(\.duoSystemBars, true)
                        .environment(\.duoInlineVideoNavigation, sidePanelOpen)
                        .environment(\.duoVisibleVideo, $visibleVideo)
                        .environment(\.duoCleanScreen, cleanScreen)
                        .overlayPreferenceValue(DYActiveVideoActionsKey.self) { actions in
                            DYNativeVideoActions(actions: hidesVideoChrome ? nil : actions,
                                                 isClean: cleanScreen,
                                                 onToggleClean: { cleanScreen.toggle() })
                        }
                        .toolbarVisibility(liveRoomOpen ? .hidden : .visible, for: .navigationBar)
                        .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
                        .toolbarMinimizationBehavior(.never, for: .navigationBar)
                        .scrollEdgeEffectHidden(true, for: .all)
                        // Hide the underlying native selector for compact
                        // sheets too, so dismissing comments does not restore
                        // a previously expanded tab picker over the video rail.
                        .modifier(DYSystemTabBar(hidden: hidesVideoChrome || cleanScreen))
                }
                .tint(nil)
            }
        }
        .environment(\.dyForwardOpenChat, { receipt in
            forwardedChat = receipt
            mainTab = .messages
        })
        // Only the tab selector inherits this accent. Every tab restores the
        // existing default tint; explicitly styled buttons keep their colors.
        .tint(theme.accent.color(for: scheme))
        .toolbarVisibility(.visible, for: .statusBar)
        .onChange(of: mainTab) { _, selected in
            saveSession()
            if selected != .home { DDPlayback.shared.pauseAll(reason: .cover) }
        }
    }

    @ViewBuilder
    private var layoutRoot: some View {
        GeometryReader { geo in
            let wide = Self.playAreaIsWide(geo)
            flatArrangement(geo)
                .onAppear { feed.screenWide = wide; insets = geo.safeAreaInsets }
                .onChange(of: geo.safeAreaInsets) { _, value in insets = value }
                .onGeometryChange(for: Bool.self) { proxy in
                    proxy.size.width >= DYDuoMetrics.legacyWideMin || (DYDuoMetrics.foldIsActive(proxy) && proxy.size.width > proxy.size.height)
                } action: { supportsSidePanel = $0 }
                .onChange(of: wide) { _, w in
                    // 转屏过程中尺寸会抖几下，稳定 0.4 秒再重排
                    let token = UUID(); wideToken = token
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard wideToken == token, feed.screenWide != w else { return }
                        feed.screenWide = w
                        remixUpcoming()
                    }
                }
        }
    }

    /// 播放区是不是横的：平放/单屏看整个窗口；半折叠看视频实际占的那块
    private static func playAreaIsWide(_ geo: GeometryProxy) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_FORCEWIDE"] == "1" { return true }
        #endif
        let w = geo.size.width, h = geo.size.height
        guard DYDuoMetrics.foldIsActive(geo) else { return w > h }
        // 与默认布局同一口径：按整屏形状判断横竖，不按半折叠后视频那一块（见 DYUpstreamFeedScreen.playAreaIsWide）。
        // 按视频块判断会把竖拿的桌面半折叠判成横屏，推荐流只排横屏视频，竖屏短视频几乎刷不到。
        return w > h ? (w * 0.55 > h) : false
    }

    /// 当前条之后按新的方向/比例重排；不够就接着拉
    private func remixUpcoming() {
        guard tab == .recommend || !feed.items.isEmpty else { return }
        feed.remix(after: currentIndex)
        DYLiveModel.log("DDMIX remix wide=\(feed.screenWide) upcoming=\(feed.items.count - (currentIndex ?? -1) - 1)")
        if currentID == nil { currentID = feed.items.first?.id; scrollID = currentID }
        lastFeedPull = .distantPast
        focusCurrent()
    }

    /// 一套布局通吃所有状态，且**不换容器**（换容器会重建播放器 → 黑屏 / 重播）：
    /// - 平放/外屏：视频铺满；够宽时评论从右侧滑出（视频缩窄），窄屏走底部 sheet
    /// - 半折叠：视频自动缩到一多半，另一半常驻评论（宽>高→左右分；高>宽→上下分）
    private func flatArrangement(_ geo: GeometryProxy) -> some View {
        let layout = DYCommentPaneMetrics(geo, isPresented: !showSearch && (authorTarget != nil || showComments),
                                          allowsResident: !showSearch && tab != .live, paneFraction: authorTarget == nil ? nil : 0.5)
        let w = geo.size.width, h = geo.size.height

        return ZStack(alignment: .topLeading) {
            feedArea
                .frame(width: layout.videoSize.width, height: layout.videoSize.height, alignment: .topLeading)
            if layout.showsPane {
                Group {
                    if let author = authorTarget {
                        DYAuthorScreen(bridge: bridge, author: author,
                                       onWeb: { web = DYWebTarget(url: $0) },
                                       onClose: { withAnimation(.snappy) { authorTarget = nil } },
                                       onWorkPresentationChange: { authorWorkOpen = $0 })
                            .padding(.trailing, layout.trailingInset)
                            .id(author.id)
                    } else if let cur = commentAweme {
                        DYCommentPanel(bridge: bridge, aweme: cur,
                                       onClose: layout.resident ? nil : { withAnimation(.snappy) { showComments = false } },
                                       fillsPane: true, trailingInset: layout.trailingInset)
                            .id(cur.id)
                    }
                }
                .frame(width: layout.paneSize.width, height: layout.paneSize.height)
                .clipped()
                .dyDeskLight(layout.resident && !layout.sideBySide && authorTarget == nil)
                .overlay(alignment: .leading) {
                    if layout.sideBySide { Color(uiColor: .separator).frame(width: 0.5) }
                }
                .offset(x: layout.paneOrigin.x, y: layout.paneOrigin.y)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .onChange(of: layout.resident, initial: true) { _, resident in residentComments = resident }
        .background(theme.media.strongScrim.color(for: scheme).ignoresSafeArea())
        .animation(showSearch ? nil : .snappy, value: layout.resident)
        .animation(showSearch ? nil : .snappy, value: showComments)
        .animation(showSearch ? nil : .snappy, value: authorTarget?.id)
        .dyBottomSheet(isPresented: Binding(get: { !showSearch && showComments && !layout.sideBySide && !layout.resident }, set: { if !supportsSidePanel && !layout.resident { showComments = $0 } }), kind: .comments) {
            if let cur = commentAweme {
                DYCommentSheet(bridge: bridge, aweme: cur, onClose: { showComments = false })
            }
        }
    }

    private func refreshNoticeUnread() async {
        guard let groups = try? await bridge.noticeCounts() else { return }
        noticeUnread = DYMessagesScreen.badge(groups)
    }

    /// 换条时：上一条看完没有（≥95%，网页版同口径）+ 新一条起播 1.5 秒后上报
    private func reportWatch(old: String?, new: String?) {
        guard let new, let item = feed.items.first(where: { $0.id == new }) else { return }
        var seen = false
        if let old, let prev = feed.items.first(where: { $0.id == old }), prev.duration > 0,
           DDNowPlaying.id == old { seen = DDNowPlaying.time / prev.duration >= 0.95 }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard currentID == new else { return }
            await bridge.reportWatch(item, preID: old, preSeen: seen)
        }
    }

    private func saveSession() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_HASHTAG_FIXTURE"] == "1" { return }
        #endif
        guard let id = currentID, feed.items.contains(where: { $0.id == id }) else { return }
        var positions = resume
        if DDNowPlaying.id == id, DDNowPlaying.time.isFinite {
            positions[id] = max(0, DDNowPlaying.time)
        }
        DYFeedSession(items: feed.items, currentID: id, positions: positions).save()
    }

    /// 自动连播：播完滑到下一条；快到底时先补一页
    private func playNext(after id: String) {
        guard let i = feed.items.firstIndex(where: { $0.id == id }) else { return }
        if i + 1 < feed.items.count {
            withAnimation { currentID = feed.items[i + 1].id }
        } else {
            Task {
                await feed.loadMore(bridge)
                if let j = feed.items.firstIndex(where: { $0.id == id }), j + 1 < feed.items.count {
                    withAnimation { currentID = feed.items[j + 1].id }
                }
            }
        }
    }

    /// 点页签只切页，不再顺手刷新（点顶部会误触成「刷新视频」）。
    /// 要换一批推荐走「更多 → 刷新推荐」。
    private func selectTab(_ target: DYTab) {
        guard tab != target, !channelSettling else { return }
        showComments = false
        authorTarget = nil
        guard channelWidth > 1 else {
            tab = target
            return
        }
        channelNeighbor = target
        commitChannelDrag(to: target, duration: 0.28)
    }

    private var shownChannels: [DYTab] {
        if let channelNeighbor, channelNeighbor != tab { return [tab, channelNeighbor] }
        return [tab]
    }

    private func channelOffset(_ channel: DYTab, width: CGFloat) -> CGFloat {
        let tabs = DYClassicChannelDrag.order
        guard let settled = tabs.firstIndex(of: tab), let index = tabs.firstIndex(of: channel) else { return 0 }
        return channelFraction * width + CGFloat(index - settled) * width
    }

    private func applyChannelDrag(translation: CGFloat, width: CGFloat) {
        guard !channelSettling else { return }
        let width = width > 1 ? width : channelWidth
        guard width > 1 else { return }
        let drag = DYClassicChannelDrag.update(tab: tab, translation: translation, width: width)
        channelFraction = drag.fraction
        channelNeighbor = drag.neighbor
        channelAuthorEdge = drag.authorEdge
    }

    private func endChannelDrag(translation: CGFloat, predicted: CGFloat, width: CGFloat, cancelled: Bool) {
        guard !channelSettling else { return }
        let width = width > 1 ? width : channelWidth
        if DYClassicChannelDrag.opensAuthor(authorEdge: channelAuthorEdge, translation: translation,
                                            predicted: predicted, width: width, cancelled: cancelled) {
            cancelChannelDrag()
            openCurrentAuthor()
            return
        }
        if !cancelled, let dest = channelNeighbor, width > 1,
           DYClassicChannelDrag.commits(translation: translation, predicted: predicted, width: width) {
            commitChannelDrag(to: dest)
        } else {
            cancelChannelDrag()
        }
    }

    private func openCurrentAuthor() {
        guard tab == .recommend, let author = current?.author else { return }
        showComments = false
        authorTarget = author
    }

    private func commitChannelDrag(to dest: DYTab, duration: TimeInterval = 0.22) {
        guard !channelSettling, dest != tab else { cancelChannelDrag(); return }
        let tabs = DYClassicChannelDrag.order
        let forward = (tabs.firstIndex(of: dest) ?? 0) > (tabs.firstIndex(of: tab) ?? 0)
        channelSettling = true
        withAnimation(.easeOut(duration: duration)) { channelFraction = forward ? -1 : 1 }
        let wait = UInt64(duration * 1000) + 30
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(wait))
            finishChannel(at: dest)
        }
    }

    private func cancelChannelDrag() {
        guard channelFraction != 0 || channelNeighbor != nil else { return }
        channelSettling = true
        withAnimation(.easeOut(duration: 0.22)) { channelFraction = 0 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(230))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                channelFraction = 0
                channelNeighbor = nil
                channelAuthorEdge = false
                channelSettling = false
            }
        }
    }

    private func finishChannel(at target: DYTab) {
        playbackSuspended = true
        Task { @MainActor in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                tab = target
                channelFraction = 0
                channelNeighbor = nil
                channelAuthorEdge = false
                channelSettling = false
            }
            playbackSuspended = false
        }
    }

    /// 先拉到新一批再替换，失败不清空当前画面；与预取互斥，避免旧请求覆盖刷新结果。
    @MainActor private func refreshRecommendations() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; focusCurrent() }
        showToast("正在刷新推荐…")
        while feed.loading {
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        let previous = Set(feed.items.map(\.id))
        let replacement = DYFeedModel()
        replacement.screenWide = feed.screenWide
        await replacement.loadMore(bridge)
        guard !Task.isCancelled else { return }
        let fresh = replacement.items.filter { !previous.contains($0.id) }
        guard !fresh.isEmpty else {
            showToast(replacement.error ?? "暂时没有新的推荐，已保留当前视频")
            DYLiveModel.log("DDREFRESH failed kept=\(currentID ?? "-")")
            return
        }
        showComments = false
        scrollEndTask?.cancel(); userScrolling = false
        preloader.clear()
        feed.reset()
        feed.items = fresh
        feed.pool = replacement.pool
        feed.liked.formUnion(replacement.liked)
        feed.collected.formUnion(replacement.collected)
        resume = [:]
        currentID = fresh.first?.id
        scrollID = currentID
        lastFeedPull = Date()
        saveSession()
        showToast("推荐已刷新")
        DYLiveModel.log("DDREFRESH ok n=\(fresh.count) first=\(currentID ?? "-")")
    }

    private func applyHashtagFilter() async {
        let previousID = currentID
        currentID = feed.applyHashtagFilter(currentID: currentID)
        if previousID != currentID {
            scrollEndTask?.cancel()
            userScrolling = false
            showComments = false
            scrollID = currentID
            preloader.clear()
        }
        saveSession()
        guard initialized else { return }
        while feed.loading {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        if feed.items.isEmpty { await feed.loadMore(bridge) }
        guard !Task.isCancelled else { return }
        if currentID == nil { currentID = feed.items.first?.id; scrollID = currentID }
        focusCurrent()
        saveSession()
    }

    private func focusCurrent() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_HASHTAG_FIXTURE"] == "1" { return }
        #endif
        guard !refreshing, let i = currentIndex else { return }
        preloader.update(feed.items, current: i)
        let curID = feed.items[i].id
        let ahead = Array(feed.items.dropFirst(i + 1))
        let currentItem = feed.items[i]
        Task {
            await DYVideoCache.shared.markWatched(curID)
            await DYVideoCache.shared.focus(current: currentItem, ahead: ahead)
        }
        // 后面不足「缓存条数」就继续拉推荐（至少保证 6 条，节流 4 秒一次）
        let want = max(6, min(DYVideoCache.limit, 60))
        if feed.items.count - i - 1 < want, Date().timeIntervalSince(lastFeedPull) > 4 {
            lastFeedPull = Date()
            Task {
                await feed.loadMore(bridge)
                if let j = currentIndex {
                    preloader.update(feed.items, current: j)
                    await DYVideoCache.shared.focus(current: feed.items[j], ahead: Array(feed.items.dropFirst(j + 1)))
                    if feed.items.count - j - 1 < want { focusCurrent() }
                }
            }
        }
    }

    @ViewBuilder
    private var feedArea: some View {
        ZStack(alignment: .top) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    ForEach(shownChannels, id: \.self) { channel in
                        channelPage(channel)
                            .frame(width: width, height: geo.size.height)
                            .offset(x: channelOffset(channel, width: width))
                            .allowsHitTesting(channel == tab && !channelSettling)
                    }
                }
                .frame(width: width, height: geo.size.height, alignment: .topLeading)
                .clipped()
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                if width > 1 { channelWidth = width }
            }
            if let t = feed.toast {
                Text(t).font(.footnote.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.62)))
                    .frame(maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("douyin.toast")
            }
            #if DEBUG
            // UI 测试锚点：当前视频 id / 当前锁定倍速
            Text(currentID ?? "-").font(.caption2).opacity(0.01)
                .accessibilityIdentifier("douyin.currentID")
                .allowsHitTesting(false)
            Text(String(format: "%g", playbackRate)).font(.caption2).opacity(0.01)
                .accessibilityIdentifier("douyin.rate")
                .allowsHitTesting(false)
            #endif
        }
        .overlay(alignment: .top) {
            // This is a sibling of the pager, never a child of a video page.
            ZStack {
                HStack {
                    DYVideoMoreMenu(extras: AnyView(moreExtrasMenu))
                    Spacer(minLength: 0)
                    Button {
                        openSearch()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("搜索")
                    .accessibilityIdentifier("douyin.search")
                    .accessibilityValue(showSearch ? "已打开" : "未打开")
                    .opacity(showSearch && searchIsSplit ? 0 : 1)
                    .allowsHitTesting(!(showSearch && searchIsSplit))
                    .accessibilityHidden(showSearch && searchIsSplit)
                }
                topBar
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.leading, 8 + (sidePanelOpen ? 0 : insets.leading))
            .padding(.trailing, 8 + (sidePanelOpen ? 0 : insets.trailing))
            .padding(.top, headerTopInset)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("douyin.feed.header")
            .opacity(cleanScreen || liveRoomOpen ? 0 : 1)
            .allowsHitTesting(!cleanScreen && !liveRoomOpen)
            .accessibilityHidden(cleanScreen || liveRoomOpen)
        }
        // The video and bottom chrome reach the physical screen; add the actual
        // home-indicator inset once, inside each page, rather than twice.
        .ignoresSafeArea(.container)
        .onChange(of: tab) { _, t in
            if t == .recommend { focusCurrent() } else { preloader.clear() }
            if t != .live { live.stop() }
        }
        .navigationDestination(item: Binding(get: { supportsSidePanel ? nil : authorTarget }, set: { if !supportsSidePanel { authorTarget = $0 } })) { a in
            DYAuthorScreen(bridge: bridge, author: a, onWeb: { u in web = DYWebTarget(url: u) })
                .navigationBarBackButtonHidden()
        }

    }

    /// 保留原版频道切换；两侧操作及安全区由系统导航栏管理。
    private var topBar: some View {
        HStack(spacing: 14) {
            ForEach(DYClassicChannelDrag.order, id: \.self) { channel in
                Button { selectTab(channel) } label: {
                    VStack(spacing: 3) {
                        Text(channel.title).font(.headline.weight(tab == channel ? .bold : .medium))
                            .foregroundStyle(.white.opacity(tab == channel ? 1 : 0.62))
                        Capsule().fill(.white).frame(width: 16, height: 3)
                            .opacity(tab == channel ? 1 : 0)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                    .accessibilityIdentifier("douyin.channel.\(channel == .follow ? "follow" : channel == .recommend ? "recommend" : "live")")
                }
                .buttonStyle(.plain)
                .accessibilityValue(tab == channel ? "已选择" : "")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("douduo.feed")) } action: { topChrome = $0 }
        .themeShadow(.mediaLabel)
    }

    @ViewBuilder
    private func channelPage(_ channel: DYTab) -> some View {
        let audible = channel == tab && !playbackSuspended
        let interactive = channel == tab
        switch channel {
        case .live:
            DYLiveFeed(bridge: bridge, model: live, onWeb: { u in web = DYWebTarget(url: u) },
                       active: audible && web == nil && !overlayOpen,
                       topChrome: topChrome, screenInsets: insets,
                       onChannelDrag: interactive ? { dx, width in applyChannelDrag(translation: dx, width: width) } : nil,
                       onChannelDragEnd: interactive ? { dx, predicted, width, cancelled in
                           endChannelDrag(translation: dx, predicted: predicted, width: width, cancelled: cancelled)
                       } : nil)
        case .follow:
            DYFollowFeed(bridge: bridge, insets: insets, active: audible && web == nil && !overlayOpen,
                         onAuthor: { a in authorTarget = a.author },
                         onLogin: { web = DYWebTarget(url: DouyinWeb.home) },
                         onToast: { showToast($0) },
                         onComments: { item in
                             visibleVideo = item
                             authorTarget = nil
                             showComments = true
                         },
                         onShowRecommendations: { selectTab(.recommend) },
                         retainedList: followList,
                         preservedSelection: $followCurrentID,
                         onChannelDrag: interactive ? { dx, width in applyChannelDrag(translation: dx, width: width) } : nil,
                         onChannelDragEnd: interactive ? { dx, predicted, width, cancelled in
                             endChannelDrag(translation: dx, predicted: predicted, width: width, cancelled: cancelled)
                         } : nil)
        case .recommend:
            recommendArea(audible: audible, interactive: interactive)
        }
    }

    @ViewBuilder
    private func recommendArea(audible: Bool, interactive: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            if feed.items.isEmpty {
                VStack(spacing: WuWeiDesign.Spacing.md) {
                    if let e = feed.error {
                        Text(e).font(.footnote).multilineTextAlignment(.center)
                            .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                        HStack {
                            Button("重试") { Task { await feed.loadMore(bridge); currentID = feed.items.first?.id } }
                                .buttonStyle(.borderedProminent)
                            Button("打开网页版") { web = DYWebTarget(url: DouyinWeb.home) }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        ProgressView().tint(theme.media.onMedia.color(for: scheme))
                        Text(bridge.ready ? "加载推荐…" : "连接抖音…").font(.footnote)
                            .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                    }
                    DYHashtagFilterButton(tags: []).buttonStyle(.bordered)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 四种界面共用同一个分页器（含「更快」收尾），见 DYFeedPager.swift
                DYFeedPager(items: feed.items, currentID: $currentID, scrollID: $scrollID,
                            userScrolling: $userScrolling, scrollEndTask: $scrollEndTask,
                            pageAxes: [.horizontal, .vertical]) { item in
                    page(for: item, audible: audible, interactive: interactive)
                }
            }
        }
    }

    /// 单页构造拆成独立函数：参数太多，写在 ForEach 里会让类型检查超时。
    private func page(for item: DYAweme, audible: Bool, interactive: Bool) -> some View {
        let active = audible && item.id == currentID && web == nil && !overlayOpen
        return DYVideoPage(item: item,
                           isCurrent: active,
                           insets: insets,
                           resume: resume[item.id],
                           liked: feed.liked.contains(item.id),
                           collected: feed.collected.contains(item.id),
                           onLike: { toggleLike(item.id, force: nil) },
                           onCollect: { toggleCollect(item.id) },
                           onDoubleTap: { toggleLike(item.id, force: true) },
                           onComments: { withAnimation(.snappy) { authorTarget = nil; showComments.toggle() } },
                           onAuthor: { showComments = false; authorTarget = item.author },
                           onSavePosition: { resume[item.id] = $0; saveSession() },
                           preloader: preloader,
                           bridge: bridge,
                           onToast: { showToast($0) },
                           onDislike: { dislike(item.id) },
                           onEnded: { playNext(after: item.id) },
                           onShowFollowing: interactive ? nil : { selectTab(.follow) },
                           onChannelDrag: interactive ? { dx, width in applyChannelDrag(translation: dx, width: width) } : nil,
                           onChannelDragEnd: interactive ? { dx, predicted, width, cancelled in
                               endChannelDrag(translation: dx, predicted: predicted, width: width, cancelled: cancelled)
                           } : nil)
    }

    /// 点赞：先本地乐观更新，再调抖音网页接口，按服务端返回决定成败
    /// （不用 cookie 判断登录态：sessionid 是 HttpOnly，document.cookie 读不到，会误判成未登录）
    private func toggleLike(_ id: String, force: Bool?) { feed.toggleLike(id, force: force, bridge: bridge) }


    /// 不感兴趣：立刻从列表拿掉并切到下一条，后台告诉抖音（失败只提示，不把视频塞回来）
    private func dislike(_ id: String) {
        guard let i = feed.items.firstIndex(where: { $0.id == id }) else { return }
        let next = i + 1 < feed.items.count ? feed.items[i + 1].id : (i > 0 ? feed.items[i - 1].id : nil)
        scrollEndTask?.cancel(); userScrolling = false
        showComments = false
        if currentID == id { currentID = next; scrollID = next }
        feed.items.remove(at: i)
        resume[id] = nil
        saveSession()
        showToast("将减少此类推荐")
        Task {
            await DYVideoCache.shared.markWatched(id)
            do {
                switch try await bridge.dislike(id) {
                case .ok: break
                case .notLoggedIn: showToast("抖音未登录，「不感兴趣」没同步到账号")
                case .failed(let why): showToast("「不感兴趣」同步失败：\(why)")
                }
            } catch {
                showToast("「不感兴趣」同步失败：\(error.localizedDescription)")
            }
        }
        if next == nil { Task { await feed.loadMore(bridge); currentID = feed.items.first?.id; scrollID = currentID } }
    }

    /// 收藏 / 取消收藏（同步到抖音账号的「收藏」）
    private func toggleCollect(_ id: String) { feed.toggleCollect(id, bridge: bridge) }


    private func showToast(_ s: String) { feed.showToast(s) }


    /// 经典顶栏「更多」：静音 / 听书 / 自动连播在表层，其余全在设置页（刷新推荐 / 弹幕 / 界面不在这里重复）。
    @ViewBuilder
    private var moreExtrasMenu: some View {
        Section {
            Toggle(isOn: $muted) { Label("静音", systemImage: "speaker.slash") }
                .accessibilityIdentifier("douyin.quick.muted")
            Toggle(isOn: $bgPlay) { Label("听书模式（后台播放）", systemImage: "headphones") }
                .accessibilityIdentifier("douyin.quick.bgplay")
            Toggle(isOn: $autoNext) { Label("自动连播", systemImage: "play.square.stack") }
                .accessibilityIdentifier("douyin.quick.autonext")
        }
        Section { DYSettingsButton() }
    }

}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}

struct DYUpstreamVideoPage: View {
    @Environment(\.horizontalSizeClass) private var hSize
    private var railWidth: CGFloat { hSize == .compact ? 50 : 54 }
    private var actionColumnWidth: CGFloat { 54 }
    private var chromeSidePadding: CGFloat { 12 }
    // Full-bleed ancestors may report zero safe-area insets. Read the app's
    // foreground key window as a fallback, never a guessed device/rail width.
    private var systemColumnInset: CGFloat {
        let windowInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.safeAreaInsets.right ?? 0
        return max(insets.trailing, windowInset)
    }
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let item: DYAweme
    let isCurrent: Bool
    let insets: EdgeInsets
    let resume: Double?
    let liked: Bool
    let collected: Bool
    let onLike: () -> Void
    let onCollect: () -> Void
    let onDoubleTap: () -> Void
    let onComments: () -> Void
    let onSearch: () -> Void
    let onAuthor: () -> Void
    let onSavePosition: (Double) -> Void
    let preloader: DYPreloader
    let bridge: DouyinBridge?
    let onToast: ((String) -> Void)?
    /// 只有推荐流传：关注 / 搜索 / 我的 里不显示「不感兴趣」
    let onDislike: (() -> Void)?
    /// 「更多」菜单末尾追加的条目（消息 / 我的 / 设置），由推荐流注入
    var moreExtras: AnyView = AnyView(EmptyView())
    /// 播完切下一条（「自动连播」打开才生效）
    var onEnded: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil
    @AppStorage("douyin_autoplay_v1") private var autoNext = false
    @AppStorage("douyin_muted_v1") private var muted = false
    @AppStorage("douyin_bg_play_v1") private var bgPlay = false
    @State private var heart = false
    @State private var danmaku: [DYDanmaku] = []
    @State private var danmakuLoaded = false
    @State private var saving = false
    @State private var showDanmakuInput = false
    @State private var danmakuDraft = ""
    @State private var danmakuSending = false
    @FocusState private var danmakuFocused: Bool
    @AppStorage("douyin_autofit_v1") private var autoFit = true
    @AppStorage("douyin_danmaku_v1") private var danmakuOn = true
    @AppStorage("douyin_playback_rate_v1") private var playbackRate = 1.0
    @AppStorage(DDChromeMode.key) private var chromeModeRaw = DDChromeMode.classic.rawValue
    private var chromeMode: DDChromeMode { DDChromeMode(rawValue: chromeModeRaw) ?? .classic }
    @ObservedObject private var peek = DDPeekInfo.shared
    /// 长按加速时右侧按钮/作者区淡出；这些控件按住也能触发加速（见 DYHoldBoost）。
    @StateObject private var boost = DYBoostControl()

    init(item: DYAweme, isCurrent: Bool, insets: EdgeInsets, resume: Double?, liked: Bool, collected: Bool,
         onLike: @escaping () -> Void, onCollect: @escaping () -> Void, onDoubleTap: @escaping () -> Void,
         onComments: @escaping () -> Void, onSearch: @escaping () -> Void, onAuthor: @escaping () -> Void, onSavePosition: @escaping (Double) -> Void,
         preloader: DYPreloader, bridge: DouyinBridge? = nil, onToast: ((String) -> Void)? = nil,
         onDislike: (() -> Void)? = nil, moreExtras: AnyView = AnyView(EmptyView()),
         onEnded: (() -> Void)? = nil, onBack: (() -> Void)? = nil) {
        self.item = item; self.isCurrent = isCurrent; self.insets = insets; self.resume = resume
        self.liked = liked; self.collected = collected
        self.onLike = onLike; self.onCollect = onCollect; self.onDoubleTap = onDoubleTap
        self.onComments = onComments; self.onSearch = onSearch; self.onAuthor = onAuthor; self.onSavePosition = onSavePosition
        self.preloader = preloader; self.bridge = bridge; self.onToast = onToast
        self.onDislike = onDislike
        self.moreExtras = moreExtras
        self.onEnded = onEnded
        self.onBack = onBack
    }

    var body: some View {
        let fg = theme.media.onMedia.color(for: scheme)
        ZStack(alignment: .bottomLeading) {
            if item.images.isEmpty, let s = item.play, let remote = URL(string: s) {
                // 只用「整条缓存」或「在线流」：不再走头部缓存 + 接续（那一下切换必然闪/卡）
                let url = DYVideoCache.localURL(item.id) ?? remote
                // 复用影库播放器：横滑快进（带预览缩略图）、双击、长按 2 倍速、竖滑切视频、底部可拖进度条、VLC 兜底
                PlayerPage.external(id: item.id, title: item.desc, url: url, durationSec: item.duration,
                                    isActive: isCurrent, topInset: insets.top, bottomInset: insets.bottom,
                                    resumePosition: resume, compactChrome: true,
                                    preparedPlayer: { preloader.take(item.id) },
                                    onEnded: autoNext ? onEnded : nil,
                                    onDoubleTap: {
                                        onDoubleTap()
                                        heart = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { heart = false }
                                    },
                                    onSavePosition: onSavePosition, onClose: {}, fillWidth: autoFit,
                                    danmaku: danmakuOn ? danmaku : [],
                                    altURL: item.playAlt.flatMap(URL.init(string:)),
                                    quality: item.q,
                                    fastURL: item.playFast.flatMap(URL.init(string:)),
                                    posterURL: item.cover.flatMap(URL.init(string:)),
                                    videoAspect: item.height > 0 ? item.width / item.height : 0,
                                    headEndSeconds: nil,
                                    continuationURL: nil,
                                    boost: boost)
            } else {
                TabView {
                    ForEach(item.images, id: \.self) { s in
                        CachedAsyncImage(url: URL(string: s)) { img in img.resizable().scaledToFit() } placeholder: { ProgressView() }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }

            if heart {
                Image(systemName: "heart.fill")
                    .font(.system(size: theme.typography.pointSize(.splash)))
                    .scaleEffect(1.7)
                    .foregroundStyle(theme.status.danger.color(for: scheme))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            if chromeMode.usesRail {
                // 简洁 / 极简：整组按钮跟着系统侧栏边缘走（PR #12）
                DYAdaptiveActionRail { edge in
                    HStack(alignment: .bottom, spacing: 12) {
                        if edge == .leading { actionRail(fg, edge: edge) }
                        if !chromeMode.hidesInfo || (isCurrent && peek.on) { info(fg).transition(.opacity) }
                        Spacer(minLength: 0)
                        if edge == .trailing { actionRail(fg, edge: edge) }
                    }
                    .padding(.horizontal, chromeSidePadding)
                    // 简洁/极简没有底部进度条（进度画在入口外圈），底部不用再给它留 36pt（issue #4）
                    .padding(.bottom, max(insets.bottom, 18) + (item.images.isEmpty ? 8 : 24))
                }
                // 长按加速时淡出按钮和信息，画面干净；不禁用点击区，手指按在按钮上也能继续加速。
                .opacity(boost.boosting ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: boost.boosting)
            } else {
                // 默认：PR #12 之前的布局，左下信息 + 右侧按钮栏
                HStack(alignment: .bottom, spacing: 12) {
                    info(fg)
                    Spacer(minLength: 0)
                    actions(fg)
                        .offset(x: DYDuoMetrics.actionRailHorizontalOffset(
                            isRegular: hSize == .regular, trailingInset: systemColumnInset,
                            columnWidth: actionColumnWidth, outerPadding: chromeSidePadding,
                            opticalLeadingInset: theme.media.expandedRailOpticalInset))
                        .modifier(DYRailReservedNudge())
                        .offset(x: hSize == .compact ? -9 : 0)
                        .padding(.bottom, item.images.isEmpty ? 56 : 0)
                }
                .padding(.horizontal, chromeSidePadding)
                .padding(.bottom, max(insets.bottom, 18) + (item.images.isEmpty ? 36 : 24))
                .opacity(boost.boosting ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: boost.boosting)
            }
        }
        .overlay(alignment: .bottom) {
            if showDanmakuInput, rootRailTab == nil || onBack != nil {
                danmakuBar.padding(.bottom, max(insets.bottom, 12) + 6)
            }
        }
        .preference(key: DYFeedInputActivePreference.self, value: isCurrent && showDanmakuInput)
        .preference(key: DYFeedComposerPreference.self, value: composerEntry)
        .preference(key: DYFeedRailPreference.self, value: railEntry(fg))
        .animation(.snappy, value: heart)
        .onChange(of: isCurrent) { _, c in
            if !c { showDanmakuInput = false }
            if c, onBack == nil { DYBoostRouter.shared.adopt(boost) }
        }
        .onAppear { if isCurrent, onBack == nil { DYBoostRouter.shared.adopt(boost) } }
        // 弹幕：轮到这条时才拉（一次拉整条视频的）
        .task(id: isCurrent) {
            guard isCurrent, !danmakuLoaded, item.images.isEmpty, let b = bridge else { return }
            danmakuLoaded = true
            do {
                danmaku = try await b.danmaku(item.id, durationMs: Int(item.duration * 1000))
                DYLiveModel.log("DDDM id=\(item.id) n=\(danmaku.count) first=\(danmaku.first.map { "\($0.offset)s \($0.text)" } ?? "-")")
            } catch {
                DYLiveModel.log("DDDM id=\(item.id) error=\(error)")
            }
        }
    }

    private var composerEntry: [DYFeedComposerEntry] {
        guard isCurrent, showDanmakuInput, onBack == nil, let rootRailTab else { return [] }
        return [DYFeedComposerEntry(id: item.id, tab: rootRailTab,
                                   content: AnyView(danmakuBar.padding(.bottom, 8)))]
    }

    private func railEntry(_ fg: Color) -> [DYFeedRailEntry] {
        guard isCurrent, onBack == nil, let rootRailTab else { return [] }
        return [DYFeedRailEntry(id: item.id, tab: rootRailTab, actions: AnyView(actions(fg)))]
    }

    private var danmakuBar: some View {
        HStack(spacing: 8) {
            TextField("", text: $danmakuDraft, prompt: Text("发个弹幕见证当下").foregroundStyle(.white.opacity(0.5)))
                .foregroundStyle(.white)
                .focused($danmakuFocused)
                .submitLabel(.send)
                .onSubmit { sendDanmaku() }
                .padding(.horizontal, 14).frame(height: 40)
                .background(Capsule().fill(.black.opacity(0.6)))
                .accessibilityIdentifier("douyin.danmaku.input")
            Button(action: sendDanmaku) {
                if danmakuSending { ProgressView().tint(.white) }
                else { Text("发送").font(.subheadline.weight(.semibold)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 40)
            .background(Capsule().fill(theme.accent.color(for: scheme)))
            .disabled(danmakuDraft.trimmingCharacters(in: .whitespaces).isEmpty || danmakuSending)
            .accessibilityIdentifier("douyin.danmaku.send")
            Button { showDanmakuInput = false; danmakuFocused = false } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 40)
            }
            .accessibilityIdentifier("douyin.danmaku.close")
        }
        .padding(.horizontal, 12)
    }

    private func sendDanmaku() {
        let text = danmakuDraft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !danmakuSending, let b = bridge else { return }
        danmakuSending = true
        let at = DDNowPlaying.id == item.id ? DDNowPlaying.time : 0
        Task {
            do {
                let id = try await b.postDanmaku(item.id, text: text, offset: at)
                // 自己发的立刻上屏（从当前时间点开始飘）
                danmaku.append(DYDanmaku(id: id, text: text, offset: at + 0.3))
                danmaku.sort { $0.offset < $1.offset }
                danmakuDraft = ""
                showDanmakuInput = false
                danmakuFocused = false
                onToast?("弹幕已发送")
            } catch {
                onToast?("弹幕发送失败：\(error.localizedDescription)")
            }
            danmakuSending = false
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        onToast?("正在保存…")
        Task {
            do {
                try await DYSaver.save(item)
                onToast?(item.images.isEmpty ? "视频已保存到相册" : "图集已保存到相册")
            } catch {
                onToast?("保存失败：\(error.localizedDescription)")
            }
            saving = false
        }
    }

    /// 小红书式左下信息区：头像 + 昵称 + 红色「关注」胶囊，下面文案 / 音乐
    private func info(_ fg: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: { if !boost.blocksTap { onAuthor() } }) {
                    HStack(spacing: 8) {
                        CachedAsyncImage(url: item.author.avatar.flatMap(URL.init(string:))) { img in
                            img.resizable().scaledToFill()
                        } placeholder: { theme.media.chromeFill.color(for: scheme) }
                        .frame(width: 34, height: 34)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(fg.opacity(0.9), lineWidth: 1))
                        .overlay(alignment: .bottomTrailing) {
                            // 已关注：绿色对勾；未关注：红色加号。follow_status > 0 即已关注（互关为 2）。
                            let followed = (item.author.follow ?? 0) > 0
                            DYAuthorFollowMark(followed: followed)
                                .offset(x: 3, y: 3)
                                .accessibilityIdentifier(followed ? "douyin.author.followed" : "douyin.author.notfollowed")
                        }
                        Text(item.author.name).font(.subheadline.weight(.semibold)).foregroundStyle(fg).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .modifier(DYHoldBoost(control: boost))
                .accessibilityIdentifier("douyin.author")
            }
            if let metadata = item.metadataText() {
                Text(metadata)
                    .font(.subheadline)
                    .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("douyin.video.metadata")
            }
            if !item.desc.isEmpty {
                DYExpandableTitle(text: item.desc, foreground: fg,
                                  secondary: theme.media.onMediaSecondary.color(for: scheme),
                                  hashtagNames: item.hashtagNames ?? [])
            }
            if !item.music.isEmpty {
                Label(item.music, systemImage: "music.note")
                    .font(.caption).lineLimit(1)
                    .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
            }
        }
        .themeShadow(.mediaLabel)
    }

    /// 小红书式右侧栏：一根竖向液态玻璃胶囊（赞 / 评论 / 收藏 / 搜索，数字在图标下），下方单独一颗「更多」圆按钮
    @Environment(\.dyRootRailTab) private var rootRailTab

    private func actionRail(_ fg: Color, edge: HorizontalEdge) -> some View {
        Group {
            if rootRailTab != nil && onBack == nil {
                Color.clear.frame(width: actionColumnWidth, height: 0).allowsHitTesting(false)
            } else {
                actions(fg)
                    .fixedSize()
                    .modifier(DYRailReservedNudge(railEdge: edge))
                    .padding(.bottom, item.images.isEmpty ? 56 : 0)
            }
        }
        .padding(.horizontal, hSize == .compact ? 9 : 0)
    }

    private func actions(_ fg: Color) -> some View {
        VStack(spacing: theme.media.actionGroupSpacing) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(fg)
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)
                .ddGlassCapsule()
                .accessibilityLabel("返回上一层")
                .accessibilityIdentifier("douyin.list.back")
            }
            VStack(spacing: theme.media.actionItemSpacing) {
                railItem(liked ? "heart.fill" : "heart", DYFormat.count(item.stats.digg + (liked ? 1 : 0)),
                         tint: liked ? theme.status.danger.color(for: scheme) : fg, "douyin.like", onLike)
                railItem("ellipsis.bubble", DYFormat.count(item.stats.comment), tint: fg, "douyin.comments", onComments)
                railItem(collected ? "star.fill" : "star", DYFormat.count(item.stats.collect + (collected ? 1 : 0)),
                         tint: collected ? theme.status.warning.color(for: scheme) : fg, "douyin.collect", onCollect)
                if !chromeMode.usesRail {
                    railItem("magnifyingglass", "", tint: fg, "douyin.search", onSearch)
                }
                if item.images.isEmpty {
                    // 有些视频铺满后会裁掉边缘，随手切回完整画面
                    // 颜色不变，靠图标形态区分：铺满中 = 向内箭头（点了缩回完整画面）；完整画面 = 向外箭头（点了放大铺满）
                    railItem(autoFit ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", "", tint: fg,
                             "douyin.fit") {
                        autoFit.toggle()
                        onToast?(autoFit ? "铺满：开" : "完整画面")
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(width: railWidth)
            .ddGlassCapsule()
            .frame(width: actionColumnWidth)
            moreMenu(fg)
        }
        .themeShadow(.mediaLabel)
    }

    private func railItem(_ icon: String, _ text: String, tint: Color, _ id: String, _ act: @escaping () -> Void) -> some View {
        Button(action: { if !boost.blocksTap { act() } }) {
            VStack(spacing: 2) {
                Group {
                    if id == "douyin.fit" {
                        DYFitCornerGlyph(inward: !autoFit)
                            .stroke(tint, style: StrokeStyle(lineWidth: theme.media.actionGlyphStroke, lineCap: .round, lineJoin: .round))
                            .frame(width: theme.media.actionGlyphSize, height: theme.media.actionGlyphSize)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: theme.media.actionGlyphSize, weight: .regular, design: .rounded))
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 34, height: 34)
                if !text.isEmpty {
                    Text(text).font(.caption2.weight(.medium)).monospacedDigit()
                        .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            // 有数字的按钮：图标 34 + 间隙 2 + 文字；没数字的（搜索/铺满）去掉文字那一截，只留图标高度，
            // 这样图标到相邻按钮的距离，和「图标—文字」之间的距离一致，不再多出一块空白
            .frame(width: railWidth, height: text.isEmpty ? 36 : 50, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(DYHoldBoost(control: boost))
        .accessibilityIdentifier(id)
    }

    private func rateTitle(_ r: Double) -> String { r == 1 ? "正常速度" : String(format: "%g 倍速", r) }

    /// 「更多」：转发 / 不感兴趣 / 下载 → 倍速 / 静音 / 听书 / 自动连播 → 发弹幕 → 设置。
    @ViewBuilder
    private func moreMenu(_ fg: Color) -> some View {
        Menu {
            ControlGroup {
                DYForwardMenu(item: item, bridge: bridge, foreground: fg)
                if let onDislike {
                    Button("不感兴趣", systemImage: "hand.thumbsdown") { onDislike() }
                        .accessibilityIdentifier("douyin.dislike")
                }
                Button {
                    save()
                } label: {
                    Label(saving ? "保存中…" : "下载", systemImage: "arrow.down.to.line")
                }
                .disabled(saving)
                .accessibilityIdentifier("douyin.save")
            }
            // 表层：倍速 / 静音 / 听书 / 自动连播。其余全局偏好都在设置页，不重复。
            Section {
                Menu {
                    Picker("倍速", selection: Binding(
                        get: { playbackRate },
                        set: { r in playbackRate = r; onToast?(rateTitle(r)) })) {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Text(rateTitle(r)).tag(r) }
                    }
                } label: {
                    Label("倍速 · \(playbackRate == playbackRate.rounded() ? String(format: "%.0f", playbackRate) : String(format: "%g", playbackRate))×", systemImage: "speedometer")
                }
                .accessibilityIdentifier("douyin.quick.speed")
                Toggle(isOn: $muted) { Label("静音", systemImage: "speaker.slash") }
                    .accessibilityIdentifier("douyin.quick.muted")
                Toggle(isOn: $bgPlay) { Label("听书模式（后台播放）", systemImage: "headphones") }
                    .accessibilityIdentifier("douyin.quick.bgplay")
                Toggle(isOn: $autoNext) { Label("自动连播", systemImage: "play.square.stack") }
                    .accessibilityIdentifier("douyin.quick.autonext")
            }
            if item.images.isEmpty, bridge != nil {
                Button("发弹幕", systemImage: "text.bubble") {
                    showDanmakuInput = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { danmakuFocused = true }
                }
                .accessibilityIdentifier("douyin.danmaku.open")
            }
            moreExtras
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: theme.media.moreGlyphSize, weight: .regular, design: .rounded))
                .foregroundStyle(fg)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
                .ddGlassCircle()
                .frame(width: 54)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityIdentifier("douyin.more")
        .modifier(DYForwardPresentation(item: item))
    }

}

@available(iOS 27.1, *)
struct DYClassicVideoPage: View {
    @Environment(\.duoCleanScreen) private var cleanScreen
    @Environment(\.duoSystemBars) private var systemBars
    @Environment(\.toolbarVerticalEdge) private var verticalBarEdge
    @Environment(\.duoInlineVideoNavigation) private var inlineNavigation
    @Environment(\.displayScale) private var displayScale
    @Environment(\.duoVisibleVideo) private var visibleVideo
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.dyHingeClosed) private var hingeClosed
    private var railWidth: CGFloat { hSize == .compact ? 50 : 54 }
    private var chromeSidePadding: CGFloat { 12 }
    @State private var pageSize: CGSize = .zero
    /// 合屏（铰链 closed）首页：TikTok 式排版——视频靠左，互动胶囊贴着视频右边，
    /// 系统竖栏只放清屏 + 我的/消息/首页三个页签（不再被互动胶囊挤成一个按钮）。
    private var closedRail: Bool { hingeClosed && systemBars && !inlineNavigation && hSize == .compact }
    /// 互动胶囊离页面右缘的距离：竖屏视频没铺满、已左贴边时，跟到视频右边；否则贴着系统竖栏左侧。
    private var closedRailTrailing: CGFloat {
        let w = pageSize.width, h = pageSize.height
        let aspect = item.height > 0 ? item.width / item.height : 0
        var gap: CGFloat = 0
        if w > 0, h > w, aspect > 0, aspect < 1, !autoFit { gap = w - min(w, h * aspect) }
        return max(systemColumnInset, gap) + 6
    }
    // Full-bleed ancestors may report zero safe-area insets. Read the app's
    // foreground key window as a fallback, never a guessed device/rail width.
    private var systemColumnInset: CGFloat {
        let windowInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.safeAreaInsets.right ?? 0
        return max(insets.trailing, windowInset)
    }
    private var actionRailTrailingPadding: CGFloat {
        guard !inlineNavigation else { return chromeSidePadding }
        // Follow the runtime system column, including the existing optical inset
        // used by Duo chrome. The column midpoint includes the outer side margin.
        return max(chromeSidePadding, systemColumnInset / 2 - railWidth / 2
                   + theme.media.expandedRailOpticalInset)
    }
    private var mediaBottomInset: CGFloat {
        // A vertical system toolbar already occupies the side column. After
        // rotation NavigationStack can retain its previous bottom-bar inset;
        // only the physical home-indicator inset belongs below this video.
        systemBars && verticalBarEdge != nil ? DYDuoMetrics.windowBottomInset : insets.bottom
    }
    private var contentInsets: EdgeInsets {
        guard systemBars else { return EdgeInsets() }
        let left = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.safeAreaInsets.left ?? 0
        // The 24 pt edge tuck is for the trailing Duo column. Restore the
        // complete system bottom inset when tabs become horizontal in portrait.
        let bottom = verticalBarEdge == nil && !inlineNavigation ? min(insets.bottom, 24) : 0
        if closedRail {
            return EdgeInsets(top: 0, leading: max(insets.leading, left), bottom: 0,
                              trailing: closedRailTrailing + railWidth + 4)
        }
        return EdgeInsets(top: 0, leading: max(insets.leading, left),
                          bottom: bottom, trailing: inlineNavigation ? 0 : max(systemColumnInset, railWidth + chromeSidePadding))
    }
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let item: DYAweme
    let isCurrent: Bool
    let insets: EdgeInsets
    let resume: Double?
    let liked: Bool
    let collected: Bool
    let onLike: () -> Void
    let onCollect: () -> Void
    let onDoubleTap: () -> Void
    let onComments: () -> Void
    let onAuthor: () -> Void
    let onSavePosition: (Double) -> Void
    let preloader: DYPreloader
    let bridge: DouyinBridge?
    let onToast: ((String) -> Void)?
    /// 只有推荐流传：关注 / 搜索 / 我的 里不显示「不感兴趣」
    let onDislike: (() -> Void)?
    /// 播完切下一条（「自动连播」打开才生效）
    var onEnded: (() -> Void)? = nil
    var onShowFollowing: (() -> Void)? = nil
    var onNavigateLeft: (() -> Void)? = nil
    var onChannelDrag: ((CGFloat, CGFloat) -> Void)? = nil
    var onChannelDragEnd: ((CGFloat, CGFloat, CGFloat, Bool) -> Void)? = nil
    /// 已裁成圆形的头像（只在头像加载完时画一次；以前每次 body 重算都重画两遍，滑动时主线程掉帧）
    @State private var authorImage: UIImage?
    @State private var followedOverride: Bool?
    @State private var followBusy = false
    private var authorFollowed: Bool { followedOverride ?? ((item.author.follow ?? 0) > 0) }
    private var followStates: AnyPublisher<[String: Bool], Never> {
        bridge?.$authorFollowStates.eraseToAnyPublisher() ?? Just([:]).eraseToAnyPublisher()
    }
    @Environment(\.ddScale) private var ui
    @AppStorage("douyin_autoplay_v1") private var autoNext = false
    @State private var heart = false
    @State private var danmaku: [DYDanmaku] = []
    @State private var danmakuLoaded = false
    @State private var showShare = false
    @State private var showOptions = false
    @State private var showDanmakuInput = false
    @State private var danmakuDraft = ""
    @State private var danmakuSending = false
    @FocusState private var danmakuFocused: Bool
    @AppStorage("douyin_autofit_v1") private var autoFit = true
    @AppStorage("douyin_danmaku_v1") private var danmakuOn = true

    init(item: DYAweme, isCurrent: Bool, insets: EdgeInsets, resume: Double?, liked: Bool, collected: Bool,
         onLike: @escaping () -> Void, onCollect: @escaping () -> Void, onDoubleTap: @escaping () -> Void,
         onComments: @escaping () -> Void, onAuthor: @escaping () -> Void, onSavePosition: @escaping (Double) -> Void,
         preloader: DYPreloader, bridge: DouyinBridge? = nil, onToast: ((String) -> Void)? = nil,
         onDislike: (() -> Void)? = nil,
         onEnded: (() -> Void)? = nil,
         onShowFollowing: (() -> Void)? = nil, onNavigateLeft: (() -> Void)? = nil,
         onChannelDrag: ((CGFloat, CGFloat) -> Void)? = nil,
         onChannelDragEnd: ((CGFloat, CGFloat, CGFloat, Bool) -> Void)? = nil) {
        self.item = item; self.isCurrent = isCurrent; self.insets = insets; self.resume = resume
        self.liked = liked; self.collected = collected
        self.onLike = onLike; self.onCollect = onCollect; self.onDoubleTap = onDoubleTap
        self.onComments = onComments; self.onAuthor = onAuthor; self.onSavePosition = onSavePosition
        self.preloader = preloader; self.bridge = bridge; self.onToast = onToast
        self.onDislike = onDislike
        self.onEnded = onEnded
        self.onShowFollowing = onShowFollowing
        self.onNavigateLeft = onNavigateLeft
        self.onChannelDrag = onChannelDrag
        self.onChannelDragEnd = onChannelDragEnd
    }

    var body: some View {
        let fg = theme.media.onMedia.color(for: scheme)
        ZStack(alignment: .bottomLeading) {
            if item.images.isEmpty, let s = item.play, let remote = URL(string: s) {
                // 只用「整条缓存」或「在线流」：不再走头部缓存 + 接续（那一下切换必然闪/卡）
                let url = DYVideoCache.localURL(item.id) ?? remote
                // 复用播放器：左右切换作者/关注、双击点赞、分区长按、竖滑切视频、底部拖动进度及 VLC 兜底
                PlayerPage.external(id: item.id, title: item.desc, url: url, durationSec: item.duration,
                                    isActive: isCurrent, topInset: insets.top, bottomInset: mediaBottomInset,
                                    resumePosition: resume, compactChrome: true,
                                    preparedPlayer: { preloader.take(item.id) },
                                    onEnded: autoNext ? onEnded : nil,
                                    onDoubleTap: {
                                        onDoubleTap()
                                        heart = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { heart = false }
                                    },
                                    onSavePosition: onSavePosition, onClose: {}, fillWidth: autoFit,
                                    onFillWidthChange: { autoFit = $0 },
                                    danmaku: danmakuOn ? danmaku : [],
                                    altURL: item.playAlt.flatMap(URL.init(string:)),
                                    quality: item.q,
                                    fastURL: item.playFast.flatMap(URL.init(string:)),
                                    posterURL: item.cover.flatMap(URL.init(string:)),
                                    videoAspect: item.height > 0 ? item.width / item.height : 0,
                                    headEndSeconds: nil,
                                    continuationURL: nil,
                                    onSwipeLeft: onChannelDrag == nil && !cleanScreen ? { (onNavigateLeft ?? onAuthor)() } : nil,
                                    onSwipeRight: onChannelDrag == nil && !cleanScreen ? { onShowFollowing?() } : nil,
                                    onContextMenu: { if !cleanScreen { showOptions = true } },
                                    onHorizontalDrag: cleanScreen ? nil : onChannelDrag,
                                    onHorizontalDragEnd: cleanScreen ? nil : onChannelDragEnd)
                    .environment(\.duoContentInsets, contentInsets)
            } else {
                TabView {
                    ForEach(item.images, id: \.self) { s in
                        CachedAsyncImage(url: URL(string: s)) { img in img.resizable().scaledToFit() } placeholder: { ProgressView() }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: cleanScreen ? .never : .always))
            }

            if heart && !cleanScreen {
                Image(systemName: "heart.fill")
                    .font(.system(size: theme.typography.pointSize(.splash)))
                    .scaleEffect(1.7)
                    .foregroundStyle(theme.status.danger.color(for: scheme))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            if !cleanScreen {
                info(fg)
                    .padding(.horizontal, chromeSidePadding)
                    .padding(contentInsets)
                    .padding(.bottom, DYDuoMetrics.mediaBottomPadding(mediaBottomInset) + (item.images.isEmpty ? 16 * ui : 16))
            }
        }
        .overlay(alignment: .trailing) {
            if !cleanScreen && closedRail {
                actionCapsule(fg)
                    .padding(.trailing, closedRailTrailing)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, DYDuoMetrics.mediaBottomPadding(mediaBottomInset) + 56)
                    .accessibilityIdentifier("douyin.video.closedRail")
            } else if !cleanScreen && !inlineNavigation && (!systemBars || verticalBarEdge == nil) {
                actionCapsule(fg)
                    .modifier(DYRailReservedNudge())
                    .padding(.trailing, actionRailTrailingPadding)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { pageSize = $0 }
        .preference(key: DYActiveVideoActionsKey.self,
                    value: systemBars && isCurrent && !inlineNavigation ? toolbarActions(fg) : nil)
        .overlay(alignment: .bottom) {
            if showDanmakuInput { danmakuBar.padding(.bottom, max(insets.bottom, 0) + 4) }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: liked) { old, new in !old && new }
        .dyBottomSheet(isPresented: $showShare, kind: .share) {
            DYForwardScreen(item: item)
        }
        .dyBottomSheet(isPresented: $showOptions, kind: .options) {
            DYVideoOptionsPanel(onDislike: onDislike, onSendDanmaku: bridge == nil ? nil : {
                showDanmakuInput = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { danmakuFocused = true }
            })
        }
        .onAppear { if isCurrent { publishVisible() } }
        .onReceive(followStates) { states in
            followedOverride = states[item.author.secUid ?? ""] ?? states[item.author.uid ?? ""]
        }
        .onChange(of: isCurrent) { _, active in if active { publishVisible() } }
        .task(id: item.author.avatar) {
            guard let url = item.author.avatar.flatMap(URL.init(string:)) else { authorImage = nil; return }
            let image = await ImageCache.shared.load(url)
            guard !Task.isCancelled else { return }
            authorImage = image.map(circularAvatar)
        }
        .animation(.snappy, value: heart)
        .onChange(of: isCurrent) { _, c in if !c { showDanmakuInput = false } }
        // 弹幕：轮到这条时才拉（一次拉整条视频的）
        .task(id: isCurrent) {
            guard isCurrent, !danmakuLoaded, item.images.isEmpty, let b = bridge else { return }
            danmakuLoaded = true
            do {
                danmaku = try await b.danmaku(item.id, durationMs: Int(item.duration * 1000))
                DYLiveModel.log("DDDM id=\(item.id) n=\(danmaku.count) first=\(danmaku.first.map { "\($0.offset)s \($0.text)" } ?? "-")")
            } catch {
                DYLiveModel.log("DDDM id=\(item.id) error=\(error)")
            }
        }
    }

    /// 只有关注流需要把「当前可见视频」报给根视图（评论/标签用）；推荐流根视图自己有 currentID。
    /// 同一条不重复写，避免翻页时根视图多重算一轮。
    private func publishVisible() {
        guard visibleVideo.wrappedValue?.id != item.id else { return }
        visibleVideo.wrappedValue = item
    }

    private var danmakuBar: some View {
        HStack(spacing: 8) {
            TextField("", text: $danmakuDraft, prompt: Text("发个弹幕见证当下").foregroundStyle(.white.opacity(0.5)))
                .foregroundStyle(.white)
                .focused($danmakuFocused)
                .submitLabel(.send)
                .onSubmit { sendDanmaku() }
                .padding(.horizontal, 14).frame(height: 40)
                .background(Capsule().fill(.black.opacity(0.6)))
                .accessibilityIdentifier("douyin.danmaku.input")
            Button(action: sendDanmaku) {
                if danmakuSending { ProgressView().tint(.white) }
                else { Text("发送").font(.subheadline.weight(.semibold)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 40)
            .background(Capsule().fill(theme.accent.color(for: scheme)))
            .disabled(danmakuDraft.trimmingCharacters(in: .whitespaces).isEmpty || danmakuSending)
            .accessibilityIdentifier("douyin.danmaku.send")
            Button { showDanmakuInput = false; danmakuFocused = false } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 40)
            }
        }
        .padding(.horizontal, 12)
    }

    private func sendDanmaku() {
        let text = danmakuDraft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !danmakuSending, let b = bridge else { return }
        danmakuSending = true
        let at = DDNowPlaying.id == item.id ? DDNowPlaying.time : 0
        Task {
            do {
                let id = try await b.postDanmaku(item.id, text: text, offset: at)
                // 自己发的立刻上屏（从当前时间点开始飘）
                danmaku.append(DYDanmaku(id: id, text: text, offset: at + 0.3))
                danmaku.sort { $0.offset < $1.offset }
                danmakuDraft = ""
                showDanmakuInput = false
                danmakuFocused = false
                onToast?("弹幕已发送")
            } catch {
                onToast?("弹幕发送失败：\(error.localizedDescription)")
            }
            danmakuSending = false
        }
    }

    /// 作者、文案、元数据、音乐；音乐贴近进度条，作者头像归入互动栏。
    private func info(_ fg: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: onAuthor) {
                Text("@" + item.author.name).font(.headline.weight(.bold))
                    .foregroundStyle(fg).lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("douyin.author")
            if !item.desc.isEmpty {
                DYExpandableTitle(text: item.desc, foreground: fg.opacity(0.9),
                                  secondary: fg.opacity(0.7), hashtagNames: item.hashtagNames ?? [])
            }
            if let metadata = item.metadataText() {
                Text(metadata).font(.caption2.weight(.regular))
                    .foregroundStyle(fg.opacity(0.62))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("douyin.video.metadata")
            }
            if !item.music.isEmpty {
                Label(item.music, systemImage: "music.note")
                    .font(.caption2).lineLimit(1)
                    .foregroundStyle(fg.opacity(0.54))
                    .accessibilityIdentifier("douyin.video.music")
            }
        }
        .themeShadow(.mediaLabel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.video.info")
    }

    private var authorButton: some View {
        DYAuthorAvatarControl(image: authorImage, name: item.author.name,
                              onAuthor: onAuthor, follow: followBadge)
            .frame(width: railWidth)
    }

    private var followBadge: AnyView? {
        guard bridge != nil, !authorFollowed,
              item.author.uid?.isEmpty == false || item.author.secUid?.isEmpty == false else { return nil }
        return AnyView(Button {
            Task { await followAuthor() }
        } label: {
            DYAuthorFollowMark(followed: false, busy: followBusy)
            .frame(width: 28, height: 28).contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(followBusy)
        .accessibilityLabel("关注 " + item.author.name)
        .accessibilityIdentifier("douyin.author.followBadge"))
    }

    private func followAuthor() async {
        guard let bridge, !followBusy, !authorFollowed else { return }
        followBusy = true
        defer { followBusy = false }
        do {
            var uid = item.author.uid
            if uid?.isEmpty != false, let sec = item.author.secUid {
                let state = try await bridge.followState(sec: sec)
                if state.followed { bridge.rememberFollow(item.author, followed: true); return }
                uid = state.uid
            }
            guard let uid, !uid.isEmpty else { onToast?("暂时无法获取作者信息"); return }
            switch try await bridge.followUser(uid, follow: true) {
            case .ok: bridge.rememberFollow(item.author, followed: true)
            case .notLoggedIn: onToast?("抖音未登录，请先登录")
            case .failed(let message): onToast?("关注失败：" + message)
            }
        } catch { onToast?("关注失败：" + error.localizedDescription) }
    }

    private func actionCapsule(_ foreground: Color) -> some View {
        actions(foreground)
            .frame(width: railWidth)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
    }

    private func toolbarActions(_ fg: Color) -> DYVideoToolbarActions {
        DYVideoToolbarActions(
            avatarImage: authorImage, authorName: item.author.name,
            onAuthor: onAuthor, follow: followBadge,
            like: AnyView(railItem(liked ? "heart.fill" : "heart", DYFormat.count(item.stats.digg + (liked ? 1 : 0)),
                                  tint: liked ? theme.status.danger.color(for: scheme) : fg, "douyin.like", onLike)),
            comments: AnyView(railItem("ellipsis.bubble", DYFormat.count(item.stats.comment), tint: fg, "douyin.comments", onComments)),
            collect: AnyView(railItem(collected ? "star.fill" : "star", DYFormat.count(item.stats.collect + (collected ? 1 : 0)),
                                     tint: collected ? theme.status.warning.color(for: scheme) : fg, "douyin.collect", onCollect)),
            share: AnyView(railItem("arrowshape.turn.up.right", DYFormat.count(item.stats.share), tint: fg, "douyin.share") { showShare = true })
        )
    }

    private func circularAvatar(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        return UIGraphicsImageRenderer(size: CGSize(width: 36, height: 36), format: format).image { _ in
            let rect = CGRect(x: 1, y: 1, width: 34, height: 34)
            UIBezierPath(ovalIn: rect).addClip()
            let ratio = max(rect.width / max(image.size.width, 1), rect.height / max(image.size.height, 1))
            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            image.draw(in: CGRect(x: 18 - size.width / 2, y: 18 - size.height / 2, width: size.width, height: size.height))
            UIColor.white.setStroke()
            UIBezierPath(ovalIn: rect).stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    /// One set of actions for the current work. Home hosts it above the native
    /// tab selector; standalone work players retain their per-page controls.
    private func actions(_ fg: Color) -> some View {
        VStack(spacing: 4) {
            authorButton
            railItem(liked ? "heart.fill" : "heart", DYFormat.count(item.stats.digg + (liked ? 1 : 0)),
                     tint: liked ? theme.status.danger.color(for: scheme) : fg, "douyin.like", onLike)
            railItem("ellipsis.bubble", DYFormat.count(item.stats.comment), tint: fg, "douyin.comments", onComments)
            railItem(collected ? "star.fill" : "star", DYFormat.count(item.stats.collect + (collected ? 1 : 0)),
                     tint: collected ? theme.status.warning.color(for: scheme) : fg, "douyin.collect", onCollect)
            railItem("arrowshape.turn.up.right", DYFormat.count(item.stats.share), tint: fg, "douyin.share") { showShare = true }
        }
        .foregroundStyle(fg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.video.actions")
    }

    private func railItem(_ icon: String, _ text: String, tint: Color, _ id: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .resizable().scaledToFit()
                    .frame(width: 27, height: 27)
                    .foregroundStyle(tint)
                    .frame(height: 30)
                if !text.isEmpty {
                    Text(text).font(.caption2.weight(.medium)).monospacedDigit()
                        .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(width: railWidth, height: text.isEmpty ? 44 : 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((id == "douyin.like" ? "点赞" : id == "douyin.comments" ? "评论" : id == "douyin.collect" ? "收藏" : "分享") + "，" + text)
        .accessibilityIdentifier(id)
    }


}

enum DYFormat {
    static func clock(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let i = Int(t.rounded(.down))
        return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i % 3600 / 60, i % 60) : String(format: "%d:%02d", i / 60, i % 60)
    }
    static func count(_ n: Int) -> String {
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 1e8) }
        if n >= 10_000 { return String(format: "%.1fw", Double(n) / 1e4) }
        return "\(n)"
    }
    static func time(_ ts: Double) -> String {
        let d = Date().timeIntervalSince1970 - ts
        if d < 3600 { return "\(max(1, Int(d / 60)))分钟前" }
        if d < 86400 { return "\(Int(d / 3600))小时前" }
        if d < 86400 * 30 { return "\(Int(d / 86400))天前" }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}

// MARK: - 评论

struct DYCommentPanel: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage(DDChromeMode.key) private var chromeModeRaw = DDChromeMode.classic.rawValue
    private var usesClassicComments: Bool {
        if #available(iOS 27.1, *) { return chromeModeRaw == DDChromeMode.duoClassic.rawValue }
        return false
    }
    let bridge: DouyinBridge
    let aweme: DYAweme
    let onClose: (() -> Void)?
    /// 从消息点评论进来：首屏用 insert_ids 把这条评论顶到第一条并高亮
    let focus: DYCommentFocus?
    let fillsPane: Bool
    let trailingInset: CGFloat
    @State private var items: [DYComment] = []
    @State private var cursor = 0
    @State private var hasMore = true
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var replies: [String: [DYComment]] = [:]
    @State private var replyCursor: [String: Int] = [:]
    @State private var replyMore: [String: Bool] = [:]
    @State private var replyLoading: Set<String> = []
    @State private var replyErr: [String: String] = [:]
    @State private var draft = ""
    @State private var replyTo: DYComment?
    /// replyTo 是楼中楼时它所在的一级评论 cid（发送走 reply_id=一级、reply_to_reply_id=这条）
    @State private var replyParent: String?
    @State private var highlight: String?
    @State private var focusMiss = false
    @State private var showEmoji = false
    @State private var showAt = false
    @State private var emojis: [DYEmoji] = []
    @State private var friends: [DYFriend] = []
    @State private var atLoading = false
    @State private var atError: String?
    @State private var sending = false
    @State private var sendErr: String?
    @State private var digged: Set<String> = []
    @State private var diggShown: [String: Int] = [:]
    @State private var relatedWords: [String] = []
    @State private var relatedQuery: DYRelatedQuery?
    @Environment(\.dyOpenSearch) private var openSearch
    @State private var listAtTop = true
    @State private var bottomSafeArea = DYDuoMetrics.windowBottomInset
    @FocusState private var inputFocused: Bool
    @Environment(\.dyCommentTrailingCleared) private var trailingCleared

    init(bridge: DouyinBridge, aweme: DYAweme, onClose: (() -> Void)?, focus: DYCommentFocus? = nil, fillsPane: Bool = false, trailingInset: CGFloat = 0) {
        self.bridge = bridge; self.aweme = aweme; self.onClose = onClose
        self.fillsPane = fillsPane
        self.trailingInset = trailingInset
        self.focus = focus?.awemeID == aweme.id ? focus : nil
    }

    var body: some View {
        Group {
            if usesClassicComments { classicBody } else { upstreamBody }
        }
        .accessibilityValue(usesClassicComments ? "经典评论" : "上游评论")
    }

    private var upstreamBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text(total > 0 ? "\(DYFormat.count(total)) 条评论" : "评论").font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("douyin.comments.title")
                Spacer()
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark").font(.subheadline.weight(.semibold)) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("douyin.comments.close")
                }
            }
            .foregroundStyle(.themeTextPrimary)
            .padding(.horizontal, 16).padding(.vertical, 12)
            // 横屏（侧栏）时关闭键离右缘太近，会和视频时间显示挤在一起，整体左移让位；
            // 外层已按系统竖栏缩窄过面板时不再重复让位（issue #15）
            .padding(.trailing, hSize == .regular && !trailingCleared ? 88 : 0)
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if focusMiss {
                        Text("这条评论已删除或暂不可见").font(.caption).foregroundStyle(.themeTextSecondary)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(items) { c in
                        VStack(alignment: .leading, spacing: 10) {
                            row(c, parent: nil)
                            if c.replies > 0 || !(replies[c.id] ?? []).isEmpty { replyBlock(c) }
                        }
                        .id(c.id)
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(theme.status.danger.color(for: scheme))
                    }
                    if hasMore {
                        ProgressView().frame(maxWidth: .infinity)
                            .onAppear { Task { await load() } }
                    } else if items.isEmpty {
                        Text("还没有评论").font(.footnote).foregroundStyle(.themeTextSecondary).frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
            .accessibilityIdentifier("douyin.comments.list")
            .onChange(of: highlight) { _, h in
                guard let h else { return }
                withAnimation(.snappy) { proxy.scrollTo(h, anchor: .center) }
            }
            }
            if !relatedWords.isEmpty {
                Divider()
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        Text("相关搜索").font(.caption).foregroundStyle(.themeTextSecondary)
                        ForEach(relatedWords, id: \.self) { word in
                            Button { searchRelated(word) } label: {
                                Label(word, systemImage: "magnifyingglass")
                                    .font(.footnote).lineLimit(1)
                                    .foregroundStyle(theme.accent.color(for: scheme))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("douyin.comments.relatedSearch")
            }
            Divider()
            inputBar
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.comments.panel")
        .background(GlassBackground())
        .modifier(DYRailReservedNudge())
        .task(id: aweme.id) { relatedWords = await bridge.relatedSearch(for: aweme) }
        .fullScreenCover(item: $relatedQuery) { query in
            DYRelatedSearchScreen(bridge: bridge, word: query.word)
        }
    }

    private var classicBody: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(total > 0 ? "\(DYFormat.count(total)) 条评论" : "评论")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("douyin.comments.title")
                if let onClose {
                    HStack {
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭评论")
                        .accessibilityIdentifier("douyin.comments.close")
                    }
                }
            }
            .frame(minHeight: 44)
            .foregroundStyle(.themeTextPrimary)
            .padding(.horizontal, 16)
            .padding(.trailing, trailingInset)
            .contentShape(Rectangle())
            .modifier(DYPanelDismissGesture(allowsSwipeRight: true, onClose: onClose))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("douyin.comments.header")

            if !relatedWords.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        Text("相关搜索").font(.caption).foregroundStyle(.themeTextSecondary)
                        ForEach(relatedWords, id: \.self) { word in
                            Button { searchRelated(word) } label: {
                                Label(word, systemImage: "magnifyingglass")
                                    .font(.footnote).lineLimit(1)
                                    .foregroundStyle(theme.accent.color(for: scheme))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 0).padding(.bottom, 4)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity)
                .clipped()
                .padding(.trailing, trailingInset)
                .accessibilityIdentifier("douyin.comments.relatedSearch")
            }
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if focusMiss {
                        Text("这条评论已删除或暂不可见").font(.caption).foregroundStyle(.themeTextSecondary)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(items) { c in
                        VStack(alignment: .leading, spacing: 10) {
                            row(c, parent: nil)
                            if c.replies > 0 || !(replies[c.id] ?? []).isEmpty { replyBlock(c) }
                        }
                        .id(c.id)
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(theme.status.danger.color(for: scheme))
                    }
                    if hasMore {
                        ProgressView().frame(maxWidth: .infinity)
                            .onAppear { Task { await load() } }
                    } else if items.isEmpty {
                        Text("还没有评论").font(.footnote).foregroundStyle(.themeTextSecondary).frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
            .clipped()
            .modifier(DYScrollTopObserver(atTop: $listAtTop))
            .modifier(DYPanelDismissGesture(isAtTop: listAtTop, allowsSwipeRight: true, onClose: onClose))
            .accessibilityIdentifier("douyin.comments.list")
            .onChange(of: highlight) { _, h in
                guard let h else { return }
                withAnimation(.snappy) { proxy.scrollTo(h, anchor: .center) }
            }
            }
            VStack(spacing: 0) {
                Divider()
                inputBar
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(fillsPane ? Color(uiColor: .secondarySystemBackground) : .clear)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(fillsPane ? Color(uiColor: .secondarySystemBackground) : .clear)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.comments.panel")
        .onGeometryChange(for: CGFloat.self) { geo in
            DYDuoMetrics.bottomSafeAreaOverlap(in: geo)
        } action: { bottomSafeArea = $0 }
        .task(id: aweme.id) { relatedWords = await bridge.relatedSearch(for: aweme) }
        .fullScreenCover(item: $relatedQuery) { query in
            DYRelatedSearchScreen(bridge: bridge, word: query.word)
        }
    }

    private func searchRelated(_ word: String) {
        guard let openSearch else { relatedQuery = DYRelatedQuery(word: word); return }
        onClose?()
        // Let a compact comment sheet dismiss before the video host presents search.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openSearch(word) }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showAt { atPanel }
            if let r = replyTo {
                HStack {
                    Text("回复 @\(r.name)").font(.caption).foregroundStyle(.themeTextSecondary).lineLimit(1)
                    Spacer()
                    Button { replyTo = nil; replyParent = nil } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.themeTextSecondary)
                }
            }
            if let e = sendErr {
                Text(e).font(.caption2).foregroundStyle(theme.status.danger.color(for: scheme))
            }
            HStack(spacing: 8) {
                Button {
                    showEmoji.toggle()
                    showAt = false
                    if showEmoji, emojis.isEmpty { Task { emojis = await bridge.emojiList() } }
                } label: {
                    Image(systemName: showEmoji ? "keyboard" : "face.smiling")
                        .font(.body).foregroundStyle(showEmoji ? theme.accent.color(for: scheme) : .themeTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.comment.emoji")
                Button {
                    showAt.toggle()
                    showEmoji = false
                    if showAt { Task { await loadFriends() } }
                } label: {
                    Image(systemName: "at").font(.body.weight(.medium))
                        .foregroundStyle(showAt ? theme.accent.color(for: scheme) : .themeTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.comment.at")
                TextField(replyTo == nil ? "说点什么…" : "回复 \(replyTo!.name)", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(minHeight: usesClassicComments ? 44 : nil)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .accessibilityIdentifier("douyin.comment.input")
                Button { Task { await send() } } label: {
                    if sending { ProgressView().controlSize(.small) }
                    else { Image(systemName: "paperplane.fill").font(.body.weight(.semibold)) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : theme.accent.color(for: scheme))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .accessibilityIdentifier("douyin.comment.send")
            }
            if showEmoji {
                if emojis.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("加载表情…").font(.caption2).foregroundStyle(.themeTextSecondary)
                    }
                    .frame(height: 60)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 8) {
                            ForEach(emojis) { e in
                                Button { draft += e.displayName } label: {
                                    CachedAsyncImage(url: e.url.flatMap(URL.init(string:))) { img in
                                        img.resizable().scaledToFit()
                                    } placeholder: { Color.clear }
                                    .frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 150)
                    .accessibilityIdentifier("douyin.comment.emojis")
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, usesClassicComments ? 6 : 8)
        .padding(.bottom, usesClassicComments ? max(18, bottomSafeArea + 4) : 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.comments.composer")
        .task { await DYEmojiStore.shared.load(bridge: bridge) }
    }

    /// 拉「我关注的人」给 @ 面板用
    private func loadFriends() async {
        guard friends.isEmpty, !atLoading else { return }
        atLoading = true
        defer { atLoading = false }
        do {
            let r = try await bridge.followingUsers()
            friends = r.items
            atError = r.items.isEmpty ? "没拿到关注列表（可能未登录）" : nil
        } catch {
            atError = "关注列表加载失败：\(error.localizedDescription)"
        }
    }

    /// @ 面板：优先「我关注的人」，拿不到时退回本视频评论区里的人
    @ViewBuilder
    private var atPanel: some View {
        let people: [DYFriend] = friends.isEmpty
            ? atCandidates.map { DYFriend(name: $0.name, avatar: $0.avatar, secUid: $0.id) }
            : friends
        // 跟抖音一致：输入框上方一排头像 + 昵称，横滑
        VStack(alignment: .leading, spacing: 4) {
            if atLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("加载朋友…").font(.caption2).foregroundStyle(.themeTextSecondary)
                }
                .padding(.vertical, 8)
            } else if people.isEmpty {
                Text(atError ?? "没有可 @ 的人").font(.caption2).foregroundStyle(.themeTextSecondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(people, id: \.id) { u in
                            Button {
                                draft += "@\(u.name) "
                                showAt = false
                                inputFocused = true
                            } label: {
                                VStack(spacing: 5) {
                                    CachedAsyncImage(url: u.avatar.flatMap(URL.init(string:))) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: { Color.primary.opacity(0.08) }
                                    .frame(width: 50, height: 50).clipShape(Circle())
                                    Text(u.name)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.themeTextPrimary)
                                        .lineLimit(1)
                                        .frame(width: 56)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 6)
                }
                .frame(height: 92)
            }
        }
        .padding(.top, 2)
    }

    /// @ 候选：评论作者 + 楼中楼作者，去重
    private var atCandidates: [DYComment] {
        var seen = Set<String>()
        var out: [DYComment] = []
        for c in items {
            if seen.insert(c.name).inserted { out.append(c) }
            for r in replies[c.id] ?? [] where seen.insert(r.name).inserted { out.append(r) }
        }
        return Array(out.prefix(30))
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        do {
            // 回楼中楼：reply_id 必须是一级评论，被回的那条放 reply_to_reply_id（网页同款）
            let top = replyParent ?? replyTo?.id
            let c = try await bridge.publishComment(aweme.id, text: text, replyID: top,
                                                    replyToReplyID: replyParent == nil ? nil : replyTo?.id)
            if let top {
                replies[top, default: []].insert(c, at: 0)
            } else {
                items.insert(c, at: 0)
                total += 1
            }
            draft = ""; replyTo = nil; replyParent = nil; sendErr = nil
            inputFocused = false
        } catch {
            sendErr = "发送失败：\(error.localizedDescription)"
        }
    }

    private func row(_ c: DYComment, parent: String?) -> some View {
        rowBody(c)
            .padding(.trailing, fillsPane && c.id == items.first?.id ? trailingInset : 0)
            .contentShape(Rectangle())
            .onTapGesture { replyTo = c; replyParent = parent ?? c.parent; inputFocused = true }
            .padding(highlight == c.id ? 6 : 0)
            .background {
                if highlight == c.id {
                    RoundedRectangle(cornerRadius: 10).fill(theme.accent.color(for: scheme).opacity(0.16))
                }
            }
            .accessibilityIdentifier(highlight == c.id ? "douyin.comment.focused" : "douyin.comment.row")
    }

    private func rowBody(_ c: DYComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CachedAsyncImage(url: c.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                placeholder: { Color.primary.opacity(0.08) }
                .frame(width: 32, height: 32).clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(c.name).font(.caption.weight(.semibold)).foregroundStyle(.themeTextSecondary)
                if !c.text.isEmpty {
                    DYEmojiStore.shared.rich(c.text).font(.subheadline).foregroundStyle(.themeTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DYCommentMedia(comment: c)
                HStack(spacing: 8) {
                    Text(DYFormat.time(c.time))
                    if let ip = c.ip, !ip.isEmpty { Text(ip) }
                }
                .font(.caption2).foregroundStyle(.themeTextSecondary)
            }
            Spacer(minLength: 4)
            commentDigg(c)
        }
    }

    private func commentDigg(_ c: DYComment) -> some View {
        let on = digged.contains(c.id)
        let n = diggShown[c.id] ?? c.digg
        return Button { Task { await toggleDigg(c) } } label: {
            VStack(spacing: 2) {
                Image(systemName: on ? "heart.fill" : "heart").font(.caption)
                Text(DYFormat.count(max(0, n))).font(.caption2)
            }
            .foregroundStyle(on ? theme.status.danger.color(for: scheme) : Color.themeTextSecondary)
            .frame(minWidth: 32, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("douyin.comment.digg")
    }

    private func toggleDigg(_ c: DYComment) async {
        let want = !digged.contains(c.id)
        let before = diggShown[c.id] ?? c.digg
        if want { digged.insert(c.id) } else { digged.remove(c.id) }
        diggShown[c.id] = max(0, before + (want ? 1 : -1))
        do {
            switch try await bridge.diggComment(c.id, awemeID: aweme.id, like: want) {
            case .ok:
                break
            case .notLoggedIn:
                revertDigg(c, want: want, before: before)
                sendErr = "抖音未登录"
            case .failed(let why):
                revertDigg(c, want: want, before: before)
                sendErr = why
            }
        } catch {
            revertDigg(c, want: want, before: before)
            sendErr = error.localizedDescription
        }
    }

    private func revertDigg(_ c: DYComment, want: Bool, before: Int) {
        if want { digged.remove(c.id) } else { digged.insert(c.id) }
        diggShown[c.id] = before
    }

    @ViewBuilder
    private func replyBlock(_ c: DYComment) -> some View {
        let got = replies[c.id] ?? []
        VStack(alignment: .leading, spacing: 10) {
            ForEach(got) { r in row(r, parent: c.id).id(r.id) }
            if replyErr[c.id] != nil {
                Button { replyErr[c.id] = nil; Task { await loadReplies(c) } } label: {
                    Text("回复加载失败，点此重试").font(.caption).foregroundStyle(.themeTextSecondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            } else if replies[c.id] == nil || (replyMore[c.id] ?? false) {
                Button { Task { await loadReplies(c) } } label: {
                    HStack(spacing: 6) {
                        Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 18, height: 1)
                        Text(replies[c.id] == nil ? "展开 \(c.replies) 条回复" : "展开更多回复")
                        if replyLoading.contains(c.id) { ProgressView().controlSize(.mini) }
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.themeTextSecondary)
                }
                .buttonStyle(.plain)
                // 和上方回复拉开距离，避免误点到回复评论
                .padding(.top, 12)
                .accessibilityIdentifier("douyin.replies")
            }
        }
        .padding(.leading, 42)
    }

    /// insert_ids 回来后：一级评论已在第一条；楼中楼挂在它的 pinned 里，先塞进回复区再高亮
    private func applyFocus(_ f: DYCommentFocus, page: [DYComment]) {
        // 接口两种形态（2026-11 实测）：
        // A. 一级评论排第一，楼中楼挂在它的 reply_comment 里；
        // B. 一级评论没回来时，楼中楼本身直接排在一级列表第一条（reply_id = 一级评论）。
        let top = f.parentCid ?? f.cid
        var target: String?
        if let head = page.first(where: { $0.id == top }) {
            if f.parentCid != nil, let pinned = head.pinned, !pinned.isEmpty {
                replies[top] = pinned
                replyMore[top] = head.replies > pinned.count
            }
            target = (replies[top] ?? []).contains { $0.id == f.cid } ? f.cid : top
        }
        if target == nil || target == top, page.contains(where: { $0.id == f.cid }) { target = f.cid }
        guard let target else {
            focusMiss = true
            DYLiveModel.log("DDFOCUS miss aweme=\(f.awemeID) cid=\(f.cid) parent=\(f.parentCid ?? "-")")
            return
        }
        let head = page.first(where: { $0.id == top })
        DYLiveModel.log("DDFOCUS hit aweme=\(f.awemeID) cid=\(f.cid) parent=\(f.parentCid ?? "-") target=\(target) pinned=\(head?.pinned?.count ?? 0)")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            highlight = target
            try? await Task.sleep(for: .seconds(6))
            withAnimation(.easeOut(duration: 0.8)) { if highlight == target { highlight = nil } }
        }
    }

    private func loadReplies(_ c: DYComment) async {
        guard !replyLoading.contains(c.id) else { return }
        replyLoading.insert(c.id)
        defer { replyLoading.remove(c.id) }
        do {
            let r = try await bridge.fetchReplies(aweme.id, commentID: c.id, cursor: replyCursor[c.id] ?? 0)
            DYLiveModel.log("DDREPLY cid=\(c.id) n=\(r.items.count) first=\(r.items.first?.text ?? "-")")
            let seen = Set((replies[c.id] ?? []).map(\.id))
            replies[c.id, default: []].append(contentsOf: r.items.filter { !seen.contains($0.id) })
            replyCursor[c.id] = r.cursor
            replyMore[c.id] = r.hasMore && !r.items.isEmpty
            replyErr[c.id] = nil
        } catch {
            DYLiveModel.log("DDREPLY cid=\(c.id) error=\(error)")
            replyErr[c.id] = "回复加载失败：\(error.localizedDescription)"
        }
    }

    private func load() async {
        guard !loading, hasMore else { return }
        loading = true
        defer { loading = false }
        do {
            let first = cursor == 0 && items.isEmpty
            let ins = first ? focus.map { f in [f.parentCid, f.cid].compactMap { $0 }.joined(separator: ",") } : nil
            let r = try await bridge.fetchComments(aweme.id, cursor: cursor, insert: ins)
            let seen = Set(items.map(\.id))
            items.append(contentsOf: r.items.filter { !seen.contains($0.id) })
            if let f = focus, first { applyFocus(f, page: r.items) }
            for c in r.items where c.userDigged == 1 { digged.insert(c.id) }
            cursor = r.cursor
            hasMore = r.hasMore && !r.items.isEmpty
            total = max(total, r.total, aweme.stats.comment)
            error = nil
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_AUTOREPLY"] == "1", let c = items.first(where: { $0.replies > 0 }), replies[c.id] == nil {
                Task { await loadReplies(c) }
            }
            #endif
        } catch {
            self.error = error.localizedDescription
            hasMore = false
        }
    }
}

// MARK: - 评论表情

/// 评论输入框的表情面板（纯 emoji，跟着文字一起发，不依赖抖音的表情包接口）
enum DYCommentEmoji {
    static let all: [String] = [
        "😀", "😄", "😁", "😂", "🤣", "😊", "😍", "🥰",
        "😘", "😎", "🤩", "🥳", "😏", "😅", "😅", "🙃",
        "😢", "😭", "😤", "😡", "🤬", "😱", "😨", "😰",
        "🤔", "🤨", "😐", "😑", "🙄", "😴", "🥱", "🤯",
        "😳", "🥺", "😬", "🤐", "🤫", "🤭", "😷", "🤒",
        "👍", "👎", "👏", "🙏", "💪", "🤝", "👌", "✌️",
        "👊", "🫶", "❤️", "💔", "🔥", "🎉", "🎊", "💯",
        "⭐", "✨", "🌹", "🌸", "🍺", "🍻", "☕", "🧋",
        "🍜", "🍚", "🍗", "🍰", "🎮", "⚽", "🏀", "🚀",
        "💰", "🎁", "🐶", "🐱", "🐼", "🦁", "🐸", "🦄"
    ]
}

// MARK: - 评论配图 / 表情包贴纸

/// 评论里的图片与贴纸：缩略图按原比例限高显示，点开全屏横滑看原图（同图集用 TabView 分页）
struct DYCommentMedia: View {
    let comment: DYComment
    @State private var viewer: DYCommentViewerTarget?

    private var pics: [DYCommentImage] { comment.images ?? [] }

    var body: some View {
        content.fullScreenCover(item: $viewer) { t in DYCommentImageViewer(target: t) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) { media }
    }

    @ViewBuilder
    private var media: some View {
        if let s = comment.sticker {
            // 贴纸：表情包尺寸，不放大
            thumb(s, maxSide: 96)
                .onTapGesture { viewer = DYCommentViewerTarget(images: [s], start: 0) }
                .accessibilityIdentifier("douyin.comment.sticker")
        }
        if !pics.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(pics.prefix(3).enumerated()), id: \.offset) { i, img in
                    thumb(img, maxSide: pics.count == 1 ? 160 : 96)
                        .overlay(alignment: .bottomTrailing) {
                            if i == 2, pics.count > 3 {
                                Text("+\(pics.count - 3)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                    .padding(4).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                                    .padding(4)
                            }
                        }
                        .onTapGesture { viewer = DYCommentViewerTarget(images: pics, start: i) }
                }
            }
            .accessibilityIdentifier("douyin.comment.images")
        }
    }

    private func thumb(_ img: DYCommentImage, maxSide: CGFloat) -> some View {
        let ratio = (img.w > 0 && img.h > 0) ? img.w / img.h : 1
        let w = ratio >= 1 ? maxSide : maxSide * ratio
        let h = ratio >= 1 ? maxSide / ratio : maxSide
        return CachedAsyncImage(url: URL(string: img.thumb)) { i in i.resizable().scaledToFill() }
            placeholder: { Color.primary.opacity(0.08) }
            .frame(width: max(w, 44), height: max(h, 44))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

struct DYCommentViewerTarget: Identifiable {
    let id = UUID()
    let images: [DYCommentImage]
    let start: Int
}

struct DYCommentImageViewer: View {
    let target: DYCommentViewerTarget
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Array(target.images.enumerated()), id: \.offset) { i, img in
                    CachedAsyncImage(url: URL(string: img.full)) { v in v.resizable().scaledToFit() }
                        placeholder: { ProgressView().tint(.white) }
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: target.images.count > 1 ? .always : .never))
            .ignoresSafeArea()
            .onTapGesture { dismiss() }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Circle().fill(.black.opacity(0.4)))
            }
            .padding(16)
            .accessibilityIdentifier("douyin.comment.viewer.close")
        }
        .dyEdgeBack { dismiss() }
        .onAppear { page = target.start }
    }
}

private struct DYTopChromeFrameKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.maxY > value.maxY { value = next }
    }
}

#if DEBUG
extension DYFeedModel {
    static var hashtagFixtures: [DYAweme] {
        let playable = ProcessInfo.processInfo.environment["DOUDUO_PLAYBACK_FIXTURE"] == "1"
        let video = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("search-playback-fixture.mp4")
        return [("hashtag-cat", "日常 #猫咪 #旅行\n" + String(repeating: "这段简介用于检查展开后的标签点击与换行。", count: 8) + " #摄影"),
         ("hashtag-travel", "周末记录 #旅行"),
         ("hashtag-plain", "这是一段没有标签的普通简介，提到猫咪也不会被屏蔽。")].map { id, text in
            DYAweme(id: id, desc: text, width: playable ? 640 : 1080, height: playable ? 360 : 1920, duration: playable ? 60 : 0, play: playable ? video.absoluteString : nil,
                    cover: nil, images: [], author: .init(name: "标签功能测试", avatar: nil, secUid: nil),
                    stats: .init(digg: 0, comment: 0, collect: 0, share: 0), music: "",
                    userDigged: nil, isCollect: nil, publishedAt: 1,
                    hashtagNames: id == "hashtag-cat" ? ["猫咪", "旅行", "摄影", "美食", "科技", "自然", "城市漫步", "运动"] : nil)
        }
    }
}
#endif

// MARK: - 推荐流共用操作（默认/简洁/极简 与 经典 两套根视图共用，别再各写一份）

@MainActor
extension DYFeedModel {
    func toggleLike(_ id: String, force: Bool?, bridge: DouyinBridge) {
        let has = self.liked.contains(id)
        let want = force ?? !has
        guard want != has else { return }
        if want { self.liked.insert(id) } else { self.liked.remove(id) }
        Task {
            do {
                switch try await bridge.digg(id, like: want) {
                case .ok:
                    break
                case .notLoggedIn:
                    await MainActor.run {
                        if want { self.liked.remove(id) } else { self.liked.insert(id) }
                        self.showToast("抖音未登录：菜单 → 网页版 / 登录")
                    }
                case .failed(let why):
                    await MainActor.run {
                        if want { self.liked.remove(id) } else { self.liked.insert(id) }
                        self.showToast("点赞失败：\(why)")
                    }
                }
            } catch {
                #if DEBUG
                ddWrite("DDACT digg ERROR \(error)")
                #endif
                await MainActor.run {
                    if want { self.liked.remove(id) } else { self.liked.insert(id) }
                    self.showToast("点赞失败：\(error.localizedDescription)")
                }
            }
        }
    }
    func toggleCollect(_ id: String, bridge: DouyinBridge) {
        let has = self.collected.contains(id)
        let want = !has
        if want { self.collected.insert(id) } else { self.collected.remove(id) }
        Task {
            do {
                switch try await bridge.favorite(id, add: want) {
                case .ok:
                    await MainActor.run { self.showToast(want ? "已收藏" : "已取消收藏") }
                case .notLoggedIn:
                    await MainActor.run {
                        if want { self.collected.remove(id) } else { self.collected.insert(id) }
                        self.showToast("抖音未登录：菜单 → 网页版 / 登录")
                    }
                case .failed(let why):
                    await MainActor.run {
                        if want { self.collected.remove(id) } else { self.collected.insert(id) }
                        self.showToast("收藏失败：\(why)")
                    }
                }
            } catch {
                #if DEBUG
                ddWrite("DDACT fav ERROR \(error)")
                #endif
                await MainActor.run {
                    if want { self.collected.remove(id) } else { self.collected.insert(id) }
                    self.showToast("收藏失败：\(error.localizedDescription)")
                }
            }
        }
    }
    /// 启动秒开：先恢复上次会话；没有会话就从本地已缓存未看的视频按竖横比例挑 6 条。
    /// 返回要定位的当前条和各条进度；都没有返回 nil。
    func restoreForLaunch() -> (currentID: String?, positions: [String: Double])? {
        var result: (currentID: String?, positions: [String: Double])?
        if items.isEmpty, let saved = DYFeedSession.load() {
            items = allowedRecommendations(saved.items)
            let cur = items.contains(where: { $0.id == saved.currentID }) ? saved.currentID : items.first?.id
            result = (cur, saved.positions)
            markAccountState(saved.items)
            DYLiveModel.log("DDSESSION 恢复 id=\(saved.currentID) t=\(saved.positions[saved.currentID] ?? 0)")
        }
        if items.isEmpty {
            let cached = DYVideoCache.pendingSnapshot()
            if !cached.isEmpty {
                seedPool(cached)
                if fill(6) == 0 { fill(6, relaxed: true) }
                markAccountState(cached)
                result = (items.first?.id, [:])
                DYLiveModel.log("DDCACHE 启动从缓存起播 n=\(items.count)/\(cached.count)")
            }
        }
        seedPool(DYVideoCache.pendingSnapshot())
        return result
    }

    private func markAccountState(_ list: [DYAweme]) {
        for a in list {
            if a.userDigged == 1 { liked.insert(a.id) }
            if a.isCollect == 1 { collected.insert(a.id) }
        }
    }

    func showToast(_ s: String) {
        self.toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self else { return }
            if self.toast == s { self.toast = nil }
        }
    }
}

/// 铺满/还原：两枚对角框，统一圆头笔画，不使用粗箭头。
private struct DYFitCornerGlyph: Shape {
    var inward: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let a = rect.width * 0.17, b = rect.width * 0.83
        let leg = rect.width * 0.29
        if inward {
            p.move(to: CGPoint(x: a, y: a + leg)); p.addLine(to: CGPoint(x: a + leg, y: a + leg)); p.addLine(to: CGPoint(x: a + leg, y: a))
            p.move(to: CGPoint(x: b, y: b - leg)); p.addLine(to: CGPoint(x: b - leg, y: b - leg)); p.addLine(to: CGPoint(x: b - leg, y: b))
        } else {
            p.move(to: CGPoint(x: a, y: a + leg)); p.addLine(to: CGPoint(x: a, y: a)); p.addLine(to: CGPoint(x: a + leg, y: a))
            p.move(to: CGPoint(x: b - leg, y: b)); p.addLine(to: CGPoint(x: b, y: b)); p.addLine(to: CGPoint(x: b, y: b - leg))
        }
        return p
    }
}
