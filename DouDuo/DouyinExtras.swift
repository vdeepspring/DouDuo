// DouDuo 扩展功能：搜索 / 我的（喜欢·收藏·历史·稍后再看）/ 关注 / 作者主页 / 弹幕 / 楼中楼 / 保存到相册
// 全部接口都走隐藏签名页（DouyinBridge.call），和推荐流同一套签名，不逆向。
import SwiftUI
import Combine
import AVFoundation
import Photos

// MARK: - 数据

extension DYAweme.Author: Identifiable { public var id: String { secUid ?? name } }

struct DYDanmaku: Identifiable, Decodable, Equatable {
    let id: String
    let text: String
    let offset: Double      // 秒
}
extension DYDanmaku {
    /// 合并分窗拉到的弹幕：按 id 去重，按时间排序
    static func merged(_ a: [DYDanmaku], _ b: [DYDanmaku]) -> [DYDanmaku] {
        var seen = Set<String>()
        var out: [DYDanmaku] = []
        for d in a + b where seen.insert(d.id).inserted { out.append(d) }
        return out.sorted { $0.offset < $1.offset }
    }
}


struct DYUser: Decodable, Equatable {
    let name: String
    let avatar: String?
    let signature: String
    let secUid: String
    let uid: String
    let followers: Int
    let following: Int
    let likes: Int
    let works: Int
    let ip: String?
    /// 仅「我的」页使用。作者页不读取，避免把别人的封面画进当前资料卡。
    let cover: String?
}

/// 评论表情（抖音官方表情包）
struct DYEmoji: Codable, Identifiable, Hashable {
    var id: String { displayName }
    let displayName: String      // 形如 [微笑]，发送时就发这个文本
    let url: String?             // CDN 图片（签名长期有效）
}
private struct DYEmojiResp: Decodable { let status: Int; let items: [DYEmoji] }

/// @ 面板里的人（关注的人）
struct DYFriend: Codable, Identifiable, Hashable {
    var id: String { secUid.isEmpty ? name : secUid }
    let name: String
    let avatar: String?
    let secUid: String
}
private struct DYFriendPage: Decodable { let status: Int; let items: [DYFriend]; let cursor: String; let hasMore: Bool }

/// 抖音热搜一条：pos 为空 = 置顶条
struct DYHot: Identifiable, Decodable, Equatable {
    var id: String { "\(pos ?? 0):\(word)" }
    let word: String
    let hot: Int
    let pos: Int?
}

struct DYSug: Identifiable, Decodable, Equatable {
    var id: String { word }
    let word: String
}

enum DYListKind: String, CaseIterable, Identifiable {
    case post, like, collect, history, later
    var id: String { rawValue }
    var title: String {
        switch self {
        case .post: "作品"
        case .like: "喜欢"
        case .collect: "收藏"
        case .history: "历史"
        case .later: "稍后再看"
        }
    }
}

private struct DYListPage: Decodable { let status: Int; let items: [DYAweme]; let cursor: String; let hasMore: Bool; let code: Int?; let msg: String? }
private struct DYDanmakuPage: Decodable { let status: Int; let items: [DYDanmaku] }

private struct DYReplyPage: Decodable { let status: Int; let items: [DYComment]; let cursor: Int; let hasMore: Bool; let msg: String? }
/// 一次性结束标记（firstWithin 用：结果和超时谁先到算谁）
@MainActor final class DYOnceFlag { var done = false; init() {} }

private struct DYPublishResp: Decodable { let status: Int; let code: Int?; let msg: String?; let comment: DYComment?; let danmakuID: String?; let diagnostic: String?; var verify: String? = nil }
private struct DYUserResp: Decodable { let status: Int; let user: DYUser?; let msg: String? }
private struct DYSugResp: Decodable { let status: Int; let items: [DYSug] }

// MARK: - 接口

extension DouyinBridge {
    /// 列表通用：喜欢 / 收藏 / 历史 / 稍后再看 / 关注 / 搜索，统一回 (items, cursor, hasMore)
    private func list(_ js: String, _ args: [String: Any]) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        let d = try await call(js, args: args)
        let p = try JSONDecoder().decode(DYListPage.self, from: d)
        if p.code == 8 || p.code == 2483 || (p.msg ?? "").contains("未登录") || (p.msg ?? "").contains("请先登录") {
            throw DYError.bad("抖音未登录：请在「我的」中登录后重试")
        }
        if js == Self.searchJS, p.status < 0 {
            throw DYError.bad(p.status == -2 || p.status == -3 ? "搜索请求超时，请稍后重试" : "搜索连接失败，请稍后重试")
        }
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        if js == Self.searchJS, let code = p.code, code != 0 {
            let message = p.msg.flatMap { $0.isEmpty ? nil : $0 } ?? "搜索暂不可用（\(code)）"
            throw DYError.bad(message)
        }
        return (p.items, p.cursor, p.hasMore)
    }

    func selfSecUid() async throws -> String {
        if let s = selfSecCache { return s }
        let u = try await selfProfile()
        selfSecCache = u.secUid
        return u.secUid
    }

    func selfProfile() async throws -> DYUser {
        let d = try await call(Self.selfJS, args: [:])
        let r = try JSONDecoder().decode(DYUserResp.self, from: d)
        guard let u = r.user, !u.secUid.isEmpty else { throw DYError.bad(r.msg ?? "抖音未登录") }
        return u
    }

    func userProfile(_ sec: String) async throws -> DYUser {
        let d = try await call(Self.otherJS, args: ["sec": sec])
        let r = try JSONDecoder().decode(DYUserResp.self, from: d)
        guard let u = r.user else { throw DYError.bad(r.msg ?? "读取作者信息失败") }
        return u
    }

    func myList(_ kind: DYListKind, cursor: String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        switch kind {
        case .post:
            let sec = try await selfSecUid()
            return try await list(Self.postJS, ["sec": sec, "cursor": cursor])
        case .like:
            let sec = try await selfSecUid()
            return try await list(Self.likeJS, ["sec": sec, "cursor": cursor])
        case .collect: return try await list(Self.collectJS, ["cursor": cursor])
        case .history: return try await list(Self.historyJS, ["cursor": cursor])
        case .later: return try await list(Self.laterJS, ["cursor": cursor])
        }
    }

    func followFeed(cursor: String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        // 未登录时抖音的关注流接口不报错，会塞推荐内容（游客兜底）。
        // 必须先确认登录态，否则「关注」页会显示一堆不是关注的人。
        if cursor == "0" { _ = try await selfProfile() }
        let r = try await list(Self.followJS, ["cursor": cursor])
        #if DEBUG
        if cursor == "0" {
            let me = try? await selfProfile()
            let who = me.map { "\($0.name)(关注\($0.following)/粉丝\($0.followers))" } ?? "未登录"
            let names = r.items.prefix(6).map { "\($0.author.name)[f\($0.author.follow ?? -1)]" }.joined(separator: " | ")
            DYLiveModel.log("DDFOLLOW me=\(who) n=\(r.items.count) more=\(r.hasMore) cur=\(r.cursor) first=\(names)")
        }
        #endif
        return r
    }

    /// 评论表情列表（抖音官方表情包，214 个；displayName 形如 [微笑]，发送时就发这个文本）
    func emojiList() async -> [DYEmoji] {
        guard let d = try? await call(Self.emojiJS, args: [:], attempts: 2),
              let r = try? JSONDecoder().decode(DYEmojiResp.self, from: d) else { return [] }
        let items = r.items.filter { !$0.displayName.isEmpty }
        #if DEBUG
        DYLiveModel.log("DDEMOJI status=\(r.status) n=\(items.count) hasUrl=\(items.filter { $0.url != nil }.count)")
        #endif
        return items
    }

    /// @ 面板的人：抖音评论 @ 的专用接口 familiar/atlist（返回「朋友」：互关/最近互动）
    func followingUsers(cursor: String = "0") async throws -> (items: [DYFriend], cursor: String, hasMore: Bool) {
        let d = try await call(Self.atListJS, args: ["cursor": cursor], attempts: 2)
        let p = try JSONDecoder().decode(DYFriendPage.self, from: d)
        #if DEBUG
        DYLiveModel.log("DDFOLLOWING status=\(p.status) n=\(p.items.count) more=\(p.hasMore) first=\(p.items.prefix(3).map(\.name).joined(separator: ","))")
        #endif
        if p.status != 200 { throw DYError.blocked("HTTP \(p.status)") }
        return (p.items, p.cursor, p.hasMore)
    }

    /// 搜索：网页接口只给第一页（翻第二页安全 SDK 直接压住不返回，换参数 / search_id 都一样）
    /// → 只拉一次、hasMore 置 false，免得底部一直转圈或报「拦截」
    func search(_ kw: String, offset: String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool) {
        guard offset == "0" else { return ([], offset, false) }
        let r = try await list(Self.searchJS, ["kw": kw, "cursor": "0"])
        return (r.items, r.cursor, false)
    }

    /// 抖音热搜
    func hotSearch() async -> [DYHot] {
        guard let d = try? await call(Self.hotJS, args: [:], attempts: 1) else { return [] }
        return (try? JSONDecoder().decode([DYHot].self, from: d)) ?? []
    }

    func suggest(_ kw: String) async -> [DYSug] {
        guard let d = try? await call(Self.sugJS, args: ["kw": kw], attempts: 1),
              let r = try? JSONDecoder().decode(DYSugResp.self, from: d) else { return [] }
        return r.items
    }

    func danmaku(_ id: String, durationMs: Int) async throws -> [DYDanmaku] {
        let d = try await call(Self.danmakuJS, args: ["id": id, "dur": String(max(durationMs, 15000))], attempts: 1)
        let r = try JSONDecoder().decode(DYDanmakuPage.self, from: d)
        return r.items.sorted { $0.offset < $1.offset }
    }

    /// 指定时间窗拉弹幕（毫秒）。
    func danmakuWindow(_ id: String, startMs: Int, endMs: Int, durationMs: Int) async throws -> [DYDanmaku] {
        let d = try await call(Self.danmakuWindowJS,
                               args: ["id": id, "from": String(startMs), "to": String(endMs), "dur": String(durationMs)],
                               attempts: 1)
        let r = try JSONDecoder().decode(DYDanmakuPage.self, from: d)
        return r.items.sorted { $0.offset < $1.offset }
    }

    /// 弹幕分窗拉取：接口单次请求只返回约 30 秒（实测传更长会被截断）。
    /// 所以按 30 秒一窗、并根据「上一次实际返回的最后一条时间」继续，保证时间轴连续覆盖，
    /// 不会出现「每 60 秒只补前 30 秒」那种一段一段的空档。
    func danmakuStream(_ id: String, durationMs: Int) -> AsyncStream<[DYDanmaku]> {
        AsyncStream { continuation in
            let task = Task {
                let total = max(durationMs, 15_000)
                let windowMs = 30_000
                var seen = Set<String>()
                var startMs = 0
                var rounds = 0
                while startMs < total, rounds < 40 {
                    if Task.isCancelled { break }
                    let endMs = min(startMs + windowMs, total)
                    do {
                        let chunk = try await self.danmakuWindow(id, startMs: startMs, endMs: endMs, durationMs: total)
                        let fresh = chunk.filter { seen.insert($0.id).inserted }
                        if !fresh.isEmpty { continuation.yield(fresh) }
                        if chunk.isEmpty {
                            startMs = endMs                                  // 整段没弹幕，直接跳到下一段
                        } else {
                            let maxMs = Int((chunk.map(\.offset).max() ?? 0) * 1000)
                            // 从实际覆盖到的地方继续；至少前进 5 秒，避免原地打转
                            startMs = max(startMs + 5_000, min(endMs, maxMs + 500))
                        }
                    } catch {
                        break
                    }
                    rounds += 1
                    // 控制请求节奏：既不给服务端压力，也让后面的段落在观看过程中陆续补齐
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }



    /// 返回 nil = 网页评论框这一步没把评论发出去（确定没发），可以退回接口方式；
    /// 只要点过发送且结果不明，就抛「未确认」，绝不再用别的方式补发，免得重复评论。
    private func publishViaWebUI(_ awemeID: String, text: String, replyID: String?, replyToReplyID: String?, op: String) async throws -> DYComment? {
        let target = replyToReplyID ?? replyID
        DYLiveModel.log("DDSEND comment op=\(op) phase=web-ui-submit reply=\(replyID == nil ? 0 : 1)/\(replyToReplyID == nil ? 0 : 1)")
        let o: DYWebComposer.Outcome
        do { o = try await DYWebComposer.shared.publish(awemeID: awemeID, text: text, top: replyID, replyTo: target, host: web.superview) }
        catch {
            DYLiveModel.log("DDSEND comment op=\(op) phase=web-ui-error")
            return nil
        }
        DYLiveModel.log("DDSEND comment op=\(op) phase=web-ui-\(o.state) stage=\(o.stage ?? "-") status=\(o.status.map(String.init) ?? "nil") code=\(o.code.map(String.init) ?? "nil") diag=\(o.diagnostic ?? "-")")
        switch o.state {
        case "sent":
            if let c = o.comment, Self.isServerCommentID(c.id) { return c }
            throw DYCommentUnconfirmed(message: "抖音回了成功但没给评论编号；先刷新评论区核对")
        case "blocked":
            // 与接口方式一致：403 后服务端常常同时作废登录，交给恢复页核验
            throw DYLoginExpired()
        case "rejected":
            if o.code == 8 { throw DYLoginExpired() }
            throw DYError.bad(o.msg?.isEmpty == false ? o.msg! : "评论被拒绝（\(o.code ?? -1)），草稿已保留")
        case "unconfirmed":
            // 已点发送但回执读不到：和接口方式一样，限时回评论区找自己刚发的这条
            let identity = try? await selfProfile()
            if let mine = await Self.firstWithin(Self.reconcileTimeout, { [weak self] in
                await self?.findMySentComment(awemeID, text: text, replyID: replyID, replyToReplyID: replyToReplyID,
                                              imageSentAt: Date().timeIntervalSince1970 - 30, identity: identity, hasImage: false)
            }) {
                DYLiveModel.log("DDSEND comment op=\(op) phase=web-ui-verified")
                return mine
            }
            DYLiveModel.log("DDSEND comment op=\(op) phase=web-ui-reconcile-miss")
            throw DYCommentUnconfirmed(message: o.msg ?? "结果未确认，可能已发出；先刷新评论区核对")
        case "logged-out":
            throw DYLoginExpired()
        case "busy":
            throw DYError.bad("上一条评论还在发送，稍等再发；草稿已保留")
        default:
            // not-ready / not-found / compose-error / not-sent：确定没有发出请求
            return nil
        }
    }

    func fetchReplies(_ id: String, commentID: String, cursor: Int) async throws -> (items: [DYComment], cursor: Int, hasMore: Bool) {
        let d = try await call(Self.replyJS, args: ["id": id, "cid": commentID, "cursor": String(cursor)], attempts: 1)
        let p = try JSONDecoder().decode(DYReplyPage.self, from: d)
        guard p.status == 200 else { throw DYError.blocked(p.msg ?? "HTTP \(p.status)") }
        return (p.items, p.cursor, p.hasMore)
    }

    /// 发评论 / 回复评论（replyID 非空 = 回复那条）
    /// 回复楼中楼：replyID = 一级评论 cid，replyToReplyID = 被回复的那条楼中楼 cid（网页 publishCommentItem 同款）
    /// image：已经传到 ImageX 的评论图片（`uploadCommentImage` 的结果）。带图时正文可以为空；一次一张（网页同款）
    func publishComment(_ awemeID: String, text: String, replyID: String? = nil, replyToReplyID: String? = nil,
                        image: DYImageXUploadResult? = nil) async throws -> DYComment {
        let args: [String: Any] = ["id": awemeID, "text": text, "reply": replyID ?? "0", "replyTo": replyToReplyID ?? "0",
                                   "imgUri": image?.uri ?? "", "imgW": String(image?.width ?? 0),
                                   "imgH": String(image?.height ?? 0), "imgFmt": image?.format ?? ""]
        let operationID = UUID().uuidString
        DYLiveModel.log("DDSEND comment op=\(operationID) phase=prepare")
        // 纯文字（含回复/楼中楼）走「真人方式」：抖音网页自己的评论框 + 发送按钮。带图仍走接口。
        if image == nil, DYWebComposer.enabled {
            if let c = try await publishViaWebUI(awemeID, text: text, replyID: replyID, replyToReplyID: replyToReplyID, op: operationID) {
                return c
            }
            DYLiveModel.log("DDSEND comment op=\(operationID) phase=web-ui-fallback")
        }
        guard await ensureWriteReady() else {
            DYLiveModel.log("DDSEND comment op=\(operationID) phase=not-ready")
            throw DYError.bad("评论签名页尚未就绪，未发送；草稿已保留")
        }
        // 在写入前获取本次身份；无法获取时可发一次，但不能把列表里的其他评论当作确认。
        let identity = try? await selfProfile()
        do {
            return try await publishViaAPI(awemeID, text: text, replyID: replyID, replyToReplyID: replyToReplyID,
                                           image: image, args: args, identity: identity, operationID: operationID, phase: "submit")
        } catch let v as DYCommentNeedsVerify {
            // 官方网页版同款：抖音要求身份验证 → 弹官方验证 → 通过后把同一条再发一次（只一次，不循环）
            DYLiveModel.log("DDSEND comment op=\(operationID) phase=verify-required")
            switch await DYPassportVerify.run(decision: v.decision) {
            case .passed:
                do {
                    return try await publishViaAPI(awemeID, text: text, replyID: replyID, replyToReplyID: replyToReplyID,
                                                   image: image, args: args, identity: identity, operationID: operationID, phase: "resubmit")
                } catch is DYCommentNeedsVerify {
                    DYLiveModel.log("DDSEND comment op=\(operationID) phase=verify-again")
                    throw DYError.bad("验证通过了，但抖音仍要求验证，这条没发出去；草稿已保留，稍后再试")
                }
            case .cancelled:
                throw DYError.bad("已取消身份验证，这条没发出去；草稿已保留")
            case .failed(let why):
                throw DYError.bad("身份验证没完成（\(why)），这条没发出去；草稿已保留")
            }
        }
    }

    /// 接口方式发一次。抖音要求身份验证且确认没收下时抛 DYCommentNeedsVerify（由上层弹验证后重发一次）。
    private func publishViaAPI(_ awemeID: String, text: String, replyID: String?, replyToReplyID: String?, image: DYImageXUploadResult?,
                               args: [String: Any], identity: DYUser?, operationID: String, phase: String) async throws -> DYComment {
        let sentAt = Date().timeIntervalSince1970
        DYLiveModel.log("DDSEND comment op=\(operationID) phase=\(phase)")
        let d: Data
        do { d = try await call(Self.publishJS, args: args, attempts: 1) }
        catch {
            DYLiveModel.log("DDSEND comment op=\(operationID) phase=transport-unknown")
            throw DYCommentUnconfirmed(message: "结果未确认，可能已发出；先刷新评论区核对")
        }
        guard let r = try? JSONDecoder().decode(DYPublishResp.self, from: d) else {
            DYLiveModel.log("DDSEND comment op=\(operationID) phase=decode-unknown")
            throw DYCommentUnconfirmed(message: "回执无法识别，可能已发出；先刷新评论区核对")
        }
        // 服务端文案、正文、账号标识与响应全文不入日志。
        DYLiveModel.log("DDSEND comment op=\(operationID) phase=response status=\(r.status) code=\(r.code.map(String.init) ?? "nil") diag=\(r.diagnostic ?? "-")")
        if r.status == -4 {
            DYLiveModel.log("DDSEND comment op=\(operationID) phase=not-ready-js")
            throw DYError.bad("评论签名页尚未就绪，未发送；草稿已保留")
        }
        if r.code == 8 {
            DYLiveModel.log("DDSEND comment op=\(operationID) phase=verification-required")
            throw DYLoginExpired()
        }
        if r.status == 200, r.code == 0, let c = r.comment, Self.isServerCommentID(c.id) {
            DYLiveModel.log("DDSEND comment op=\(operationID) phase=acknowledged")
            return c
        }
        // 明确业务拒绝不回查为成功，也不重试写请求。
        if let code = r.code, code != 0 {
            DYLiveModel.log("DDSEND comment op=\(operationID) phase=rejected")
            throw DYError.bad(r.msg?.isEmpty == false ? r.msg! : "评论被拒绝（\(code)），草稿已保留")
        }
        // 回查有总时限：读接口在风控期间可能被安全 SDK 压住十几秒，界面不能一直转圈（老板 11-18 实测卡约 30 秒）。
        DYLiveModel.log("DDSEND comment op=\(operationID) phase=reconcile")
        let started = Date()
        let mine = await Self.firstWithin(Self.reconcileTimeout) { [weak self] in
            await self?.findMySentComment(awemeID, text: text, replyID: replyID,
                                          replyToReplyID: replyToReplyID, imageSentAt: sentAt,
                                          identity: identity, hasImage: image != nil)
        }
        if let mine {
            DYLiveModel.log("DDSEND comment op=\(operationID) phase=verified")
            return mine
        }
        let waited = Int(Date().timeIntervalSince(started) * 1000)
        // 空回执 + 要求身份验证，且回查确认评论区里没有这条：确定没收下，交给上层弹验证
        if let decision = r.verify, !decision.isEmpty, r.comment == nil {
            DYLiveModel.log("DDSEND comment op=\(operationID) phase=needs-verify waitedMs=\(waited)")
            throw DYCommentNeedsVerify(decision: decision)
        }
        // 403 空响应：签名完整仍被拒，属于抖音对这次写入的拦截（常伴随验证要求），引导去网页版处理，不自动重发
        if r.status == 403 {
            DYLiveModel.log("DDSEND comment op=\(operationID) phase=blocked-403 waitedMs=\(waited)")
            throw DYLoginExpired()
        }
        DYLiveModel.log("DDSEND comment op=\(operationID) phase=unknown waitedMs=\(waited)")
        throw DYCommentUnconfirmed(message: "结果未确认，可能已发出；先刷新评论区核对")
    }

    /// 发送后回查的总时限（秒）。超时按「结果未知」处理，不当成功、不重发。
    static var reconcileTimeout: Double = 8

    /// 在时限内取结果：到点直接返回 nil，后台那次读取自己跑完即丢弃（WebView 里的 JS 调用无法取消）。
    static func firstWithin<T>(_ seconds: Double, _ work: @escaping @MainActor () async -> T?) async -> T? {
        let once = DYOnceFlag()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            Task { @MainActor in
                let v = await work()
                if !once.done { once.done = true; cont.resume(returning: v) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if !once.done { once.done = true; cont.resume(returning: nil) }
            }
        }
    }

    private static func isServerCommentID(_ id: String) -> Bool {
        !id.isEmpty && id != "0" && id.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    /// 仅核对本次身份、本次发送时间、精确正文和目标楼层；证据不足就是未知。
    /// 图片本身无法精确比对，纯图不作列表确认。最多只读本次目标楼层，不跨楼搜索。
    private func findMySentComment(_ awemeID: String, text: String, replyID: String?, replyToReplyID: String?,
                                   imageSentAt sentAt: Double, identity: DYUser?, hasImage: Bool) async -> DYComment? {
        guard !text.isEmpty, let me = identity, !me.secUid.isEmpty || !me.uid.isEmpty else { return nil }
        let parent = replyID.flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }
        let target = replyToReplyID.flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }
        let items: [DYComment]
        if let parent {
            guard let page = try? await fetchReplies(awemeID, commentID: parent, cursor: 0) else { return nil }
            items = page.items
        } else {
            guard target == nil, let page = try? await fetchComments(awemeID, cursor: 0) else { return nil }
            items = page.items
        }
        let now = Date().timeIntervalSince1970
        let matches = items.filter { c in
            // 若双方都有同类 ID，任何冲突都拒绝；至少要有一组稳定 ID 相等。
            let secMatches = !me.secUid.isEmpty && c.sec?.isEmpty == false && c.sec == me.secUid
            let uidMatches = !me.uid.isEmpty && c.uid?.isEmpty == false && c.uid == me.uid
            if !me.secUid.isEmpty, let sec = c.sec, !sec.isEmpty, sec != me.secUid { return false }
            if !me.uid.isEmpty, let uid = c.uid, !uid.isEmpty, uid != me.uid { return false }
            // 不给时间向前容差；服务端只有秒级时间而无法排除发送前旧评论时，宁可保持未知。
            guard secMatches || uidMatches, Self.isServerCommentID(c.id), c.text == text,
                  c.time >= sentAt, c.time <= now,
                  !hasImage || !(c.images ?? []).isEmpty else { return false }
            let actualParent = c.parent.flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }
            let actualTarget = c.replyTo.flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }
            return actualParent == parent && actualTarget == target
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// 发完回复后核对：在那条一级评论的回复里翻前 3 页找这条 id。nil = 读不到，核对不了。
    func replyIsVisible(_ awemeID: String, thread: String, id: String) async -> Bool? {
        var cursor = 0
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)); cursor = 0 }
            for _ in 0..<3 {
                guard let page = try? await fetchReplies(awemeID, commentID: thread, cursor: cursor) else { return nil }
                if page.items.contains(where: { $0.id == id }) { return true }
                guard page.hasMore, !page.items.isEmpty else { break }
                cursor = page.cursor
            }
        }
        return false
    }

    /// 删除评论（自己发的，或自己作品下的）。只在用户确认之后调用，不重试。
    func deleteComment(_ cid: String) async throws -> DYActionResult {
        await ensureWriteReady()
        let d = try await call(Self.deleteCommentJS, args: ["cid": cid], attempts: 1)
        let r = try JSONDecoder().decode(DYPublishResp.self, from: d)
        DYLiveModel.log("DDSEND comment-delete status=\(r.status) code=\(r.code.map(String.init) ?? "nil") msg=\(r.msg ?? "-")")
        return Self.manageResult(DYManageResp(status: r.status, statusCode: r.code, msg: r.msg))
    }

    /// 发视频弹幕（offset 秒 = 出现在视频的哪个时间点）
    func postDanmaku(_ awemeID: String, text: String, offset: Double) async throws -> String {
        let d = try await call(Self.danmakuPostJS, args: ["id": awemeID, "text": text, "offset": String(Int(max(0, offset) * 1000))], attempts: 1)
        let r = try JSONDecoder().decode(DYPublishResp.self, from: d)
        DYLiveModel.log("DDSEND danmaku status=\(r.status) code=\(r.code ?? -1) msg=\(r.msg ?? "-") id=\(r.danmakuID ?? "-")")
        if r.code == 8 { throw DYError.bad("抖音未登录") }
        guard r.status == 200, (r.code ?? 0) == 0 else {
            throw DYError.bad(r.msg?.isEmpty == false ? r.msg! : "发送失败（HTTP \(r.status) / \(r.code ?? -1)）")
        }
        return r.danmakuID ?? UUID().uuidString
    }

    func deleteDanmaku(_ id: String) async -> Bool {
        guard let d = try? await call(Self.danmakuDeleteJS, args: ["did": id], attempts: 1),
              let r = try? JSONDecoder().decode(DYPublishResp.self, from: d) else { return false }
        return r.status == 200 && (r.code ?? 0) == 0
    }

    private static let cmap = #"""
    const cmapImg = o => { const u = o && o.url_list && o.url_list[0]; return u ? { u, w: o.width || 0, h: o.height || 0 } : null; };
    const cmapImages = c => (c.image_list || []).map(x => {
      const m = cmapImg(x.medium_url) || cmapImg(x.thumb_url) || cmapImg(x.crop_url) || cmapImg(x.origin_url);
      const o = cmapImg(x.origin_url) || m;
      return m ? { thumb: m.u, full: o.u, w: o.w || m.w, h: o.h || m.h } : null;
    }).filter(Boolean);
    const cmap = c => c ? ({ id: typeof c.cid === 'string' ? c.cid : Number.isSafeInteger(c.cid) ? String(c.cid) : '', text: c.text || '', name: (c.user && c.user.nickname) || '', sec: (c.user && c.user.sec_uid) || null, avatar: c.user && first(c.user.avatar_thumb),
      digg: c.digg_count || 0, time: c.create_time || Math.floor(Date.now() / 1000), replies: 0, ip: c.ip_label || null,
      images: cmapImages(c) }) : null;
    """#

    // 网页版同款：params 放 app_name/enter_from，body 放 aweme_id/text（安全 SDK 会自动补签名头）
    static let publishJS = cmap + #"""
    // 网页版写接口带这几个身份参数（只在 cookie 里）：msToken / webid / verifyFp(=fp=s_v_web_id)
    const ck = n => { const c = (typeof document !== 'undefined' && document.cookie) || ''; const m = c.match(new RegExp('(?:^|;\\s*)' + n + '=([^;]*)')); return m ? decodeURIComponent(m[1]) : ''; };
    const fp = ck('s_v_web_id') || ck('verifyFp');
    const ident = { msToken: ck('msToken'), webid: ck('webid'), verifyFp: fp, fp: fp };
    const haveIdent = Object.keys(ident).filter(k => ident[k]).join(',');
    const P = q(Object.assign({ app_name: 'aweme', enter_from: 'video_detail', previous_page: 'video_detail' }, ident));
    const body = new URLSearchParams({ aweme_id: id, text: text, text_extra: '[]', comment_send_celltime: '0', comment_video_celltime: '0' });
    if (reply && reply !== '0') { body.set('reply_id', reply); body.set('reply_to_reply_id', (replyTo && replyTo !== '0') ? replyTo : '0'); }
    // 带图：网页评论框传完图后往 body 里多放这几个字段；不带图时请求形状不变
    const hasImage = typeof imgUri === 'string' && imgUri !== '';
    if (hasImage) {
      body.set('image_uri_list', imgUri); body.set('image_widths', imgW); body.set('image_heights', imgH); body.set('image_formats', imgFmt);
      body.set('paste_edit_method', 'non_paste'); body.set('one_level_comment_rank', '-1');
    }
    // 等安全 SDK 挂钩完成再发；x-secsdk-csrf-token: DOWNGRADE 是网页版写接口的 CSRF 降档标记
    const sdk = typeof sdkReady === 'function' ? await sdkReady(6000) : false;
    if (!sdk) return JSON.stringify({ status: -4, code: null, msg: '评论签名页尚未就绪，未发送；草稿已保留', comment: null, danmakuID: null, diagnostic: 'sdk=false phase=not-ready' });
    const r = await req('POST', '/aweme/v1/web/comment/publish?' + P, body.toString(), { 'x-secsdk-csrf-token': 'DOWNGRADE' });
    const raw = r.t || '', parsed = parse(raw), d = parsed || {};
    const kind = !raw.trim() ? 'empty' : parsed !== null ? 'json' : /^\s*</.test(raw) ? 'html' : 'other';
    // 只记录形状，不记录响应正文、评论内容、cookie 或 token；写操作不自动重试。
    const keys = Object.keys(d).filter(k => /^[a-zA-Z_]+$/.test(k)).slice(0, 12).join(',');
    const signed = /a_bogus=/.test(r.u || '');
    const hooked = (f) => { try { return !/native code/.test(f().toString()); } catch (e) { return 'na'; } };
    const diagnostic = 'kind=' + kind + ' chars=' + raw.length + ' keys=' + keys + ' ident=' + (haveIdent || 'none')
      + ' sdk=' + sdk + ' signed=' + signed + ' img=' + hasImage + ' imgBack=' + ((d.comment && d.comment.image_list) || []).length
      // 只记 id：请求挂在哪条下面、抖音实际挂到哪条下面、评论状态（判断「发出了却看不到」）
      + ' req=' + (typeof reply === 'string' && reply ? reply : '0') + '/' + (typeof replyTo === 'string' && replyTo ? replyTo : '0')
      + ' got=' + (d.comment ? String(d.comment.reply_id ?? '-') + '/' + String(d.comment.reply_to_reply_id ?? '-') + ' st=' + String(d.comment.status ?? '-') : '-')
      // 只记验证相关响应头「有没有」，不记值（官方网页版靠它们弹滑块/短信验证后重发）
      + (() => { const h = String(r.h || '').toLowerCase(); const f = n => h.includes('\n' + n + ':') ? 1 : 0;
          return ' vp=' + f('x-tt-verify-passport-decision') + ' bt=' + f('bdturing-verify') + ' vc=' + f('x-vc-bdturing-parameters')
            + ' tg=' + f('bd-ticket-guard-result') + ' shark=' + ((d.data && d.data.shark_decision_conf) ? 1 : 0)
            + ' tgr=' + (() => { const m = h.match(/\nbd-ticket-guard-result:\s*([^\r\n]*)/); if (!m) return '-'; const v = m[1].trim(); return /^-?\d{1,6}$/.test(v) ? v : 'x'; })(); })()
      + ' xhrHooked=' + hooked(() => XMLHttpRequest.prototype.send)
      + ' fetchHooked=' + hooked(() => window.fetch);
    const fallback = kind === 'empty' ? '抖音返回空响应，未能确认评论是否发送，请勿连续重发'
      : kind === 'html' ? '抖音返回了网页而非评论结果，请在网页版查看是否有验证提示'
      : '未收到有效的评论确认结果，请勿连续重发';
    const msg = d.status_msg || ((!d.comment || d.status_code !== 0 || r.s !== 200) ? fallback : null);
    // 抖音要求身份验证时把头的原值交回 App（只在内存里转给官方验证组件，不进日志）
    const vm = String(r.h || '').match(/\nx-tt-verify-passport-decision:\s*([^\r\n]*)/i);
    const verify = !d.comment && vm && vm[1].trim() ? vm[1].trim() : null;
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg, comment: cmap(d.comment), danmakuID: null, diagnostic, verify });
    """#

    static let deleteCommentJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const r = await req('POST', '/aweme/v1/web/comment/delete?' + q({ cid: cid, channel_id: '0', app_name: 'aweme' }), '');
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, comment: null, danmakuID: null });
    """#

    static let danmakuPostJS = #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const r = await req('POST', '/aweme/v1/web/danmaku/post_v2/?' + q({ item_id: id, offset_time: offset, text: text, user_id: '', enter_from: 'video_detail', previous_page: 'video_detail' }), '');
    const d = parse(r.t) || {};
    const dm = d.danmaku || d.data || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || (r.s === 200 ? null : (r.t || '').slice(0, 80)), comment: null,
      danmakuID: dm.danmaku_id ? String(dm.danmaku_id) : (d.danmaku_id ? String(d.danmaku_id) : null) });
    """#

    static let danmakuDeleteJS = #"""
    const r = await req('POST', '/aweme/v1/web/danmaku/delete_v2/?' + q({ app_name: 'aweme', format: 'json', user_type: '1', danmaku_id: did }), '');
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, comment: null, danmakuID: null });
    """#

    // MARK: JS（requestJS 里有 req / base / parse / first / q / mapA）

    private static let listTail = #"""
    const pack = (r, d, arr, cur, more) => JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || (r.s === 200 ? null : (r.t || '').slice(0, 80)),
      items: (arr || []).filter(a => a && (a.video || a.images) && !a.is_ads).map(mapA), cursor: String(cur ?? 0), hasMore: !!more });
    """#

    private static let userMap = #"""
    const coverOf = raw => {
      if (!raw) return null;
      const item = Array.isArray(raw) ? raw[0] : raw;
      return first(item);
    };
    const umap = u => u ? ({ name: u.nickname || '', avatar: first(u.avatar_larger) || first(u.avatar_thumb), signature: u.signature || '',
      secUid: u.sec_uid || '', uid: u.uid ? String(u.uid) : '', followers: u.follower_count || u.mplatform_followers_count || 0, following: u.following_count || 0,
      likes: u.total_favorited || 0, works: u.aweme_count || 0, ip: u.ip_location || null,
      cover: coverOf(u.cover_url) || coverOf(u.white_cover_url) }) : null;
    """#

    static let selfJS = userMap + #"""
    const r = await req('GET', '/aweme/v1/web/user/profile/self/?' + q({ publish_video_strategy_type: '2', source: 'channel_pc_web', personal_center_strategy: '1' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, user: umap(d.user), msg: d.status_msg || null });
    """#

    static let otherJS = userMap + #"""
    const r = await req('GET', '/aweme/v1/web/user/profile/other/?' + q({ sec_user_id: sec, publish_video_strategy_type: '2', personal_center_strategy: '1' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, user: umap(d.user), msg: d.status_msg || null });
    """#

    static let postJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/aweme/post/?' + q({ sec_user_id: sec, max_cursor: cursor, locate_query: 'false', show_live_replay_strategy: '1', need_time_list: '1', time_list_query: '0', whale_cut_token: '', cut_version: '1', count: '18' }));
    const d = parse(r.t) || {};
    // 自己的作品：origin_cover 是全黑占位图（2026-11-16 实测 360×721 全 0），改用 cover
    (d.aweme_list || []).forEach(a => { if (a) a.__ddSelfList = true; });
    return pack(r, d, d.aweme_list, d.max_cursor, d.has_more);
    """#

    static let likeJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/aweme/favorite/?' + q({ sec_user_id: sec, max_cursor: cursor, min_cursor: '0', count: '18', cut_version: '1' }));
    const d = parse(r.t) || {};
    return pack(r, d, d.aweme_list, d.max_cursor, d.has_more);
    """#

    static let collectJS = listTail + #"""
    const r = await req('POST', '/aweme/v1/web/aweme/listcollection/?' + q({ cursor: cursor, count: '18' }), 'count=18&cursor=' + cursor);
    const d = parse(r.t) || {};
    return pack(r, d, d.aweme_list, d.cursor, d.has_more);
    """#

    static let historyJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/history/read/?' + q({ max_cursor: cursor, count: '20' }));
    const d = parse(r.t) || {};
    return pack(r, d, d.aweme_list, d.max_cursor, d.has_more);
    """#

    static let laterJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/watchlater/list/?' + q({ cursor: cursor, count: '20', offset: cursor }));
    const d = parse(r.t) || {};
    const arr = (d.items || []).map(x => x && (x.aweme || x.aweme_info || x)).filter(Boolean);
    return pack(r, d, arr, (d.offset ?? 0), d.has_more);
    """#

    static let followJS = listTail + #"""
    if (typeof sdkReady === 'function') await sdkReady(6000);
    const r = await req('GET', '/aweme/v1/web/follow/feed/?' + q({ cursor: cursor, level: '1', count: '20', pull_type: cursor === '0' ? '0' : '2' }));
    const d = parse(r.t) || {};
    const arr = (d.data || []).map(x => x && (x.aweme || x.aweme_info)).filter(Boolean);
    return pack(r, d, arr, d.cursor, d.has_more);
    """#

    static let emojiJS = #"""
    const r = await req('GET', '/aweme/v1/web/emoji/list/?' + q({}));
    const d = parse(r.t) || {};
    const arr = (d.emoji_list || []).filter(e => e && e.display_name && !e.hide)
      .map(e => ({ displayName: e.display_name, url: ((e.emoji_url || {}).url_list || [])[0] || null }));
    return JSON.stringify({ status: r.s, items: arr });
    """#

    static let atListJS = #"""
    const r = await req('GET', '/aweme/v1/web/familiar/atlist/?' + q({ count: '20', cursor: cursor, scene: 'comment' }));
    const d = parse(r.t) || {};
    const arr = (d.user_list || []).filter(u => u).map(u => ({
      name: u.nickname || '',
      avatar: first(u.avatar_thumb) || first(u.avatar_168x168) || first(u.avatar_300x300),
      secUid: u.sec_uid || ''
    }));
    return JSON.stringify({ status: r.s, items: arr, cursor: String(d.cursor || 0), hasMore: !!d.has_more });
    """#

    static let followingJS = #"""
    const r = await req('GET', '/aweme/v1/web/user/following/list/?' + q({ sec_user_id: sec, count: '30', cursor: cursor, offset: cursor, source_type: '1' }));
    const d = parse(r.t) || {};
    const arr = (d.followings || []).filter(u => u).map(u => ({ name: u.nickname || '', avatar: first(u.avatar_thumb) || first(u.avatar_medium), secUid: u.sec_uid || '' }));
    return JSON.stringify({ status: r.s, items: arr, cursor: String(d.cursor || 0), hasMore: !!d.has_more });
    """#

    static let searchJS = listTail + #"""
    const r = await req('GET', '/aweme/v1/web/search/item/?' + q({ search_channel: 'aweme_video_web', keyword: kw, search_source: 'normal_search',
      query_correct_type: '1', is_filter_search: '0', from_group_id: '', offset: cursor, count: '24', need_filter_settings: cursor === '0' ? '1' : '0', list_type: 'single' }));
    const d = parse(r.t) || {};
    const arr = (d.data || []).map(x => x && (x.aweme_info || x.aweme)).filter(Boolean);
    return pack(r, d, arr, d.cursor, d.has_more);
    """#

    static let hotJS = #"""
    const r = await req('GET', '/aweme/v1/web/hot/search/list/?' + q({ detail_list: '1', source: '6', board_type: '0', board_sub_type: '' }));
    const d = parse(r.t) || {};
    const wl = ((d.data || {}).word_list) || [];
    return JSON.stringify(wl.filter(w => w && w.word).map(w => ({ word: w.word, hot: w.hot_value || 0, pos: w.position ?? null })));
    """#

    static let sugJS = #"""
    const r = await req('GET', '/aweme/v1/web/search/sug/?' + q({ keyword: kw, source: 'aweme_video_web', from_group_id: '' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, items: (d.sug_list || []).map(s => ({ word: s.content || '' })).filter(s => s.word) });
    """#

    static let danmakuJS = #"""
    const r = await req('GET', '/aweme/v1/web/danmaku/get_v2/?' + q({ app_name: 'aweme', format: 'json', group_id: id, item_id: id, start_time: '0', end_time: dur, duration: dur }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, items: (d.danmaku_list || []).filter(x => x && x.text).map(x => ({ id: String(x.danmaku_id), text: x.text, offset: (x.offset_time || 0) / 1000 })) });
    """#

    /// 诊断用：同一接口，显式指定 start_time/end_time 窗口
    static let danmakuWindowJS = #"""
    const r = await req('GET', '/aweme/v1/web/danmaku/get_v2/?' + q({ app_name: 'aweme', format: 'json', group_id: id, item_id: id, start_time: from, end_time: to, duration: dur }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, items: (d.danmaku_list || []).filter(x => x && x.text).map(x => ({ id: String(x.danmaku_id), text: x.text, offset: (x.offset_time || 0) / 1000 })) });
    """#

    static let replyJS = #"""
    let r = await req('GET', '/aweme/v2/web/comment/list/reply/?' + q({ item_id: id, comment_id: cid, cut_version: '1', cursor: cursor, count: '10', item_type: '0' }));
    let d = parse(r.t);
    if (!d || !Array.isArray(d.comments)) {
      r = await req('GET', '/aweme/v1/web/comment/list/reply/?' + q({ item_id: id, comment_id: cid, cut_version: '1', cursor: cursor, count: '10', item_type: '0' }));
      d = parse(r.t);
    }
    if (!d) {
      r = await req('GET', '/aweme/v1/web/comment/list/reply/?' + q({ item_id: id, comment_id: cid, cursor: cursor, count: '10', item_type: '0', whale_cut_token: '', cut_version: '1', rcFT: '' }));
      d = parse(r.t);
    }
    if (!d) return JSON.stringify({ status: r.s === 200 ? 403 : r.s, items: [], cursor: 0, hasMore: false, msg: '抖音没返回回复（网页接口受限）' });
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
    const ddStableID = v => typeof v === 'string' ? (v && v !== '0' ? v : null) : Number.isSafeInteger(v) && v > 0 ? String(v) : null;
    const ddCommentID = c => [c.cid, c.user && c.user.uid, c.reply_id, c.reply_to_reply_id].some(v => typeof v === 'number' && !Number.isSafeInteger(v)) ? '' : ddStableID(c.cid) || '';
    const items = (d.comments || []).map(c => ({
      id: ddCommentID(c), text: c.text || '', name: (c.user && c.user.nickname) || '', sec: (c.user && c.user.sec_uid) || null, avatar: c.user && first(c.user.avatar_thumb),
      digg: c.digg_count || 0, time: c.create_time || 0, replies: 0, ip: c.ip_label || null,
      images: ddImages(c), sticker: ddSticker(c),
      uid: ddStableID(c.user && c.user.uid),
      parent: ddStableID(c.reply_id),
      replyTo: ddStableID(c.reply_to_reply_id) }));
    return JSON.stringify({ status: r.s, items, cursor: d.cursor || 0, hasMore: !!d.has_more, msg: null });
    """#
}

/// 当前在播视频的进度（PlayerPage 周期性写入；发弹幕时取）
@MainActor enum DDNowPlaying {
    static var id = ""
    static var time: Double = 0
}

// MARK: - 弹幕调度策略

/// 仅影响视频滚动弹幕：上方三分之一、密度限流与短时间相同内容去重。
enum DYDanmakuPolicy {
    static let laneHeight: CGFloat = 28
    static let gap: CGFloat = 28
    static let densityKey = "douyin_video_danmaku_density_v1"
    static let deduplicateKey = "douyin_video_danmaku_deduplicate_v1"

    enum Density: Int, CaseIterable, Identifiable {
        case sparse = 0, standard = 1, dense = 2
        var id: Int { rawValue }
        var title: String {
            switch self { case .sparse: "稀疏"; case .standard: "标准"; case .dense: "密集" }
        }
        var maxLanes: Int {
            switch self { case .sparse: 2; case .standard: 4; case .dense: 6 }
        }
        var maxPerSecond: Int {
            switch self { case .sparse: 1; case .standard: 2; case .dense: 4 }
        }
    }
    struct Region { let top: CGFloat; let bottom: CGFloat; let lanes: Int }
    struct Placed { let d: DYDanmaku; let lane: Int; let width: CGFloat; let dur: Double; let start: Double }

    static func region(height: CGFloat, topInset: CGFloat, density: Density) -> Region {
        guard height.isFinite, height >= 0, topInset.isFinite else { return Region(top: 0, bottom: 0, lanes: 0) }
        let bottom = height / 3
        let top = max(0, topInset) + 64
        let available = max(0, ((bottom - top) / laneHeight).rounded(.down))
        return Region(top: top, bottom: bottom, lanes: Int(min(CGFloat(density.maxLanes), available)))
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .split(whereSeparator: { $0.isWhitespace }).joined()
    }

    static func layout(_ items: [DYDanmaku], w: CGFloat, lanes: Int, speed: CGFloat,
                       density: Density, deduplicate: Bool) -> [Placed] {
        guard w.isFinite, w > 0, speed.isFinite, speed > 0, lanes > 0 else { return [] }
        let laneCount = min(lanes, density.maxLanes)
        var free = Array(repeating: -Double.infinity, count: laneCount)
        var out: [Placed] = []
        var seenIDs = Set<String>(), lastShown: [String: Double] = [:]
        // 源数据一扎堆就只放前几条、后面直接丢，视觉上会「一片一片」。
        // 改成：能放就放在原时刻；轨道都占着就顺延（最多 2.5 秒），把成团的弹幕摊成连续流。
        let maxDelay = 2.5
        let sorted = items.enumerated().filter { $0.element.offset.isFinite && $0.element.offset >= 0 }
            .sorted { $0.element.offset == $1.element.offset ? $0.offset < $1.offset : $0.element.offset < $1.element.offset }
        for entry in sorted {
            let d = entry.element
            let text = normalized(d.text)
            guard !d.id.isEmpty, !text.isEmpty, !seenIDs.contains(d.id) else { continue }
            if deduplicate, let last = lastShown[text], d.offset - last < 10 { continue }
            let width = d.text.unicodeScalars.reduce(CGFloat(6)) { $0 + ($1.value < 0x2E80 ? 9 : 16) }
            // 选最早空出来的轨道
            var lane = -1
            var start = Double.infinity
            for (i, f) in free.enumerated() {
                let candidate = max(d.offset, f)
                if candidate < start { start = candidate; lane = i }
            }
            guard lane >= 0, start - d.offset <= maxDelay else { continue }
            free[lane] = start + Double((width + gap) / speed)
            out.append(Placed(d: d, lane: lane, width: width, dur: Double((w + width) / speed), start: start))
            seenIDs.insert(d.id); lastShown[text] = d.offset
        }
        return out
    }
}

// MARK: - 弹幕层（视频）

/// 弹幕时钟：播放器每 0.25 秒报一次进度，弹幕按帧插值出「现在」的视频时间，否则位置一跳一跳。
/// 播放器报一次就校准一次（锚点 = 报的时间 + 报的时刻），中间按播放速率往前推。
struct DYDanmakuClock {
    var anchorTime: Double = 0
    var anchorDate = Date()
    var rate: Double = 1
    var playing = false
    /// 微调速率（±8%）：跟播放器对不上时不再把位置往回拽，而是让弹幕稍快/稍慢一点点追上。
    /// 原来每 0.25 秒把锚点拉回一次 → 弹幕每秒往回抖 4 下（实测平稳时偏差 20～90ms），看着不顺。
    var slew: Double = 0
    /// 快进/拖动后的「冷静期」：播放器在重建音频、缓冲，报上来的时间与暂停状态在抖，只做平滑追赶不硬跳
    var settleUntil = Date.distantPast
    /// 用户每跳转一次 +1：弹幕层看到变化就清屏、从新位置重新出（抖音同款）
    var epoch = 0

    func now(_ d: Date) -> Double {
        playing ? anchorTime + d.timeIntervalSince(anchorDate) * rate * (1 + slew) : anchorTime
    }

    /// 用户主动跳转（拖进度、快进/快退）：直接对齐到目标，并进入冷静期
    mutating func seek(_ t: Double, playing p: Bool, rate r: Double) {
        anchorTime = t; anchorDate = Date(); playing = p; rate = r; slew = 0
        settleUntil = Date().addingTimeInterval(2.5)
        epoch += 1
    }

    /// 用户点了暂停/播放：立刻生效
    mutating func userToggle(_ t: Double, playing p: Bool, rate r: Double) {
        settleUntil = .distantPast
        anchorTime = t; anchorDate = Date(); playing = p; rate = r; slew = 0
    }

    /// 诊断：每次校准时预测值与播放器报告值的偏差（秒）
    static var errSamples: [Double] = []

    mutating func sync(_ t: Double, playing p: Bool, rate r: Double) {
        let now = Date()
        let predicted = self.now(now)
        let err = t - predicted
        let settling = now < settleUntil
        if p, playing {
            Self.errSamples.append(err)
            if Self.errSamples.count >= 40 {
                let e = Self.errSamples
                let absMax = e.map { abs($0) }.max() ?? 0
                let mean = e.reduce(0, +) / Double(e.count)
                DYLiveModel.log("DDDMCLOCK n=\(e.count) mean=\(String(format: "%+.3f", mean))s maxAbs=\(String(format: "%.3f", absMax))s over50ms=\(e.filter { abs($0) > 0.05 }.count)")
                Self.errSamples.removeAll()
            }
        }
        // 冷静期里播放器短暂报「暂停」（缓冲）不跟着停；其余情况状态/倍速变了就硬对齐
        let pausedBlip = settling && !p && playing
        let stateChanged = !pausedBlip && (p != playing || r != rate)
        let hardLimit = settling ? 1.5 : 0.35
        if stateChanged || !playing || abs(err) > hardLimit {
            anchorTime = t; anchorDate = now; slew = 0
            if !pausedBlip { playing = p }
            rate = r
            return
        }
        // 连续：位置不跳，只在 1 秒内用 ±8% 的速率把偏差追平
        anchorTime = predicted; anchorDate = now
        slew = max(-0.08, min(0.08, err / max(rate, 0.25)))
        if settling, abs(err) < 0.1 { settleUntil = .distantPast }
        rate = r
    }
}

/// 抖音同款滚动弹幕：所有弹幕同一速度从右往左飘（同速 → 同一轨道里后面的永远追不上前面的）。
/// 轨道按「前一条尾巴已经完全进屏 + 间距」分配，整条视频一次排好（布局只在弹幕列表 / 屏幕宽变化时重算）；
/// 某个时刻所有轨道都满就丢掉这一条（抖音也是这样）。
/// 位置用 TimelineView(.animation) 逐帧算（跟屏幕刷新率走，ProMotion 上 120Hz），不靠 SwiftUI 补间动画。
struct DYDanmakuLayer: View {
    let items: [DYDanmaku]
    let clock: DYDanmakuClock
    let topInset: CGFloat
    @AppStorage(DYDanmakuPolicy.densityKey) private var densityRaw = DYDanmakuPolicy.Density.standard.rawValue
    @AppStorage(DYDanmakuPolicy.deduplicateKey) private var deduplicate = true

    private var renderItems: [DYDanmaku] {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_DM_STRESS"] == "1" {
            return (0..<600).map { DYDanmaku(id: "stress-\($0)", text: "弹幕流畅度测试 \($0)", offset: Double($0) * 0.15) }
        }
        #endif
        return items
    }

    var body: some View {
        GeometryReader { g in
            let density = DYDanmakuPolicy.Density(rawValue: densityRaw) ?? .standard
            let region = DYDanmakuPolicy.region(height: g.size.height, topInset: topInset, density: density)
            // 字号变大后轨道变高：按新行高重算这块区域能放几条轨道
            let lanes = min(density.maxLanes, Int(max(0, (region.bottom - region.top) / DYDanmakuStyle.laneHeight)))
            DYDanmakuLiveSurface(items: renderItems, clock: clock, regionTop: region.top,
                                 regionHeight: max(0, region.bottom - region.top), lanes: lanes,
                                 density: density, deduplicate: deduplicate)
                .frame(width: g.size.width, height: g.size.height)
        }
        .allowsHitTesting(false)
    }
}


// MARK: - 保存到相册

enum DYSaver {
    enum SaveError: LocalizedError {
        case denied, noURL
        var errorDescription: String? {
            switch self {
            case .denied: "没有相册权限：设置 → DouDuo → 照片 → 允许添加"
            case .noURL: "这条没有可下载的地址"
            }
        }
    }

    static func save(_ a: DYAweme, fromOfflineLibrary: Bool = false) async throws {
        let st = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard st == .authorized || st == .limited else { throw SaveError.denied }
        if fromOfflineLibrary {
            guard let file = DYOfflineVideoStore.localURL(a.id) else { throw SaveError.noURL }
            try await saveVideo(file)
            return
        }
        if !a.images.isEmpty {
            var datas: [Data] = []
            for s in a.images { if let u = URL(string: s) { datas.append(try await download(u)) } }
            try await PHPhotoLibrary.shared().performChanges {
                for d in datas { PHAssetCreationRequest.forAsset().addResource(with: .photo, data: d, options: nil) }
            }
            return
        }
        guard let s = a.play, let u = URL(string: s) else { throw SaveError.noURL }
        let data = try await download(u)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dd-\(a.id).mp4")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await saveVideo(file)
    }

    private static func saveVideo(_ file: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: nil)
        }
    }

    private static func download(_ u: URL) async throws -> Data {
        var r = URLRequest(url: u)
        DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        let (d, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw DYError.bad("下载失败 HTTP \(h.statusCode)") }
        return d
    }
}

// MARK: - 封面网格（搜索 / 我的 / 作者）

struct DYGrid: View {
    let items: [DYAweme]
    let hasMore: Bool
    let loading: Bool
    let error: String?
    let onLoadMore: () -> Void
    let onOpen: (Int) -> Void
    var showsPlayCount = false
    /// 长按格子出的移除项（例如「移出稍后再看」）。两个都给了才有长按菜单。
    var removeTitle: String? = nil
    var onRemove: ((DYAweme) -> Void)? = nil
    /// 作者主页：刚刚看过的那条（同抖音：格子上标「刚刚看过」，不在屏上时底部给一键定位）
    var focusID: String? = nil
    private let cols = [GridItem(.adaptive(minimum: 140), spacing: 2)]
    @State private var focusVisible = false

    @ViewBuilder
    private func gridButton(_ i: Int, _ a: DYAweme) -> some View {
        let button = Button { onOpen(i) } label: { cell(a) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("douyin.grid.item.\(a.id)")
            .id(a.id)
            .onAppear { if a.id == focusID { focusVisible = true } }
            .onDisappear { if a.id == focusID { focusVisible = false } }
        if let onRemove, let removeTitle {
            button.contextMenu {
                Button(removeTitle, systemImage: "minus.circle", role: .destructive) { onRemove(a) }
                    .accessibilityIdentifier("douyin.grid.remove")
            }
        } else {
            button
        }
    }

    var body: some View {
        // 底部哨兵只在真正滚进可视区时才翻页：ScrollView 的非惰性子视图会立刻 onAppear，
        // 直接 onAppear 会一页接一页把作者作品全拉下来（2026-11-07 实测）。
        GeometryReader { outer in
          ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: cols, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, a in
                        gridButton(i, a)
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(24)
                } else if loading {
                    ProgressView().tint(.primary).padding(24)
                } else if items.isEmpty {
                    Text("这里还没有内容").font(.footnote).foregroundStyle(.secondary).padding(40)
                } else if hasMore {
                    Color.clear
                        .frame(height: 40)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(key: DYBottomYKey.self, value: g.frame(in: .named("ddgrid")).minY)
                            }
                        )
                }
            }
            .coordinateSpace(name: "ddgrid")
            .onPreferenceChange(DYBottomYKey.self) { y in
                if y < outer.size.height - 16 { onLoadMore() }
            }
            .overlay(alignment: .bottom) {
                if let focusID, !focusVisible, items.contains(where: { $0.id == focusID }) {
                    Button {
                        withAnimation(.snappy) { proxy.scrollTo(focusID, anchor: .center) }
                        DYLiveModel.log("DDAUTHOR jump-to-recent id=\(focusID)")
                    } label: {
                        Label("定位到刚刚看过", systemImage: "scope")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("douyin.author.jumpRecent")
                }
            }
            .animation(.snappy, value: focusVisible)
          }
        }
    }

    private func cell(_ a: DYAweme) -> some View {
        Color.black.opacity(0.4)
            .aspectRatio(3/4, contentMode: .fit)
            .overlay {
                CachedAsyncImage(url: a.cover.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                    placeholder: { Color.white.opacity(0.06) }
            }
            .clipped()
            .overlay {
                if a.id == focusID {
                    Rectangle().strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                }
            }
            .overlay(alignment: .topLeading) {
                if a.id == focusID {
                    Text("刚刚看过")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.black.opacity(0.6), in: .rect(cornerRadius: 4))
                        .padding(5)
                        .accessibilityIdentifier("douyin.grid.recent")
                }
            }
            .overlay(alignment: .topTrailing) {
                if !a.images.isEmpty {
                    Image(systemName: "photo.on.rectangle").font(.caption).foregroundStyle(.white).padding(6)
                        .shadow(radius: 2)
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    if !a.desc.isEmpty {
                        Text(a.desc).font(.caption2).lineLimit(2)
                    }
                    Label(showsPlayCount ? a.stats.play.map(DYFormat.count) ?? "—" : DYFormat.count(a.stats.digg),
                          systemImage: showsPlayCount ? "play" : "heart")
                        .font(.caption2.weight(.semibold))
                        .accessibilityLabel(showsPlayCount ? "播放量 \(a.stats.play.map(String.init) ?? "未提供")" : "点赞量 \(a.stats.digg)")
                        .accessibilityIdentifier(showsPlayCount ? "douyin.grid.playCount" : "douyin.grid.likeCount")
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 2)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            }
            .clipped()
            .contentShape(Rectangle())
    }
}

private struct DYBottomYKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

// MARK: - 列表播放器（从网格点进来，上下滑接着看）

/// Lives with the presentation request so a window transfer can remount the
/// player without restoring the original grid selection or losing progress.
@Observable @MainActor
final class DYListPlayback {
    var items: [DYAweme]
    var currentID: String?
    var resume: [String: Double] = [:]
    var liked: Set<String>
    var collected: Set<String>
    var loadingMore = false
    @ObservationIgnored private var offlineCheckpoint: DYOfflineVideoStore.PlaybackCheckpoint?

    init(items: [DYAweme], start: Int) {
        self.items = items
        currentID = items.indices.contains(start) ? items[start].id : items.first?.id
        liked = Set(items.filter { $0.userDigged == 1 }.map(\.id))
        collected = Set(items.filter { $0.isCollect == 1 }.map(\.id))
    }

    func restoreOfflineCheckpoint(_ checkpoint: DYOfflineVideoStore.PlaybackCheckpoint) {
        offlineCheckpoint = checkpoint
        resume[checkpoint.id] = checkpoint.seconds
    }

    func updateOfflineItems(_ saved: [DYAweme]) {
        let oldIDs = Set(items.map(\.id))
        let oldIndex = items.firstIndex { $0.id == currentID } ?? 0
        let newItems = saved.filter { !oldIDs.contains($0.id) }
        liked.formUnion(newItems.filter { $0.userDigged == 1 }.map(\.id))
        collected.formUnion(newItems.filter { $0.isCollect == 1 }.map(\.id))
        items = saved
        if !saved.contains(where: { $0.id == currentID }) {
            currentID = saved.isEmpty ? nil : saved[min(oldIndex, saved.count - 1)].id
        }
    }

    func saveOfflineCheckpoint(_ id: String, seconds: Double, periodic: Bool = false) {
        guard id == currentID, seconds.isFinite, seconds >= 0 else { return }
        let checkpoint = DYOfflineVideoStore.PlaybackCheckpoint(id: id, seconds: seconds)
        if let previous = offlineCheckpoint, previous.id == id,
           abs(previous.seconds - seconds) < (periodic ? 5 : 0.10) { return }
        if DYOfflineVideoStore.saveCheckpoint(checkpoint) { offlineCheckpoint = checkpoint }
    }
}

struct DYListPlayer: View {
    @State private var searchSession: DYSearchSession?
    @State private var searchIsSplit = false
    let bridge: DouyinBridge
    let title: String
    @State private var playback: DYListPlayback
    /// 滚动位置单独一个状态：直接绑 currentID 的话，SwiftUI 在下一条滑过中线时就把它设成当前条并开播，
    /// 画面还在往上走就已经出声了。当前条只在收尾动画停住时（DYPagingSpeedBridge.didSettle）才切。
    @State private var scrollPos: String?
    let loadMore: (() async -> [DYAweme])?
    let onAuthor: (DYAweme) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preloader = DYPreloader()
    @State private var showComments = false
    @State private var toast: String?
    @State private var showSettings = false
    @State private var web: DYWebTarget?
    /// 从消息点评论进来：自动开评论区并定位那条评论
    let commentFocus: DYCommentFocus?
    /// 信息里点开的分享视频：关掉时彻底收掉声音（播放器、音频引擎、音频会话）
    let hardStopOnDismiss: Bool
    /// 打开时外面已经盖了几层遮罩（信息页 / 我的）：这个播放器就在那一层之上，可以照常播
    @State private var coverLevel = DDPlayback.shared.coverDepth
    /// 点头像时作者页由播放器自己弹在上面。播放器是全屏页：交给底下的页面弹，会被播放器盖住，
    /// 要返回关掉播放器后才看到（老板 11-16 报：搜索出来的视频点头像不跳，返回才跳）
    let presentsAuthor: Bool
    @State private var authorSheet: DYAweme.Author?
    let offlineLibrary: Bool
    @State private var networkIsOffline = false
    @State private var failedOfflineVideos: Set<String> = []
    @State private var userScrolling = false
    @State private var scrollEndTask: Task<Void, Never>?

    init(bridge: DouyinBridge, title: String, items: [DYAweme], start: Int,
         loadMore: (() async -> [DYAweme])? = nil, onAuthor: @escaping (DYAweme) -> Void,
         commentFocus: DYCommentFocus? = nil, hardStopOnDismiss: Bool = false, presentsAuthor: Bool = false) {
        self.init(bridge: bridge, title: title, playback: DYListPlayback(items: items, start: start),
                  loadMore: loadMore, onAuthor: onAuthor, commentFocus: commentFocus,
                  hardStopOnDismiss: hardStopOnDismiss, presentsAuthor: presentsAuthor)
    }

    init(bridge: DouyinBridge, title: String, playback: DYListPlayback,
         loadMore: (() async -> [DYAweme])? = nil, onAuthor: @escaping (DYAweme) -> Void,
         commentFocus: DYCommentFocus? = nil, hardStopOnDismiss: Bool = false, presentsAuthor: Bool = false,
         offlineLibrary: Bool = false) {
        self.bridge = bridge; self.title = title
        self.presentsAuthor = presentsAuthor
        self.commentFocus = commentFocus
        self.offlineLibrary = offlineLibrary
        _networkIsOffline = State(initialValue: offlineLibrary && DYOfflineDownloads.shared.isOffline)
        self.hardStopOnDismiss = hardStopOnDismiss
        _showComments = State(initialValue: commentFocus != nil)
        _playback = State(initialValue: playback)
        self.loadMore = loadMore
        self.onAuthor = onAuthor
    }

    private var current: DYAweme? { playback.items.first { $0.id == playback.currentID } }
    private var allowsOnlineActions: Bool { !offlineLibrary || !networkIsOffline }

    var body: some View {
        DYCommentPlayerLayout(bridge: bridge, aweme: current, showComments: $showComments, focus: commentFocus,
                              onBack: { dismiss() }, backIdentifier: offlineLibrary ? "offline.library.close" : "douyin.list.back",
                              allowsComments: allowsOnlineActions, allowsResidentComments: !offlineLibrary) { insets in
            ZStack(alignment: .topLeading) {
                Color.ddBackground.ignoresSafeArea()
                pager(insets)
                if let t = toast {
                    Text(t).font(.footnote.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.62)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
        }
        // 左缘右滑返回上一层（博主主页 / 我的 / 搜索结果 / 消息里点开的视频）
        .dyEdgeBack(enabled: searchSession == nil) { dismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(offlineLibrary ? "offline.library.content" : "douyin.list.player")
        .accessibilityValue(playback.currentID ?? "")
        .accessibilityAction(.escape) { dismiss() }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            Text(playback.currentID ?? "-")
                .font(.caption2).opacity(0.01)
                .accessibilityIdentifier(offlineLibrary ? "offline.library.currentID" : "douyin.list.currentID")
                .allowsHitTesting(false)
        }
        #endif
        .modifier(DYSearchPresentation(bridge: bridge, session: $searchSession, isSplit: $searchIsSplit,
                                      onOpen: { showComments = false }))
        .onChange(of: showComments) { _, shown in if shown { searchSession = nil } }
        // Full-screen works own their chrome; do not inherit the author split
        // pane's hidden rail or the home page's pinned header.
        .environment(\.duoSystemBars, true)
        .environment(\.duoCleanScreen, false)
        .environment(\.duoInlineVideoNavigation, false)
        .environment(\.ddCoverLevel, offlineLibrary ? 0 : coverLevel)
        .onReceive(DYOfflineDownloads.shared.$isOffline.removeDuplicates()) { offline in
            guard offlineLibrary else { return }
            networkIsOffline = offline
            if offline { showComments = false }
        }
        .onChange(of: playback.currentID) { old, new in
            if new == nil, let old, playback.items.contains(where: { $0.id == old }) {
                playback.currentID = old
                return
            }
            guard let i = playback.items.firstIndex(where: { $0.id == new }) else { return }
            if offlineLibrary {
                let id = playback.items[i].id
                scrollPos = id
                playback.saveOfflineCheckpoint(id, seconds: playback.resume[id] ?? 0)
                return
            }
            preloader.update(playback.items, current: i)
            // 不再预解首帧：界面已不用首帧图顶替（老板要纯黑直出），省 CPU 和解码
            if i >= playback.items.count - 4, let loadMore, !playback.loadingMore {
                playback.loadingMore = true
                Task {
                    let more = await loadMore()
                    let seen = Set(playback.items.map(\.id))
                    playback.items.append(contentsOf: more.filter { !seen.contains($0.id) })
                    playback.loadingMore = false
                }
            }
        }
        .onAppear {
            if !offlineLibrary, let i = playback.items.firstIndex(where: { $0.id == playback.currentID }) {
                preloader.update(playback.items, current: i)
            }
        }
        .onDisappear {
            scrollEndTask?.cancel()
            preloader.clear()
            if hardStopOnDismiss {
                // 关掉分享视频：播放器拆掉的同时，把音频引擎和会话一并停掉，
                // 否则无缝音频引擎还在出声（以前返回后声音继续响）
                DDAudioEngineHub.shared.pauseAll()
                DYLiveModel.log("DDSHAREPLAY close hard-stop")
            }
        }
        .environment(\.dyOpenSettings, { if !offlineLibrary { showSettings = true } })
        .sheet(isPresented: $showSettings, onDismiss: { DDPlayback.shared.releaseCover() }) {
            DYSettingsScreen(onOpenWeb: { showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { web = DYWebTarget(url: DouyinWeb.home) } })
                .onAppear { DDPlayback.shared.pauseAll(reason: .cover) }   // 设置页也停掉视频
        }
        .fullScreenCover(item: $web) { t in DouyinWebScreen(start: t.url) }
        .sheet(item: $authorSheet, onDismiss: { if !offlineLibrary { DDPlayback.shared.releaseCover() } }) { a in
            NavigationStack {
                DYAuthorScreen(bridge: bridge, author: a, onWeb: { url in
                    authorSheet = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { web = DYWebTarget(url: url) }
                })
            }
            .onAppear { if !offlineLibrary { DDPlayback.shared.pauseAll(reason: .cover) } }
        }
    }

    @ViewBuilder private func pager(_ insets: EdgeInsets) -> some View {
        @Bindable var playback = playback
        if offlineLibrary {
            DYFeedPager(items: playback.items, currentID: $playback.currentID, scrollID: $scrollPos,
                        userScrolling: $userScrolling, scrollEndTask: $scrollEndTask) { item, _ in
                page(item, insets: insets)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("offline.library.player")
        } else {
            ScrollView(.vertical) {
                DYPagerStack(items: playback.items, currentID: playback.currentID, page: { item in
                    page(item, insets: insets)
                })
                .scrollTargetLayout()
                .background(DYPagingSpeedBridge(ids: playback.items.map(\.id), currentID: $playback.currentID))
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollPos, anchor: .center)
            .onAppear { scrollPos = playback.currentID }
            .onChange(of: playback.currentID) { _, new in if scrollPos != new { scrollPos = new } }
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
        }
    }

    @ViewBuilder private func page(_ item: DYAweme, insets: EdgeInsets) -> some View {
        let video = DYVideoPage(
            item: item, isCurrent: item.id == playback.currentID && (!offlineLibrary || (authorSheet == nil && web == nil)),
            insets: insets, resume: playback.resume[item.id],
            liked: playback.liked.contains(item.id), collected: playback.collected.contains(item.id),
            onLike: { toggleLike(item.id, force: nil) }, onCollect: { toggleCollect(item.id) },
            onDoubleTap: { toggleLike(item.id, force: true) },
            onComments: { if requireConnection() { showComments.toggle() } },
            onSearch: { if requireConnection() {
                DYSearchSession.transition { showComments = false; searchSession = DYSearchSession() }
            } },
            onAuthor: { if requireConnection() {
                if presentsAuthor { authorSheet = item.author } else { onAuthor(item) }
            } },
            onSavePosition: {
                guard $0.isFinite, $0 >= 0 else { return }
                playback.resume[item.id] = $0
                if offlineLibrary { playback.saveOfflineCheckpoint(item.id, seconds: $0) }
            },
            preloader: preloader, bridge: allowsOnlineActions ? bridge : nil, onToast: { show($0) },
            moreExtras: offlineLibrary ? AnyView(EmptyView()) : AnyView(Section { DYSettingsButton() }),
            onEnded: { playNext(after: item.id) }
        )
        if offlineLibrary {
            video.environment(\.dyOfflineVideoPlayback,
                DYOfflinePlaybackContext(id: item.id, localOnly: true,
                    position: playback.items.firstIndex { $0.id == item.id }.map { $0 + 1 },
                    total: playback.items.count, onFailure: { skipFailedOfflineVideo(item.id) }, inLibrary: true,
                    onPositionUpdate: { playback.saveOfflineCheckpoint(item.id, seconds: $0, periodic: true) },
                    onlineActionsAllowed: allowsOnlineActions))
        } else {
            video
        }
    }

    private func requireConnection() -> Bool {
        guard allowsOnlineActions else { show("联网后可用"); return false }
        return true
    }

    private func skipFailedOfflineVideo(_ id: String) {
        guard playback.currentID == id else { return }
        failedOfflineVideos.insert(id)
        let playable = nextOfflineVideo(after: id)
        if let playable { advance(from: id, to: playable.id) }
        else { show("这个离线视频无法播放") }
    }

    private func nextOfflineVideo(after id: String) -> DYAweme? {
        guard let i = playback.items.firstIndex(where: { $0.id == id }) else { return nil }
        return playback.items.dropFirst(i + 1).first {
            !failedOfflineVideos.contains($0.id) && DYOfflineVideoStore.localURL($0.id) != nil
        }
    }

    /// 「自动连播」打开时播完切下一条；到尾部先拉下一页
    /// 自动连播翻页带滑动动画（议题 #21-4）；分页代理没接上时退回直接切
    private func advance(from: String, to: String) {
        if !DYPagerAdvance.request(from: from, to: to) { withAnimation { playback.currentID = to } }
    }

    private func playNext(after id: String) {
        if offlineLibrary {
            guard playback.currentID == id else { return }
            if let next = nextOfflineVideo(after: id) { advance(from: id, to: next.id) }
            return
        }
        guard let i = playback.items.firstIndex(where: { $0.id == id }) else { return }
        if i + 1 < playback.items.count { advance(from: id, to: playback.items[i + 1].id); return }
        guard let loadMore, !playback.loadingMore else { return }
        playback.loadingMore = true
        Task {
            let more = await loadMore()
            let seen = Set(playback.items.map(\.id))
            playback.items.append(contentsOf: more.filter { !seen.contains($0.id) })
            playback.loadingMore = false
            if let j = playback.items.firstIndex(where: { $0.id == id }), j + 1 < playback.items.count {
                advance(from: id, to: playback.items[j + 1].id)
            }
        }
    }

    private func show(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if toast == s { toast = nil } }
    }

    private func toggleLike(_ id: String, force: Bool?) {
        guard requireConnection() else { return }
        let has = playback.liked.contains(id), want = force ?? !has
        guard want != has else { return }
        if want { playback.liked.insert(id) } else { playback.liked.remove(id) }
        Task {
            let r = try? await bridge.digg(id, like: want)
            if case .ok = r { return }
            if want { playback.liked.remove(id) } else { playback.liked.insert(id) }
            show(r.map { if case .notLoggedIn = $0 { return "抖音未登录" } else { return "点赞失败" } } ?? "点赞失败")
        }
    }

    private func toggleCollect(_ id: String) {
        guard requireConnection() else { return }
        let want = !playback.collected.contains(id)
        if want { playback.collected.insert(id) } else { playback.collected.remove(id) }
        Task {
            let r = try? await bridge.favorite(id, add: want)
            if case .ok = r { show(want ? "已收藏" : "已取消收藏"); return }
            if want { playback.collected.remove(id) } else { playback.collected.insert(id) }
            show("收藏失败")
        }
    }
}

// MARK: - 通用分页列表模型

@MainActor
final class DYPagedModel: ObservableObject {
    @Published var items: [DYAweme] = []
    @Published var loading = false
    @Published var error: String?
    @Published var hasMore = true
    private var cursor = "0"
    private let fetch: (String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool)

    init(fetch: @escaping (String) async throws -> (items: [DYAweme], cursor: String, hasMore: Bool)) {
        self.fetch = fetch
    }

    func reset() { items = []; cursor = "0"; hasMore = true; error = nil }

    @discardableResult
    func loadMore() async -> [DYAweme] {
        guard !loading, hasMore else { return [] }
        loading = true
        defer { loading = false }
        do {
            let r = try await fetch(cursor)
            let seen = Set(items.map(\.id))
            let fresh = r.items.filter { !seen.contains($0.id) && ($0.play != nil || !$0.images.isEmpty) }
            items.append(contentsOf: fresh)
            hasMore = r.hasMore && !r.items.isEmpty && r.cursor != cursor
            cursor = r.cursor
            error = nil
            return fresh
        } catch {
            self.error = error.localizedDescription
            hasMore = false
            return []
        }
    }
}

@MainActor
struct DYListTarget: Identifiable {
    let id = UUID()
    let title: String
    let model: DYPagedModel?
    let playback: DYListPlayback

    init(title: String, items: [DYAweme], start: Int, model: DYPagedModel?) {
        self.title = title
        self.model = model
        playback = DYListPlayback(items: items, start: start)
    }
}

// MARK: - 搜索


struct DYSearchScreen: View {
    let bridge: DouyinBridge
    let onAuthor: (DYAweme) -> Void
    private let onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var state: DYSearchSession
    @State private var open: DYListTarget?

    init(bridge: DouyinBridge, onAuthor: @escaping (DYAweme) -> Void, initialQuery: String = "",
         session: DYSearchSession? = nil, onClose: (() -> Void)? = nil) {
        self.bridge = bridge
        self.onAuthor = onAuthor
        self.onClose = onClose
        _state = State(initialValue: session ?? DYSearchSession(query: initialQuery))
    }

    @FocusState private var focused: Bool
    @Environment(\.dySearchInSplitPane) private var edgeIsSplitDivider
    @AppStorage("douyin_search_history_v1") private var historyRaw = ""

    private var history: [String] { historyRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        NavigationStack {
            searchContent
                .modifier(DYSearchBackToolbar(onBack: { if let onClose { onClose() } else { dismiss() } }))
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        }
        // 左缘右滑返回；Duo 内屏左右分栏时搜索在右半屏，左缘是分界线，不挂
        .dyEdgeBack(enabled: !edgeIsSplitDivider) { if let onClose { onClose() } else { dismiss() } }
    }

    private var searchContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.primary.opacity(0.6))
                        .fixedSize().accessibilityHidden(true)
                    TextField("", text: $state.keyword, prompt: Text("搜索视频").foregroundStyle(Color.primary.opacity(0.45)))
                        .foregroundStyle(Color.primary)
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit { run(state.keyword) }
                        .accessibilityIdentifier("douyin.search.field")
                    if !state.keyword.isEmpty {
                        Button { state.keyword = ""; state.lastRun = ""; state.model = nil; focused = true } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.primary.opacity(0.5))
                        }
                        .accessibilityLabel("清空搜索")
                        .accessibilityIdentifier("douyin.search.clear")
                        .fixedSize()
                    }
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(Capsule().fill(Color.primary.opacity(0.12)))
                Button("搜索") { run(state.keyword) }.foregroundStyle(Color.primary).font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("douyin.search.submit")
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18).padding(.bottom, 12)

            if let model = state.model {
                DYSearchResults(model: model, onOpen: { i in
                    state.presentsVideo = true
                    open = DYListTarget(title: "搜索：\(state.keyword)", items: model.items, start: i, model: model)
                })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !state.suggestions.isEmpty && !state.keyword.isEmpty {
                            ForEach(state.suggestions) { s in
                                Button { state.keyword = s.word; run(s.word) } label: {
                                    HStack {
                                        Image(systemName: "magnifyingglass").foregroundStyle(Color.primary.opacity(0.45))
                                        Text(s.word).foregroundStyle(Color.primary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } else if !history.isEmpty {
                            HStack {
                                Text("搜索历史").font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                                Spacer()
                                Button("清空") { historyRaw = "" }.font(.caption).foregroundStyle(Color.primary.opacity(0.6))
                            }
                            .padding(16)
                            FlowTags(tags: history) { w in state.keyword = w; run(w) }
                                .padding(.horizontal, 16)
                        }
                        if !state.hot.isEmpty && (state.suggestions.isEmpty || state.keyword.isEmpty) {
                            hotSection
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .background(Color.ddBackground.ignoresSafeArea())
        .task {
            guard state.hot.isEmpty else { return }
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_SEARCH_FIXTURE"] == "1" {
                state.hot = [DYHot(word: "开放之门：深圳", hot: 0, pos: nil),
                             DYHot(word: "手工敲虾到底有多好吃", hot: 11_103_000, pos: 1),
                             DYHot(word: "课本里的逍遥游有画面了", hot: 10_098_000, pos: 2),
                             DYHot(word: "解锁 APEC 限定寻宝路线", hot: 9_440_000, pos: 3),
                             DYHot(word: "油价下调 加满一箱油少花约26元", hot: 9_293_000, pos: 4)]
                return
            }
            #endif
            let result = await bridge.hotSearch()
            guard !Task.isCancelled else { return }
            state.hot = result
        }
        .onAppear {
            guard !state.initialized else { return }
            state.initialized = true
            if !state.initialQuery.isEmpty {
                run(state.initialQuery)
            } else { focused = true }
            #if DEBUG
            if let w = ProcessInfo.processInfo.environment["DOUDUO_SEARCHKW"] { run(w) }
            else if ProcessInfo.processInfo.environment["DOUDUO_SEARCHCAT"] == "1" { run("猫") }
            #endif
        }
        .task(id: state.keyword) {
            let value = state.keyword
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state.suggestions = []; return
            }
            guard value != state.lastRun else { return }
            state.model = nil
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_SEARCH_FIXTURE"] == "1" { return }
            #endif
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            let result = await bridge.suggest(value)
            guard !Task.isCancelled else { return }
            state.suggestions = result
        }
        .fullScreenCover(item: $open, onDismiss: { state.presentsVideo = false }) { t in
            DYListPlayer(bridge: bridge, title: t.title, playback: t.playback,
                         loadMore: t.model.map { m in { await m.loadMore() } }, onAuthor: onAuthor, presentsAuthor: true)
        }
    }

    private var hotSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("抖音热搜").font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                .padding(.top, 20)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(state.hot) { item in
                    Button { run(item.word) } label: { DYHotSearchRow(item: item) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("douyin.search.hot.\(item.pos ?? 0)")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private func run(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        focused = false
        state.suggestions = []
        state.lastRun = w
        state.keyword = w
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_SEARCH_FIXTURE"] == "1" {
            let items = ProcessInfo.processInfo.environment["DOUDUO_PLAYBACK_FIXTURE"] == "1" || ProcessInfo.processInfo.environment["DOUDUO_GRID_FIXTURE"] == "1"
                ? Array(DYFeedModel.hashtagFixtures.dropFirst()) : []
            let model = DYPagedModel { _ in (items: items, cursor: "0", hasMore: false) }
            state.model = model
            Task { await model.loadMore() }
            return
        }
        #endif
        var h = history.filter { $0 != w }
        h.insert(w, at: 0)
        historyRaw = h.prefix(15).joined(separator: "\n")
        let m = DYPagedModel { [bridge] cur in try await bridge.search(w, offset: cur) }
        state.model = m
        Task { await m.loadMore() }
    }
}

private struct DYSearchResults: View {
    @ObservedObject var model: DYPagedModel
    let onOpen: (Int) -> Void
    var body: some View {
        DYGrid(items: model.items, hasMore: model.hasMore, loading: model.loading, error: model.error,
               onLoadMore: { Task { await model.loadMore() } }, onOpen: onOpen)
    }
}

/// 标签流式排版（搜索历史）
struct FlowTags: View {
    let tags: [String]
    let onTap: (String) -> Void
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(tags, id: \.self) { t in
                Button { onTap(t) } label: {
                    Text(t).font(.subheadline).foregroundStyle(Color.primary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.primary.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: min(s.sizeThatFits(.unspecified).width, w), height: nil))
            if x + sz.width > w, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing; row = max(row, sz.height)
        }
        return CGSize(width: w, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: min(s.sizeThatFits(.unspecified).width, bounds.width), height: nil))
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; row = max(row, sz.height)
        }
    }
}

// MARK: - 我的

struct DYMineScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @AppStorage(DDChromeMode.key) private var chromeModeRaw = DDChromeMode.classic.rawValue
    let bridge: DouyinBridge
    let onLogin: () -> Void
    let onAuthor: (DYAweme) -> Void
    var onMessages: (() -> Void)? = nil
    /// 嵌在信息页里（跟信息共用右侧栏）：不画自己的返回键、不做左缘返回
    var embedded = false
    @State private var user: DYUser?
    @State private var userErr: String?
    @State private var kind: DYListKind = .post
    @State private var models: [DYListKind: DYPagedModel] = [:]
    @State private var open: DYListTarget?
    @State private var relations: DYRelationsTarget?
    @State private var manageMsg: String?
    @State private var confirmClearHistory = false
    @State private var clearingHistory = false
    /// App 内登录页（DYAppLoginScreen）；检测到未登录时进「我的」先弹它（老板 2026-11-17）
    @State private var showLogin = false
    @State private var showAccounts = false
    /// 这次打开期间已经自动弹过登录：放在静态里——简洁 / 极简模式在信息 ⇄ 我的之间切换会重建「我的」，
    /// @State 会被重置，导致每切回来一次就再弹一次登录
    private static var autoLoginShownAt: Date?
    private var autoLoginShown: Bool {
        get { Self.autoLoginShownAt.map { Date().timeIntervalSince($0) < 120 } ?? false }
        nonmutating set { Self.autoLoginShownAt = newValue ? Date() : nil }
    }

    var body: some View {
        NavigationStack {
            content
                // 左缘右滑返回（和左上「返回」同条件：经典模式下「我的」是底部 Tab，没有上一层）
                .dyEdgeBack(enabled: !embedded && chromeModeRaw != DDChromeMode.duoClassic.rawValue) { dismiss() }
                .modifier(DYSystemTabBar())
                .navigationTitle(user?.name ?? "我的")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(embedded ? .hidden : .automatic, for: .navigationBar)
                .toolbar {
                    if !embedded && chromeModeRaw != DDChromeMode.duoClassic.rawValue {
                        ToolbarItem(placement: .navigation) { Button("返回", systemImage: "chevron.backward") { dismiss() } }
                    }
                    // 「网页版 / 登录」按钮已按老板要求去掉：未登录时页内仍有「去登录」入口，功能不受影响
                    // 嵌在信息页（简洁 / 极简）时「账号」在右侧栏，顶栏不放，免得跟返回键挤在一起
                    if !embedded {
                        ToolbarItem(placement: .primaryAction) {
                            Button("账号", systemImage: "person.2.circle") { showAccounts = true }
                                .accessibilityIdentifier("douyin.mine.accounts")
                        }
                    }
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dyOpenAccounts)) { _ in if embedded { showAccounts = true } }
        .sheet(isPresented: $showAccounts) {
            DYAccountsScreen(onChanged: { Task { await accountChanged() } },
                             onAddAccount: {
                                 // 添加账号：先把当前账号存好并退出本机登录态，再弹登录页
                                 Task {
                                     await DYAccountStore.shared.signOut()
                                     await accountChanged(showLoginAfter: true)
                                 }
                             })
        }

    }

    /// 切换 / 退出 / 添加账号后：签名页重载，清空当前页面数据，重新读资料
    private func accountChanged(showLoginAfter: Bool = false) async {
        user = nil; userErr = nil; models = [:]
        bridge.reload()
        onLogin()   // 外层刷新推荐流
        try? await Task.sleep(for: .seconds(2))
        await loadSelf()
        if showLoginAfter { try? await Task.sleep(for: .milliseconds(400)); showLogin = true }
    }

    private func loadSelf() async {
        #if DEBUG
        // UI 测试：假的已登录资料，用来检查「我的」页头布局（不读真账号）
        if ProcessInfo.processInfo.environment["DOUDUO_SELF_FIXTURE"] == "1" {
            user = DYUser(name: "测试账号", avatar: nil, signature: "这是一段测试用的个人简介，用来检查页头布局。",
                          secUid: "fixture", uid: "1", followers: 1280, following: 96, likes: 35600, works: 42,
                          ip: "IP属地：广东", cover: nil)
            userErr = nil
            if user != nil { models = [:]; ensure(kind) }
            return
        }
        #endif
        do {
            let u = try await bridge.selfProfile()
            user = u; userErr = nil
            await DYAccountStore.shared.remember(u)   // 登录过的账号存起来，之后可直接切换
        } catch {
            userErr = error.localizedDescription
            DYLiveModel.log("DDMINE self err " + error.localizedDescription)
        }
        if user != nil { models = [:]; ensure(kind) }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if embedded {
                // 跟信息页「消息」标题同字号、同高度、同位置
                HStack {
                    Text("我的").font(.title2.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .frame(height: theme.messages.headerHeight)
                .accessibilityIdentifier("douyin.mine.title")
            }
            header.padding(.horizontal, 16).padding(.bottom, 12)

            HStack(spacing: 22) {
                ForEach(DYListKind.allCases) { k in
                    Button { kind = k } label: {
                        VStack(spacing: 5) {
                            Text(k.title).font(.subheadline.weight(kind == k ? .bold : .medium))
                                .foregroundStyle(Color.primary.opacity(kind == k ? 1 : 0.6))
                            Capsule().fill(Color.primary).frame(width: 18, height: 2.5).opacity(kind == k ? 1 : 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("douyin.mine.\(k.rawValue)")
                }
            }
            .padding(.bottom, 6)

            if kind == .history || manageMsg != nil {
                HStack(spacing: 10) {
                    if let manageMsg {
                        Text(manageMsg).font(.caption).foregroundStyle(.orange).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if kind == .history {
                        Button(clearingHistory ? "清空中…" : "清空历史", systemImage: "trash") { confirmClearHistory = true }
                            .font(.caption)
                            .disabled(clearingHistory)
                            .accessibilityIdentifier("douyin.mine.history.clear")
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 6)
            }

            if let m = models[kind] {
                DYMineList(model: m, showsPlayCount: kind == .post,
                           removeTitle: kind == .later ? "移出稍后再看" : nil,
                           onRemove: kind == .later ? { a in Task { await removeLater(a, from: m) } } : nil) { i in
                    open = DYListTarget(title: kind.title, items: m.items, start: i, model: m)
                }
                .id(kind)
            }
        }
        .background(alignment: .top) {
            DYSelfProfileBackdrop(cover: user?.cover)
        }
        .background(Color.ddBackground.ignoresSafeArea())
        .task {
            #if DEBUG
            // UI-only entry fixture: a real public work, never a fake account list.
            if ProcessInfo.processInfo.environment["DOUDUO_COMMENT_ENTRY"] == "mine",
               let id = ProcessInfo.processInfo.environment["DOUDUO_VIDEO_ID"],
               let item = try? await bridge.awemeDetail(id) {
                open = DYListTarget(title: "评论布局回归", items: [item], start: 0, model: nil)
                return
            }
            #endif
            // 未登录：进「我的」先弹登录。看共享 cookie 有没有 sessionid，不等资料接口——
            // 真机上签名页没加载好时接口报的是「页面还没加载好 / 被拦截」，不是「未登录」，以前因此不弹（老板 11-17）
            if !autoLoginShown, !(await DYLoginState.hasSession()) {
                autoLoginShown = true
                DYLiveModel.log("DDAPPLOGIN auto-show (no sessionid)")
                showLogin = true
            }
            await loadSelf()
            // cookie 还在但会话已失效（抖音侧退出 / 过期）：资料接口说未登录，也弹
            if user == nil, !autoLoginShown, userErr?.contains("未登录") == true {
                autoLoginShown = true
                DYLiveModel.log("DDAPPLOGIN auto-show (profile 未登录)")
                showLogin = true
            }
        }
        .sheet(isPresented: $showLogin, onDismiss: {
            // 网页登录组件把登录态写进共享 cookie：签名页重载后再读一次资料
            bridge.reload()
            Task { try? await Task.sleep(for: .seconds(2)); await loadSelf() }
            onLogin()
        }) {
            DYAppLoginScreen()
        }
        .onAppear { ensure(kind) }
        .onChange(of: kind) { _, k in manageMsg = nil; ensure(k) }
        .alert("清空观看历史？", isPresented: $confirmClearHistory) {
            Button("清空", role: .destructive) { Task { await clearHistory() } }
            Button("取消", role: .cancel) {}
        } message: { Text("清空后找不回来。") }
        .fullScreenCover(item: $open) { t in
            DYListPlayer(bridge: bridge, title: t.title, playback: t.playback,
                         loadMore: t.model.map { m in { await m.loadMore() } }, onAuthor: onAuthor, presentsAuthor: true)
        }
        .fullScreenCover(item: $relations) { t in
            DYRelationsScreen(bridge: bridge, kind: t.kind, uid: t.user.uid, secUid: t.user.secUid, manageFollowers: true)
        }
    }

    /// 移出稍后再看。抖音确认了才从列表里拿掉。
    private func removeLater(_ a: DYAweme, from m: DYPagedModel) async {
        do {
            switch try await bridge.removeWatchLater(a.id) {
            case .ok: m.items.removeAll { $0.id == a.id }; manageMsg = nil
            case .notLoggedIn: manageMsg = "抖音未登录"
            case .failed(let why): manageMsg = "没移出去：" + why
            }
        } catch { manageMsg = "没移出去：" + error.localizedDescription }
    }

    /// 清空观看历史。成功后重新拉一遍，以抖音那边为准。
    private func clearHistory() async {
        guard !clearingHistory else { return }
        clearingHistory = true
        defer { clearingHistory = false }
        do {
            switch try await bridge.clearHistory() {
            case .ok:
                manageMsg = nil
                if let m = models[.history] { m.reset(); await m.loadMore() }
            case .notLoggedIn: manageMsg = "抖音未登录"
            case .failed(let why): manageMsg = "没清掉：" + why
            }
        } catch { manageMsg = "没清掉：" + error.localizedDescription }
    }

    private func ensure(_ k: DYListKind) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_COMMENT_ENTRY"] == "mine" { return }
        if ProcessInfo.processInfo.environment["DOUDUO_GRID_FIXTURE"] == "1" {
            guard models[k] == nil else { return }
            let model = DYPagedModel { _ in (items: DYFeedModel.hashtagFixtures, cursor: "0", hasMore: false) }
            models[k] = model
            Task { await model.loadMore() }
            return
        }
        #endif
        guard models[k] == nil else { return }
        let m = DYPagedModel { [bridge] cur in
            let r = try await bridge.myList(k, cursor: cur)
            // 诊断：「我的」作品封面不显示——看接口给没给封面地址、是什么样的地址
            let noCover = r.items.filter { ($0.cover ?? "").isEmpty }.count
            let sample = r.items.first?.cover ?? "-"
            DYLiveModel.log("DDMINE list=\(k.rawValue) n=\(r.items.count) noCover=\(noCover) sample=\(sample)")
            return r
        }
        models[k] = m
        Task { await m.loadMore() }
    }

    @ViewBuilder
    private var header: some View {
        if let u = user {
            DYUserHeader(user: u,
                         onFollowing: { relations = DYRelationsTarget(kind: .following, user: u) },
                         onFollowers: { relations = DYRelationsTarget(kind: .followers, user: u) })
        } else if let e = userErr {
            VStack(spacing: 10) {
                Text(e.contains("未登录") ? "还没登录抖音" : e).foregroundStyle(Color.primary.opacity(0.8)).font(.subheadline)
                Button("去登录") { showLogin = true }.buttonStyle(.borderedProminent).tint(.pink)
                    .accessibilityIdentifier("douyin.mine.login")
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
        } else {
            ProgressView().tint(.primary).frame(height: 80)
        }
    }
}

private struct DYMineList: View {
    @ObservedObject var model: DYPagedModel
    var showsPlayCount = false
    var removeTitle: String? = nil
    var onRemove: ((DYAweme) -> Void)? = nil
    let onOpen: (Int) -> Void
    var body: some View {
        DYGrid(items: model.items, hasMore: model.hasMore, loading: model.loading, error: model.error,
               onLoadMore: { Task { await model.loadMore() } }, onOpen: onOpen, showsPlayCount: showsPlayCount,
               removeTitle: removeTitle, onRemove: onRemove)
    }
}

/// 「我的」页顶部封面。没有 URL、URL 无效或图片失败时不画这层，页面仍是原来的黑底。
private struct DYSelfProfileBackdrop: View {
    let cover: String?

    private var url: URL? {
        guard let cover, !cover.isEmpty, let url = URL(string: cover),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    var body: some View {
        if let url {
            // 宽度写死为容器宽度：以前 scaledToFill 后接 .frame(maxWidth: .infinity)，
            // 封面比例比容器宽时这个框会按图片自身宽度撑开（居中），clipped 只裁到撑开后的框，
            // 右边就画出容器、盖到右侧栏那一列（合屏时最明显）。顶部仍延伸到状态栏。
            GeometryReader { geo in
                let inset = geo.safeAreaInsets
                let width = max(0, geo.size.width - inset.leading - inset.trailing)
                CachedAsyncImage(url: url, thumbnailMaxPixel: 1600) { image in
                    image.resizable().scaledToFill()
                        .frame(width: width, height: 240)
                        .clipped()
                        .overlay {
                            LinearGradient(
                                colors: [.ddBackground.opacity(0.88), .ddBackground.opacity(0.72), .ddBackground],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                } placeholder: {
                    Color.clear
                }
                .frame(width: width, height: 240)
                .padding(.leading, inset.leading)
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct DYUserHeader: View {
    let user: DYUser
    /// 「关注 / 粉丝」数字可点（传了回调才显示为按钮）；不传保持纯展示，作者页不受影响
    var onFollowing: (() -> Void)? = nil
    var onFollowers: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                CachedAsyncImage(url: user.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                    placeholder: { Color.primary.opacity(0.1) }
                    .frame(width: 72, height: 72).clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.name).font(.title3.weight(.bold)).foregroundStyle(Color.primary)
                    if let ip = user.ip, !ip.isEmpty {
                        Text(ip).font(.caption).foregroundStyle(Color.primary.opacity(0.55))
                    }
                }
            }
            HStack(spacing: 20) {
                stat(user.likes, "获赞")
                statTap(user.following, "关注", onFollowing, "douyin.header.following")
                statTap(user.followers, "粉丝", onFollowers, "douyin.header.followers")
                stat(user.works, "作品")
            }
            if !user.signature.isEmpty {
                Text(user.signature).font(.footnote).foregroundStyle(Color.primary.opacity(0.75)).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func stat(_ n: Int, _ t: String) -> some View {
        HStack(spacing: 4) {
            Text(DYFormat.count(n)).font(.subheadline.weight(.bold)).foregroundStyle(Color.primary)
            Text(t).font(.caption).foregroundStyle(Color.primary.opacity(0.6))
        }
    }
    @ViewBuilder
    private func statTap(_ n: Int, _ t: String, _ act: (() -> Void)?, _ id: String) -> some View {
        if let act {
            Button(action: act) {
                stat(n, t).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
        } else {
            // Read-only author statistics use the same colors as interactive
            // account statistics; a disabled Button would dim only these two.
            stat(n, t).accessibilityIdentifier(id)
        }
    }
}

// MARK: - 作者主页（资料卡 + 原生作品网格；网页版只作兜底）

struct DYAuthorScreen: View {
    let bridge: DouyinBridge
    let author: DYAweme.Author
    let onWeb: (URL) -> Void
    var onClose: (() -> Void)? = nil
    var onWorkPresentationChange: ((Bool) -> Void)? = nil
    /// 刚刚看过的作品 ID；不传就取打开主页那一刻正在播的视频（只有它确实是这个作者的作品才会标出来）
    var focusAwemeID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var recentID: String?
    @State private var user: DYUser?
    @State private var err: String?
    @State private var posts: [DYAweme] = []
    @State private var cursor = "0"
    @State private var hasMore = true
    @State private var loading = false
    @State private var postErr: String?
    @State private var followed = false
    @State private var followUID: String?
    @State private var followBusy = false
    @State private var followMsg: String?
    @State private var blocked = false
    /// 我自己的 sec_uid；没认出我是谁之前不给拉黑入口
    @State private var selfSec: String?
    @State private var blockBusy = false
    @State private var confirmBlock = false
    @State private var player: DYAuthorPlay?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let u = user {
                DYUserHeader(user: u)
            } else if let err {
                Text(err).foregroundStyle(Color.primary.opacity(0.7)).font(.footnote)
            } else {
                ProgressView().tint(.primary).frame(maxWidth: .infinity, minHeight: 72)
            }
            if let s = author.secUid, let u = URL(string: "https://www.douyin.com/user/\(s)") {
                Button {
                    close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onWeb(u) }
                } label: {
                    Text("网页版")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.primary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.author.web")
            }
            if let followMsg {
                Text(followMsg).font(.caption2).foregroundStyle(.orange)
            }
            DYGrid(items: posts, hasMore: hasMore, loading: loading, error: postErr, onLoadMore: { requestMore() }, onOpen: { i in
                onWorkPresentationChange?(true)
                player = DYAuthorPlay(playback: DYListPlayback(items: posts, start: i))
            }, focusID: recentID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("douyin.author.works")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(Color.ddBackground)
        .dyEdgeBack(enabled: edgeBackEnabled) { close() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.author.panel")
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("返回", systemImage: "chevron.backward", action: close)
                    .accessibilityIdentifier("douyin.author.back")
            }
            .dyVerticalPreferred()
            ToolbarItem(placement: .primaryAction) { followButton }
                .dyVerticalPreferred()
            if canBlock {
                ToolbarItem(placement: .primaryAction) { blockMenu }
                    .dyVerticalPreferred()
            }
        }
        .alert(blocked ? "解除拉黑？" : "拉黑这个人？", isPresented: $confirmBlock) {
            Button(blocked ? "解除拉黑" : "拉黑", role: blocked ? nil : .destructive) { Task { await toggleBlock() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(blocked ? "解除拉黑后，对方可以搜索到你，可以给你发私信" : "拉黑后，对方将无法搜索到你，也不能给你发私信")
        }
        .fullScreenCover(item: $player, onDismiss: {
            onWorkPresentationChange?(false)
            // 从主页点开作品看完回来：「刚刚看过」换成最后停留的那条
            let last = DDNowPlaying.id
            if !last.isEmpty, posts.contains(where: { $0.id == last }) { recentID = last }
        }) { p in
            DYListPlayer(bridge: bridge, title: author.name.isEmpty ? "作品" : author.name, playback: p.playback,
                         loadMore: { await loadPosts() }, onAuthor: { _ in })
        }
        .task {
            guard let s = author.secUid else { err = "没有作者信息"; hasMore = false; return }
            async let profile: Void = loadProfile(s)
            async let state: Void = loadFollow(s)
            _ = await (profile, state)
            #if DEBUG
            // Exercise the real author -> work navigation when a logged-out
            // posts request returns an empty list. Only a matching public work
            // is seeded; the release build never includes this test route.
            if ProcessInfo.processInfo.environment["DOUDUO_AUTHOR_WORK_FIXTURE"] == "1",
               let id = ProcessInfo.processInfo.environment["DOUDUO_VIDEO_ID"],
               let item = try? await bridge.awemeDetail(id), item.author.secUid == s {
                posts = [item]
                hasMore = false
                return
            }
            #endif
            _ = await loadPosts()
            await locateRecent(s)
        }
    }

    /// 同抖音：刚刚看过的作品不在第一页时继续往下翻，直到翻到它（先核实它确实是这个作者的，别白翻）
    private func locateRecent(_ sec: String) async {
        let candidate = focusAwemeID ?? (DDNowPlaying.id.isEmpty ? nil : DDNowPlaying.id)
        guard let id = candidate, !id.isEmpty else { return }
        if posts.contains(where: { $0.id == id }) { recentID = id; DYLiveModel.log("DDAUTHOR recent found page=1 id=\(id)"); return }
        guard hasMore, let item = try? await bridge.awemeDetail(id), item.author.secUid == sec else { return }
        for page in 2...30 {
            guard hasMore, !Task.isCancelled else { break }
            while loading { try? await Task.sleep(for: .milliseconds(120)) }
            _ = await loadPosts()
            if posts.contains(where: { $0.id == id }) {
                recentID = id
                DYLiveModel.log("DDAUTHOR recent found page=\(page) id=\(id)")
                return
            }
        }
        DYLiveModel.log("DDAUTHOR recent not found id=\(id) n=\(posts.count)")
    }

    private func close() { if let onClose { onClose() } else { dismiss() } }
    /// 经典模式右半屏博主窗格（onClose 由宿主给）左缘是分界线，不挂边缘返回
    private var edgeBackEnabled: Bool { onClose == nil }

    /// 自己的主页不给拉黑入口；没登录（认不出我是谁）时也不给
    private var canBlock: Bool {
        guard let sec = author.secUid, !sec.isEmpty, let me = selfSec, !me.isEmpty else { return false }
        return sec != me
    }

    private var blockMenu: some View {
        Menu {
            Button(blocked ? "解除拉黑" : "拉黑", systemImage: blocked ? "hand.raised.slash" : "hand.raised") { confirmBlock = true }
                .disabled(blockBusy)
                .accessibilityIdentifier("douyin.author.block")
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("更多")
        .accessibilityIdentifier("douyin.author.more")
    }

    private func toggleBlock() async {
        guard !blockBusy else { return }
        guard let sec = author.secUid, !sec.isEmpty, let uid = followUID ?? author.uid, !uid.isEmpty else {
            followMsg = "还没拿到对方的账号信息，稍后再试"
            return
        }
        blockBusy = true
        defer { blockBusy = false }
        let want = !blocked
        do {
            switch try await bridge.blockUser(uid: uid, secUid: sec, block: want) {
            case .ok:
                // 关注关系以抖音那边为准重读一遍；拉黑状态用这次写入的回执（回执里的 block_status 已核对过）
                await loadFollow(sec)
                blocked = want
                followMsg = want ? "已拉黑" : "已解除拉黑"
            case .notLoggedIn:
                followMsg = "抖音未登录"
            case .failed(let why):
                followMsg = (want ? "没拉黑：" : "没解除：") + why
            }
        } catch {
            followMsg = (want ? "没拉黑：" : "没解除：") + error.localizedDescription
        }
    }

    @ViewBuilder
    private var followButton: some View {
        let uid = followUID ?? author.uid
        Button(followBusy ? "处理中" : (followed ? "已关注" : "关注"),
               systemImage: followed ? "person.badge.minus" : "person.badge.plus") {
            Task { await toggleFollow() }
        }
        .disabled(followBusy || uid == nil || uid?.isEmpty == true)
        .accessibilityIdentifier("douyin.author.follow")
    }

    private func loadProfile(_ sec: String) async {
        do { user = try await bridge.userProfile(sec) } catch { err = error.localizedDescription }
    }

    private func loadFollow(_ sec: String) async {
        if let s = try? await bridge.followState(sec: sec) {
            followed = s.followed
            blocked = s.blocked
            if selfSec == nil { selfSec = try? await bridge.selfSecUid() }
            bridge.rememberFollow(author, followed: s.followed)
            if let uid = s.uid, !uid.isEmpty { followUID = uid }
        }
    }

    private func requestMore() {
        guard !loading, hasMore, author.secUid != nil else { return }
        loading = true
        Task { _ = await loadPosts(alreadyLocked: true) }
    }

    private func loadPosts(alreadyLocked: Bool = false) async -> [DYAweme] {
        guard hasMore, let sec = author.secUid else { return [] }
        if !alreadyLocked {
            guard !loading else { return [] }
            loading = true
        }
        defer { loading = false }
        do {
            let r = try await bridge.userPosts(sec, cursor: cursor)
            let seen = Set(posts.map(\.id))
            let fresh = r.items.filter { !seen.contains($0.id) }
            posts.append(contentsOf: fresh)
            hasMore = r.hasMore && !r.items.isEmpty && r.cursor != cursor
            cursor = r.cursor
            postErr = nil
            DYLiveModel.log("DDPOST sec=\(sec.prefix(8)) n=\(fresh.count) more=\(hasMore)")
            return fresh
        } catch {
            postErr = error.localizedDescription
            hasMore = false
            DYLiveModel.log("DDPOST error \(error.localizedDescription)")
            return []
        }
    }

    /// 只在按钮点击时发关注。不要在测试里点。
    private func toggleFollow() async {
        guard let uid = followUID ?? author.uid, !uid.isEmpty, !followBusy else { return }
        followBusy = true
        defer { followBusy = false }
        let want = !followed
        do {
            switch try await bridge.followUser(uid, follow: want) {
            case .ok:
                followed = want
                bridge.rememberFollow(author, followed: want)
                followMsg = nil
            case .notLoggedIn:
                followMsg = "抖音未登录"
            case .failed(let why):
                followMsg = why
            }
        } catch {
            followMsg = error.localizedDescription
        }
    }
}

private struct DYAuthorPlay: Identifiable {
    let id = UUID()
    let playback: DYListPlayback
}

// MARK: - 关注流

struct DYFollowFeed: View {
    @ObservedObject var bridge: DouyinBridge
    let insets: EdgeInsets
    let active: Bool
    let onAuthor: (DYAweme) -> Void
    let onLogin: () -> Void
    let onToast: (String) -> Void
    let onComments: (DYAweme) -> Void
    var onShowRecommendations: (() -> Void)? = nil
    /// 经典模式把列表模型留在不会随频道切换销毁的屏幕上，避免每次进入都重新请求。
    var retainedList: DYPagedModelHolder? = nil
    /// 经典模式把当前作品 ID 留在屏幕上。视图被拆掉后再进来，按这个 ID 恢复，而不是第一条。
    var preservedSelection: Binding<String?>? = nil
    var onChannelDrag: ((CGFloat, CGFloat) -> Void)? = nil
    var onChannelDragEnd: ((CGFloat, CGFloat, CGFloat, Bool) -> Void)? = nil
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @StateObject private var ownedList = DYPagedModelHolder()
    private var list: DYPagedModelHolder { retainedList ?? ownedList }
    @State private var ownedID: String?
    private var currentID: Binding<String?> { preservedSelection ?? $ownedID }
    /// 同上：滚动位置与「当前条」分开，停住才切当前条
    @State private var scrollPos: String?
    @State private var preloader = DYPreloader()
    @State private var resume: [String: Double] = [:]
    @State private var liked: Set<String> = []
    @State private var collected: Set<String> = []

    var body: some View {
        let m = list.model(bridge)
        ZStack {
            if m.items.isEmpty {
                VStack(spacing: 12) {
                    if let e = m.error {
                        Text(e).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        HStack {
                            Button("重试") {
                                m.reset(); currentID.wrappedValue = nil
                                Task {
                                    await m.loadMore()
                                    currentID.wrappedValue = DYFollowFeedSelection.restored(preserved: nil, ids: m.items.map(\.id))
                                }
                            }
                                .buttonStyle(.borderedProminent)
                            Button("登录") { onLogin() }.buttonStyle(.bordered)
                        }
                    } else if m.loading || m.hasMore {
                        ProgressView().tint(.primary)
                        Text("加载关注…").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("关注的人还没有新作品").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    DYPagerStack(items: m.items, currentID: currentID.wrappedValue, page: { item in
                            DYVideoPage(item: item, isCurrent: active && item.id == currentID.wrappedValue, insets: insets,
                                        resume: resume[item.id], liked: liked.contains(item.id) || item.userDigged == 1,
                                        collected: collected.contains(item.id) || item.isCollect == 1,
                                        onLike: { like(item.id, force: nil) }, onCollect: { collect(item.id) },
                                        onDoubleTap: { like(item.id, force: true) }, onComments: { onComments(item) },
                                        onAuthor: { onAuthor(item) }, onSavePosition: { resume[item.id] = $0 },
                                        preloader: preloader, bridge: bridge, onToast: onToast,
                                        onNavigateLeft: onChannelDrag == nil ? onShowRecommendations : nil,
                                        onChannelDrag: onChannelDrag, onChannelDragEnd: onChannelDragEnd)
                    })
                    .scrollTargetLayout()
                    .background(DYPagingSpeedBridge(ids: m.items.map(\.id), currentID: currentID))
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrollPos, anchor: .center)
                .onAppear { scrollPos = currentID.wrappedValue }
                .onChange(of: currentID.wrappedValue) { _, new in if scrollPos != new { scrollPos = new } }
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.follow.feed")
        .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { value in
            guard m.items.isEmpty, let onChannelDrag,
                  abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
            onChannelDrag(value.translation.width, 0)
        }.onEnded { value in
            if let onChannelDragEnd, m.items.isEmpty {
                let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.2
                if horizontal {
                    onChannelDragEnd(value.translation.width, value.predictedEndTranslation.width, 0, false)
                } else {
                    onChannelDragEnd(0, 0, 0, true)
                }
                return
            }
            guard m.items.isEmpty, value.translation.width < -60,
                  abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
            onShowRecommendations?()
        })
        .task {
            #if DEBUG
            // Exercise the real following player without requiring an account.
            if ProcessInfo.processInfo.environment["DOUDUO_COMMENT_ENTRY"] == "follow",
               let id = ProcessInfo.processInfo.environment["DOUDUO_VIDEO_ID"],
               let item = try? await bridge.awemeDetail(id) {
                m.items = [item]; m.hasMore = false; currentID.wrappedValue = item.id
                return
            }
            #endif
            if m.items.isEmpty { await m.loadMore() }
            let restored = DYFollowFeedSelection.restored(preserved: currentID.wrappedValue, ids: m.items.map(\.id))
            if currentID.wrappedValue != restored { currentID.wrappedValue = restored }
        }
        .onChange(of: currentID.wrappedValue) { old, new in
            if new == nil, let old, m.items.contains(where: { $0.id == old }) { currentID.wrappedValue = old; return }
            guard let i = m.items.firstIndex(where: { $0.id == new }) else { return }
            preloader.update(m.items, current: i)
            if i >= m.items.count - 4 { Task { await m.loadMore() } }
        }
        // 关注页只放关注作品。关注主播开播统一走直播页的「我的关注」。
        .onChange(of: active) { _, a in if !a { preloader.clear() } }
        .onDisappear { preloader.clear() }
    }

    private func like(_ id: String, force: Bool?) {
        let has = liked.contains(id), want = force ?? !has
        guard want != has else { return }
        if want { liked.insert(id) } else { liked.remove(id) }
        Task {
            let r = try? await bridge.digg(id, like: want)
            if case .ok = r { return }
            if want { liked.remove(id) } else { liked.insert(id) }
            onToast("点赞失败")
        }
    }

    private func collect(_ id: String) {
        let want = !collected.contains(id)
        if want { collected.insert(id) } else { collected.remove(id) }
        Task {
            let r = try? await bridge.favorite(id, add: want)
            if case .ok = r { onToast(want ? "已收藏" : "已取消收藏"); return }
            if want { collected.remove(id) } else { collected.insert(id) }
            onToast("收藏失败")
        }
    }
}

/// DYPagedModel 需要 bridge 才能建，StateObject 包一层延迟创建
@MainActor
final class DYPagedModelHolder: ObservableObject {
    private var m: DYPagedModel?
    private var sub: Any?
    func model(_ b: DouyinBridge) -> DYPagedModel {
        if let m { return m }
        let n = DYPagedModel { cur in try await b.followFeed(cursor: cur) }
        sub = n.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        m = n
        return n
    }

    func resetModel() {
        sub = nil
        m = nil
        objectWillChange.send()
    }
}


#if DEBUG
/// 真机自检：用 App 里真实的接口函数逐个跑一遍（登录态），结果写 ddlog，不用点界面
@MainActor enum DDSelfTest {
    static func run(_ b: DouyinBridge) async {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        func log(_ s: String) { DYLiveModel.log("DDSELF " + s) }
        await b.debugExportCookies()
        do { let u = try await b.selfProfile(); log("self ok name=\(u.name) likes=\(u.likes) works=\(u.works) sec=\(u.secUid.prefix(10))") }
        catch { log("self FAIL \(error.localizedDescription)") }
        for k in DYListKind.allCases {
            do {
                let r = try await b.myList(k, cursor: "0")
                let playable = r.items.filter { $0.play != nil || !$0.images.isEmpty }.count
                log("\(k.title) ok n=\(r.items.count) playable=\(playable) more=\(r.hasMore) cur=\(r.cursor) first=\(r.items.first?.desc.prefix(16) ?? "-")")
                if r.hasMore {
                    let r2 = try await b.myList(k, cursor: r.cursor)
                    log("\(k.title) page2 n=\(r2.items.count) dup=\(Set(r.items.map(\.id)).intersection(r2.items.map(\.id)).count)")
                }
            } catch { log("\(k.title) FAIL \(error.localizedDescription)") }
        }
        do { let r = try await b.followFeed(cursor: "0"); log("关注 ok n=\(r.items.count) more=\(r.hasMore) first=\(r.items.first?.author.name ?? "-")") }
        catch { log("关注 FAIL \(error.localizedDescription)") }
        do {
            let r = try await b.search("猫", offset: "0")
            log("搜索 ok n=\(r.items.count) more=\(r.hasMore) cur=\(r.cursor) first=\(r.items.first?.desc.prefix(16) ?? "-")")
            if r.hasMore { let r2 = try await b.search("猫", offset: r.cursor); log("搜索 page2 n=\(r2.items.count)") }
        } catch { log("搜索 FAIL \(error.localizedDescription)") }
        let sug = await b.suggest("猫"); log("联想 n=\(sug.count) first=\(sug.first?.word ?? "-")")
        log("done")
    }
}
#endif


extension ToolbarContent {
    @ToolbarContentBuilder func dyVerticalPreferred() -> some ToolbarContent {
        if #available(iOS 27.1, *) { self.axisBehavior(.verticalPreferred) }
        else { self }
    }
}



#if DEBUG
private struct DYSelfProfileBackdropPreview: View {
    let cover: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DYUserHeader(user: DYUser(
                name: "预览", avatar: nil, signature: "封面预览",
                secUid: "preview", uid: "0", followers: 12, following: 3,
                likes: 40, works: 5, ip: nil, cover: cover))
                .padding(16)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) { DYSelfProfileBackdrop(cover: cover) }
        .background(Color.ddBackground)
    }
}

#Preview("无封面") {
    DYSelfProfileBackdropPreview(cover: nil)

}

#Preview("无效地址") {
    DYSelfProfileBackdropPreview(cover: "not a url")

}
#endif
