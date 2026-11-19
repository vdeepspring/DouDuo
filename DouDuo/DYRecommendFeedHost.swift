import SwiftUI
import AVFoundation

struct DYOfflinePlaybackContext {
    let id: String
    let localOnly: Bool
    let position: Int?
    let total: Int
    let onFailure: () -> Void
    var inLibrary = false
    var onFinished: (() -> Bool)? = nil
    var onPositionUpdate: ((Double) -> Void)? = nil
    var onlineActionsAllowed = true

    func localURL() -> URL? {
        inLibrary ? DYOfflineVideoStore.localURL(id) : DYVideoCache.localURL(id)
    }
}

/// 推荐流的共用操作（默认 / 简洁 / 极简 / 经典四种界面同一份）。
///
/// 维护规矩：推荐流「数据怎么动」只写在这里——刷新、连播、不感兴趣、话题屏蔽、存档会话、上报观看、
/// 点赞收藏等。两个推荐页（`DYUpstreamFeedScreen`、`DYClassicFeedScreen`）只负责「长什么样」，
/// 不要在它们里面再各写一份同名函数；需要按界面区分的，见 docs/ui-modes.md 的「必须分开」清单。
@MainActor
protocol DYRecommendFeedHost: View {
    var bridge: DouyinBridge { get }
    var feed: DYFeedModel { get }
    var preloader: DYPreloader { get }
    var tab: DYTab { get nonmutating set }
    var currentID: String? { get nonmutating set }
    var scrollID: String? { get nonmutating set }
    var resume: [String: Double] { get nonmutating set }
    var userScrolling: Bool { get nonmutating set }
    var scrollEndTask: Task<Void, Never>? { get nonmutating set }
    var initialized: Bool { get nonmutating set }
    var refreshing: Bool { get nonmutating set }
    var lastFeedPull: Date { get nonmutating set }
    var showComments: Bool { get nonmutating set }
    var noticeUnread: Int { get nonmutating set }
    var searchSession: DYSearchSession? { get nonmutating set }
}

@MainActor
extension DYRecommendFeedHost {
    /// 用户点了频道（关注 / 推荐 / 直播）。四种界面的频道入口都走这里：
    /// 默认的顶栏、简洁 / 极简的模块菜单、经典的顶部频道栏。
    /// 点**已选中的「推荐」= 刷新推荐**；其它情况交给各界面自己的 `switchTab`（经典有跟手切换动画）。
    /// 滑动切换、程序切换（调试 / 回到推荐）不走这里，不会误刷新。
    func tapChannel(_ target: DYTab, switchTab: (DYTab) -> Void) {
        DYLiveModel.log("DDTAB tap target=\(target) from=\(tab)")
        if target == .recommend, tab == .recommend {
            DYLiveModel.log("DDREFRESH tap selected recommend")
            #if DEBUG
            DYRefreshProbe.shared.count += 1
            #endif
            // 点下去同一帧就出提示：不等 Task 排到下一轮，也不等正在进行的预取
            if !feed.offlinePlayback { feed.showRefreshingToast() }
            Task { await refreshRecommendations() }
        } else {
            switchTab(target)
        }
    }

    var currentIndex: Int? { currentID.flatMap { id in feed.items.firstIndex { $0.id == id } } }
    var current: DYAweme? { currentIndex.map { feed.items[$0] } }

    /// 自动连播翻页带滑动动画（议题 #21-4）；分页代理没接上时退回直接切
    func advance(from: String, to: String) {
        if !DYPagerAdvance.request(from: from, to: to) { withAnimation { currentID = to } }
    }

    func applyHashtagFilter() async {
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

    /// 不感兴趣：立刻从列表拿掉并切到下一条，后台告诉抖音（失败只提示，不把视频塞回来）
    func dislike(_ id: String) {
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

    /// 推荐是一页页拉回来、一条条排进列表的。以前要等首批 6 条全部凑齐才定「当前条」、才给后面的备播放器
    /// （真机日志：中位 6 秒，慢的 15 秒以上）——这段时间第一条不开播，后面的也滑不过去。
    /// 现在到一条算一条：第一条到了立刻开播，后面每到一条马上备好播放器。
    func feedGrew() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_HASHTAG_FIXTURE"] == "1" { return }
        #endif
        guard initialized, !refreshing, !feed.offlinePlayback, tab == .recommend,
              let first = feed.items.first else { return }
        if currentID == nil {
            currentID = first.id   // 两个推荐页的 onChange(currentID) 会接着调 focusCurrent
            scrollID = first.id
        } else if let i = currentIndex {
            preloader.update(feed.items, current: i)
        }
    }

    func offlineCandidates(_ requestedCount: Int) async throws -> [DYAweme] {
        let count = min(max(0, requestedCount), DYOfflineDownloads.maximumCount)
        guard count > 0 else { return [] }
        let saved = await DYVideoCache.shared.offlineItems()
        var seen = Set(saved.map(\.id))
        var result: [DYAweme] = []
        func add(_ candidates: [DYAweme]) {
            for item in feed.allowedRecommendations(candidates) where result.count < count {
                guard item.images.isEmpty, item.duration.isFinite, item.duration > 0,
                      let playback = item.play.flatMap(URL.init(string:)),
                      let scheme = playback.scheme?.lowercased(),
                      scheme == "http" || scheme == "https",
                      seen.insert(item.id).inserted else { continue }
                result.append(item)
            }
        }
        add(Array(feed.items.dropFirst((currentIndex ?? -1) + 1)) + feed.pool)
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_HASHTAG_FIXTURE"] == "1" { return result }
        #endif
        var pagesWithoutCandidates = 0
        for _ in 0..<max(4, (count + 4) / 5) {
            guard result.count < count else { break }
            try Task.checkCancellation()
            do {
                let page = try await bridge.fetchFeed()
                try Task.checkCancellation()
                let previousCount = result.count
                add(page.items)
                pagesWithoutCandidates = result.count == previousCount ? pagesWithoutCandidates + 1 : 0
                if !page.hasMore || page.items.isEmpty || pagesWithoutCandidates >= 3 { break }
            } catch {
                try Task.checkCancellation()
                if result.isEmpty { throw error }
                break
            }
        }
        return result
    }

    func refreshOfflineQueueIfNeeded() async {
        guard feed.offlinePlayback, DYOfflineDownloads.shared.isOffline else { return }
        await updateOfflineFeed(true, refresh: true)
    }

    func offlinePlaybackContext(for item: DYAweme) -> DYOfflinePlaybackContext {
        let ids: [String]
        if feed.offlinePlayback || feed.onlineContinuationID == item.id {
            ids = feed.savedOfflineIDs.contains(item.id) ? feed.savedOfflineIDs : feed.automaticOfflineIDs
        } else {
            ids = []
        }
        return DYOfflinePlaybackContext(id: item.id, localOnly: feed.offlinePlayback,
            position: ids.firstIndex(of: item.id).map { $0 + 1 }, total: ids.count,
            onFailure: { Task { await recommendationPlaybackFailed(item.id) } },
            onFinished: { offlineVideoFinished(item.id) })
    }

    func updateOfflineFeed(_ offline: Bool, refresh: Bool = false) async {
        let connectivity = DYOfflineDownloads.shared
        guard offline == connectivity.isOffline else { return }
        let pathChanged = feed.pathIsOffline != offline
        feed.pathIsOffline = offline
        if !offline {
            guard feed.offlinePlayback, pathChanged || refresh else { return }
            await resumeOnlineRecommendations()
            if feed.offlinePlayback { scheduleOnlineRecovery() }
            return
        }

        if pathChanged {
            feed.onlineRecoveryTask?.cancel()
            feed.onlineRecoveryTask = nil
            feed.offlineEpoch += 1
        }
        if feed.offlinePlayback, !refresh { return }
        let epoch = feed.offlineEpoch
        let local = await DYVideoCache.shared.offlinePlaybackItems()
        guard !Task.isCancelled, connectivity.isOffline, epoch == feed.offlineEpoch else { return }
        setOfflineFeed(saved: local.saved, automatic: local.automatic, fallback: false)
    }

    private func recommendationPlaybackFailed(_ id: String) async {
        guard tab == .recommend, currentID == id, DDPlayback.shared.appIsActive,
              !DDPlayback.shared.coverHold, !feed.failedRecommendationIDs.contains(id) else { return }
        if continueOnlineAfterOfflineVideo(id) { return }
        let local = await DYVideoCache.shared.offlinePlaybackItems()
        guard !Task.isCancelled, tab == .recommend, currentID == id, DDPlayback.shared.appIsActive,
              !DDPlayback.shared.coverHold, feed.failedRecommendationIDs.insert(id).inserted else { return }
        feed.finishedOfflineID = id
        // If a local queue is in use, skip to its next playable video without replaying its earlier entries.
        if feed.offlinePlayback, let index = currentIndex {
            if let next = nextOfflineRecommendation(after: index) {
                advance(from: id, to: next.id)
                return
            }
        } else if setOfflineFeed(saved: local.saved, automatic: local.automatic, fallback: true) {
            DYLiveModel.log("DDOFFLINE fallback failed=\(id) next=\(currentID ?? "-")")
            if !DYOfflineDownloads.shared.isOffline { scheduleOnlineRecovery() }
            return
        }
        showToast("视频加载失败，暂无其他可播放的离线视频")
    }

    private func nextOfflineRecommendation(after index: Int) -> DYAweme? {
        feed.items.dropFirst(index + 1).first {
            !feed.failedRecommendationIDs.contains($0.id) && DYVideoCache.localURL($0.id) != nil
        }
    }

    @discardableResult
    private func setOfflineFeed(saved: [DYAweme], automatic: [DYAweme], fallback: Bool) -> Bool {
        let previous = currentID
        var ids = Set<String>()
        let videos = feed.allowedRecommendations(fallback ? automatic + saved : saved + automatic)
            .filter {
                $0.images.isEmpty && !feed.failedRecommendationIDs.contains($0.id) &&
                    DYVideoCache.localURL($0.id) != nil && ids.insert($0.id).inserted
            }
        if fallback, videos.isEmpty { return false }

        let savedIDs = Set(saved.map(\.id))
        feed.savedOfflineIDs = saved.map(\.id)
        feed.automaticOfflineIDs = videos.map(\.id).filter { !savedIDs.contains($0) }
        scrollEndTask?.cancel()
        preloader.clear()
        userScrolling = false
        if previous.map({ ids.contains($0) }) != true { showComments = false }
        if !feed.offlinePlayback { feed.offlineEpoch += 1 }
        feed.offlinePlayback = true
        feed.error = videos.isEmpty ? "没有可播放的离线视频" : nil
        feed.pool = []
        feed.items = videos
        currentID = previous.flatMap { ids.contains($0) ? $0 : nil } ?? videos.first?.id
        scrollID = currentID
        focusCurrent()
        return true
    }

    private func scheduleOnlineRecovery() {
        guard feed.onlineRecoveryTask == nil else { return }
        feed.onlineRecoveryTask = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            await resumeOnlineRecommendations()
            if !Task.isCancelled { feed.onlineRecoveryTask = nil }
        }
    }

    private func resumeOnlineRecommendations() async {
        let epoch = feed.offlineEpoch
        guard !DYOfflineDownloads.shared.isOffline, feed.offlinePlayback,
              feed.recoveringOnlineEpoch != epoch else { return }
        feed.recoveringOnlineEpoch = epoch
        defer {
            if feed.recoveringOnlineEpoch == epoch { feed.recoveringOnlineEpoch = nil }
        }
        guard let replacement = try? await feed.prepareRefresh(bridge, excludingCurrentItems: false),
              epoch == feed.offlineEpoch, !DYOfflineDownloads.shared.isOffline,
              feed.offlinePlayback else { return }
        let currentLocalVideo = current.flatMap { item in
            feed.finishedOfflineID != item.id && DYVideoCache.localURL(item.id) != nil ? item : nil
        }
        let consumed = Set(feed.items.prefix((currentIndex ?? -1) + 1).map(\.id))
        guard let first = feed.recoverOnline(with: replacement, keeping: currentLocalVideo, excluding: consumed) else { return }
        preloader.clear()
        if currentID != first.id {
            scrollEndTask?.cancel()
            userScrolling = false
            showComments = false
        }
        currentID = first.id
        if currentLocalVideo == nil { scrollID = currentID }
        feed.finishedOfflineID = nil
        feed.onlineContinuationID = currentLocalVideo?.id
        lastFeedPull = Date()
        focusCurrent()
        saveSession()
        DYLiveModel.log("DDOFFLINE online kept=\(currentLocalVideo?.id ?? "-") current=\(first.id)")
    }

    private func offlineVideoFinished(_ id: String) -> Bool {
        guard tab == .recommend, currentID == id else { return false }
        if feed.offlinePlayback {
            feed.finishedOfflineID = id
            return false
        }
        return continueOnlineAfterOfflineVideo(id)
    }

    private func continueOnlineAfterOfflineVideo(_ id: String) -> Bool {
        guard !feed.offlinePlayback, feed.onlineContinuationID == id,
              currentID == id, let index = currentIndex, index + 1 < feed.items.count else { return false }
        feed.onlineContinuationID = nil
        advance(from: id, to: feed.items[index + 1].id)
        return true
    }

    func focusCurrent() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_HASHTAG_FIXTURE"] == "1", !feed.offlinePlayback {
            if ProcessInfo.processInfo.environment["DOUDUO_OFFLINE_FIXTURE_URL"] != nil, let i = currentIndex {
                preloader.update(feed.items, current: i)
            }
            return
        }
        #endif
        guard !refreshing, let i = currentIndex else { return }
        preloader.update(feed.items, current: i, localOnly: feed.offlinePlayback)
        guard !feed.offlinePlayback else { return }
        // 不再预解首帧：界面已不用首帧图顶替（老板要纯黑直出），省 CPU 和解码
        let curID = feed.items[i].id
        let ahead = Array(feed.items.dropFirst(i + 1))
        let regionIDs = ahead.prefix(2).filter {
            DYPublicationRegion.name(for: $0.publicationCityCode, country: $0.publicationCountry) == nil
        }.map(\.id)
        Task(priority: .utility) { await DYPublicationRegionClient.shared.prefetch(regionIDs) }
        let currentItem = feed.items[i]
        Task {
            await DYVideoCache.shared.markWatched(curID)
            await DYVideoCache.shared.focus(current: currentItem, ahead: ahead)
        }
        // 后面不足「缓存条数」就继续拉推荐（至少保证 6 条，节流 4 秒一次）
        let want = max(6, min(DYVideoCache.limit, 60))
        // 正在拉的时候不重复发起，也不占用节流窗口（否则这一批拉完后要白等 4 秒才接着拉）
        if feed.items.count - i - 1 < want, !feed.loading, Date().timeIntervalSince(lastFeedPull) > 4 {
            lastFeedPull = Date()
            Task {
                await feed.loadMore(bridge)
                if !feed.offlinePlayback, let j = currentIndex {
                    preloader.update(feed.items, current: j)
                    await DYVideoCache.shared.focus(current: feed.items[j], ahead: Array(feed.items.dropFirst(j + 1)))
                    if feed.items.count - j - 1 < want { focusCurrent() }
                }
            }
        }
    }

    func openSearch() {
        DYSearchSession.transition { showComments = false; searchSession = DYSearchSession() }
    }

    /// 自动连播：播完滑到下一条；快到底时先补一页
    func playNext(after id: String) {
        guard currentID == id, let i = currentIndex else { return }
        if feed.offlinePlayback {
            if let next = nextOfflineRecommendation(after: i) {
                advance(from: id, to: next.id)
            } else {
                feed.finishedOfflineID = id
                showToast("离线视频已播完")
            }
        } else if i + 1 < feed.items.count {
            advance(from: id, to: feed.items[i + 1].id)
        } else {
            Task {
                await feed.loadMore(bridge)
                if currentID == id, let j = currentIndex, j + 1 < feed.items.count {
                    advance(from: id, to: feed.items[j + 1].id)
                }
            }
        }
    }

    func refreshNoticeUnread() async {
        guard let groups = try? await bridge.noticeCounts() else { return }
        noticeUnread = DYMessagesScreen.badge(groups)
    }

    func reloadRecommendationsAfterLogin() {
        if !feed.offlinePlayback {
            preloader.clear()
            feed.reset()
            currentID = nil
        }
        bridge.reload()
        Task {
            if feed.offlinePlayback {
                await updateOfflineFeed(DYOfflineDownloads.shared.isOffline, refresh: true)
                return
            }
            await feed.loadMore(bridge)
            guard !feed.offlinePlayback, currentID == nil else { return }
            currentID = feed.items.first?.id
            focusCurrent()
        }
    }

    /// 先拉到新一批再替换，失败不清空当前画面；与预取互斥，避免旧请求覆盖刷新结果。
    @MainActor func refreshRecommendations() async {
        if feed.offlinePlayback {
            feed.endRefreshingToast()
            await updateOfflineFeed(DYOfflineDownloads.shared.isOffline, refresh: true)
            return
        }
        // 刷新中再点：提示照样亮着（以前直接返回，提示 2.2 秒后消失，后面要干等到刷新结果）
        feed.showRefreshingToast()
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; feed.endRefreshingToast(); focusCurrent() }
        guard let replacement = try? await feed.prepareRefresh(bridge), !feed.offlinePlayback else { return }
        guard !replacement.items.isEmpty else {
            showToast(replacement.error ?? "暂时没有新的推荐，已保留当前视频")
            DYLiveModel.log("DDREFRESH failed kept=\(currentID ?? "-")")
            return
        }
        showComments = false
        scrollEndTask?.cancel(); userScrolling = false
        preloader.clear()
        feed.replaceRecommendations(with: replacement)
        resume = [:]
        currentID = feed.items.first?.id
        scrollID = currentID
        lastFeedPull = Date()
        saveSession()
        showToast("视频已刷新")
        DYLiveModel.log("DDREFRESH ok n=\(feed.items.count) first=\(currentID ?? "-")")
    }

    /// 当前条之后按新的方向/比例重排；不够就接着拉
    func remixUpcoming() {
        guard !feed.offlinePlayback, tab == .recommend || !feed.items.isEmpty else { return }
        let keepAll: Bool
        #if DEBUG
        // 固定播放样本不会补拉推荐，布局切换时要保留后续测试视频。
        keepAll = ProcessInfo.processInfo.environment["DOUDUO_PLAYBACK_FIXTURE"] == "1"
        #else
        keepAll = false
        #endif
        feed.remix(after: currentIndex, keepAll: keepAll)
        DYLiveModel.log("DDMIX remix wide=\(feed.screenWide) upcoming=\(feed.items.count - (currentIndex ?? -1) - 1)")
        if currentID == nil { currentID = feed.items.first?.id; scrollID = currentID }
        lastFeedPull = .distantPast
        focusCurrent()
    }

    /// 换条时：上一条看完没有（≥95%，网页版同口径）+ 新一条起播 1.5 秒后上报
    func reportWatch(old: String?, new: String?) {
        if feed.finishedOfflineID == old { feed.finishedOfflineID = nil }
        if feed.onlineContinuationID == old { feed.onlineContinuationID = nil }
        guard !feed.offlinePlayback, let new, let item = feed.items.first(where: { $0.id == new }) else { return }
        var seen = false
        if let old, let prev = feed.items.first(where: { $0.id == old }), prev.duration > 0,
           DDNowPlaying.id == old { seen = DDNowPlaying.time / prev.duration >= 0.95 }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !feed.offlinePlayback, currentID == new else { return }
            await bridge.reportWatch(item, preID: old, preSeen: seen)
        }
    }

    func saveSession() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_HASHTAG_FIXTURE"] == "1" { return }
        #endif
        guard let id = currentID, feed.items.contains(where: { $0.id == id }) else { return }
        var positions = resume
        if DDNowPlaying.id == id, DDNowPlaying.time.isFinite {
            positions[id] = max(0, DDNowPlaying.time)
        }
        feed.noteCurrent(id, positions: positions)   // 切换界面模式后另一套根视图接手（main f76e636）
        DYFeedSession(items: feed.items, currentID: id, positions: positions).save()
    }

    func showToast(_ s: String) { feed.showToast(s) }

    /// 收藏 / 取消收藏（同步到抖音账号的「收藏」）
    func toggleCollect(_ id: String) { feed.toggleCollect(id, bridge: bridge) }

    /// 点赞：先本地乐观更新，再调抖音网页接口，按服务端返回决定成败
    /// （不用 cookie 判断登录态：sessionid 是 HttpOnly，document.cookie 读不到，会误判成未登录）
    func toggleLike(_ id: String, force: Bool?) { feed.toggleLike(id, force: force, bridge: bridge) }
}

/// The settings entry uses the standalone player; the recommendation feed owns a separate session.
struct DYOfflineLibraryScreen: View {
    let interactionBridge: DouyinBridge?
    let presentation: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var fallbackBridge: DouyinBridge?
    @State private var playback: DYListPlayback?
    @State private var initialized = false
    @State private var reloadRevision = 0

    var body: some View {
        Group {
            if let bridge = interactionBridge ?? fallbackBridge, let playback, !playback.items.isEmpty {
                DYListPlayer(bridge: bridge, title: "离线视频", playback: playback,
                             onAuthor: { _ in }, presentsAuthor: true, offlineLibrary: true)
            } else {
                Group {
                    if initialized {
                        ContentUnavailableView("暂无可播放的离线视频", systemImage: "airplane")
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { Color.black.ignoresSafeArea() }
                .overlay(alignment: .topLeading) {
                    Button("关闭离线视频", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .frame(width: 44, height: 44)
                        .accessibilityIdentifier("offline.library.close")
                        .padding(8)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(DYOfflineDownloads.shared.$storageRevision) { reloadRevision = $0 }
        .task(id: reloadRevision) { await reload() }
    }

    private func reload() async {
        let saved = await DYVideoCache.shared.offlineItems()
        guard !Task.isCancelled else { return }
        if let playback {
            playback.updateOfflineItems(saved)
        } else if !saved.isEmpty {
            if interactionBridge == nil { fallbackBridge = DouyinBridge() }
            let checkpoint = DYOfflineVideoStore.loadCheckpoint()
            let start = saved.firstIndex { $0.id == checkpoint?.id } ?? 0
            let state = DYListPlayback(items: saved, start: start)
            if let checkpoint, checkpoint.id == state.currentID {
                state.restoreOfflineCheckpoint(checkpoint)
            }
            DDPlayback.shared.beginOfflineLibrary(presentation)
            playback = state
        }
        initialized = true
    }
}

#if DEBUG
/// UI 测试锚点：点已选中「推荐」触发刷新的次数（离线数据刷不出新视频，靠它确认确实刷了）。
@MainActor
final class DYRefreshProbe: ObservableObject {
    static let shared = DYRefreshProbe()
    @Published var count = 0
}

/// 挂在推荐页上，把刷新次数暴露给 UI 测试（`douyin.refreshCount`）。
struct DYRefreshProbeAnchor: View {
    @ObservedObject private var probe = DYRefreshProbe.shared
    var body: some View {
        Text("\(probe.count)").font(.caption2).opacity(0.01)
            .accessibilityIdentifier("douyin.refreshCount")
            .allowsHitTesting(false)
    }
}
#endif

/// 推荐流按横 / 竖选片的口径，四种界面共用（「横屏时只放横屏内容」开关据此生效）。
/// 老板 2026-11-17 定：半折叠时横竖反过来——
/// - 竖着拿半折（桌面姿态，上面放视频、下面评论）→ 视频区是横的，按**横屏**规则放
/// - 横着拿半折（书本姿态，左边视频、右边评论）→ 视频区是竖的，按**竖屏**规则放
/// - 没半折：看整个窗口宽 > 高
/// （1.3.14 曾按视频块判断后又撤回，那次是「短视频变少」；这次是老板明确要求半折按反向选片。）
enum DYFeedOrientation {
    static func playAreaIsWide(_ geo: GeometryProxy) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_FORCEWIDE"] == "1" { return true }
        #endif
        return DYVideoFit.feedPlaysLandscape(window: geo.size, halfFolded: DYDuoMetrics.foldIsActive(geo))
    }
}
