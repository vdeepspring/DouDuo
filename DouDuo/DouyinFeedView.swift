// DouDuo：抖音第三方客户端。数据走抖音网页端接口，界面 / 播放全原生。
// 源自 無為 App 的「抖音原生模式」。
// - 一个看不见的 WKWebView（电脑版 UA）挂在抖音页面上，只当「签名代理」：在页面里发 XHR，
//   抖音自己的安全 SDK 自动补 a_bogus 等签名，签名算法跟着官方更新走，我们不用逆向。
// - 登录态与「网页版」共用 WKWebsiteDataStore.default()，在网页版登录后原生模式即带账号。
// - 推荐流：POST /aweme/v2/web/module/feed/（module_id=3003101，绝大多数竖屏）；
//   播放用 /aweme/v1/play/ 链接（302 到 CDN mp4，不需要 cookie，系统播放器直接播）。
// - 评论：GET /aweme/v1/web/comment/list/。
import SwiftUI
import Combine
import WebKit
import AVFoundation

// MARK: - 数据

struct DYAweme: Identifiable, Codable, Equatable {
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

    struct Author: Codable, Equatable { let name: String; let avatar: String?; let secUid: String?; var uid: String? = nil; var follow: Int? = nil }
    struct Stats: Codable, Equatable { let digg: Int; let comment: Int; let collect: Int; let share: Int }

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
    let portrait: Bool

    var bestHLS: URL? {
        for k in ["HD1", "FULL_HD1", "SD2", "SD1"] { if let s = hls[k], let u = URL(string: s) { return u } }
        return hls.values.first.flatMap(URL.init(string:))
    }
    var webURL: URL { URL(string: "https://live.douyin.com/\(webRid)")! }
}

private struct DYLiveResp: Decodable { let status: Int; let items: [DYLiveRoom] }

private struct DYFeedPage: Decodable { let status: Int; let items: [DYAweme]; let hasMore: Bool; let msg: String? }
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
    let web: WKWebView
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
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
        ready = false
        web.load(URLRequest(url: URL(string: "https://www.douyin.com/jingxuan")!))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 安全 SDK 在 load 之后还要初始化一小会儿
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.ready = true
            // 签名 SDK 就绪后把整页 DOM 清空：隐藏页面不再持续渲染（真机上 WebContent 曾占约 43% 一个核，手机发烫）
            self.web.evaluateJavaScript(Self.quietPageJS) { r, _ in DYLiveModel.log("DDQUIET \(r.map { String(describing: $0) } ?? "nil")") }
            self.readyWaiters.forEach { $0.resume() }
            self.readyWaiters.removeAll()
        }
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
        await waitReady()
        var lastErr: Error = DYError.notReady
        for attempt in 0..<attempts {
            do {
                let r = try await web.callAsyncJavaScript(Self.requestJS + body, arguments: args, contentWorld: .page)
                guard let s = r as? String, let d = s.data(using: .utf8) else { throw DYError.bad("返回为空") }
                return d
            } catch {
                lastErr = error
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
      const kill = () => document.querySelectorAll('video,audio').forEach(v => { try { v.muted = true; v.pause(); v.removeAttribute('autoplay'); v.preload = 'none'; } catch (e) {} });
      document.addEventListener('DOMContentLoaded', kill);
      new MutationObserver(kill).observe(document.documentElement, { childList: true, subtree: true });
    })();
    """

    func fetchFeed() async throws -> (items: [DYAweme], hasMore: Bool) {
        refreshIndex += 1
        let d = try await call(Self.feedJS, args: ["refresh": String(refreshIndex),
                                                   "install": String(Self.installTime),
                                                   "pull": refreshIndex <= 2 ? "0" : "2"])
        let p = try JSONDecoder().decode(DYFeedPage.self, from: d)
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

    func fetchComments(_ id: String, cursor: Int) async throws -> (items: [DYComment], cursor: Int, hasMore: Bool, total: Int) {
        let d = try await call(Self.commentJS, args: ["id": id, "cursor": String(cursor)])
        let p = try JSONDecoder().decode(DYCommentPage.self, from: d)
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        return (p.items, p.cursor, p.hasMore, p.total)
    }

    private var liveMaxTime = "0"

    func fetchLive(reset: Bool) async throws -> [DYLiveRoom] {
        if reset { liveMaxTime = "0" }
        let d = try await call(Self.liveJS, args: ["maxtime": liveMaxTime])
        let p = try JSONDecoder().decode(DYLiveResp.self, from: d)
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        liveMaxTime = String(Int(Date().timeIntervalSince1970))
        return p.items
    }

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
        hls: su.hls_pull_url_map || {}, portrait: su.stream_orientation !== 2 };
    }).filter(x => Object.keys(x.hls).length > 0);
    return JSON.stringify({ status: r.s, items });
    """#

    private static let diggJS = #"""
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
        new MutationObserver(ms => ms.forEach(m => m.addedNodes.forEach(n => { if (n.nodeType === 1 && n.tagName !== 'SCRIPT') n.remove(); })))
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
      x.onload = () => fin({ s: x.status, t: x.responseText }); x.onerror = () => fin({ s: -1, t: '' });
      x.send(body || null);
    });
    const base = { device_platform: 'webapp', aid: '6383', channel: 'channel_pc_web', pc_client_type: '1', pc_libra_divert: 'Mac',
      update_version_code: '170400', support_h265: '1', support_dash: '0', version_code: '170400', version_name: '17.4.0',
      cookie_enabled: 'true', screen_width: '1440', screen_height: '900', browser_language: 'zh-CN', browser_platform: 'MacIntel',
      browser_name: 'Safari', browser_version: '26.0', browser_online: 'true', engine_name: 'WebKit', engine_version: '605.1.15',
      os_name: 'Mac OS', os_version: '10.15.7', cpu_core_num: '8', device_memory: '8', platform: 'PC', downlink: '10',
      effective_type: '4g', round_trip_time: '50' };
    const parse = t => { try { return JSON.parse(t) } catch (e) { return null } };
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
        id: String(a.aweme_id), desc: a.desc || '', width: v.width || 0, height: v.height || 0, duration: (v.duration || 0) / 1000,
        play: best || def,
        playAlt: pickRedirect(br ? br.play_addr.url_list : urls) || (best && def && best !== def ? def : null),
        playFast: fast && fast !== (best || def) ? fast : null,
        q: (br ? (br.gear_name || '?') + ' ' + resOf(br) + 'p h265=' + (br.is_h265 ? 1 : 0) + ' ' + Math.round((br.bit_rate || 0) / 1000) + 'k' : 'nolist')
          + ' | def ' + (pd.width || 0) + 'x' + (pd.height || 0) + ' | gears ' + (v.bit_rate || []).map(r => (r.gear_name || '?') + ':' + Math.round((r.bit_rate || 0) / 1000) + 'k' + (r.is_h265 ? 'h' : '')).join(','),
        cover: first(v.cover) || first(v.origin_cover) || (a.images && a.images[0] && first(a.images[0])) || null,
        images: (a.images || []).map(i => first(i)).filter(Boolean),
        author: { name: (a.author && a.author.nickname) || '', avatar: a.author && first(a.author.avatar_thumb), secUid: a.author && a.author.sec_uid, uid: a.author && a.author.uid ? String(a.author.uid) : null, follow: a.author ? (a.author.follow_status || 0) : 0 },
        awemeType: a.aweme_type || 0,
        stats: { digg: st.digg_count || 0, comment: st.comment_count || 0, collect: st.collect_count || 0, share: st.share_count || 0 },
        music: (a.music && a.music.title) || '',
        userDigged: a.user_digged ? 1 : 0,
        isCollect: (a.is_collect || a.is_collected || (a.collect_stat === 1)) ? 1 : 0
      };
    };
    """#

    private static let feedJS = #"""
    const P = Object.assign({}, base, { module_id: '3003101', count: '20', screen_width: '430', screen_height: '932', filterGids: '', presented_ids: '', refresh_index: refresh,
      refer_id: '', refer_type: '10', pull_type: pull,
      awemePcRecRawData: JSON.stringify({ is_xigua_user: 0, danmaku_switch_status: 0, is_client: false }),
      'Seo-Flag': '0', install_time: install, tag_id: '', active_id: '', is_active_tab: 'false', use_lite_type: '0',
      xigua_user: '0', is_out_feed: '1', enable_ad: '1' });
    const r = await req('POST', '/aweme/v2/web/module/feed/?' + new URLSearchParams(P).toString(), '');
    const d = parse(r.t);
    if (!d) return JSON.stringify({ status: r.s, items: [], hasMore: false, msg: (r.t || '').replace(/[^\u4e00-\u9fa5A-Za-z0-9 ]/g, '').slice(-20) });
    const items = (d.aweme_list || []).filter(a => a && a.video && !a.is_ads && !(a.raw_ad_data)).map(mapA);
    return JSON.stringify({ status: r.s, items, hasMore: !!d.has_more, msg: d.status_msg || null });
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
    const r = await req('GET', '/aweme/v1/web/comment/list/?' + new URLSearchParams(P).toString());
    const d = parse(r.t);
    if (!d) return JSON.stringify({ status: r.s, items: [], cursor: 0, hasMore: false, total: 0, msg: 'blocked' });
    const items = (d.comments || []).map(c => ({
      id: String(c.cid), text: c.text || '', name: (c.user && c.user.nickname) || '', avatar: c.user && first(c.user.avatar_thumb),
      digg: c.digg_count || 0, time: c.create_time || 0, replies: c.reply_comment_total || 0, ip: c.ip_label || null, userDigged: c.user_digged ? 1 : 0
    }));
    return JSON.stringify({ status: r.s, items, cursor: d.cursor || 0, hasMore: !!d.has_more, total: d.total || 0, msg: null });
    """#
}

/// 隐藏网页要挂进窗口里，JS 定时器 / 网络才不被系统节流
private struct DouyinBridgeHost: UIViewRepresentable {
    let bridge: DouyinBridge
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.isUserInteractionEnabled = false
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
        // 错峰：紧挨着的下一条马上暖；再往后的等当前这条先起播一会儿再开，
        // 不然一滑过来当前条要和 2～3 路预加载同时抢带宽 / 解码，起播反而变慢、开头卡
        laterTask?.cancel()
        if let next = window.first { warm(next) }
        let rest = window.dropFirst()
        guard !rest.isEmpty else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for a in rest { self.warm(a) }
        }
        laterTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }

    private var laterTask: DispatchWorkItem?

    private func warm(_ a: DYAweme) {
        guard players[a.id] == nil, !handedOut.contains(a.id) else { return }
        guard a.images.isEmpty, let s = a.play, let url = URL(string: s) else {
            if let c = a.images.first.flatMap(URL.init(string:)) { Task { _ = await ImageCache.shared.load(c) } }
            return
        }
        let local = DYVideoCache.localURL(a.id)
        let item = AVPlayerItem(asset: DYMedia.asset(local ?? url))
        // 本地文件不用预缓冲；在线的只要开头几秒够起播就行，缓多了是在跟当前条抢带宽
        item.preferredForwardBufferDuration = local != nil ? 2 : 4
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.automaticallyWaitsToMinimizeStalling = true
        players[a.id] = p
        // ready 后 preroll：把开头的数据和首帧解码好
        obs[a.id] = item.observe(\.status, options: [.new]) { [weak p] it, _ in
            guard it.status == .readyToPlay else { return }
            DispatchQueue.main.async { p?.preroll(atRate: 1) { _ in } }
        }
        if let c = a.cover.flatMap(URL.init(string:)) { Task { _ = await ImageCache.shared.load(c) } }
    }

    /// 页面起播时来领；领走后由页面负责释放
    func take(_ id: String) -> AVPlayer? {
        guard let p = players.removeValue(forKey: id) else { return nil }
        obs.removeValue(forKey: id)?.invalidate()
        handedOut.insert(id)
        p.isMuted = false
        // 预加载时为省流量限了前向缓冲；变成正在看的这条就交还给系统自动管理，
        // 否则网一抖只有几秒余量，播着播着就卡住转圈
        p.currentItem?.preferredForwardBufferDuration = 0
        return p
    }

    func clear() {
        laterTask?.cancel(); laterTask = nil
        for (id, p) in players { release(id, p) }
        handedOut.removeAll()
    }

    private func release(_ id: String, _ p: AVPlayer) {
        obs.removeValue(forKey: id)?.invalidate()
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

    /// 竖屏占比（拿手机竖着看时）：-1 = 不限（网页推荐原样，约八成横屏）；30/50/70；100 = 只看竖屏。
    /// 网页推荐里竖屏偏少，按比例从拉到的视频里挑；多出来的先放进候选池，下次直接用，不浪费。
    @AppStorage("douyin_portrait_ratio_v1") var portraitRatio = 70
    /// 横着看（屏幕/播放区比高宽）时只放横屏视频
    @AppStorage("douyin_wide_landscape_v1") var landscapeWhenWide = true
    /// 视频比屏幕窄（左右黑边）时自动放大铺满宽度；菜单里可关
    @AppStorage("douyin_autofit_v1") var autoFit = true
    /// 当前播放区是不是横的（宽 > 高），由页面布局同步
    var screenWide = false
    /// 候选池：拉到了但按比例暂时没排进列表的（保持推荐原顺序），以及启动时本地已缓存没看过的
    var pool: [DYAweme] = []
    static let poolCap = 80
    private var mixCredit: Double = 0

    init() {
        // 旧版「只看竖屏」开着的，迁移成 100%
        let d = UserDefaults.standard
        if d.object(forKey: "douyin_portrait_ratio_v1") == nil, d.bool(forKey: "douyin_portrait_only_v2") {
            d.set(100, forKey: "douyin_portrait_ratio_v1")
        }
    }

    static func isPortrait(_ a: DYAweme) -> Bool { !a.images.isEmpty || a.isTallFrame }

    /// 目标竖屏比例；nil = 不限
    var targetRatio: Double? {
        if screenWide && landscapeWhenWide { return 0 }
        return portraitRatio < 0 ? nil : Double(min(portraitRatio, 100)) / 100
    }

    var mixLabel: String {
        if screenWide && landscapeWhenWide { return "横屏中：只放横屏" }
        switch portraitRatio {
        case ..<0: return "不限"
        case 100...: return "只看竖屏"
        default: return "竖屏 \(portraitRatio)%"
        }
    }

    /// 从候选池按比例往列表里排最多 maxN 条；relaxed = 比例凑不齐时也照原顺序放（别让列表断粮）
    @discardableResult
    func fill(_ maxN: Int, relaxed: Bool = false) -> Int {
        var n = 0
        while n < maxN, !pool.isEmpty {
            var idx: Int?
            var wantPortrait: Bool?
            if let r = targetRatio, !relaxed {
                // 均匀穿插（类似 Bresenham）：每条攒 r 份「竖屏额度」，满 1 份就放竖屏，例如 70% → 竖横竖竖横竖竖…
                wantPortrait = r >= 1 ? true : r <= 0 ? false : (mixCredit + r >= 1)
                idx = pool.firstIndex { Self.isPortrait($0) == wantPortrait! }
            } else {
                idx = 0
            }
            guard let i = idx else { break }
            let a = pool.remove(at: i)
            items.append(a)
            if let r = targetRatio, r > 0, r < 1 {
                mixCredit = (mixCredit + r - (Self.isPortrait(a) ? 1 : 0)).clamped(-1, 1)
            }
            n += 1
        }
        return n
    }

    /// 方向 / 比例变了：当前条之后的重新按比例排（当前这条不动，不打断播放）
    func remix(after index: Int?) {
        let keep = (index ?? -1) + 1
        guard keep <= items.count else { return }
        let upcoming = Array(items[keep...])
        items.removeSubrange(keep...)
        pool = upcoming + pool
        mixCredit = 0
        fill(max(upcoming.count, 6))
        trimPool()
    }

    /// 启动时把本地已缓存、没看过、又不在列表里的放到候选池最前（秒开）
    func seedPool(_ cached: [DYAweme]) {
        let have = Set(items.map(\.id)).union(pool.map(\.id))
        pool = cached.filter { !have.contains($0.id) } + pool
    }

    private func trimPool() {
        // 超上限先丢多出来的那一类里最早的（网页推荐横屏多，通常丢横屏）
        while pool.count > Self.poolCap {
            let wantPortrait = (targetRatio ?? 0.5) >= 0.5
            if let i = pool.firstIndex(where: { Self.isPortrait($0) != wantPortrait }) { pool.remove(at: i) }
            else { pool.removeFirst() }
        }
    }

    func loadMore(_ bridge: DouyinBridge) async {
        guard !loading, hasMore || items.isEmpty || !pool.isEmpty else { return }
        loading = true
        defer { loading = false }
        let want = 6
        var added = fill(want)
        do {
            var pages = 0
            while added < want && pages < 8 && (hasMore || items.isEmpty) {
                let r = try await bridge.fetchFeed()
                pages += 1
                let seen = Set(items.map(\.id)).union(pool.map(\.id))
                let fresh = r.items.filter { a in !seen.contains(a.id) && (a.play != nil || !a.images.isEmpty) }
                // 账号里已点赞/已收藏的，进页面就是选中态
                for a in fresh {
                    if a.userDigged == 1 { liked.insert(a.id) }
                    if a.isCollect == 1 { collected.insert(a.id) }
                }
                pool.append(contentsOf: fresh)
                hasMore = r.hasMore || !r.items.isEmpty
                added += fill(want - added)
                if targetRatio == nil { break }
            }
            // 比例凑不齐（例如竖屏太少）：不是「只看竖屏/只看横屏」就照原顺序补，别让列表断粮
            if added == 0, let r = targetRatio, r > 0, r < 1 { added += fill(want, relaxed: true) }
            trimPool()
            DYLiveModel.log("DDMIX added=\(added) pool=\(pool.count) ratio=\(targetRatio.map { String(format: "%.2f", $0) } ?? "free") wide=\(screenWide) recent=\(items.suffix(20).filter(Self.isPortrait).count)/\(min(20, items.count))")
            error = (items.isEmpty && added == 0) ? (targetRatio == 1 ? "暂时没刷到竖屏视频，可在「更多 → 竖屏占比」里调低或登录后再试" : "暂时没刷到推荐，登录后或稍后再试") : nil
        } catch {
            if items.isEmpty { self.error = error.localizedDescription }
        }
    }

    func reset() { items = []; hasMore = true; error = nil; pool = []; mixCredit = 0 }
}

struct DouyinFeedScreen: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var bridge = DouyinBridge()
    @StateObject private var feed = DYFeedModel()
    @State private var insets = EdgeInsets()
    @State private var preloader = DYPreloader()
    @State private var resume: [String: Double] = [:]
    @State private var currentID: String?
    @State private var scrollID: String?
    @State private var userScrolling = false
    @State private var dragStartID: String?
    @State private var scrollEndTask: Task<Void, Never>?
    @State private var initialized = false
    @State private var refreshing = false
    @State private var showComments = false
    @State private var web: DYWebTarget?
    @State private var tab: DYTab = ProcessInfo.processInfo.environment["DOUDUO_STARTLIVE"] == "1" ? .live : .recommend
    @StateObject private var live = DYLiveModel()
    @State private var showSearch = false
    @State private var lastFeedPull = Date.distantPast
    @AppStorage(DYVideoCache.countKey) private var cacheCount = DYVideoCache.defaultCount
    @AppStorage("douyin_danmaku_v1") private var danmakuOn = true
    @State private var showMine = false
    @State private var authorTarget: DYAweme.Author?
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage("douyin_autoplay_v1") private var autoNext = false
    @AppStorage("douyin_muted_v1") private var muted = false
    @State private var pendingUpdate: DDUpdate?
    @State private var showMessages = false
    @State private var noticeUnread = 0
    @State private var wideToken = UUID()

    private var currentIndex: Int? { currentID.flatMap { id in feed.items.firstIndex { $0.id == id } } }
    private var current: DYAweme? { currentIndex.map { feed.items[$0] } }

    var body: some View {
        ZStack(alignment: .top) {
            layoutRoot
            topBar
                .padding(.top, hSize == .regular ? 0 : -80)
                .frame(maxWidth: .infinity)
        }
        // 顶栏要从物理屏最上沿开始排（外屏/内屏都贴顶），所以整层忽略顶部安全区
        .ignoresSafeArea(edges: [.top, .horizontal])
        .background(DouyinBridgeHost(bridge: bridge).frame(width: 1, height: 1).allowsHitTesting(false))
        .task {
            guard !initialized else { return }
            initialized = true
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_SELFTEST"] == "1" { Task { await DDSelfTest.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_APITEST"] == "1" { Task { await DDApiProbe.run(bridge) } }
            #endif
            if tab == .live { return }   // 起手就是直播页（调试）时别把推荐流的播放器都拉起来
            // 秒开：先播上次缓存好、还没看过的；连接抖音 / 拉推荐在后台接着往后补
            if feed.items.isEmpty, let saved = DYFeedSession.load() {
                feed.items = saved.items
                resume = saved.positions
                currentID = saved.currentID
                scrollID = saved.currentID
                for a in saved.items {
                    if a.userDigged == 1 { feed.liked.insert(a.id) }
                    if a.isCollect == 1 { feed.collected.insert(a.id) }
                }
                DYLiveModel.log("DDSESSION 恢复 id=\(saved.currentID) t=\(saved.positions[saved.currentID] ?? 0)")
            }
            if feed.items.isEmpty {
                // 没有会话：本地缓存好、没看过的按竖横比例挑出来先播
                let cached = DYVideoCache.pendingSnapshot()
                if !cached.isEmpty {
                    feed.seedPool(cached)
                    feed.fill(6)
                    for a in cached {
                        if a.userDigged == 1 { feed.liked.insert(a.id) }
                        if a.isCollect == 1 { feed.collected.insert(a.id) }
                    }
                    currentID = feed.items.first?.id
                    DYLiveModel.log("DDCACHE 启动从缓存起播 n=\(feed.items.count)/\(cached.count)")
                }
            }
            feed.seedPool(DYVideoCache.pendingSnapshot())
            // 恢复的会话里「当前条之后」是上次的排法：按现在的方向 / 比例重排（当前这条不动）
            if currentIndex != nil { feed.remix(after: currentIndex) }
            await feed.loadMore(bridge)
            if currentID == nil { currentID = feed.items.first?.id }
            focusCurrent()
            #if DEBUG
            let env0 = ProcessInfo.processInfo.environment
            if let d = env0["DOUDUO_LIVEDELAY"], let sec = Double(d) {
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) { tab = .live }
            }
            let env = ProcessInfo.processInfo.environment
            if let o = env["DOUDUO_OPEN"] {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                switch o {
                case "search": showSearch = true
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
        .onChange(of: currentID) { old, new in
            // ⚠️ 宽屏（Duo 内屏）首次布局时 ScrollView 会把 scrollPosition 回写成 nil → 没有「当前条」→ 全部不播、上滑也不认。
            // 列表非空时把 nil 顶回上一个；刷新 / 重载会先清空列表再置 nil，不受影响。
            if new == nil, let old, feed.items.contains(where: { $0.id == old }) { currentID = old; return }
            scrollID = new
            focusCurrent()
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
        .onChange(of: feed.portraitRatio) { _, _ in remixUpcoming() }
        .onChange(of: feed.landscapeWhenWide) { _, _ in remixUpcoming() }
        .onDisappear { live.stop(); preloader.clear() }
        .fullScreenCover(item: $web, onDismiss: {
            // 网页里可能登录 / 过了验证：重开签名页，先重新读登录态，再刷推荐
            live.reset(); preloader.clear(); feed.reset(); currentID = nil; bridge.reload()
            Task {
                await feed.loadMore(bridge)
                currentID = feed.items.first?.id
                focusCurrent()
            }
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
            flatArrangement(geo)
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
        return w > h ? (w * 0.55 > h) : false
    }

    /// 当前条之后按新的方向/比例重排；不够就接着拉
    private func remixUpcoming() {
        guard tab == .recommend || !feed.items.isEmpty else { return }
        feed.remix(after: currentIndex)
        DYLiveModel.log("DDMIX remix wide=\(feed.screenWide) mode=\(feed.mixLabel) upcoming=\(feed.items.count - (currentIndex ?? -1) - 1)")
        if currentID == nil { currentID = feed.items.first?.id; scrollID = currentID }
        lastFeedPull = .distantPast
        focusCurrent()
    }

    /// 一套布局通吃所有状态，且**不换容器**（换容器会重建播放器 → 黑屏 / 重播）：
    /// - 平放/外屏：视频铺满；够宽时评论从右侧滑出（视频缩窄），窄屏走底部 sheet
    /// - 半折叠：视频自动缩到一多半，另一半常驻评论（宽>高→左右分；高>宽→上下分）
    private func flatArrangement(_ geo: GeometryProxy) -> some View {
        let fold = DYDuoMetrics.foldIsActive(geo)
        let wide = geo.size.width >= DYDuoMetrics.legacyWideMin
        let w = geo.size.width, h = geo.size.height
        let bookFold = fold && w > h          // 书本姿态：左右分
        let tableFold = fold && w <= h        // 桌面姿态：上下分
        let sideBySide = wide || bookFold
        let showPanel = fold || (showComments && sideBySide && tab == .recommend)

        let panelW = showPanel && sideBySide ? (bookFold ? w * 0.45 : min(380, w * 0.42)) : 0
        let panelH = tableFold ? h * 0.45 : 0
        let videoW = sideBySide && panelW > 0 ? w - panelW : w
        let videoH = tableFold ? h - panelH : h

        return ZStack(alignment: .topLeading) {
            feedArea
                .frame(width: videoW, height: videoH, alignment: .topLeading)
            if showPanel, let cur = current {
                DYCommentPanel(bridge: bridge, aweme: cur,
                               onClose: fold ? nil : { withAnimation(.snappy) { showComments = false } })
                    .frame(width: sideBySide ? panelW : w,
                           height: tableFold ? panelH : h)
                    .offset(x: sideBySide ? videoW : 0, y: tableFold ? videoH : 0)
                    .id(cur.id)
            }
        }
        .background(theme.media.strongScrim.color(for: scheme).ignoresSafeArea())
        .animation(.snappy, value: fold)
        .animation(.snappy, value: showComments)
        .sheet(isPresented: Binding(get: { showComments && !sideBySide && !fold }, set: { showComments = $0 })) {
            if let cur = current {
                DYCommentPanel(bridge: bridge, aweme: cur, onClose: { showComments = false })
                    .presentationDetents([.fraction(0.62), .large])
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

    private func focusCurrent() {
        guard !refreshing, let i = currentIndex else { return }
        preloader.update(feed.items, current: i)
        let curID = feed.items[i].id
        let ahead = Array(feed.items.dropFirst(i + 1))
        Task {
            await DYVideoCache.shared.markWatched(curID)
            // 整条下载晚 1.5 秒再排：让刚滑到的这条先把开头缓冲好；期间又滑走了就交给下一次
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard currentID == curID else { return }
            await DYVideoCache.shared.enqueue(ahead)
        }
        // 后面不足「缓存条数」就继续拉推荐（至少保证 6 条，节流 4 秒一次）
        let want = max(6, min(DYVideoCache.limit, 60))
        if feed.items.count - i - 1 < want, Date().timeIntervalSince(lastFeedPull) > 4 {
            lastFeedPull = Date()
            Task {
                await feed.loadMore(bridge)
                if let j = currentIndex {
                    preloader.update(feed.items, current: j)
                    await DYVideoCache.shared.enqueue(Array(feed.items.dropFirst(j + 1)))
                    if feed.items.count - j - 1 < want { focusCurrent() }
                }
            }
        }
    }

    @ViewBuilder
    private var feedArea: some View {
        ZStack(alignment: .top) {
            if tab == .live {
                DYLiveFeed(bridge: bridge, model: live, onWeb: { u in web = DYWebTarget(url: u) })
            } else if tab == .follow {
                DYFollowFeed(bridge: bridge, insets: insets, active: tab == .follow && web == nil && !showSearch && !showMine,
                             onAuthor: { a in authorTarget = a.author },
                             onLogin: { web = DYWebTarget(url: DouyinWeb.home) },
                             onToast: { showToast($0) })
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
            // UI 测试锚点：当前视频 id
            Text(currentID ?? "-").font(.caption2).opacity(0.01)
                .accessibilityIdentifier("douyin.currentID")
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
        .fullScreenCover(isPresented: $showSearch) {
            DYSearchScreen(bridge: bridge, onAuthor: { a in authorTarget = a.author })
        }
        .fullScreenCover(isPresented: $showMine) {
            DYMineScreen(bridge: bridge,
                         onLogin: { showMine = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { web = DYWebTarget(url: DouyinWeb.home) } },
                         onAuthor: { a in authorTarget = a.author },
                         onMessages: { showMine = false
                             DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showMessages = true } })
        }
        .sheet(item: $authorTarget) { a in
            DYAuthorScreen(bridge: bridge, author: a, onWeb: { u in web = DYWebTarget(url: u) })
                .presentationDetents([.medium, .large])
                .presentationBackground(.black)
        }

    }

    /// 顶部一排：左菜单，中间 关注/推荐/直播，右边 搜索 / 我的
    /// 顶栏：只留「关注 / 推荐 / 直播」三个纯文字页签，不用胶囊，与状态栏时间/信号同一行。
    private var topBar: some View {
        HStack(spacing: 22) {
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .themeShadow(.mediaLabel)
        .frame(maxWidth: .infinity, alignment: .center)
        // 外屏（compact）状态区更深：外屏时间约 85pt，内屏（regular）约 39pt
        // 注意用 size class 判断，不能用容器宽度——评论栏打开时视频区会变窄。
        .padding(.top, hSize == .regular ? 27 : 80)
    }

    private func topIcon(_ name: String, _ id: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: name)
                .font(.system(size: theme.typography.pointSize(.headline), weight: .semibold))
                .foregroundStyle(theme.media.onMedia.color(for: scheme))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// 顶栏「消息」。样式跟现有 topIcon，红暴液态按钮合并后会一起换。
    private var messageEntry: some View {
        topIcon("bell", "douyin.messages") { showMessages = true }
            .overlay(alignment: .topTrailing) {
                if noticeUnread > 0 {
                    Circle().fill(theme.status.danger.color(for: scheme))
                        .frame(width: 8, height: 8)
                        .offset(x: -6, y: 6)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("douyin.messages.badge")
                }
            }
    }

    /// 顶部「关注 / 推荐 / 直播」切换（抖音顶栏同款位置）
    private var tabSwitcher: some View {
        let fg = theme.media.onMedia.color(for: scheme)
        return HStack(spacing: 14) {
            ForEach(DYTab.allCases, id: \.self) { t in
                Button { selectTab(t) } label: {
                    VStack(spacing: 4) {
                        Text(t.title)
                            .font(.headline.weight(tab == t ? .bold : .medium))
                            .foregroundStyle(fg.opacity(tab == t ? 1 : 0.6))
                            .lineLimit(1)
                            .fixedSize()
                        Capsule().fill(fg).frame(width: 18, height: 3).opacity(tab == t ? 1 : 0)
                    }
                    .padding(.horizontal, 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
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
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(feed.items) { item in
                            page(for: item)
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrollID, anchor: .center)
                .onAppear { scrollID = currentID }
                .simultaneousGesture(DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if abs(value.translation.height) > abs(value.translation.width) {
                            if !userScrolling { dragStartID = currentID }
                            scrollEndTask?.cancel(); userScrolling = true
                        }
                    }
                    .onEnded { _ in
                        // 下拉不再触发刷新（顶部点击/轻扫会误判成刷新）；刷新走「更多 → 刷新推荐」。
                        dragStartID = nil
                        scrollEndTask = Task {
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            if !Task.isCancelled { userScrolling = false }
                        }
                    })
                .onChange(of: scrollID) { _, id in
                    guard let id, feed.items.contains(where: { $0.id == id }) else { return }
                    if userScrolling { currentID = id }
                    else if id != currentID { scrollID = currentID }
                }
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
            }
        }
    }

    /// 单页构造拆成独立函数：参数太多，写在 ForEach 里会让类型检查超时。
    private func page(for item: DYAweme) -> some View {
        let extras = AnyView(moreExtrasMenu(item))
        let active = item.id == currentID && web == nil && tab == .recommend && !showSearch && !showMine
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
                           onSearch: { showSearch = true },
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
    private func toggleLike(_ id: String, force: Bool?) {
        let has = feed.liked.contains(id)
        let want = force ?? !has
        guard want != has else { return }
        if want { feed.liked.insert(id) } else { feed.liked.remove(id) }
        Task {
            do {
                switch try await bridge.digg(id, like: want) {
                case .ok:
                    break
                case .notLoggedIn:
                    await MainActor.run {
                        if want { feed.liked.remove(id) } else { feed.liked.insert(id) }
                        showToast("抖音未登录：菜单 → 网页版 / 登录")
                    }
                case .failed(let why):
                    await MainActor.run {
                        if want { feed.liked.remove(id) } else { feed.liked.insert(id) }
                        showToast("点赞失败：\(why)")
                    }
                }
            } catch {
                #if DEBUG
                ddWrite("DDACT digg ERROR \(error)")
                #endif
                await MainActor.run {
                    if want { feed.liked.remove(id) } else { feed.liked.insert(id) }
                    showToast("点赞失败：\(error.localizedDescription)")
                }
            }
        }
    }

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
    private func toggleCollect(_ id: String) {
        let has = feed.collected.contains(id)
        let want = !has
        if want { feed.collected.insert(id) } else { feed.collected.remove(id) }
        Task {
            do {
                switch try await bridge.favorite(id, add: want) {
                case .ok:
                    await MainActor.run { showToast(want ? "已收藏" : "已取消收藏") }
                case .notLoggedIn:
                    await MainActor.run {
                        if want { feed.collected.remove(id) } else { feed.collected.insert(id) }
                        showToast("抖音未登录：菜单 → 网页版 / 登录")
                    }
                case .failed(let why):
                    await MainActor.run {
                        if want { feed.collected.remove(id) } else { feed.collected.insert(id) }
                        showToast("收藏失败：\(why)")
                    }
                }
            } catch {
                #if DEBUG
                ddWrite("DDACT fav ERROR \(error)")
                #endif
                await MainActor.run {
                    if want { feed.collected.remove(id) } else { feed.collected.insert(id) }
                    showToast("收藏失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func showToast(_ s: String) {
        feed.toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if feed.toast == s { feed.toast = nil }
        }
    }

    /// 「更多」后半段（推荐流注入）：播放偏好一组、常用入口一组、低频设置收进「设置」子菜单
    @ViewBuilder
    private func moreExtrasMenu(_ item: DYAweme) -> some View {
        Section("播放") {
            Picker(selection: $feed.portraitRatio) {
                Text("不限（网页原样）").tag(-1)
                Text("竖屏 30%").tag(30)
                Text("竖屏 50%").tag(50)
                Text("竖屏 70%").tag(70)
                Text("只看竖屏").tag(100)
            } label: {
                Label("竖屏占比", systemImage: "rectangle.portrait.on.rectangle.portrait")
                Text(feed.mixLabel)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("douyin.mix")
            Toggle(isOn: $autoNext) { Label("自动连播", systemImage: "play.square.stack") }
            Toggle(isOn: $muted) { Label("静音", systemImage: "speaker.slash") }
            Toggle(isOn: $danmakuOn) { Label("显示弹幕", systemImage: "text.bubble") }
        }
        Section {
            Button("刷新推荐", systemImage: "arrow.clockwise") {
                Task { await refreshRecommendations() }
            }
            .disabled(refreshing)
            Button { showMine = true } label: { Label("我的", systemImage: "person.crop.circle") }
                .accessibilityIdentifier("douyin.mine")
            Menu {
                Toggle(isOn: $feed.landscapeWhenWide) { Label("横着看时只放横屏", systemImage: "rectangle") }
                Toggle(isOn: $feed.autoFit) { Label("自动铺满宽度", systemImage: "arrow.up.left.and.arrow.down.right") }
                Picker(selection: $cacheCount) {
                    Text("关闭").tag(0)
                    Text("20 条").tag(20)
                    Text("50 条").tag(50)
                    Text("100 条").tag(100)
                } label: { Label("预缓存视频", systemImage: "arrow.down.circle") }
                .pickerStyle(.menu)
                Button("清除视频缓存", systemImage: "trash") {
                    Task {
                        let b = await DYVideoCache.shared.clear()
                        showToast("已清除 \(b / 1024 / 1024) MB")
                        focusCurrent()
                    }
                }
                Button("网页版 / 登录", systemImage: "safari") { web = DYWebTarget(url: DouyinWeb.home) }
                Button {
                    UIApplication.shared.open(DDUpdateChecker.repoURL)
                } label: {
                    Label("关于（GitHub 开源仓库）", systemImage: "info.circle")
                }
                .accessibilityIdentifier("douyin.about")
            } label: {
                Label("设置", systemImage: "gearshape")
            }
        }
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}

struct DYWebTarget: Identifiable { let id = UUID(); let url: URL }

enum DYTab: CaseIterable { case follow, recommend, live
    var title: String {
        switch self {
        case .follow: "关注"
        case .recommend: "推荐"
        case .live: "直播"
        }
    }
}

// MARK: - 直播

@MainActor
final class DYLiveModel: ObservableObject {
    @Published var rooms: [DYLiveRoom] = []
    @Published var currentID: String?
    @Published var error: String?
    @Published var loading = false
    /// 当前直播是否已出画面（首帧前显示「加载中」）
    @Published var ready = false
    /// ⚠️ 直播必须走 VLC：抖音直播 HLS 用 AVPlayer 只解析出音轨（tracks=1 types=soun），
    /// 表现就是「有声有封面、没有画面」。VLC 能正确拿到视频轨道。
    let vlc = VLCPlayerController()
    private var qualityOrder: [String] = []
    private var roomRef: DYLiveRoom?
    private var retryTask: DispatchWorkItem?
    private var sizeObs: AnyCancellable?

    /// 直播日志：Release 也要能用（ddWrite 只在 DEBUG 编译），排查真机「有声无画」靠它
    /// 以前每条都在主线程新建 DateFormatter + 同步开关文件，滑动 / 切房间时一次打好几条 → 掉帧；
    /// 而且 Release 里文件只增不减。现在丢到后台串行队列写，超过 2MB 只留后一半。
    nonisolated static func log(_ s: String) {
        let now = Date()
        DDLogWriter.queue.async { DDLogWriter.write(now, s) }
    }

    init() {
        sizeObs = vlc.$videoSize.receive(on: RunLoop.main).sink { [weak self] size in
            guard let self else { return }
            let r = (size.width > 0 && size.height > 0) || self.vlc.current > 0
            // 只允许 false → true：播过之后短暂的缓冲不要再弹「加载中」
            if r, !self.ready { self.ready = true }
            if r { DYLiveModel.log("DDLIVE 出画 size=\(size)") }
        }
    }

    func load(_ bridge: DouyinBridge, reset: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await bridge.fetchLive(reset: reset)
            if reset { rooms = [] }
            let seen = Set(rooms.map(\.id))
            rooms.append(contentsOf: r.filter { !seen.contains($0.id) })
            if currentID == nil { currentID = rooms.first?.id }
            error = rooms.isEmpty ? "暂时没有直播" : nil
        } catch {
            if rooms.isEmpty { self.error = error.localizedDescription }
        }
    }

    private var loadedRoom: String?

    func play(_ room: DYLiveRoom?) {
        // ⚠️ 别对 nil 停播：LazyVStack 布局/滚动会把 scrollPosition 回写成 nil
        guard let room else { return }
        // 只按房间去重：缓冲瞬间 isPlaying=videoSize 都会变，按它们判断会不断重开流 → 卡顿+反复「加载中」
        if loadedRoom == room.id, vlc.mediaPlayer.media != nil { return }
        loadedRoom = room.id
        roomRef = room
        // 画质从高到低排队：某个码流在这台机器/这个网络下起不来时自动降一档
        qualityOrder = ["FULL_HD1", "HD1", "SD1", "SD2"].filter { room.hls[$0] != nil }
        startCurrentQuality()
    }

    private func startCurrentQuality() {
        guard let room = roomRef else { return }
        retryTask?.cancel()
        guard let key = qualityOrder.first, let s = room.hls[key], let u = URL(string: s) else {
            if let u = room.bestHLS { start(u, key: "-") }
            return
        }
        start(u, key: key)
        let task = DispatchWorkItem { [weak self] in
            // 只要在走时间就算活着（VLC 对 HLS 常常不报 videoSize，别误判成没出画又重开，越重开越不出画）
            guard let self, self.vlc.videoSize == .zero, self.vlc.current < 1 else { return }
            DYLiveModel.log("DDLIVE retry quality=\(key) 没出画，降一档")
            if !self.qualityOrder.isEmpty { self.qualityOrder.removeFirst() }
            guard !self.qualityOrder.isEmpty else { return }
            self.startCurrentQuality()
        }
        retryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: task)
    }

    private var readyFallback: DispatchWorkItem?

    private func start(_ u: URL, key: String) {
        ready = false
        // VLC 有些流不回报 videoSize，4 秒后无论如何收起「加载中」，别一直转圈
        readyFallback?.cancel()
        let fb = DispatchWorkItem { [weak self] in self?.ready = true }
        readyFallback = fb
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: fb)
        vlc.stop()   // 换码流/换房间先停，避免旧画面残留
        vlc.play(url: u, headers: DYMedia.liveHeaders, cachingMs: 3000)   // 直播 3 秒缓存，抗网络抖动
        DYLiveModel.log("DDLIVEPLAY room=\(roomRef?.id ?? "-") q=\(key) url=\(u.absoluteString.prefix(70)) drawable=\(vlc.mediaPlayer.drawable != nil)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [self] in
            DYLiveModel.log("DDLIVESTATE state=\(vlc.mediaPlayer.state.rawValue) size=\(vlc.videoSize) cur=\(String(format: "%.1f", vlc.current))")
        }
    }

    func stop() {
        retryTask?.cancel()
        vlc.stop()
        loadedRoom = nil; ready = false
    }
    func reset() { stop(); rooms = []; currentID = nil; error = nil; loadedRoom = nil }
}

private struct DYLiveFeed: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let bridge: DouyinBridge
    @ObservedObject var model: DYLiveModel
    let onWeb: (URL) -> Void
    /// ⚠️ 不能直接 @StateObject DYLiveChat：热门直播间每秒都有新弹幕，owner 会跟着整页重算
    /// （ScrollView + VLC 渲染层 updateUIView 一起刷）→ 直播一顿一顿。包一层不发通知的盒子，
    /// 只让左下角聊天浮层自己订阅。
    @StateObject private var chatBox = DYLiveChatBox()
    private var chat: DYLiveChat { chatBox.chat }
    @State private var liveDraft = ""
    @State private var liveSending = false
    @State private var liveErr: String?
    @FocusState private var liveFocused: Bool
    @AppStorage("douyin_danmaku_v1") private var danmakuOn = true
    #if DEBUG
    @State private var tick = 0      // 0.5s 刷新一次，让调试进度文案跟着走（只在调试包里：Release 每 0.5s 整页重算会卡）
    #endif
    @State private var scrollID: String?
    @State private var userScrolling = false

    var body: some View {
        ZStack {
            #if DEBUG
            VStack {
                Text(model.currentID ?? "-").font(.caption2).opacity(0.01)
                    .accessibilityIdentifier("live.currentID")
                Text(String(format: "%.1f", model.vlc.current)).font(.caption2).opacity(0.01)
                    .accessibilityIdentifier("live.time")
                Text(String(format: "%.2f", model.vlc.isPlaying ? 1 : 0)).font(.caption2).opacity(0.01)
                    .accessibilityIdentifier("live.rate")
                Text("\(model.vlc.videoSize.width > 0 ? 1 : 0)").font(.caption2).opacity(0.01)
                    .accessibilityIdentifier("live.status")
                Text("\(Int(model.vlc.videoSize.width))x\(Int(model.vlc.videoSize.height))").font(.caption2).opacity(0.01)
                    .accessibilityIdentifier("live.err")
            }
            .allowsHitTesting(false)
            #endif
            if model.rooms.isEmpty {
                VStack(spacing: WuWeiDesign.Spacing.md) {
                    if let e = model.error {
                        Text(e).font(.footnote).foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                        Button("重试") { Task { await model.load(bridge, reset: true) } }.buttonStyle(.borderedProminent)
                    } else {
                        ProgressView().tint(theme.media.onMedia.color(for: scheme))
                        Text("加载直播…").font(.footnote).foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 上下滑翻直播间（抖音手感）。⚠️ 不能把 scrollPosition 直接绑到 currentID：
                // LazyVStack 追加内容/重排时系统会自己改写它，导致直播莫名其妙切房间（看着就是卡一下+加载中）。
                // 这里滚动位置单独存 scrollID，只有「手指在滑」时才同步给 currentID。
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rooms) { room in
                            DYLivePage(room: room, vlc: model.currentID == room.id ? model.vlc : nil,
                                       ready: model.ready, onWeb: onWeb,
                                       chat: (danmakuOn && model.currentID == room.id) ? chat : nil,
                                       chatInput: model.currentID == room.id ? AnyView(liveInput) : nil)
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(room.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrollID)
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in
                            if !userScrolling { DYLiveModel.log("DDLIVEOID 手势开始") }
                            userScrolling = true
                        }
                        .onEnded { _ in
                            // 分页动画/惯性要一会儿才落位，延迟复位
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { userScrolling = false }
                        }
                )
                .onChange(of: scrollID) { _, id in
                    guard let id else { return }
                    // 只接受「相邻」的房间切换（用户上下滑必然是相邻页）；
                    // 系统重排时把 scrollPosition 写到很远的房间 → 拉回当前房间，避免莫名其妙换直播间
                    let a = model.rooms.firstIndex { $0.id == id }
                    let b = model.rooms.firstIndex { $0.id == model.currentID }
                    let adjacent = a != nil && b != nil && abs(a! - b!) <= 1
                    if model.currentID != id, userScrolling || adjacent {
                        DYLiveModel.log("DDLIVEOID 切房间 \(model.currentID ?? "-") -> \(id) user=\(userScrolling)")
                        model.currentID = id
                    } else if id != model.currentID {
                        DYLiveModel.log("DDLIVEOID 忽略 \(model.currentID ?? "-") -> \(id) 并拉回")
                        scrollID = model.currentID
                    }
                }
                .onChange(of: model.currentID) { _, id in
                    if let id, scrollID != id { scrollID = id }
                }
            }
        }
        .task {
            if model.rooms.isEmpty { await model.load(bridge, reset: true) }
            #if DEBUG
            if let n = Int(ProcessInfo.processInfo.environment["DOUDUO_LIVEPICK"] ?? ""),
               let r = model.rooms.sorted(by: { (Int($0.viewers.filter(\.isNumber)) ?? 0) > (Int($1.viewers.filter(\.isNumber)) ?? 0) }).dropFirst(n).first {
                // 把热门间挪到第一个（程序跳页 ScrollView 不一定真滚过去）
                model.rooms.removeAll { $0.id == r.id }
                model.rooms.insert(r, at: 0)
                model.stop()
                model.currentID = r.id
                model.play(r)
                DYLiveModel.log("DDCHAT pick \(r.title) viewers=\(r.viewers)")
            }
            #endif
            model.play(model.rooms.first { $0.id == model.currentID })
        }
        .onChange(of: model.currentID) { old, id in
            DYLiveModel.log("DDLIVEID \(old ?? "-") -> \(id ?? "-") rooms=\(model.rooms.count)")
            if id == nil, let old, model.rooms.contains(where: { $0.id == old }) {
                model.currentID = old
                return
            }
            model.play(model.rooms.first { $0.id == id })
            if let id, let i = model.rooms.firstIndex(where: { $0.id == id }), i >= model.rooms.count - 3 {
                Task { await model.load(bridge) }
            }
        }
        .onDisappear { model.stop(); chat.close() }
        .background(DYLiveChatHost(chat: chat).frame(width: 1, height: 1).allowsHitTesting(false))
        .onChange(of: model.currentID) { _, id in openChat(id) }
        .onChange(of: danmakuOn) { _, on in if on { openChat(model.currentID) } else { chat.close() } }
        .onAppear { openChat(model.currentID) }
        #if DEBUG
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in tick += 1 }
        #endif
    }
}

extension DYLiveFeed {
    fileprivate var liveInput: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let e = liveErr { Text(e).font(.caption2).foregroundStyle(.orange) }
            HStack(spacing: 8) {
                TextField("", text: $liveDraft, prompt: Text("说点什么…").foregroundStyle(.white.opacity(0.5)))
                    .foregroundStyle(.white)
                    .focused($liveFocused)
                    .submitLabel(.send)
                    .onSubmit { sendLive() }
                    .padding(.horizontal, 14).frame(height: 38)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .accessibilityIdentifier("live.chat.input")
                if !liveDraft.isEmpty {
                    Button(action: sendLive) {
                        if liveSending { ProgressView().tint(.white) } else { Text("发送").font(.subheadline.weight(.semibold)) }
                    }
                    .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 38)
                    .background(Capsule().fill(Color(red: 1.0, green: 0.17, blue: 0.33)))
                    .accessibilityIdentifier("live.chat.send")
                }
            }
        }
    }

    fileprivate func sendLive() {
        let text = liveDraft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !liveSending else { return }
        liveSending = true
        Task {
            if let err = await chat.send(text) { liveErr = err } else { liveDraft = ""; liveErr = nil; liveFocused = false }
            liveSending = false
        }
    }

    fileprivate func openChat(_ id: String?) {
        guard danmakuOn, let id, let r = model.rooms.first(where: { $0.id == id }) else { return }
        chat.open(r.webRid)
    }
}

private struct DYLivePage: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let room: DYLiveRoom
    let vlc: VLCPlayerController?
    let ready: Bool
    let onWeb: (URL) -> Void
    /// 只有当前房间且开了弹幕才传；浮层自己订阅消息，新消息不会让整页（含 VLC 画面）重算
    var chat: DYLiveChat? = nil
    var chatInput: AnyView? = nil

    var body: some View {
        GeometryReader { geo in
            let fg = theme.media.onMedia.color(for: scheme)
            let fill = room.portrait && geo.size.height > geo.size.width * 1.2
            ZStack(alignment: .bottomLeading) {
                if let c = room.cover, let u = URL(string: c) {
                    CachedAsyncImage(url: u) { img in img.resizable().aspectRatio(contentMode: fill ? .fill : .fit) } placeholder: { Color.clear }
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                }
                if let vlc {
                    VLCPlayerSurface(controller: vlc, fillWidth: fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                if vlc != nil, !ready {
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("直播加载中…").font(.caption).foregroundStyle(.white.opacity(0.85))
                    }
                    .allowsHitTesting(false)
                }
                LinearGradient(colors: [.clear, theme.media.strongScrim.color(for: scheme).opacity(0.5)],
                               startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 8) {
                    if let chat { DYLiveChatLiveOverlay(chat: chat) }
                    HStack(spacing: 8) {
                        CachedAsyncImage(url: room.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                            placeholder: { theme.media.chromeFill.color(for: scheme) }
                            .frame(width: 36, height: 36).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(room.owner).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if !room.viewers.isEmpty { Text("\(room.viewers) 在看").font(.caption2) }
                        }
                        Text("直播中").font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(theme.status.danger.color(for: scheme)))
                    }
                    if !room.title.isEmpty { Text(room.title).font(.subheadline).lineLimit(2) }
                    if let chatInput { chatInput.frame(maxWidth: 320) }
                    Button { onWeb(room.webURL) } label: {
                        Label("进直播间（礼物）", systemImage: "gift")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(theme.media.chromeFill.color(for: scheme)))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(fg)
                .themeShadow(.mediaLabel)
                .padding(.horizontal, 14)
                .padding(.bottom, max(geo.safeAreaInsets.bottom, 10) + 18)
            }
        }
    }
}

// MARK: - 单页

struct DYVideoPage: View {
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
    @AppStorage("douyin_autoplay_v1") private var autoNext = false
    @State private var heart = false
    /// 右侧按钮栏右边距：外屏按摄像头预留区域算（中线对齐状态栏那一列），读不到用默认值
    @State private var railTrailing: CGFloat = DYDuoMetrics.railDefaultTrailing
    @State private var descExpanded = false
    @State private var danmaku: [DYDanmaku] = []
    @State private var danmakuLoaded = false
    @State private var saving = false
    @State private var followedNow: Bool?
    @State private var followBusy = false
    @State private var showDanmakuInput = false
    @State private var danmakuDraft = ""
    @State private var danmakuSending = false
    @FocusState private var danmakuFocused: Bool
    @AppStorage("douyin_autofit_v1") private var autoFit = true
    @AppStorage("douyin_danmaku_v1") private var danmakuOn = true

    init(item: DYAweme, isCurrent: Bool, insets: EdgeInsets, resume: Double?, liked: Bool, collected: Bool,
         onLike: @escaping () -> Void, onCollect: @escaping () -> Void, onDoubleTap: @escaping () -> Void,
         onComments: @escaping () -> Void, onSearch: @escaping () -> Void, onAuthor: @escaping () -> Void, onSavePosition: @escaping (Double) -> Void,
         preloader: DYPreloader, bridge: DouyinBridge? = nil, onToast: ((String) -> Void)? = nil,
         onDislike: (() -> Void)? = nil, moreExtras: AnyView = AnyView(EmptyView()),
         onEnded: (() -> Void)? = nil) {
        self.item = item; self.isCurrent = isCurrent; self.insets = insets; self.resume = resume
        self.liked = liked; self.collected = collected
        self.onLike = onLike; self.onCollect = onCollect; self.onDoubleTap = onDoubleTap
        self.onComments = onComments; self.onSearch = onSearch; self.onAuthor = onAuthor; self.onSavePosition = onSavePosition
        self.preloader = preloader; self.bridge = bridge; self.onToast = onToast
        self.onDislike = onDislike
        self.moreExtras = moreExtras
        self.onEnded = onEnded
    }

    var body: some View {
        let fg = theme.media.onMedia.color(for: scheme)
        ZStack(alignment: .bottomLeading) {
            if item.images.isEmpty, let s = item.play, let remote = URL(string: s) {
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
                                    videoAspect: item.height > 0 ? item.width / item.height : 0)
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

            // 文案 / 右侧按钮栏压在播放器底部进度条上方（进度条 + 拖动条约 70pt）
            HStack(alignment: .bottom, spacing: 12) {
                // 作者头像 / 名字 / 关注 / 文案整体下移，少压画面（横屏视频下沿常被挡）；
                // 右侧按钮栏不动。下移后离进度条拖动区（约 36pt）仍留空，不抢拖进度
                info(fg)
                    .offset(y: item.images.isEmpty ? Self.infoDrop : 0)
                Spacer(minLength: 0)
                actions(fg)
                    .modifier(DYRailReservedNudge())
            }
            // 苹果 iPhone Duo 规范：
            // · 左下信息是前景控件 → 放在安全区内，左右分开算（不假设两边一样）。外屏倒拿 / 分屏在左半边时，
            //   系统那一列（摄像头、状态栏）跑到左侧，信息块自动让开
            // · 右侧按钮栏和摄像头、状态栏同一列（HIG：外屏摄像头与侧边控件垂直对齐）→ 中线对齐摄像头预留区域
            .padding(.leading, insets.leading + 12)
            .padding(.trailing, railTrailing)
            .padding(.bottom, max(insets.bottom, 18) + (item.images.isEmpty ? 92 : 24))   // 让开底部时间 + 进度条 + 拖动区
        }
        .overlay(alignment: .bottom) {
            if showDanmakuInput { danmakuBar.padding(.bottom, max(insets.bottom, 12) + 6) }
        }
        .animation(.snappy, value: heart)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: DYRailTrailingPref.self, value: DYDuoMetrics.railTrailing(proxy, safeTrailing: insets.trailing))
            }
        }
        .onPreferenceChange(DYRailTrailingPref.self) { v in
            if abs(v - railTrailing) > 0.5 { railTrailing = v }
        }
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
    /// 视频页左下信息块相对按钮栏往下挪的距离
    static let infoDrop: CGFloat = 48

    private func info(_ fg: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: onAuthor) {
                    HStack(spacing: 8) {
                        CachedAsyncImage(url: item.author.avatar.flatMap(URL.init(string:))) { img in
                            img.resizable().scaledToFill()
                        } placeholder: { theme.media.chromeFill.color(for: scheme) }
                        .frame(width: 34, height: 34)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(fg.opacity(0.9), lineWidth: 1))
                        Text(item.author.name).font(.subheadline.weight(.semibold)).foregroundStyle(fg).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.author")
                if bridge != nil, item.author.uid != nil, !((followedNow ?? ((item.author.follow ?? 0) > 0))) {
                    Button { toggleFollow() } label: {
                        Group {
                            if followBusy { ProgressView().controlSize(.mini).tint(fg) }
                            else { Text("关注").font(.footnote.weight(.semibold)) }
                        }
                        .foregroundStyle(fg)
                        .frame(minWidth: 58).frame(height: 30)
                        .padding(.horizontal, 6)
                        .contentShape(Capsule())
                        .background(Capsule().fill(theme.accent.color(for: scheme)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("douyin.follow")
                }
            }
            if !item.desc.isEmpty {
                Text(item.desc)
                    .font(.subheadline)
                    .foregroundStyle(fg)
                    .lineLimit(descExpanded ? 8 : 2)
                    .onTapGesture { descExpanded.toggle() }
            }
            if !item.music.isEmpty {
                Label(item.music, systemImage: "music.note")
                    .font(.caption).lineLimit(1)
                    .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
            }
        }
        .themeShadow(.mediaLabel)
    }

    /// 只在用户点「关注」时发请求
    private func toggleFollow() {
        guard let b = bridge, let uid = item.author.uid, !followBusy else { return }
        followBusy = true
        Task {
            do {
                switch try await b.followUser(uid, follow: true) {
                case .ok: followedNow = true; onToast?("已关注")
                case .notLoggedIn: onToast?("抖音未登录")
                case .failed(let why): onToast?("关注失败：\(why)")
                }
            } catch { onToast?("关注失败：\(error.localizedDescription)") }
            followBusy = false
        }
    }

    /// 小红书式右侧栏：一根竖向液态玻璃胶囊（赞 / 收藏 / 评论，数字在图标下），下方单独一颗「更多」圆按钮
    private func actions(_ fg: Color) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 14) {
                railItem(liked ? "heart.fill" : "heart", DYFormat.count(item.stats.digg + (liked ? 1 : 0)),
                         tint: liked ? theme.status.danger.color(for: scheme) : fg, "douyin.like", onLike)
                railItem(collected ? "star.fill" : "star", DYFormat.count(item.stats.collect + (collected ? 1 : 0)),
                         tint: collected ? theme.status.warning.color(for: scheme) : fg, "douyin.collect", onCollect)
                railItem("ellipsis.bubble", DYFormat.count(item.stats.comment), tint: fg, "douyin.comments", onComments)
                railItem("magnifyingglass", "", tint: fg, "douyin.search", onSearch)
            }
            .padding(.vertical, 14)
            .frame(width: 54)
            .ddGlassCapsule()
            moreMenu(fg)
        }
        .themeShadow(.mediaLabel)
    }

    private func railItem(_ icon: String, _ text: String, tint: Color, _ id: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 22, weight: .regular)).foregroundStyle(tint)
                    .frame(height: 26)
                if !text.isEmpty {
                    Text(text).font(.caption2.weight(.medium)).monospacedDigit()
                        .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(width: 54, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// 「更多」：顶部一排图标（转发 / 下载 / 发弹幕）→ 不感兴趣 → 推荐流注入的播放偏好与设置
    @ViewBuilder
    private func moreMenu(_ fg: Color) -> some View {
        Menu {
            ControlGroup {
                ShareLink(item: item.webURL) {
                    Label("转发", systemImage: "arrowshape.turn.up.right")
                }
                Button {
                    save()
                } label: {
                    Label(saving ? "保存中…" : "下载", systemImage: "arrow.down.to.line")
                }
                .disabled(saving)
                .accessibilityIdentifier("douyin.save")
                if item.images.isEmpty, bridge != nil {
                    Button {
                        showDanmakuInput = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { danmakuFocused = true }
                    } label: {
                        Label("发弹幕", systemImage: "text.bubble")
                    }
                    .accessibilityIdentifier("douyin.danmaku.open")
                }
            }
            if let onDislike {
                Button("不感兴趣", systemImage: "hand.thumbsdown", role: .destructive) { onDislike() }
                    .accessibilityIdentifier("douyin.dislike")
            }
            moreExtras
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(fg)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
                .ddGlassCircle()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityIdentifier("douyin.more")
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
    let bridge: DouyinBridge
    let aweme: DYAweme
    let onClose: (() -> Void)?
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
    @State private var sending = false
    @State private var sendErr: String?
    @State private var digged: Set<String> = []
    @State private var diggShown: [String: Int] = [:]
    @FocusState private var inputFocused: Bool

    init(bridge: DouyinBridge, aweme: DYAweme, onClose: (() -> Void)?) {
        self.bridge = bridge; self.aweme = aweme; self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(total > 0 ? "\(DYFormat.count(total)) 条评论" : "评论").font(.subheadline.weight(.semibold))
                Spacer()
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark").font(.subheadline.weight(.semibold)) }
                        .buttonStyle(.plain)
                }
            }
            .foregroundStyle(.themeTextPrimary)
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(items) { c in
                        VStack(alignment: .leading, spacing: 10) {
                            row(c)
                            if c.replies > 0 { replyBlock(c) }
                        }
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
            Divider()
            inputBar
        }
        .background(GlassBackground())
        .modifier(DYRailReservedNudge())
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let r = replyTo {
                HStack {
                    Text("回复 @\(r.name)").font(.caption).foregroundStyle(.themeTextSecondary).lineLimit(1)
                    Spacer()
                    Button { replyTo = nil } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.themeTextSecondary)
                }
            }
            if let e = sendErr {
                Text(e).font(.caption2).foregroundStyle(theme.status.danger.color(for: scheme))
            }
            HStack(spacing: 8) {
                TextField(replyTo == nil ? "说点什么…" : "回复 \(replyTo!.name)", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
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
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        do {
            let c = try await bridge.publishComment(aweme.id, text: text, replyID: replyTo?.id)
            if let parent = replyTo {
                replies[parent.id, default: []].insert(c, at: 0)
            } else {
                items.insert(c, at: 0)
                total += 1
            }
            draft = ""; replyTo = nil; sendErr = nil
            inputFocused = false
        } catch {
            sendErr = "发送失败：\(error.localizedDescription)"
        }
    }

    private func row(_ c: DYComment) -> some View {
        rowBody(c)
            .contentShape(Rectangle())
            .onTapGesture { replyTo = c; inputFocused = true }
    }

    private func rowBody(_ c: DYComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CachedAsyncImage(url: c.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                placeholder: { Color.primary.opacity(0.08) }
                .frame(width: 32, height: 32).clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(c.name).font(.caption.weight(.semibold)).foregroundStyle(.themeTextSecondary)
                Text(c.text).font(.subheadline).foregroundStyle(.themeTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
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
            ForEach(got) { r in row(r) }
            if replyErr[c.id] != nil {
                Button { replyErr[c.id] = nil; Task { await loadReplies(c) } } label: {
                    Text("回复加载失败，点此重试").font(.caption).foregroundStyle(.themeTextSecondary)
                }
                .buttonStyle(.plain)
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
                .accessibilityIdentifier("douyin.replies")
            }
        }
        .padding(.leading, 42)
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
            let r = try await bridge.fetchComments(aweme.id, cursor: cursor)
            let seen = Set(items.map(\.id))
            items.append(contentsOf: r.items.filter { !seen.contains($0.id) })
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

/// DYLiveModel.log 的后台写入器（只在 queue 上访问）
enum DDLogWriter {
    static let queue = DispatchQueue(label: "douduo.log", qos: .utility)
    private static let maxBytes: UInt64 = 2 * 1024 * 1024
    private static let formatter: DateFormatter = {
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"; return df
    }()
    private static let url: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
        .appendingPathComponent("ddlog.txt")
    private static var handle: FileHandle?

    static func write(_ date: Date, _ s: String) {
        guard let url else { return }
        let line = Data((formatter.string(from: date) + " " + s + "\n").utf8)
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
        }
        guard let h = handle else { return }
        let end = (try? h.seekToEnd()) ?? 0
        if end > maxBytes {
            // 只留后一半（最近的日志）
            try? h.close(); handle = nil
            if let data = try? Data(contentsOf: url) {
                try? data.suffix(data.count / 2).write(to: url, options: .atomic)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: line)
    }
}
