import Foundation

struct DYHashtagFilter {
    static let storageKey = "douyin_blocked_hashtags_v1"
    private(set) var tags: [String]
    private var keys: Set<String>

    init(rawValue: String = "") {
        let saved = (try? JSONDecoder().decode([String].self, from: Data(rawValue.utf8))) ?? []
        var seen = Set<String>()
        tags = saved.compactMap { DYHashtag.name(from: $0) }
            .filter { seen.insert(DYHashtag.key($0)).inserted }
        keys = seen
    }

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(tags) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    func contains(_ tag: String) -> Bool { keys.contains(DYHashtag.key(tag)) }

    func blocks(description: String, knownNames: [String] = []) -> Bool {
        guard !keys.isEmpty else { return false }
        return DYHashtag.names(in: description, knownNames: knownNames).contains(where: contains)
    }

    enum AddResult { case added, duplicate, invalid }

    mutating func add(_ input: String) -> AddResult {
        guard let tag = DYHashtag.name(from: input) else { return .invalid }
        guard keys.insert(DYHashtag.key(tag)).inserted else { return .duplicate }
        tags.append(tag)
        return .added
    }

    mutating func remove(_ tag: String) {
        keys.remove(DYHashtag.key(tag))
        tags.removeAll { DYHashtag.key($0) == DYHashtag.key(tag) }
    }
}

extension DYAweme {
    var hashtags: [String] { DYHashtag.names(in: desc, knownNames: hashtagNames ?? []) }
}

/// 推荐内容偏好：只放竖屏内容 / 只看短视频（设置 → 内容偏好）
enum DYContentPrefs {
    static let portraitOnlyKey = "douyin_portrait_only_v3"
    /// 只看短视频的时长上限（秒），0 = 不限
    static let shortMaxKey = "douyin_short_max_v1"
    static let shortChoices: [(Int, String)] = [(0, "不限"), (60, "1 分钟内"), (180, "3 分钟内"), (300, "5 分钟内")]

    /// 图集不算时长，一律放行；拿不到时长（0）的视频在限定时不放，免得混进长视频
    static func passesShort(_ a: DYAweme, max: Int) -> Bool {
        max <= 0 || !a.images.isEmpty || (a.duration > 0 && a.duration <= Double(max))
    }
}
