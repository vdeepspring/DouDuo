// 评论「先上屏」：点发送后先在列表里放一条本地评论，成功换成抖音回来的那条，失败就地显示重发。
// 参照官方抖音 41.2.0 的 fakeCommentID / isFakePost / CommentNewCellPostRetryView（仅静态符号证据）。
import Foundation

/// 发送结果确定不了（写请求可能已经到了抖音）：界面不能当失败让人直接重发，要先核对。
struct DYCommentUnconfirmed: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 一条还没被抖音确认的本地评论
struct DYPendingSend {
    enum State: Equatable {
        case sending
        /// 明确没发出去（没就绪、被拒、图没传上），可以直接重发
        case failed(String)
        /// 结果不明，可能已经发出；重发前要先核对或二次确认
        case unknown(String)
    }
    static let prefix = "local-"
    static func isLocal(_ id: String) -> Bool { id.hasPrefix(prefix) }

    let text: String
    var imageDraft: DYCommentImageDraft?
    var uploaded: DYImageXUploadResult?
    /// 一级评论 cid（回复时）与被回复的楼中楼 cid
    let top: String?
    let replyTo: String?
    /// 「改一改」时把回复目标还给输入框
    let replyTarget: DYComment?
    let sentAt: Double
    var state: State = .sending
}

/// 评论草稿：按「作品 + 回复目标」存在本机，关掉评论区或 App 被杀也不丢。只存文字，3 天过期，最多 50 条。
enum DYCommentDraftStore {
    static let key = "douyin_comment_drafts_v1"
    static let maxAge: TimeInterval = 3 * 86_400
    static let capacity = 50
    struct Entry: Codable, Equatable { var text: String; var at: Date }

    static func id(_ aweme: String, top: String?, to: String?) -> String {
        [aweme, top ?? "0", to ?? "0"].joined(separator: ":")
    }

    static func load(_ id: String, now: Date = Date(), defaults: UserDefaults = .standard) -> String? {
        guard let e = read(defaults)[id], now.timeIntervalSince(e.at) <= maxAge,
              !e.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return e.text
    }

    static func save(_ id: String, text: String, now: Date = Date(), defaults: UserDefaults = .standard) {
        var all = read(defaults).filter { now.timeIntervalSince($0.value.at) <= maxAge }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { all[id] = nil }
        else { all[id] = Entry(text: text, at: now) }
        if all.count > capacity {
            for k in all.sorted(by: { $0.value.at < $1.value.at }).prefix(all.count - capacity).map(\.key) { all[k] = nil }
        }
        if let d = try? JSONEncoder().encode(all) { defaults.set(d, forKey: key) }
    }

    static func remove(_ id: String, defaults: UserDefaults = .standard) { save(id, text: "", defaults: defaults) }

    private static func read(_ defaults: UserDefaults) -> [String: Entry] {
        guard let d = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: d)) ?? [:]
    }
}
