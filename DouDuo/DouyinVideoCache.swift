// 本地视频缓存：推荐流播放时，后台把后面 N 条（默认 50）完整下载到 Caches/dd-videos/。
// - 下滑到已缓存的条目直接播本地文件，不等网络
// - 下次打开 App 先播「已缓存、还没看过」的，连接抖音放到后台
// - 超过上限先删看过的、再删最早的
import Foundation
import UIKit

/// 浏览会话保存在 Application Support，不随视频缓存清理或系统回收而丢失。
struct DYFeedSession: Codable {
    var items: [DYAweme]
    var currentID: String
    var positions: [String: Double]

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("feed-session.json")
    }
    static func load() -> DYFeedSession? {
        guard let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(Self.self, from: data),
              session.items.contains(where: { $0.id == session.currentID }) else { return nil }
        return session
    }
    /// 后台串行写：推荐列表能有上百条，每 5 秒在主线程整份 JSON 编码 + 落盘会让播放一顿
    private static let saveQueue = DispatchQueue(label: "douduo.session", qos: .utility)
    /// 只写最新一份：排队期间又来了新的，旧的直接丢弃
    private static var pendingGen = 0
    private static let genLock = NSLock()

    func save() {
        guard items.contains(where: { $0.id == currentID }) else { return }
        let snapshot = self
        Self.genLock.lock(); Self.pendingGen += 1; let gen = Self.pendingGen; Self.genLock.unlock()
        Self.saveQueue.async {
            Self.genLock.lock(); let latest = Self.pendingGen; Self.genLock.unlock()
            guard gen == latest, let data = try? JSONEncoder().encode(snapshot) else { return }
            do { try data.write(to: Self.url, options: .atomic) }
            catch { DYLiveModel.log("DDSESSION 保存失败 \(error.localizedDescription)") }
        }
    }
}

actor DYVideoCache {
    static let shared = DYVideoCache()
    static let countKey = "douyin_cache_count_v1"
    static let defaultCount = 50
    /// 超过这个时长的不整条下载（太大），仍走在线播放 + 内存预缓冲
    static let maxDuration: Double = 300
    /// 磁盘总量上限（条数没到也按这个删，长视频单条能有 100MB）
    static let maxBytes = 2 * 1024 * 1024 * 1024

    struct Entry: Codable {
        var aweme: DYAweme
        var watched: Bool
        var added: Double
        var bytes: Int
    }

    nonisolated static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("dd-videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    nonisolated static var indexURL: URL { dir.appendingPathComponent("index.json") }

    nonisolated static var limit: Int {
        (UserDefaults.standard.object(forKey: countKey) as? Int) ?? defaultCount
    }

    /// 已经下完的本地文件（同步，播放器建 item 时直接用）
    nonisolated static func localURL(_ id: String) -> URL? {
        let f = dir.appendingPathComponent("\(id).mp4")
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// 启动时用：缓存好、还没看过的，按加入顺序
    nonisolated static func pendingSnapshot() -> [DYAweme] {
        guard let d = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return list.filter { !$0.watched && localURL($0.aweme.id) != nil }.map(\.aweme)
    }

    private var entries: [Entry]
    private var queue: [DYAweme] = []
    private var active: Set<String> = []
    private var failed: Set<String> = []
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        if let d = try? Data(contentsOf: Self.indexURL), let list = try? JSONDecoder().decode([Entry].self, from: d) {
            entries = list.filter { Self.localURL($0.aweme.id) != nil }
        } else {
            entries = []
        }
    }

    /// 当前位置之后的列表（按顺序），排队下载；已下 / 正在下 / 失败过的跳过
    /// 紧挨着的这几条由 DYPreloader（ahead = 3）的 AVPlayer 边播边缓冲，这里再整条下载就是同一视频下两遍
    static let skipNearest = 3   // = DYPreloader.ahead

    func enqueue(_ ahead: [DYAweme]) {
        let lim = Self.limit
        guard lim > 0 else { queue = []; return }
        let have = Set(entries.map(\.aweme.id))
        queue = ahead.prefix(lim).dropFirst(Self.skipNearest).filter { a in
            a.images.isEmpty && a.play != nil && a.duration <= Self.maxDuration
                && !have.contains(a.id) && !active.contains(a.id) && !failed.contains(a.id)
        }
        // 图文：图片走图片缓存
        for a in ahead.prefix(lim) where !a.images.isEmpty {
            for s in a.images.prefix(9) { if let u = URL(string: s) { Task { _ = await ImageCache.shared.load(u) } } }
        }
        pump()
    }

    func markWatched(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.aweme.id == id }), !entries[i].watched else { return }
        entries[i].watched = true
        save()
    }

    func usage() -> (count: Int, bytes: Int) {
        (entries.count, entries.reduce(0) { $0 + $1.bytes })
    }

    func clear() -> Int {
        let bytes = entries.reduce(0) { $0 + $1.bytes }
        queue = []
        entries = []
        if let files = try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        return bytes
    }

    // MARK: 下载

    /// 正在后台下载的条数（调试日志用，不要求精确）
    nonisolated(unsafe) static var activeDownloads = 0

    /// 一次只下一条（两条并发 + 预加载播放器一起抢带宽、还持续发热）；手机发烫（serious 及以上）就先不开新下载，
    /// 下次滑动 / 下完一条时再看
    private func pump() {
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            DYLiveModel.log("DDCACHE paused thermal=\(ProcessInfo.processInfo.thermalState.rawValue) queued=\(queue.count)")
            return
        }
        while active.count < 1, !queue.isEmpty {
            let a = queue.removeFirst()
            guard let s = a.play, let u = URL(string: s) else { continue }
            active.insert(a.id)
            Self.activeDownloads = active.count
            // 低优先级：别跟正在看的那条抢带宽（URLSession 会按 Task 优先级排）
            Task(priority: .background) { await self.download(a, u) }
        }
    }

    private func download(_ a: DYAweme, _ u: URL) async {
        var r = URLRequest(url: u)
        DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        let t0 = Date()
        do {
            let (tmp, resp) = try await session.download(for: r)
            if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw URLError(.badServerResponse) }
            let dst = Self.dir.appendingPathComponent("\(a.id).mp4")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: dst.path)[.size]) as? Int) ?? 0
            guard bytes > 50_000 else { try? FileManager.default.removeItem(at: dst); throw URLError(.zeroByteResource) }
            entries.removeAll { $0.aweme.id == a.id }
            entries.append(Entry(aweme: a, watched: false, added: Date().timeIntervalSince1970, bytes: bytes))
            evict()
            save()
            DYLiveModel.log("DDCACHE ok \(a.id) \(bytes / 1024)KB \(String(format: "%.1f", Date().timeIntervalSince(t0)))s total=\(entries.count)")
        } catch {
            failed.insert(a.id)
            DYLiveModel.log("DDCACHE fail \(a.id) \(error.localizedDescription)")
        }
        active.remove(a.id)
        Self.activeDownloads = active.count
        pump()
    }

    /// 超上限：先删看过的（最早的先删），还超就删最早加进来的
    private func evict() {
        let lim = max(Self.limit, 0)
        while entries.count > lim || (entries.count > 1 && entries.reduce(0, { $0 + $1.bytes }) > Self.maxBytes) {
            let idx = entries.firstIndex(where: \.watched) ?? 0
            let e = entries.remove(at: idx)
            try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent("\(e.aweme.id).mp4"))
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: Self.indexURL, options: .atomic) }
    }
}
