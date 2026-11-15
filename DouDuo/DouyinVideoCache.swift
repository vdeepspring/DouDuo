// 本地视频缓存：
// - 正在播的这条：立刻开始缓存（长视频只缓存头部），划走就停
// - 后面 1–2 条：只预取头部，刷到时能本地起播
// - 完整缓存的条目下次刷到/重开 App 直接播本地
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
    /// 串行队列：保证后写的会话不会被先写的覆盖。
    private static let saveQueue = DispatchQueue(label: "me.rrmm.douduo.feed-session", qos: .utility)
    /// 编码整份列表 + 原子写盘放到后台：每次换条要存两次（换条 + 上一条存进度），在主线程上做会卡滑动。
    func save() {
        guard items.contains(where: { $0.id == currentID }) else { return }
        let snapshot = self
        Self.saveQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            do { try data.write(to: Self.url, options: .atomic) }
            catch { DYLiveModel.log("DDSESSION 保存失败 \(error.localizedDescription)") }
        }
    }
}

actor DYVideoCache {
    static let shared = DYVideoCache()
    static let countKey = "douyin_cache_count_v2"
    static let defaultCount = 5
    /// 超过这个时长不缓存（整条太大），直接在线播。30 分钟以内整条下，长视频切换也能秒开
    static let maxDuration: Double = 1800
    /// 长视频（>10 分钟）预存的体积：文件第一段（1/4 或这个下限，取大者），够起播和看几分钟
    static let longHeadBytes = 32 * 1024 * 1024
    /// 超过这个时长算长视频：只预存第一段，播起来 10 秒后再并发补后面几段（老板定的策略）
    static let longThreshold: Double = 600
    /// 「已看过」的缓存最多留几条：看过的没必要占盘，重启也不该再刷到
    static let watchedKeep = 3
    /// 单条缓存体积上限（估算）：超过就不整条下，避免 20 分钟以上的大片把盘和带宽吃满
    static let sizeCap: Double = 400 * 1024 * 1024
    /// 不超过这个时长的算短视频：整条几秒内下完，优先下；更长的排在后面，不堵下一条
    static let blockingDuration: Double = 90
    /// 头部缓存字节数：约 6–20 秒（抖音码率 0.5–3 Mbps），够起播
    static let headBytes = 4_000_000
    /// 后面几条做头部预取（刷过来不卡的关键）
    static let headPrefetch = 2
    /// 保守按 3.2 Mbps 折算，宁可早一点切在线流，也不要播到没数据的尾部
    static let assumeBitsPerSecond: Double = 2_500_000
    static let maxBytes = 2 * 1024 * 1024 * 1024

    struct Entry: Codable {
        var aweme: DYAweme
        var watched: Bool
        var added: Double
        var bytes: Int
    }
    /// 头部缓存索引
    struct Head: Codable {
        var id: String
        var bytes: Int
        var added: Double
    }

    nonisolated static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("dd-videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    nonisolated static var indexURL: URL { dir.appendingPathComponent("index.json") }
    nonisolated static var headIndexURL: URL { dir.appendingPathComponent("heads.json") }
    nonisolated static func fileURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).mp4") }
    nonisolated static func headURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).head") }

    nonisolated static var limit: Int {
        (UserDefaults.standard.object(forKey: countKey) as? Int) ?? defaultCount
    }

    /// 已经整条下完的本地文件
    nonisolated static func localURL(_ id: String) -> URL? {
        let f = fileURL(id)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// 头部缓存（够起播即可）
    nonisolated static func headFile(_ id: String) -> URL? {
        let f = headURL(id)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size]) as? Int, size > 120_000 else { return nil }
        return f
    }

    /// 头部缓存能安全播到的秒数（保守折算，留 1.5 秒余量）
    nonisolated static func headPlayableSeconds(_ id: String) -> Double? {
        guard let f = headFile(id),
              let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size]) as? Int else { return nil }
        // 估算能播到第几秒：按平均码率算，再留 20% 余量（宁可早一点交接，也别播到没数据卡住）
        let s = Double(size) * 8 / assumeBitsPerSecond * 0.8 - 1.5
        return s > 1 ? s : nil
    }

    /// 启动时用：缓存好、还没看过的，按加入顺序
    nonisolated static func pendingSnapshot() -> [DYAweme] {
        guard let d = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return list.filter { !$0.watched && localURL($0.aweme.id) != nil }.map(\.aweme)
    }

    /// 调试日志用（不要求精确）
    nonisolated(unsafe) static var activeDownloads = 0

    private var entries: [Entry]
    private var heads: [Head]
    private var job: Task<Void, Never>?
    private var jobID: String?
    private var failed: Set<String> = []
    /// async 方法里不直接引用 DYAweme 作为参数类型（该编译器在此处解析失败），改用它中转
    private var pending: [String: DYAweme] = [:]
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        if let d = try? Data(contentsOf: Self.indexURL), let list = try? JSONDecoder().decode([Entry].self, from: d) {
            entries = list.filter { Self.localURL($0.aweme.id) != nil }
        } else {
            entries = []
        }
        if let d = try? Data(contentsOf: Self.headIndexURL), let list = try? JSONDecoder().decode([Head].self, from: d) {
            heads = list.filter { Self.headFile($0.id) != nil }
        } else {
            heads = []
        }
    }

    /// 播放焦点变了：下一条最优先（刷过去就要播），然后当前这条。
    /// 1.5.1 以前是「当前 → 下下条 → 第 4 条」：紧挨着的下一条被漏掉；当前是长视频时要整条下完才轮到后面，
    /// 下载还和下一条的预加载抢带宽，一划走整条作废。现在 ≤90 秒的先下（几秒完成），
    /// 长一些的（≤10 分钟）排在后面补；超过 10 分钟不缓存，起播靠预加载器提前读好的开头。
    /// 长视频只预存「第一段」的顺序（当前正在播的那条不抢带宽）
    nonisolated static func longHeadPlan(current: DYAweme, ahead: [DYAweme]) -> [String] {
        func long(_ a: DYAweme) -> Bool { a.images.isEmpty && a.play != nil && a.duration > longThreshold }
        var out: [String] = []
        for a in ahead where long(a) && !out.contains(a.id) { out.append(a.id) }
        return out
    }

    /// 长视频「第一段」预存队列：**不跟随 focus 取消**——老板实测滑动一快就被取消，
    /// 长视频永远拿不到预存段，只能联网慢等（日志里一排 DDHEAD fail cancelled）。
    /// 播放卡在等待数据时，下载自动让路（busy 门闸），把带宽留给播放器。
    private var headQueue: [String] = []
    private var headTask: Task<Void, Never>?
    /// 播放器正在等数据（起播/卡顿）时为 true，缓存下载暂停让路
    private var playbackWaiting = false

    func setPlaybackWaiting(_ v: Bool) { playbackWaiting = v }

    /// 播放器直接调用（不 await）：起播/卡顿时让缓存下载让路
    nonisolated func reportPlaybackWaiting(_ v: Bool) {
        Task { await setPlaybackWaiting(v) }
    }

    private func waitWhilePlaybackWaiting() async {
        var n = 0
        while playbackWaiting && n < 40 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            n += 1
        }
    }

    private func enqueueHeads(_ ids: [String]) {
        for id in ids where !headQueue.contains(id) && Self.headFile(id) == nil {
            headQueue.append(id)
        }
        guard headTask == nil, !headQueue.isEmpty else { return }
        headTask = Task { [weak self] in
            guard let self else { return }
            await self.drainHeads()
        }
    }

    /// 逐个把长视频第一段存好；不会因为切视频被取消
    private func drainHeads() async {
        while !headQueue.isEmpty {
            let id = headQueue.removeFirst()
            if Self.headFile(id) != nil || Self.localURL(id) != nil { continue }
            await waitWhilePlaybackWaiting()
            await storeLongHead(id: id)
        }
        headTask = nil
    }

    func focus(current: DYAweme?, ahead: [DYAweme]) {
        guard Self.limit > 0 else { job?.cancel(); job = nil; jobID = nil; return }
        let target = current ?? ahead.first
        guard let target else { return }
        if jobID == target.id, job != nil { return }
        if job != nil { DYLiveModel.log("DDCACHE refocus \(jobID ?? "-") -> \(target.id)") }
        job?.cancel()
        job = nil
        jobID = target.id
        let rest = current == nil ? Array(ahead.dropFirst()) : ahead
        let follow = Array(rest.prefix(Self.headPrefetch))
        let plan = Self.plan(current: target, ahead: follow)
        let longIDs = Self.longHeadPlan(current: target, ahead: follow)
        for a in [target] + follow { pending[a.id] = a }
        // 半截文件播不了（-11828），预存第一段已经没有意义：长视频改为整条后台缓存。
        // 这里不再入队，避免白占 30MB 带宽和磁盘；已有头段文件启动时清掉。
        _ = longIDs
        job = Task { [weak self] in
            guard let self else { return }
            for id in plan {
                if Task.isCancelled { return }
                await self.store(id: id)
            }
        }
    }

    /// 整条缓存的顺序（纯函数，脚本测试直接跑）：
    /// 先下一条、当前、再后面一条里的短视频（≤90 秒），再补长视频（当前 → 下一条 → 后面），超 10 分钟的不排。
    nonisolated static func plan(current: DYAweme, ahead: [DYAweme]) -> [String] {
        func playable(_ a: DYAweme) -> Bool { a.images.isEmpty && a.play != nil }
        func quick(_ a: DYAweme) -> Bool { a.duration > 0 && a.duration <= blockingDuration }
        /// 能整条下：时长在范围内、估算体积不至于太大
        func cacheable(_ a: DYAweme) -> Bool {
            a.duration > 0 && a.duration <= maxDuration
                && a.duration * assumeBitsPerSecond / 8 <= sizeCap
        }
        let next = Array(ahead.prefix(1)), later = Array(ahead.dropFirst())
        // 正在播的这条：短的下完不碍事；长的（还在联网播）绝不同时整条下载，
        // 否则下载和播放抢同一条连接，起播要等到十秒以上（实测 dur=1228 等了 11.78s 还没起）
        let currentIsLong = current.duration > longThreshold && localURL(current.id) == nil
        let order = (currentIsLong ? [] : [current]) + next + later
        var out: [String] = []
        for a in order where playable(a) && quick(a) && cacheable(a) && !out.contains(a.id) { out.append(a.id) }
        for a in order where playable(a) && !quick(a) && cacheable(a) && !out.contains(a.id) { out.append(a.id) }
        return out
    }

    /// 划走 / 离开：立刻停止缓存
    func stopCaching() {
        job?.cancel(); job = nil; jobID = nil
    }

    /// 只缓存整条视频：不再存「头部」，也就没有「头部播完接在线流」那一下切换
    /// （切换必然有一瞬闪烁/缓冲，长痛不如短痛）
    private func store(id: String) async {
        guard let a = pending[id], a.images.isEmpty, a.play != nil else { return }
        if Self.localURL(a.id) != nil { return }
        if failed.contains(a.id) { return }
        await waitWhilePlaybackWaiting()
        // 超长的视频整条太大，干脆不缓存，直接走在线流（不会闪，只是首帧慢一点）
        guard a.duration <= Self.maxDuration else { return }
        if Task.isCancelled { return }
        await storeFull(id: id)
    }

    /// 头部缓存：Range 请求前 2.5MB（服务端忽略 Range 返回整条时截取前段）
    /// 抖音直连 CDN 的 play 地址对 App 自己的请求会 403（播放器能播）；
    /// 实测 `/aweme/v1/play/`（带 sign，302 跳 CDN）和 playFast 可以正常下载。
    private func downloadURLs(_ a: DYAweme) -> [URL] {
        // 重定向地址优先（直连 CDN 现在 403），失败再试直连和低清
        [a.play, a.playAlt, a.playFast].compactMap { $0 }.compactMap { URL(string: $0) }
    }

    private func storeHead(id: String) async {
        guard let a = pending[id] else { return }
        let t0 = Date()
        Self.activeDownloads = 1
        defer { Self.activeDownloads = 0 }
        for u in downloadURLs(a) {
            if Task.isCancelled { return }
            var r = URLRequest(url: u)
            DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            r.setValue("bytes=0-\(Self.headBytes - 1)", forHTTPHeaderField: "Range")
            do {
                let (data, resp) = try await session.data(for: r)
                guard let h = resp as? HTTPURLResponse else { continue }
                guard h.statusCode == 200 || h.statusCode == 206 else {
                    DYLiveModel.log("DDHEAD status=\(h.statusCode) host=\(u.host ?? "-") id=\(a.id)")
                    continue
                }
                let slice = data.count > Self.headBytes ? data.prefix(Self.headBytes) : data
                guard slice.count > 120_000 else { continue }
                try slice.write(to: Self.headURL(a.id))
                heads.removeAll { $0.id == a.id }
                heads.append(Head(id: a.id, bytes: slice.count, added: Date().timeIntervalSince1970))
                let cap = max(Self.limit * 2, 40)
                if heads.count > cap { heads.removeFirst(heads.count - cap) }
                saveHeads()
                DYLiveModel.log("DDHEAD ok \(a.id) \(slice.count / 1024)KB host=\(u.host ?? "-") \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
                return
            } catch {
                DYLiveModel.log("DDHEAD fail host=\(u.host ?? "-") \(error.localizedDescription)")
            }
        }
        if !Task.isCancelled { failed.insert(a.id) }
    }

    /// 长视频预存第一段：探测总长后取 1/4（不少于 32MB），存成 .head 文件。
    /// MP4 的 moov 在文件开头（实测），所以这半截可以直接播；播过 10 秒后再补后面几段。
    private func storeLongHead(id: String) async {
        guard let a = pending[id], Self.headFile(a.id) == nil else { return }
        let t0 = Date()
        await waitWhilePlaybackWaiting()
        for u in downloadURLs(a) {
            if Task.isCancelled { return }
            var probe = URLRequest(url: u)
            DYMedia.headers.forEach { probe.setValue($1, forHTTPHeaderField: $0) }
            probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            do {
                let (first, resp) = try await session.download(for: probe)
                defer { try? FileManager.default.removeItem(at: first) }
                guard let h = resp as? HTTPURLResponse, h.statusCode == 206 || h.statusCode == 200 else { continue }
                var total = 0
                if let cr = h.value(forHTTPHeaderField: "Content-Range"),
                   let n = Int(cr.split(separator: "/").last ?? "") { total = n }
                let want = max(Self.longHeadBytes, total / 4)
                var r = URLRequest(url: u)
                DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
                r.setValue("bytes=0-\(want - 1)", forHTTPHeaderField: "Range")
                let (tmp, resp2) = try await session.download(for: r)
                guard let h2 = resp2 as? HTTPURLResponse, h2.statusCode == 206 || h2.statusCode == 200 else { continue }
                let dst = Self.headURL(a.id)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.moveItem(at: tmp, to: dst)
                let bytes = ((try? FileManager.default.attributesOfItem(atPath: dst.path)[.size]) as? Int) ?? 0
                guard bytes > 200_000 else { try? FileManager.default.removeItem(at: dst); continue }
                heads.removeAll { $0.id == a.id }
                heads.append(Head(id: a.id, bytes: bytes, added: Date().timeIntervalSince1970))
                let cap = max(Self.limit * 2, 40)
                if heads.count > cap { heads.removeFirst(heads.count - cap) }
                saveHeads()
                DYLiveModel.log("DDHEAD ok \(a.id) \(bytes / 1024)KB/\(total / 1024)KB host=\(u.host ?? "-") \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
                return
            } catch {
                DYLiveModel.log("DDHEAD fail host=\(u.host ?? "-") \(error.localizedDescription)")
            }
        }
    }

    /// 长视频播起来 10 秒后，把剩下的部分并发补齐，拼成完整文件（下次直接本地起播）
    func completeLong(id: String) async {
        guard Self.localURL(id) == nil, let head = Self.headFile(id) else { return }
        await waitWhilePlaybackWaiting()
        guard let a = pending[id] ?? entries.first(where: { $0.aweme.id == id })?.aweme else { return }
        guard let u = downloadURLs(a).first else { return }
        let have = ((try? FileManager.default.attributesOfItem(atPath: head.path)[.size]) as? Int) ?? 0
        let t0 = Date()
        var probe = URLRequest(url: u)
        DYMedia.headers.forEach { probe.setValue($1, forHTTPHeaderField: $0) }
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (first, resp) = try? await session.download(for: probe), let h = resp as? HTTPURLResponse else { return }
        try? FileManager.default.removeItem(at: first)
        guard let cr = h.value(forHTTPHeaderField: "Content-Range"), let total = Int(cr.split(separator: "/").last ?? ""),
              total > have else { return }
        let rest = total - have
        let parts = min(4, max(1, rest / (4 * 1024 * 1024)))
        let size = rest / parts
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ddrest-\(id)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let files = try await withThrowingTaskGroup(of: (Int, URL).self) { group -> [URL] in
                for i in 0..<parts {
                    let lo = have + i * size
                    let hi = i == parts - 1 ? total - 1 : (lo + size - 1)
                    group.addTask {
                        var r = URLRequest(url: u)
                        DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
                        r.setValue("bytes=\(lo)-\(hi)", forHTTPHeaderField: "Range")
                        let (tmp, resp) = try await self.session.download(for: r)
                        guard let sh = resp as? HTTPURLResponse, sh.statusCode == 206 || sh.statusCode == 200 else { throw URLError(.badServerResponse) }
                        let named = dir.appendingPathComponent(String(format: "%03d", i))
                        try? FileManager.default.removeItem(at: named)
                        try FileManager.default.moveItem(at: tmp, to: named)
                        return (i, named)
                    }
                }
                var out = [URL](repeating: dir, count: parts)
                for try await (i, f) in group { out[i] = f }
                return out
            }
            let dst = Self.fileURL(id)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: head, to: dst)
            let out = try FileHandle(forWritingTo: dst)
            out.seekToEndOfFile()
            for f in files {
                let fh = try FileHandle(forReadingFrom: f)
                while let chunk = try fh.read(upToCount: 4 << 20), !chunk.isEmpty { try out.write(chunk) }
                try fh.close()
                try? FileManager.default.removeItem(at: f)
            }
            try out.close()
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: dst.path)[.size]) as? Int) ?? 0
            guard bytes >= total - 1024 else { try? FileManager.default.removeItem(at: dst); return }
            try? FileManager.default.removeItem(at: head)
            heads.removeAll { $0.id == id }
            saveHeads()
            entries.removeAll { $0.aweme.id == id }
            entries.append(Entry(aweme: a, watched: false, added: Date().timeIntervalSince1970, bytes: bytes))
            evict(); save()
            DYLiveModel.log("DDCACHE 长视频补齐 \(id) \(bytes / 1024)KB \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        } catch {
            DYLiveModel.log("DDCACHE 长视频补齐失败 \(id) \(error.localizedDescription)")
        }
    }

    /// 整条缓存（≤300 秒的视频才做；划走会取消，头部缓存已留下）
    /// 分段并发下载：4 条 Range 连接同时拉，再按顺序拼成一个文件。
    /// 单连接对长视频太慢（实测 100MB 用 3.7s，20 分钟的大片要几十秒），分段后基本能跑满带宽。
    private static let segments = 4
    /// 小于这个体积就单连接，分段反而多几次握手
    private static let segmentMinBytes = 6 * 1024 * 1024

    private func storeFull(id: String) async {
        guard let a = pending[id] else { return }
        let t0 = Date()
        for u in downloadURLs(a) {
            if Task.isCancelled { return }
            do {
                if let h = try await downloadParallel(u, id: a.id) {
                    let dst = Self.fileURL(a.id)
                    let bytes = ((try? FileManager.default.attributesOfItem(atPath: h.path)[.size]) as? Int) ?? 0
                    guard bytes > 50_000 else { try? FileManager.default.removeItem(at: h); continue }
                    try? FileManager.default.removeItem(at: dst)
                    try FileManager.default.moveItem(at: h, to: dst)
                    entries.removeAll { $0.aweme.id == a.id }
                    entries.append(Entry(aweme: a, watched: false, added: Date().timeIntervalSince1970, bytes: bytes))
                    evict()
                    save()
                    DYLiveModel.log("DDCACHE ok \(a.id) \(bytes / 1024)KB host=\(u.host ?? "-") \(String(format: "%.1f", Date().timeIntervalSince(t0)))s total=\(entries.count)")
                    return
                }
            } catch {
                DYLiveModel.log("DDCACHE fail host=\(u.host ?? "-") \(error.localizedDescription)")
            }
        }
        if !Task.isCancelled { failed.insert(a.id) }
    }

    /// 返回下载到临时文件（未移动、未登记）；不支持 Range 或体积未知时退回单连接
    private func downloadParallel(_ url: URL, id: String) async throws -> URL? {
        var probe = URLRequest(url: url)
        DYMedia.headers.forEach { probe.setValue($1, forHTTPHeaderField: $0) }
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (first, resp) = try await session.download(for: probe)
        guard let h = resp as? HTTPURLResponse else { return nil }
        guard h.statusCode == 200 || h.statusCode == 206 else {
            DYLiveModel.log("DDCACHE status=\(h.statusCode) host=\(url.host ?? "-") id=\(id)")
            return nil
        }
        // Content-Range: bytes 0-0/12345 → 总长；200 表示服务端忽略了 Range（整包就是这个文件）
        var total = 0
        if let cr = h.value(forHTTPHeaderField: "Content-Range"),
           let slash = cr.split(separator: "/").last, let n = Int(slash) { total = n }
        if h.statusCode == 200 { return first }
        guard total > Self.segmentMinBytes else {
            // 体积小或未知：把探测到的那一小段换成完整文件（重新整包下）
            try? FileManager.default.removeItem(at: first)
            var r = URLRequest(url: url)
            DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            let (whole, _) = try await session.download(for: r)
            return whole
        }

        let parts = Self.segments
        let size = total / parts
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ddseg-\(id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        do {
            let tmpFiles = try await withThrowingTaskGroup(of: (Int, URL).self) { group -> [URL] in
                for i in 0..<parts {
                    let lo = i * size
                    let hi = i == parts - 1 ? total - 1 : (lo + size - 1)
                    group.addTask {
                        var r = URLRequest(url: url)
                        DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
                        r.setValue("bytes=\(lo)-\(hi)", forHTTPHeaderField: "Range")
                        let (tmp, resp) = try await self.session.download(for: r)
                        guard let h = resp as? HTTPURLResponse, h.statusCode == 206 || h.statusCode == 200 else {
                            throw URLError(.badServerResponse)
                        }
                        let named = dir.appendingPathComponent(String(format: "%03d", i))
                        try? FileManager.default.removeItem(at: named)
                        try FileManager.default.moveItem(at: tmp, to: named)
                        return (i, named)
                    }
                }
                var out = [URL](repeating: dir, count: parts)
                for try await (i, f) in group { out[i] = f }
                return out
            }
            urls = tmpFiles
            let joined = dir.appendingPathComponent("full")
            FileManager.default.createFile(atPath: joined.path, contents: nil)
            let out = try FileHandle(forWritingTo: joined)
            for f in urls {
                let h = try FileHandle(forReadingFrom: f)
                while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { try out.write(chunk) }
                try h.close()
            }
            try out.close()
            try? FileManager.default.removeItem(at: first)
            return joined
        } catch {
            try? FileManager.default.removeItem(at: first)
            throw error
        }
    }

    func markWatched(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.aweme.id == id }), !entries[i].watched else { return }
        entries[i].watched = true
        save()
    }

    func usage() -> (count: Int, bytes: Int) {
        (entries.count + heads.count, entries.reduce(0) { $0 + $1.bytes } + heads.reduce(0) { $0 + $1.bytes })
    }

    func clear() -> Int {
        let bytes = entries.reduce(0) { $0 + $1.bytes } + heads.reduce(0) { $0 + $1.bytes }
        job?.cancel(); job = nil; jobID = nil
        entries = []; heads = []
        if let files = try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        return bytes
    }

    /// 超上限：先删看过的（最早的先删），还超就删最早加进来的
    private func evict() {
        // 「已看过」最多留 watchedKeep 条，其余先删：看过的缓存没意义，重启也不该再刷到
        var watched = entries.filter(\.watched).count
        while watched > Self.watchedKeep, let idx = entries.firstIndex(where: \.watched) {
            let e = entries.remove(at: idx)
            try? FileManager.default.removeItem(at: Self.fileURL(e.aweme.id))
            watched -= 1
        }
        let lim = max(Self.limit, 0)
        while entries.count > lim || (entries.count > 1 && entries.reduce(0, { $0 + $1.bytes }) > Self.maxBytes) {
            let idx = entries.firstIndex(where: \.watched) ?? 0
            let e = entries.remove(at: idx)
            try? FileManager.default.removeItem(at: Self.fileURL(e.aweme.id))
        }
    }

    /// 启动时清一次：上次看过的缓存全部删掉（老板要求「看过的清理掉，重启别再刷到旧的」）
    /// 清掉历史遗留的「第一段」文件（新策略不再使用）
    func purgeHeads() {
        guard !heads.isEmpty else { return }
        for h in heads { try? FileManager.default.removeItem(at: Self.headURL(h.id)) }
        heads.removeAll()
        saveHeads()
        DYLiveModel.log("DDCACHE 清理历史头段 \(heads.count)")
    }

    func purgeWatched() {
        let stale = entries.filter(\.watched)
        guard !stale.isEmpty else { return }
        for e in stale { try? FileManager.default.removeItem(at: Self.fileURL(e.aweme.id)) }
        entries.removeAll(where: \.watched)
        save()
        DYLiveModel.log("DDCACHE 清理已看过 \(stale.count) 条，剩 \(entries.count)")
    }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: Self.indexURL, options: .atomic) }
    }
    private func saveHeads() {
        if let d = try? JSONEncoder().encode(heads) { try? d.write(to: Self.headIndexURL, options: .atomic) }
    }
}
