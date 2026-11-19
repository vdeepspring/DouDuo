// 短视频播放页：从 無為 影库播放器（PlayerPage）精简而来，只留抖音需要的部分——
// AVPlayer 直连、横滑快进（预览缩略图 + 目标时间 HUD）、双击、长按 2 倍速、单击暂停、竖滑切视频、底部可拖进度条。
import SwiftUI
import AVFoundation
import MediaPlayer

/// 谁触发了这次全局暂停。失焦、后台和 App 内覆盖层不是同一件事。
enum DDPlaybackPauseReason: Equatable {
    case inactive
    case background
    case cover
}

/// 全局播放登记表：App 进后台/失焦时由 App 层直接通知所有播放器，
/// 比依赖视图的 onReceive 稳（视图可能还没渲染、或被 LazyVStack 回收）。
/// 短视频是否继续，由「后台播放」决定。直播是否继续出声，由「后台直播声音」决定。
/// 音频会话只在短视频后台播放和直播都不需要时才交给其他 App。
/// 当前绑着锁屏控件的播放器实例；首页和离线页可能同时持有同一视频 ID。
@MainActor enum DDRemoteOwner { static var instance: UUID? }

final class DDPlayback {
    static let shared = DDPlayback()
    private var stoppers: [UUID: () -> Void] = [:]
    private var starters: [UUID: () -> Void] = [:]
    private var sessionRetainers: [UUID: () -> Bool] = [:]
    /// 播放器所在的遮罩层级：0 = 首页；从信息页/我的里点开的全屏播放器 = 打开时的遮罩数。
    /// 遮罩数没超过这一层，说明它就是最上面那层，可以播（老板 11-18：信息里点开的视频要等十几秒才动）。
    private var coverLevels: [UUID: Int] = [:]
    private var lock = NSLock()
    /// App 当前是否在前台：注册晚于切后台时（视频刚起播），要立刻停，不能接着响
    private(set) var appIsActive = true
    private(set) var pauseReason: DDPlaybackPauseReason = .background
    /// 转发等覆盖层还盖着。后台锁不能把它清掉，前台回调也不能在它消失前把直播拉起来。
    private var coverCount = 0
    // Settings may destroy their presenter when switching UI mode.
    // Stable owners make root teardown and late sheet dismissal idempotent.
    private var settingsCovers: Set<UUID> = []
    var coverHold: Bool { coverDepth > 0 }
    var coverDepth: Int { coverCount + settingsCovers.count }
    /// 这一层的播放器现在是不是露在最上面
    func isUncovered(level: Int) -> Bool { coverDepth == 0 || (level > 0 && coverDepth <= level) }

    func beginSettingsCover(_ owner: UUID) {
        guard settingsCovers.insert(owner).inserted else { return }
        pauseAll(reason: .cover, countLegacyCover: false)
    }

    func endSettingsCover(_ owner: UUID) {
        guard settingsCovers.remove(owner) != nil else { return }
        resumeAfterLastCover()
    }
    @MainActor private var offlineLibraryPresentations: Set<UUID> = []
    @MainActor var offlineLibraryPresented: Bool { !offlineLibraryPresentations.isEmpty }

    @MainActor func beginOfflineLibrary(_ presentation: UUID) {
        let wasPresented = offlineLibraryPresented
        offlineLibraryPresentations.insert(presentation)
        guard !wasPresented else { return }

        // The settings sheet already owns a cover. Suspend its underlying
        // players even in listening mode, without taking another cover count.
        lock.lock()
        let stops = Array(stoppers.values)
        lock.unlock()
        let previous = pauseReason
        pauseReason = .cover
        stops.forEach { $0() }
        DDAudioEngineHub.shared.pauseAll()
        pauseReason = previous
    }

    @MainActor func endOfflineLibrary(_ presentation: UUID) {
        guard offlineLibraryPresentations.remove(presentation) != nil, !offlineLibraryPresented,
              appIsActive, !coverHold, UIApplication.shared.applicationState == .active else { return }
        startRegisteredPlayers()
    }

    /// 「更多」菜单里的「后台播放」：短视频开了就不因切后台/锁屏停声（听书用）。
    /// 不跳过直播自己的后台策略。
    static var bgPlay: Bool { UserDefaults.standard.bool(forKey: "douyin_bg_play_v1") }

    func register(_ id: UUID, stop: @escaping () -> Void, start: @escaping () -> Void,
                  retainsAudioSession: (() -> Bool)? = nil, playsInsideCover: Bool = false, coverLevel: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        stoppers[id] = stop; starters[id] = start
        coverLevels[id] = coverLevel
        if let retainsAudioSession { sessionRetainers[id] = retainsAudioSession }
        else { sessionRetainers[id] = nil }
        // 被遮罩挡住才停；自己就在最上层（信息页里点开的视频）时不停
        let onTop = coverLevel > 0 && coverDepth > 0 && coverDepth <= coverLevel
            && UIApplication.shared.applicationState == .active
        let shouldStop = !appIsActive && !playsInsideCover && !onTop
        #if DEBUG
        ddWrite("DDBG register \(id.uuidString.prefix(4)) total=\(stoppers.count) appActive=\(appIsActive)")
        #endif
        if shouldStop { stop() }
    }
    func unregister(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        stoppers[id] = nil; starters[id] = nil; sessionRetainers[id] = nil; coverLevels[id] = nil
        #if DEBUG
        ddWrite("DDBG unregister \(id.uuidString.prefix(4)) total=\(stoppers.count)")
        #endif
    }
    /// 控制中心、通知横幅这类失焦。短视频暂停；不把 App 标成后台，直播的停止留到真正的 background。
    func pauseForInactivity() {
        guard appIsActive else { return }
        lock.lock()
        let stops = Array(stoppers.values)
        lock.unlock()
        let previous = pauseReason
        pauseReason = .inactive
        stops.forEach { $0() }
        if pauseReason == .inactive { pauseReason = previous }
    }
    func pauseAll(reason: DDPlaybackPauseReason = .background) {
        pauseAll(reason: reason, countLegacyCover: true)
    }

    private func pauseAll(reason: DDPlaybackPauseReason, countLegacyCover: Bool) {
        let addsLegacyCover = reason == .cover && countLegacyCover
        if addsLegacyCover { coverCount += 1 }
        let backgroundWhileCover = reason == .background && !appIsActive && coverHold
        if !backgroundWhileCover {
            guard DYLivePlaybackGate.apply(appIsActive: appIsActive, command: .pause) else {
                if addsLegacyCover { coverCount = max(0, coverCount - 1) }
                return
            }
            appIsActive = false
        }
        pauseReason = reason
        lock.lock()
        let stops = Array(stoppers.values)
        let retainers = Array(sessionRetainers.values)
        lock.unlock()
        #if DEBUG
        let label = reason == .background ? "background" : (reason == .cover ? "cover" : "inactive")
        ddWrite("DDBG pauseAll count=\(stops.count) reason=\(label)")
        #endif
        stops.forEach { $0() }
        if !Self.bgPlay {   // 后台播放开着时声音引擎要继续出声
            if Thread.isMainThread {
                MainActor.assumeIsolated { DDAudioEngineHub.shared.pauseAll() }
            } else {
                DispatchQueue.main.sync { MainActor.assumeIsolated { DDAudioEngineHub.shared.pauseAll() } }
            }
        }
        let keepSession = Self.bgPlay || retainers.contains { $0() }
        if !keepSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    func resumeAll() {
        guard DYLivePlaybackGate.apply(appIsActive: appIsActive, command: .resume) else { return }
        appIsActive = true
        guard !coverHold else { startPlayersOnTop(); return }
        startRegisteredPlayers()
    }
    /// 覆盖层消失。还在后台时只减计数；人已经回到前台才启动。
    func releaseCover() {
        guard coverCount > 0 else { return }
        coverCount -= 1
        resumeAfterLastCover()
    }
    private func resumeAfterLastCover() {
        guard UIApplication.shared.applicationState == .active else { return }
        guard !coverHold else { startPlayersOnTop(); return }
        appIsActive = true
        startRegisteredPlayers()
    }
    /// 还有遮罩时：只启动「就在最上层」的播放器（例如信息页里点开的视频关掉它自己的设置页后）
    private func startPlayersOnTop() {
        lock.lock()
        let s = starters.filter { id, _ in let l = coverLevels[id] ?? 0; return l > 0 && coverDepth <= l }.map(\.value)
        lock.unlock()
        guard !s.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        s.forEach { $0() }
    }
    private func startRegisteredPlayers() {
        lock.lock(); let s = Array(starters.values); lock.unlock()
        #if DEBUG
        ddWrite("DDBG resumeAll count=\(s.count)")
        #endif
        if !s.isEmpty {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        s.forEach { $0() }
    }
}

/// 抖音视频 CDN（douyinvod.com）要浏览器 UA + Referer，否则 403（真机实测：plain/CoreMedia UA 403，Safari UA+Referer 206）
enum DYMedia {
    static let headers = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        "Referer": "https://www.douyin.com/",
    ]
    static func asset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }
    /// 直播（VLC 用）：Referer 要 live.douyin.com
    static var liveHeaders: [String: String] {
        var h = headers
        h["Referer"] = "https://live.douyin.com/"
        return h
    }
    /// 直播 HLS：CDN 认 live.douyin.com 的 Referer，不带会 403（表现为一直转圈/黑屏）
    static func liveAsset(_ url: URL) -> AVURLAsset {
        var h = headers
        h["Referer"] = "https://live.douyin.com/"
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": h])
    }
}

extension PlayerPage {
    /// 与 無為 同名同参的构造入口，DouyinFeedView 原样复用
    static func external(id: String, title: String, url: URL, durationSec: Double, isActive: Bool,
                         topInset: CGFloat, bottomInset: CGFloat, resumePosition: Double?,
                         compactChrome: Bool,
                         preparedPlayer: (() -> AVPlayer?)? = nil,
                         returnPlayer: ((AVPlayer) -> Bool)? = nil,
                         onEnded: (() -> Void)?, onDoubleTap: (() -> Void)?,
                         onSavePosition: @escaping (Double) -> Void, onClose: @escaping () -> Void,
                         fillWidth: Bool = true, onFillWidthChange: ((Bool) -> Void)? = nil,
                         danmaku: [DYDanmaku] = [], altURL: URL? = nil,
                         quality: String? = nil, fastURL: URL? = nil, posterURL: URL? = nil,
                         videoAspect: Double = 0,
                         headEndSeconds: Double? = nil, continuationURL: URL? = nil,
                         onSwipeLeft: (() -> Void)? = nil, onSwipeRight: (() -> Void)? = nil,
                         onContextMenu: (() -> Void)? = nil, boost: DYBoostControl? = nil,
                         onHorizontalDrag: ((CGFloat, CGFloat) -> Void)? = nil,
                         onHorizontalDragEnd: ((CGFloat, CGFloat, CGFloat, Bool) -> Void)? = nil) -> PlayerPage {
        PlayerPage(id: id, url: url, knownDuration: durationSec, isActive: isActive, bottomInset: bottomInset,
                   resumePosition: resumePosition, preparedPlayer: preparedPlayer, returnPlayer: returnPlayer, onEnded: onEnded,
                   onDoubleTap: onDoubleTap, onSavePosition: onSavePosition, fillWidth: fillWidth,
                   onFillWidthChange: onFillWidthChange,
                   topInset: topInset, danmaku: danmaku, altURL: altURL, quality: quality, fastURL: fastURL,
                   posterURL: posterURL, headEndSeconds: headEndSeconds,
                   continuationURL: continuationURL, videoAspect: videoAspect, title: title,
                   navigationSwipes: onSwipeLeft != nil || onSwipeRight != nil || onContextMenu != nil || onHorizontalDrag != nil,
                   onSwipeLeft: onSwipeLeft, onSwipeRight: onSwipeRight,
                   onContextMenu: onContextMenu, boost: boost,
                   onHorizontalDrag: onHorizontalDrag, onHorizontalDragEnd: onHorizontalDragEnd)
    }
}

/// 视频页的存活标记（引用类型：延后执行的闭包拿到的是同一个对象）
final class PageLife {
    var alive = false
    var generation = 0
}

/// 极简模式：长按圆形模块入口时，让当前视频页把左下角的作者和标题临时显示出来（松手消失）。
/// 直接复用页面里原来的信息区，所以样式、位置和平时完全一样。
@MainActor final class DDPeekInfo: ObservableObject {
    static let shared = DDPeekInfo()
    @Published var on = false
}

/// 极简模式：播放进度画在圆形模块入口的外圈。播放器页把当前进度写进来，屏幕层读。
/// 只有「当前页」会写（isActive），所以不会被相邻预加载页的进度干扰。
@MainActor final class DDRailProgress: ObservableObject {
    static let shared = DDRailProgress()
    @Published var fraction: Double = 0
    @Published var seeking = false
    var ownerID = ""
    func update(id: String, fraction: Double, seeking: Bool) {
        ownerID = id
        let f = fraction.isFinite ? max(0, min(1, fraction)) : 0
        // 0.5% 以内的变化不发布，避免每 0.25s 都重绘整个屏幕层
        if abs(f - self.fraction) > 0.005 || f == 0 || f == 1 { self.fraction = f }
        if self.seeking != seeking { self.seeking = seeking }
    }
}

/// 右侧按钮/作者区也要能长按加速：这些控件盖在手势层上面，触摸到不了手势层，
/// 所以由 PlayerPage 把「加速开始/结束」交给这个对象，外层控件按住时直接调用。
@MainActor final class DYBoostControl: ObservableObject {
    /// 正在加速：外层据此淡出按钮和状态图标。
    @Published var boosting = false {
        didSet { if DYBoostRouter.shared.control === self { DYBoostRouter.shared.boosting = boosting } }
    }
    var press: (Bool) -> Void = { _ in }
    private var held = false
    private var lastEnd = Date.distantPast
    /// 按住或刚松手的一小段时间内，按钮自己的点击要忽略（否则长按加速后松手会变成点赞/评论）。
    var blocksTap: Bool { held || Date().timeIntervalSince(lastEnd) < 0.8 }
    func begin() {
        guard !held else { return }
        held = true
        #if DEBUG
        DYGestureDiagnostics.shared.boostStarts += 1
        #endif
        press(true)
    }
    func end() { guard held else { return }; held = false; lastEnd = Date(); press(false) }
}

/// 长按加速的触发时长。原来 0.5 秒，用户反馈比抖音原版慢、不跟手（issue #4），改 0.3。
enum DYBoostTiming {
    static let holdSeconds: Double = 0.3
}

/// 简洁/极简模式的右侧栏画在首页最外层，拿不到每一页自己的 DYBoostControl。
/// 当前这一页把自己的控制登记到这里：根层的入口按钮按住可加速，整列按钮跟着淡出（issue #4）。
@MainActor final class DYBoostRouter: ObservableObject {
    static let shared = DYBoostRouter()
    weak var control: DYBoostControl?
    @Published var boosting = false
    func adopt(_ c: DYBoostControl) {
        control = c
        if boosting != c.boosting { boosting = c.boosting }
    }
    func begin() { control?.begin() }
    func end() { control?.end() }
}

/// 根层按钮列：当前页长按加速时淡出。单独订阅 DYBoostRouter，不让整页跟着重算。
struct DDBoostFade<Content: View>: View {
    @ObservedObject private var router = DYBoostRouter.shared
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .opacity(router.boosting ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: router.boosting)
    }
}

/// 给按钮加「按住 0.3 秒进入加速、松手恢复」。GestureState 在松手和被系统取消时都会复位，不会卡在加速状态。
struct DYHoldBoost: ViewModifier {
    let control: DYBoostControl
    @GestureState private var holding = false
    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                LongPressGesture(minimumDuration: DYBoostTiming.holdSeconds)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($holding) { value, state, _ in
                        if case .second(true, _) = value { state = true }
                    })
            .onChange(of: holding) { _, now in now ? control.begin() : control.end() }
    }
}

/// 经典模式右侧控制区（对齐抖音）：整块区域按住都加速——留白、按钮间隙，按钮本身也算。
/// 手势挂在容器上与按钮同时识别；按钮的点击要用 `DYBoostControl.blocksTap` 拦一下，
/// 否则长按加速后松手会变成点赞/评论/进作者页。
struct DYHoldBoostArea: ViewModifier {
    let control: DYBoostControl?
    func body(content: Content) -> some View {
        if let control {
            content
                .contentShape(Rectangle())
                .modifier(DYHoldBoost(control: control))
        } else {
            content
        }
    }
}

struct PlayerPage: View {
    @Environment(\.dyRestrictsPlaybackToPane) private var restrictsPlaybackToPane

    private var playbackSafeAreaEdges: Edge.Set {
        restrictsPlaybackToPane ? [] : .all
    }
    @Environment(\.dyOfflineVideoPlayback) private var offlineVideoContext
    @Environment(\.duoCleanScreen) private var cleanScreen
    @Environment(\.duoContentInsets) private var chromeInsets
    @Environment(\.ddCoverLevel) private var coverLevel
    let id: String
    let url: URL
    let knownDuration: Double
    let isActive: Bool
    let bottomInset: CGFloat
    let resumePosition: Double?
    let preparedPlayer: (() -> AVPlayer?)?
    /// 还没轮到播就被回收时，把播放器还给预热池（返回 true = 池子收下了，这里不销毁）
    var returnPlayer: ((AVPlayer) -> Bool)? = nil
    let onEnded: (() -> Void)?
    let onDoubleTap: (() -> Void)?
    let onSavePosition: (Double) -> Void
    /// 竖屏时视频比屏幕窄（左右黑边）→ 放大铺满宽度；关掉则保持完整画面（上下留边）
    var fillWidth: Bool = true
    var onFillWidthChange: ((Bool) -> Void)? = nil
    var topInset: CGFloat = 0
    /// 视频弹幕（空 = 不显示）
    var danmaku: [DYDanmaku] = []
    /// 高清流起不来时的备用地址（抖音默认清晰度那条）；看门狗第一次重建就换它
    var altURL: URL? = nil
    /// 选中的清晰度描述（只进调试日志）
    var quality: String? = nil
    /// 秒开：低码率地址。滑到一条还没缓冲好的视频时先放它，高清在上层缓冲好后无缝盖上去
    var fastURL: URL? = nil
    /// 封面：首帧出来前先显示（网格里已经缓存过，点进来立刻有画面，不是黑屏转圈）
    var posterURL: URL? = nil
    /// 本地「头部缓存」能安全播到的秒数：播到这里就用 continuationURL 接上在线流，
    /// 不能让 AVPlayer 冲到没数据的尾部（那样会卡住而不是 ended）
    var headEndSeconds: Double? = nil
    /// 头部缓存播完后继续播的在线地址（一次性）
    var continuationURL: URL? = nil
    @State private var continued = false
    @State private var firstFrame = false
    @State private var offlineBadgeVisible = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// 视频画面宽高比（海报占位用同一套铺满规则，避免「先小后跳」）
    var videoAspect: Double = 0
    /// 锁屏 / 控制中心「正在播放」上显示的标题
    var title: String = ""
    var navigationSwipes = false
    var onSwipeLeft: (() -> Void)? = nil
    var onSwipeRight: (() -> Void)? = nil
    var onContextMenu: (() -> Void)? = nil
    var boost: DYBoostControl? = nil
    var onHorizontalDrag: ((CGFloat, CGFloat) -> Void)? = nil
    var onHorizontalDragEnd: ((CGFloat, CGFloat, CGFloat, Bool) -> Void)? = nil
    /// 简洁 / 极简模式：隐藏底部进度条，进度改画在模块入口外圈
    @AppStorage("douyin_chrome_mode_v1") private var chromeModeRaw = "classic"
    private var progressOnRail: Bool {
        offlineContext?.inLibrary != true && (chromeModeRaw == "minimal" || chromeModeRaw == "rail")
    }
    /// 上一次刷新「正在播放」信息的位置（约每秒一次）
    @State private var lastNowPlaying = -10.0
    /// 静音（右下角按钮，全局记住）
    @AppStorage("douyin_muted_v1") private var muted = false
    @Environment(\.ddScale) private var ui

    private var dmStress: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["DOUDUO_DM_STRESS"] == "1"
        #else
        false
        #endif
    }

    @State private var player: AVPlayer?
    @AppStorage(DYAutoPiP.storageKey) private var autoPiP = false
    @StateObject private var pictureInPicture = DYPictureInPicture()
    @State private var imgGen: AVAssetImageGenerator?
    @State private var duration: Double = 0
    @State private var current: Double = 0
    @State private var pendingOfflineSeek: Double?
    @State private var isPlaying = false
    /// 用户是不是手动暂停了：回前台不能把「我自己按的暂停」当成后台中断接着播。
    @State private var userPaused = false
    @State private var seeking = false
    @State private var seekPreview: Double = 0
    @State private var seekDelta: Double = 0
    @State private var previewImage: UIImage?
    @State private var lastPreviewAt: Double = 0
    @State private var holdAnchor: Double = 0
    @State private var rateBoost = false
    /// 设置里选的速度（全局、持久化）：所有视频都按它播
    @AppStorage("douyin_playback_rate_v1") private var playbackRate = 1.0
    /// 长按下滑锁定的 2 倍速：只锁当前这条视频，滑到下一条自动回到设置速度
    @State private var lockedBoost = false

    /// 当前实际速度：本视频锁了 2 倍就 2 倍，否则跟设置走
    /// 设置里的倍速，直接读 UserDefaults。
    /// 时间观察器和 VLC 回调是播放器创建（预加载）时挂的闭包，里面拿到的 @AppStorage 是当时的旧值，
    /// 之后在「更多」里改倍速，这些闭包还会把播放速率拉回旧值，于是当前视频不变速，滑到下一条才生效。
    private var liveRate: Double {
        let v = UserDefaults.standard.double(forKey: "douyin_playback_rate_v1")
        return v > 0 ? v : 1.0
    }
    private var effectiveRate: Double { lockedBoost ? 2 : liveRate }
    private func rateText(_ r: Double) -> String {
        r == r.rounded() ? String(format: "%.0f×", r) : String(format: "%g×", r)
    }
    @State private var dmClock = DYDanmakuClock()
    @State private var timeToken: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var barWidth: CGFloat = 1
    @State private var vlc: VLCPlayerController?        // AVPlayer 起播失败 → VLC 软解兜底
    @State private var vlcURL: URL?
    @State private var playbackIsActive = false
    @State private var vlcDeadline: Task<Void, Never>?
    @State private var savedPlaybackStarted = false
    @State private var savedPlaybackCompleted = false
    @State private var avRetried = false
    /// 秒开期间：高清播放器（静音、几乎透明地叠在低清上面缓冲），就绪后淡入接管
    @State private var hdPlayer: AVPlayer?
    @State private var hdVisible = false
    /// 头部缓存播完要接在线流：提前预热好，到点直接换图层里的 player（不重建、不重新缓冲）
    @State private var nextPlayer: AVPlayer?
    @State private var nextPrimedAt: Double = 0
    @State private var nextOpacity: Double = 0
    @State private var stalledTicks = 0
    @State private var headCompleted = false
    private var hadStagedHead: Bool { headEndSeconds != nil && continuationURL != nil }
    @State private var lastTick: Double = 0
    @State private var telemetry = DYPlaybackTelemetry()
    @State private var fastT0 = Date()
    @State private var seamAudio = DDSeamlessController()
    @State private var playbackID = UUID()
    /// 页面是否还挂着：延后执行的建播放器要先看它（页面被回收后不能再领预热池的播放器）
    @State private var pageLife = PageLife()
    @AppStorage(DYVideoAmbient.key) private var ambientLevel = DYVideoAmbient.defaultLevel
    @State private var videoScale: CGFloat = 1
    @Environment(\.dyUsesClassicVideoLayout) private var usesClassicVideoLayout
    @Environment(\.dyCommentVideoFrame) private var commentVideoFrame
    @Environment(\.accessibilityReduceMotion) private var commentReduceMotion

    /// 评论打开且外屏要把横屏视频移到评论上方：四种界面都一样（评论统一用经典几何，老板 2026-11-17 定）
    private var showsVideoAboveComments: Bool { isActive && commentVideoFrame != nil }

    private var fillsVideoPlane: Bool { fillWidth && !showsVideoAboveComments }
    /// 实际播放速度（含按住的临时 2 倍）：播放器、音频引擎、弹幕时钟和倍速角标都认这一个值
    private var actualRate: Double { rateBoost ? 2 : effectiveRate }
    private var playRate: Float { Float(actualRate) }

    private var offlineContext: DYOfflinePlaybackContext? {
        offlineVideoContext?.id == id ? offlineVideoContext : nil
    }
    private var canControlPlayback: Bool {
        playbackIsActive && (!DDPlayback.shared.offlineLibraryPresented || offlineContext?.inLibrary == true)
    }
    private var initialResumePosition: Double? {
        guard let seconds = resumePosition, seconds.isFinite,
              seconds > (offlineContext?.inLibrary == true ? 0 : 1) else { return nil }
        return seconds
    }

    private func savePosition(_ seconds: Double) {
        // A restored video may be closed before AVPlayer lands on the saved frame.
        // Always preserve the intended position while that seek is in flight.
        onSavePosition(pendingOfflineSeek ?? seconds)
    }

    private func recordOfflinePosition(_ seconds: Double) {
        guard firstFrame, playbackIsActive, !seeking, pendingOfflineSeek == nil else { return }
        offlineContext?.onPositionUpdate?(seconds)
    }

    private func restorePosition(_ seconds: Double, using player: AVPlayer) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard offlineContext?.inLibrary == true else { player.seek(to: time); return }
        pendingOfflineSeek = seconds
        current = seconds
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] done in
            DispatchQueue.main.async {
                guard done, let player, self.player === player, pendingOfflineSeek == seconds else { return }
                pendingOfflineSeek = nil
            }
        }
    }

    private var playingLocalFile: Bool {
        let source = vlcURL ?? (player?.currentItem?.asset as? AVURLAsset)?.url
        guard let source, source.isFileURL, let offlineContext else { return false }
        if !offlineContext.inLibrary, source == DYVideoCache.fileURL(id) { return true }
        return source == offlineContext.localURL()
    }

    var body: some View {
        let offlinePosition = isActive && firstFrame && playingLocalFile ? offlineContext?.position : nil
        ZStack {
            // 视频画面区出画前与留边一律纯黑，不随亮色外观变白（老板定：出帧前纯黑）
            Color.black
            // All playback entry points share this backdrop. Mask the player's
            // opaque letterbox below so uncovered areas reveal the blurred cover.
            // 老板要求「不要封面、不要预览图」：没出画面就保持纯黑（原来这里铺模糊封面，起播时会闪一下）
            // 实时环境光：盖在模糊封面上，出第一帧后淡入；VLC 兜底时没有 AVPlayerItem，保留封面
            if ambientLevel > 0, vlc == nil, let player {
                DYAmbientBackdrop(player: player, active: isActive, dim: Double(ambientLevel) / 100, fillWidth: fillWidth)
                    .ignoresSafeArea(edges: playbackSafeAreaEdges)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("douyin.video.ambient")
            }
            if usesClassicVideoLayout {
                GeometryReader { geometry in
                    let fitted = DYVideoFit.contentSize(container: geometry.size, videoAspect: videoAspect,
                                                       fillWidth: fillsVideoPlane)
                    let placement = showsVideoAboveComments
                        ? DYVideoFit.commentPlacement(viewport: geometry.frame(in: .global), fitted: fitted, target: commentVideoFrame)
                        : (scale: CGFloat(1), offset: CGSize.zero)
                    ZStack {
                        videoPlane
                            .mask {
                                Rectangle()
                                    .frame(width: fitted.width, height: fitted.height)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .scaleEffect(showsVideoAboveComments ? 1 : videoScale)
                            .modifier(DYClosedPortraitAlignment(viewport: geometry.size,
                                                               videoAspect: videoAspect, fills: fillsVideoPlane))
                        if !cleanScreen && isActive && !isPlaying && (player != nil || vlc != nil) && !seeking {
                            Image(systemName: "play.fill").font(.system(size: 52 * ui)).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(placement.scale)
                    .offset(x: placement.offset.width, y: placement.offset.height)
                    .animation(commentReduceMotion ? nil : .snappy, value: showsVideoAboveComments)
                    .allowsHitTesting(false)
                }
            } else {
                GeometryReader { outer in
                    // 评论打开、外屏把横屏视频移到评论上方：与经典同一套位移（DYVideoFit.commentPlacement），
                    // 不切换渲染分支，避免重建画面层闪黑。
                    let lift = showsVideoAboveComments
                        ? DYVideoFit.commentPlacement(viewport: outer.frame(in: .global),
                                                      fitted: DYVideoFit.contentSize(container: outer.size, videoAspect: videoAspect, fillWidth: false),
                                                      target: commentVideoFrame)
                        : (scale: CGFloat(1), offset: CGSize.zero)
                    videoPlane
                    .mask {
                    GeometryReader { geometry in
                        let fitted = DYVideoFit.contentSize(container: geometry.size, videoAspect: videoAspect, fillWidth: fillsVideoPlane)
                        Rectangle()
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                    }
                    .scaleEffect(showsVideoAboveComments ? 1 : videoScale)
                    .allowsHitTesting(false)
                        // 仅系统铰链 closed 时左贴边；展开、半折、分屏均保持原来的居中。
                        .modifier(DYClosedPortraitAlignment(viewport: outer.size,
                                                           videoAspect: videoAspect, fills: fillsVideoPlane))
                    .scaleEffect(lift.scale)
                    .offset(x: lift.offset.width, y: lift.offset.height)
                    .animation(commentReduceMotion ? nil : .snappy, value: showsVideoAboveComments)
                }
            }
            if !cleanScreen && isActive && (!danmaku.isEmpty || dmStress) {
                DYDanmakuLayer(items: danmaku, clock: dmClock, topInset: topInset)
            }
            // 手势层铺满整页（含视频上下黑边）：横滑快进 / 单击 / 双击 / 长按，竖滑漏给分页
            if player != nil || vlc != nil { gestures }
            #if DEBUG
            Text(String(format: "%.2f", videoScale)).font(.caption2).opacity(0.01)
                .accessibilityIdentifier("douyin.video.zoom")
                .allowsHitTesting(false)
            Text(fillWidth ? "fill" : "fit").font(.caption2).opacity(0.01)
                .accessibilityIdentifier("douyin.video.fitMode")
                .allowsHitTesting(false)
            Text("\(DYGestureDiagnostics.shared.boostStarts)").font(.caption2).opacity(0.01)
                .accessibilityIdentifier("douyin.video.boostStarts")
                .allowsHitTesting(false)
            if isActive {
                // 评论打开时视频是否已移到评论上方（外屏横屏视频）
                Text((showsVideoAboveComments ? "lifted" : "inPlace") + String(format: " a=%.2f", videoAspect)).font(.caption2).opacity(0.01)
                    .accessibilityIdentifier("douyin.video.lift").allowsHitTesting(false)
                Text(isPlaying ? "playing" : "paused").font(.caption2).opacity(0.01)
                    .accessibilityIdentifier("douyin.video.playback").allowsHitTesting(false)
                Text(!pictureInPicture.supported ? "unsupported" : pictureInPicture.active ? "active" : (pictureInPicture.canStart ? "ready" : "waiting"))
                    .font(.caption2).opacity(0.01)
                    .accessibilityIdentifier("douyin.video.pipState").allowsHitTesting(false)
            }
            #endif
            if seeking && !cleanScreen {
                seekHUD
            }
            if !usesClassicVideoLayout && !cleanScreen && isActive && !isPlaying && (player != nil || vlc != nil) && !seeking {
                Image(systemName: "play.fill").font(.system(size: 52 * ui)).foregroundStyle(.white.opacity(0.9))
                    .themeShadow(.mediaLabel)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            playbackBadge(offlinePosition: offlinePosition)
                // Duo 上 66pt 正好在顶栏下面；其他手机的顶栏让到了安全区下沿（#16），角标跟着往下让
                .padding(.leading, 14)
                .padding(.top, DYDuoMetrics.isDuoHardware ? 66 * ui : DYDuoMetrics.windowSafeTop + 56)
                .animation(commentReduceMotion ? nil : .easeOut(duration: 0.18), value: offlineBadgeVisible)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if isActive && !cleanScreen && !progressOnRail {
                progressBar
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("视频进度")
                    .accessibilityValue("\(Int(current.isFinite ? current : 0)) / \(Int(duration.isFinite ? duration : 0)) 秒")
                    .accessibilityIdentifier("douyin.progress")
                    .padding(chromeInsets)
                    .padding(.bottom, DYDuoMetrics.mediaBottomPadding(bottomInset))
            }
        }
        .clipped()
        .task(id: offlinePosition) {
            offlineBadgeVisible = offlinePosition != nil
            guard offlineBadgeVisible else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            offlineBadgeVisible = false
        }
        .sensoryFeedback(.impact(weight: .light), trigger: rateBoost) { old, new in !old && new }
        .onAppear {
            let life = pageLife
            life.alive = true
            life.generation += 1
            let generation = life.generation
            playbackIsActive = isActive
            if player == nil, vlc == nil {
                // 动画帧里不建播放器：非当前页延迟到滑动结束后再建（抖音也是提前预渲染，不在滑动那一帧做）
                if isActive { DYSwipeProbe.mark("setup-active(\(id.suffix(4)))"); setup() }
                else if let pre = preparedPlayer?() {
                    // 预热池里已经有这条（数据已缓冲、首帧已解码）：立刻挂画面层，手指往上拖时下一条就是真画面。
                    // 以前这里一律延后 0.35s，结果拖动中看到的下一条永远是黑的、「刚加载上」。
                    setup(prepared: pre)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + DYPlaybackTelemetry.setupDelay) { [self] in
                        // 这 0.35 秒里页面可能已经被回收（惰性分页只留屏幕上那一两页）。以前照样建：
                        // 把预热池里备好的播放器领进一个已经不在的页面，池子记成「已交出」不再重备，
                        // 这条就永远等不到「可播」，上滑被拦 3 次才放行（真机日志：刚启动时最常见）。
                        guard life.alive, life.generation == generation else { return }
                        if player == nil, vlc == nil { DYSwipeProbe.mark("setup-deferred(\(id.suffix(4)))"); setup() }
                    }
                }
            }
            #if DEBUG
            DYSearchPlaybackProbe.register(playbackID, id: id) {
                let time = player?.currentTime().seconds ?? vlc?.current ?? 0
                let hub = DDAudioEngineHub.shared
                return ["id": id, "instance": playbackID.uuidString,
                        "rate": player?.rate ?? (vlc?.isPlaying == true ? 1 : 0),
                        "time": time.isFinite ? time : 0,
                        "ready": firstFrame, "library": offlineContext?.inLibrary == true,
                        "active": playbackIsActive, "playing": isPlaying,
                        "remote": DDRemoteOwner.instance == playbackID,
                        "engine": hub.activeOwner == seamAudio.ownerID && hub.playerNode.isPlaying]
            }
            #endif
            boost?.press = { handleLongPress($0) }
            if isActive { bindRemote() }
            // The settings sheet owns a cover while its foreground offline library is playing.
            let playsInsideCover = offlineContext?.inLibrary == true && UIApplication.shared.applicationState == .active
            DDPlayback.shared.register(playbackID, stop: { pauseForBackground() }, start: { resumeAfterBackground() },
                                       retainsAudioSession: { !DDPlayback.shared.coverHold && pictureInPicture.keepsPlaybackOnExit },
                                       playsInsideCover: playsInsideCover, coverLevel: coverLevel)
        }
        .onDisappear {
            playbackIsActive = false
            if DDRemoteOwner.instance == playbackID { clearRemote() }
            #if DEBUG
            DYSearchPlaybackProbe.unregister(playbackID, id: id)
            #endif
            DDPlayback.shared.unregister(playbackID)
            telemetry.end()
            pageLife.alive = false
            teardown()
        }
        // 切后台 / 来电 / 下拉控制中心立刻停声（否则退出 App 声音还在响）
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            pauseForBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            DDAudioSessionGate.invalidate()
            pictureInPicture.didEnterBackground()
            pauseForBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // 被信息页/我的/设置等盖住时不许自己起播：以前每个播放器都直接监听回前台并恢复，
            // 绕过了 DDPlayback 的遮罩计数 → 停在信息页切出去再回来，外面的视频照样出声。
            // 遮罩期间交给 DDPlayback.releaseCover() 在真正回到首页时统一恢复。
            guard DDPlayback.shared.isUncovered(level: coverLevel) || offlineContext?.inLibrary == true else {
                DYLiveModel.log("DDRESUME skip id=\(id.suffix(6)) cover")
                return
            }
            resumeAfterBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification).receive(on: DispatchQueue.main)) { note in
            guard offlineContext != nil, playbackIsActive, isPlaying,
                  let p = player, let failedItem = note.object as? AVPlayerItem,
                  failedItem === p.currentItem else { return }
            retryPlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.playbackStalledNotification).receive(on: DispatchQueue.main)) { note in
            guard offlineContext != nil, playbackIsActive, isPlaying,
                  let p = player, let stalledItem = note.object as? AVPlayerItem,
                  stalledItem === p.currentItem else { return }
            watchdog(p)
        }
        .onChange(of: offlineContext?.localOnly) { _, localOnly in
            guard localOnly == true, !playingLocalFile, player != nil || vlc != nil else { return }
            teardown()
            avRetried = false
            firstFrame = false
            setup()
        }
        .onChange(of: cleanScreen) { _, _ in
            guard let p = player, vlc == nil else { return }
            bindSeamlessAudio(to: p, initialPos: p.currentTime().seconds, active: isActive, playing: isPlaying)
        }
        .onChange(of: autoPiP) { _, _ in
            guard let p = player, vlc == nil else { return }
            bindSeamlessAudio(to: p, initialPos: p.currentTime().seconds, active: isActive, playing: isPlaying)
        }
        .onChange(of: rateBoost) { _, on in boost?.boosting = on }
        .onChange(of: current) { _, _ in pushRailProgress() }
        .onChange(of: seeking) { _, _ in pushRailProgress() }
        .onChange(of: seekPreview) { _, _ in if seeking { pushRailProgress() } }
        .onChange(of: isActive) { _, active in if !active, rateBoost { handleLongPress(false) } }
        .onChange(of: muted) { _, m in
            guard isActive else { return }
            seamAudio.setMuted(m)
            vlc?.mediaPlayer.audio?.isMuted = m
        }
        // 设置里改播放速度 = 明确要这个速度：撤掉本条的长按锁定，当前视频立刻生效
        .onChange(of: playbackRate) { _, newRate in
            // 只有当前这一页自己响应：预加载的相邻页不动，滑过去时由 isActive 路径按新速度起播
            guard isActive else { return }
            if !rateBoost { lockedBoost = false }
            let target = rateBoost ? 2 : newRate
            // 起播一律原生声音；播放中改速度交给 seamAudio.setRate：原生时就地交接给独立引擎（不断声），
            // 已在引擎上就直接改引擎速率。不再按 1x / 非 1x 换声音通路（换通路要重绑，会断一下声，#52-1）。
            if let v = vlc { v.setRate(Float(target)); dmClock.sync(v.current, playing: v.isPlaying, rate: target) }
            else if isPlaying {
                seamAudio.setRate(Float(target))
                dmClock.sync(seamAudio.currentMediaTime ?? player?.currentTime().seconds ?? current, playing: isPlaying, rate: target)
            }
        }
        // 锁定/解锁（含锁屏控件改速度）：交给独立音频引擎即时生效
        .onChange(of: lockedBoost) { _, _ in
            if vlc == nil, isPlaying, !rateBoost { seamAudio.setRate(Float(effectiveRate)) }
        }
        .onChange(of: isActive) { _, active in
            playbackIsActive = active
            if !active {
                if DDRemoteOwner.instance == playbackID { clearRemote() }
                savedPlaybackStarted = false
                vlcDeadline?.cancel()
                vlcDeadline = nil
            }
            if !active { lockedBoost = false; videoScale = DYVideoFit.releasedScale }   // 滑走就解锁：只锁「当前这条」
            if active { bindRemote() }
            // Returning from a search result is not a request to play a video
            // the user paused before opening search.
            if active && (userPaused || !canControlPlayback) { return }
            if let v = vlc {
                if active {
                    v.mediaPlayer.audio?.isMuted = muted
                    v.resume()
                    isPlaying = true
                    watchVLC(v)
                } else { v.pause(); isPlaying = false; savePosition(v.current) }
                return
            }
            if !active && hdPlayer != nil { revertToHD() }   // 秒开中途滑走：留下高清那个，回来接着用
            guard let p = player else { if active { setup() }; return }
            if active, p.currentItem == nil || p.currentItem?.status == .failed {
                if offlineContext != nil { retryPlayback() } else { rebuild() }
                return
            }
            if active, shouldFastStart(p) {
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                try? AVAudioSession.sharedInstance().setActive(true)
                startFast(hd: p)
                return
            }
            if active {
                DYSwipeProbe.active(id)
                // 先开播：已缓冲够就跳过 AVPlayer 的「评估缓冲速率」等待，直接按目标速率走（抖音同款「零首帧」的关键）
                DDAudioSessionGate.ensureActive()
                isPlaying = true
                if DYPlaybackTelemetry.bufferedAhead(p) >= 1.5, p.currentItem?.status == .readyToPlay,
                   seamAudio.mode == .fallbackAVPlayer || seamAudio.mode == .noAudio {
                    p.isMuted = seamAudio.mode == .noAudio || muted
                    p.playImmediately(atRate: playRate)
                }
                seamAudio.setActive(true, isPlaying: true, rate: playRate, muted: muted)
                DYSwipeProbe.rate()
                let shown = firstFrame
                telemetry.begin(p, id: id, duration: knownDuration)
                DYLiveModel.log("DDFRAME \(id) shown=\(shown) t=\(String(format: "%.2f", p.currentTime().seconds)) audio=\(seamAudio.mode)")
                #if DEBUG
                logSwipeStart(p)
                #endif
                watchdog(p)
            } else {
                telemetry.end()
                let savedPos = seamAudio.currentMediaTime ?? p.currentTime().seconds
                isPlaying = false
                seamAudio.setActive(false, isPlaying: false, rate: 1, muted: true)
                savePosition(savedPos)
            }
        }
    }

    private var videoPlane: some View {
        ZStack {
            if let vlc {
                // 画面铺到屏幕边缘（状态栏/底部安全区也盖住）：跟抖音原生一样，不留上下黑边
                VLCPlayerSurface(controller: vlc, fillWidth: fillsVideoPlane).ignoresSafeArea(edges: playbackSafeAreaEdges)
            } else if let player {
                // 画面层真正有帧可显示（isReadyForDisplay）就撤掉封面：预加载 / 本地缓存的视频滑过来就是真画面，
                // 不再「先闪一下封面再播」
                ZStack {
                    VideoSurface(player: player, fillWidth: fillsVideoPlane, onReady: { if !firstFrame { firstFrame = true }; DYReadiness.mark(id) },
                                 pictureInPicture: pictureInPicture,
                                 pictureInPictureEnabled: DYAutoPiP.shortVideoWantsAutomaticPiP(
                                     preference: autoPiP, cleanScreen: cleanScreen, isActive: isActive),
                                 onPictureInPictureClose: {
                                     userPaused = true
                                     pauseInlineForBackground()
                                 },
                                 onPictureInPictureUnavailable: {
                                     if !DDPlayback.bgPlay { pauseInlineForBackground() }
                                 })
                        .ignoresSafeArea(edges: playbackSafeAreaEdges)
                    // 头部缓存接在线流：新播放器先叠在上面亮相（已缓冲、时间点对齐），再撤掉旧的，
                    // 避免换 AVPlayerLayer 的 player 时断帧
                    if let np = nextPlayer {
                        VideoSurface(player: np, fillWidth: fillsVideoPlane)
                            .ignoresSafeArea(edges: playbackSafeAreaEdges)
                            .opacity(nextOpacity)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                ProgressView().tint(.white)
            }
            if vlc == nil, let hd = hdPlayer {
                // 0.001 而不是 0：完全透明的层可能不出画面，换上来时会黑一下
                VideoSurface(player: hd, fillWidth: fillsVideoPlane).ignoresSafeArea(edges: playbackSafeAreaEdges)
                    .opacity(hdVisible ? 1 : 0.001).allowsHitTesting(false)
            }
            // 不再铺首帧图/封面临时顶替：出帧前就是纯黑，出帧即真画面（老板嫌「开头跳一下预览图」）
        }
    }

    private func pushRailProgress() {
        guard isActive, progressOnRail else { return }
        let pos = seeking ? seekPreview : current
        DDRailProgress.shared.update(id: id, fraction: duration > 0 ? pos / duration : 0, seeking: seeking)
    }

    /// 长按加速开始/结束。手势层和右侧按钮（DYBoostControl）共用。
    private func handleLongPress(_ pressing: Bool) {

        if let v = vlc {
            if pressing { v.setRate(2); rateBoost = true } else if rateBoost { v.setRate(Float(effectiveRate)); rateBoost = false }
            return
        }
        guard let p = player else { return }
        DYBoostProbe.begin(pressing ? "on" : "off", mode: "\(seamAudio.mode)", player: p)
        // PR #42（@ImSingee）：1x 原生声音下第一次变速，就地把声音交给独立引擎（AVPlayer 带音轨改速率会冲刷音频队列、画面停 50~110ms）。
        // 之后这一条留在引擎上，松手/再按都是 0ms 变速。所以这里统一走 seamAudio.setRate，不再直接调 AVPlayer.softRate。
        if pressing { rateBoost = true; seamAudio.setRate(2) }
        else if rateBoost {
            rateBoost = false
            if isPlaying { seamAudio.setRate(Float(effectiveRate)) } else { seamAudio.pause() }
        }
    }

    // MARK: 手势（UIKit 宿主：起手定方向，竖向优先让给分页）

    private var gestures: some View {
        PlayerGestureView(
            onSingleTap: { togglePlay() },
            onDoubleTap: { _, _ in onDoubleTap?() },
            onLongPress: { pressing in handleLongPress(pressing) },
            // 下滑：锁住本条视频的 2 倍速（不写设置、不影响下一条）
            onLongPressLock: { lockedBoost = true },
            // 上滑：立刻取消倍速，回到设置里的速度
            onLongPressUnlock: {
                lockedBoost = false; rateBoost = false
                if let v = vlc { v.setRate(Float(liveRate)) }
                else if isPlaying { seamAudio.setRate(Float(liveRate)) } else { seamAudio.pause() }
            },
            onContextMenu: onContextMenu,
            onSeekBegan: {
                guard duration > 0 else { return }
                if let v = vlc { current = v.current }
                else if let aSec = seamAudio.currentMediaTime { current = aSec }
                else if let p = player { current = p.currentTime().seconds } else { return }
                holdAnchor = current
                seekPreview = current
                seeking = true
            },
            onSeekChanged: { dx, w in
                guard duration > 0, seeking else { return }
                seekPreview = max(0, min(duration, holdAnchor + dx / max(w, 1) * duration * 0.9))
                seekDelta = seekPreview - current
                requestPreview(seekPreview)
            },
            onSeekEnded: {
                #if DEBUG
                    #endif
                if seeking { seekTo(seekPreview); seeking = false; previewImage = nil }
            },
            verticalFirst: true,
            onHorizontalSwipe: navigationSwipes && onHorizontalDrag == nil ? { left in
                if left { onSwipeLeft?() } else { onSwipeRight?() }
            } : nil,
            onHorizontalDrag: onHorizontalDrag,
            onHorizontalDragEnd: onHorizontalDragEnd,
            onPinchChanged: { scale in
                videoScale = min(1.2, max(0.8, scale))
            },
            onPinchEnded: { scale in
                // 用识别器的最终 scale 提交全局铺满偏好，松手后缩放回到 1。
                DYVideoFit.applyPinchEnd(magnitude: scale, endedNormally: true, notify: onFillWidthChange)
                withAnimation(.snappy(duration: 0.22)) { videoScale = DYVideoFit.releasedScale }
            },
            onPinchCancelled: {
                withAnimation(.snappy(duration: 0.22)) { videoScale = DYVideoFit.releasedScale }
            }
        )
    }

    @ViewBuilder private func playbackBadge(offlinePosition: Int?) -> some View {
        if !cleanScreen {
            if !rateBoost, !seeking, offlineBadgeVisible || voiceOver,
               let position = offlinePosition, let offlineContext {
                DYOfflinePlaybackIndicator(position: position, total: offlineContext.total)
            } else if actualRate != 1 {
                playbackSpeedBadge
            }
        }
    }

    private var playbackSpeedBadge: some View {
        let detail: String?
        if rateBoost {
            detail = lockedBoost ? "上滑取消倍速" : "下滑锁定倍速"
        } else {
            detail = lockedBoost ? "已锁定本条 · 长按上滑取消" : nil
        }
        return DYPlaybackBadge(title: .speed(rateText(actualRate)), detail: detail,
                               showsLockInstructions: lockedBoost && !rateBoost)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("douyin.playbackSpeedHint")
    }

    private var seekHUD: some View {
        VStack(spacing: 10) {
            Group {
                if let img = previewImage {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.black.opacity(0.4).overlay(ProgressView().tint(.white))
                }
            }
            .frame(width: 196 * ui, height: 110 * ui)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                Text(fmt(seekPreview)).font(.subheadline.weight(.bold).monospacedDigit())
                Text("/ " + fmt(duration)).font(.caption.monospacedDigit()).opacity(0.6)
                Text((seekDelta >= 0 ? "+" : "") + String(format: "%.0fs", seekDelta))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(seekDelta >= 0 ? Color.green : Color.orange)
            }
            .foregroundStyle(.white)
        }
        .dyPlaybackHintStyle()
    }

    private var progressBar: some View {
        let pos = seeking ? seekPreview : current
        let frac = duration > 0 ? max(0, min(1, pos / duration)) : 0
        // 不显示时间（拖动时预览气泡里有），只留细进度条
        return VStack(spacing: 0) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    // 平时半透明不挡画面，只有进度条拖动时才变实
                    Capsule().fill(.white.opacity(seeking ? 0.28 : 0.12)).frame(height: (seeking ? 6 : 2) * ui)
                    Capsule().fill(.white.opacity(seeking ? 1 : 0.4)).frame(width: g.size.width * frac, height: (seeking ? 6 : 2) * ui)
                    Circle().fill(.white.opacity(seeking ? 1 : 0.45)).frame(width: (seeking ? 15 : 6) * ui, height: (seeking ? 15 : 6) * ui)
                        .offset(x: max(0, g.size.width * frac - (seeking ? 7.5 : 3) * ui))
                }
                .frame(maxHeight: .infinity)
                .onAppear { barWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in barWidth = w }
            }
            .frame(height: 16 * ui)
            .padding(.horizontal, 16 * ui)
            // 拖动区：进度条往上多 20pt 好按，不往下占空白
            .padding(.top, 20 * ui)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard duration > 0 else { return }
                        if !seeking { holdAnchor = current; seeking = true }
                        seekPreview = max(0, min(duration, holdAnchor + v.translation.width / max(barWidth, 1) * duration))
                        seekDelta = seekPreview - current
                        requestPreview(seekPreview)
                    }
                    .onEnded { _ in if seeking { seekTo(seekPreview); seeking = false; previewImage = nil } })
        }
    }

    // MARK: 播放

    /// 头部缓存文件：把播放终点钉在安全位置，播到这里会正常 ended，而不是卡在没数据的尾部
    private func makeItem(asset: AVAsset) -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        if let h = headEndSeconds, h > 0 {
            item.forwardPlaybackEndTime = CMTime(seconds: h, preferredTimescale: 600)
        }
        return item
    }

    /// 头部缓存播完 → 用在线流从同一时间点接上（一次性；接上后不再触发）
    @discardableResult
    private func continueFromRemote(_ p: AVPlayer) -> Bool {
        guard !continued, let remote = continuationURL else { return false }
        let start = headEndSeconds ?? p.currentTime().seconds
        // 预热好的播放器直接接管：图层里的 player 从 p 换成 np（都不是 nil，不重建 surface）
        if let np = nextPlayer, np.currentItem?.status == .readyToPlay {
            handOver(to: np, from: p, at: start, primed: true)
            return true
        }
        continued = true
        #if DEBUG
        ddWrite("DDHEAD continue remote(cold) at \(String(format: "%.1f", start))")
        #endif
        teardownPlayerOnly()
        let np = AVPlayer(playerItem: AVPlayerItem(asset: DYMedia.asset(remote)))
        np.automaticallyWaitsToMinimizeStalling = true
        player = np
        attachObservers(np)
        isPlaying = true
        bindSeamlessAudio(to: np, initialPos: start, active: isActive, playing: true)
        np.seek(to: CMTime(seconds: start, preferredTimescale: 600)) { _ in np.rate = playRate }
        watchdog(np)
        return true
    }

    /// 距接续点还有几秒时，先把在线流的播放器拉起来缓冲（静音、不显示），到点零等待接管
    private func primeContinuation() {
        guard !continued, nextPlayer == nil, let remote = continuationURL, let h = headEndSeconds, h > 0 else { return }
        // 整条已经下完（多数视频在播到接续点前就下完了）→ 直接读本地文件续播，
        // 本地 seek 是瞬时的，切换后不会再有等网络缓冲的卡顿
        let localFull = DYVideoCache.localURL(id)
        let src = localFull ?? remote
        let np = AVPlayer(playerItem: AVPlayerItem(asset: DYMedia.asset(src)))
        np.automaticallyWaitsToMinimizeStalling = true
        np.isMuted = true
        // 缓冲就绪后停住；接续点前后各留一点已缓冲数据，切换时 seek 是瞬时的
        np.seek(to: CMTime(seconds: max(0, h - 0.4), preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            DispatchQueue.main.async {
                np.play()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if self.nextPlayer === np { np.pause() } }
            }
        }
        nextOpacity = 0.01          // 极低透明度常驻：layer 一直在出帧，切换时只改透明度，不来不急建层
        nextPlayer = np
        nextPrimedAt = h
        #if DEBUG
        ddWrite("DDHEAD prime at \(String(format: "%.1f", h)) src=\(localFull != nil ? "local" : "remote")")
        #endif
    }

    /// 把画面和时间轴从旧 player 交接到新 player：新画面先叠上层亮相，再撤旧层，全程不断帧
    private func handOver(to np: AVPlayer, from old: AVPlayer, at start: Double, primed: Bool) {
        guard !continued else { return }
        continued = true
        #if DEBUG
        ddWrite("DDHEAD continue remote at \(String(format: "%.1f", start)) primed=\(primed)")
        #endif
        let wasPlaying = isPlaying
        np.isMuted = true
        // 先把它精确定位到接续点（预热过的话这段是已缓冲区间，seek 基本瞬时），
        // seek 完成才让它亮相，避免露出预热时的错帧
        np.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            DispatchQueue.main.async {
                if wasPlaying { np.rate = self.playRate }
                self.nextOpacity = 1
                // 新画面已经在顶层播同一位置 → 把主 player 换过去（此时 layer 换绑不会露黑）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    if let t = self.timeToken { old.removeTimeObserver(t); self.timeToken = nil }
                    if let o = self.endObserver { NotificationCenter.default.removeObserver(o); self.endObserver = nil }
                    self.player = np
                    self.nextOpacity = 0
                    self.nextPlayer = nil
                    self.attachObservers(np)
                    self.isPlaying = wasPlaying
                    self.bindSeamlessAudio(to: np, initialPos: np.currentTime().seconds, active: self.isActive, playing: wasPlaying)
                    self.watchdog(np)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { old.replaceCurrentItem(with: nil) }
                }
            }
        }
    }

    private func bindSeamlessAudio(to p: AVPlayer, initialPos: Double?, active: Bool, playing: Bool) {
        seamAudio.onBackgroundEnded = { [weak p] in
            guard let p, player === p, canControlPlayback, isPlaying else { return }
            noteSavedPlayback(completed: true)
            if completeOfflinePlayback() { return }
            if let onEnded { onEnded() }
            else {
                p.seek(to: .zero)
                seamAudio.loopToZero(rate: playRate, muted: muted)
            }
        }
        let nativeAudio = DYAutoPiP.bindsNativeAudio(preference: autoPiP, cleanScreen: cleanScreen)
        seamAudio.bind(player: p, initialPosition: initialPos, isActive: active, isPlaying: playing, rate: playRate, muted: muted,
                       useEngine: !nativeAudio && DDSeamlessController.engineWanted, engineHandoff: !nativeAudio)
    }

    private func setup(prepared: AVPlayer? = nil) {
        let localURL = offlineContext?.localOnly == true ? offlineContext?.localURL() : nil
        if offlineContext?.localOnly == true, localURL == nil {
            if playbackIsActive { offlineContext?.onFailure() }
            return
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_FORCE_VLC"] == "1" {
            if knownDuration > 0 { duration = knownDuration }
            startVLC(); return
        }
        #endif
        let candidate = prepared ?? preparedPlayer?()
        let pre = localURL == nil || (candidate?.currentItem?.asset as? AVURLAsset)?.url == localURL ? candidate : nil
        DYLiveModel.log("DDSETUP \(id.suffix(6)) active=\(isActive) pre=\(pre != nil) status=\(pre?.currentItem?.status.rawValue ?? -1) buf=\(String(format: "%.1f", pre.map { DYPlaybackTelemetry.bufferedAhead($0) } ?? 0))s")
        #if DEBUG
        let preReady = pre?.currentItem?.status == .readyToPlay
        let preBuf = pre?.currentItem?.loadedTimeRanges.first.map { CMTimeGetSeconds($0.timeRangeValue.duration) } ?? 0
        #endif
        let asset = (pre?.currentItem?.asset as? AVURLAsset) ?? DYMedia.asset(localURL ?? url)
        let p = pre ?? AVPlayer(playerItem: makeItem(asset: asset))
        if localURL == nil, let pre, let h = headEndSeconds, pre.currentItem?.forwardPlaybackEndTime.seconds ?? 0 <= 0 {
            pre.currentItem?.forwardPlaybackEndTime = CMTime(seconds: h, preferredTimescale: 600)
        }
        p.automaticallyWaitsToMinimizeStalling = true
        player = p
        if knownDuration > 0 { duration = knownDuration }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 180)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1.5, preferredTimescale: 600)
        imgGen = gen
        attachObservers(p)
        if let seconds = initialResumePosition { restorePosition(seconds, using: p) }
        let shouldPlay = canControlPlayback && !userPaused
        if shouldPlay, shouldFastStart(p) {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            startFast(hd: p)
            return
        }
        isPlaying = shouldPlay
        bindSeamlessAudio(to: p, initialPos: initialResumePosition, active: isActive, playing: shouldPlay)
        if shouldPlay {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            p.rate = playRate
        }
        if shouldPlay {
            DYSwipeProbe.active(id)
            watchdog(p); telemetry.begin(p, id: id, duration: knownDuration)
        }
        else { primeFirstFrame(p) }
        #if DEBUG
        if isActive {
            let t0 = Date()
            func probe(_ n: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if p.currentTime().seconds > 0.05 {
                        ddWrite("DDSTART \(id) local=\(url.isFileURL) pre=\(pre != nil) preReady=\(preReady) preBuf=\(String(format: "%.1f", preBuf))s q=\(quality ?? "-") 起播用时=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s 距启动=\(String(format: "%.2f", Date().timeIntervalSince(DDLaunch.t0)))s")
                    } else if n < 100 { probe(n + 1) }
                }
            }
            probe(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            ddWrite("DDPLAY \(id) active=\(isActive) engine=\(vlc == nil ? "AV" : "VLC") status=\(p.currentItem?.status.rawValue ?? -1) t=\(p.currentTime().seconds) err=\(String(describing: p.currentItem?.error))")
        }
        #endif
    }

    #if DEBUG
    /// 滑到这条时记一笔：滑入时缓冲了多少、是不是本地文件、后台缓存在下几条，以及多久真正动起来
    private func logSwipeStart(_ p: AVPlayer, fast: Bool = false) {
        let t0 = Date(), start = p.currentTime().seconds
        let it = p.currentItem
        let buf = it?.loadedTimeRanges.first.map { CMTimeGetSeconds($0.timeRangeValue.duration) } ?? 0
        let st = it?.status.rawValue ?? -1
        let local = (it?.asset as? AVURLAsset)?.url.isFileURL ?? false
        let dl = DYVideoCache.activeDownloads
        let th = ProcessInfo.processInfo.thermalState.rawValue   // 0 正常 1 微热 2 烫 3 很烫
        func probe(_ n: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard player === p else { return }
                if p.currentTime().seconds > start + 0.05 {
                    ddWrite("DDSWIPE \(id) 起播=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s fast=\(fast) local=\(local) status=\(st) buf=\(String(format: "%.1f", buf))s dl=\(dl) th=\(th) q=\(quality ?? "-")")
                } else if n < 400 { probe(n + 1) }
                else { ddWrite("DDSWIPE \(id) 20s 未起播 local=\(local) status=\(st) buf=\(String(format: "%.1f", buf))s dl=\(dl)") }
            }
        }
        probe(0)
    }
    #endif

    // MARK: 秒开（低码率先放，高清缓冲好后无缝接管）

    /// 冷：没就绪，或就绪了但缓冲不到 1 秒。本地文件 / 没有低码率档 / VLC 接管中都不走秒开
    private func shouldFastStart(_ p: AVPlayer) -> Bool {
        // 默认关：实测低清也要 1–2s 才起播、还要两路解码陪跑发热；直连 CDN 后冷启动本身快了 ~1s。菜单里可开
        guard UserDefaults.standard.bool(forKey: "douyin_faststart_v1"), fastURL != nil, vlc == nil, hdPlayer == nil, !url.isFileURL, let it = p.currentItem else { return false }
        if (it.asset as? AVURLAsset)?.url.isFileURL == true { return false }
        let buf = it.loadedTimeRanges.first.map { CMTimeGetSeconds($0.timeRangeValue.duration) } ?? 0
        return it.status != .readyToPlay || buf < 1
    }

    private func startFast(hd: AVPlayer) {
        guard let f = fastURL else { return }
        detachObservers()
        let resume = hd.currentTime()
        // 高清：静音陪跑（播着 AVPlayer 才会一直往前缓冲），放在上层几乎透明
        hd.isMuted = true
        hd.automaticallyWaitsToMinimizeStalling = true
        hd.currentItem?.preferredForwardBufferDuration = 0
        hd.play()
        hdPlayer = hd; hdVisible = false
        // 低清：拿到一点数据就开播
        let low = AVPlayer(playerItem: AVPlayerItem(asset: DYMedia.asset(f)))
        low.automaticallyWaitsToMinimizeStalling = false
        if resume.seconds > 1 { low.seek(to: resume) }
        player = low
        attachObservers(low)
        isPlaying = true
        bindSeamlessAudio(to: low, initialPos: resume.seconds > 1 ? resume.seconds : nil, active: isActive, playing: true)
        low.rate = playRate
        fastT0 = Date()
        #if DEBUG
        logSwipeStart(low, fast: true)
        #endif
        watchdog(low)
        pollUpgrade(low, hd, 0)
    }

    /// 高清在 target 之后已缓冲多少秒（target 不在已缓冲区间里 → 0）
    private func bufferedAhead(_ it: AVPlayerItem, from target: Double) -> Double {
        for v in it.loadedTimeRanges {
            let r = v.timeRangeValue
            let s = r.start.seconds, e = (r.start + r.duration).seconds
            if target >= s - 0.05 && target <= e { return e - target }
        }
        return 0
    }

    private func pollUpgrade(_ low: AVPlayer, _ hd: AVPlayer, _ n: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard isActive, player === low, hdPlayer === hd else { return }
            if pictureInPicture.active { cancelUpgrade(); return }
            guard let it = hd.currentItem, it.status != .failed else { cancelUpgrade(); return }
            let t = low.currentTime().seconds
            if it.status == .readyToPlay, !seeking, bufferedAhead(it, from: t + 0.1) >= 1.5 {
                swapToHD(low, hd)
            } else if n < 160 {
                pollUpgrade(low, hd, n + 1)      // 最多等 40 秒；网太慢就一直看低清，不卡
            } else {
                cancelUpgrade()
            }
        }
    }

    private func swapToHD(_ low: AVPlayer, _ hd: AVPlayer) {
        let target = low.currentTime() + CMTime(seconds: 0.08, preferredTimescale: 600)
        hd.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { done in
            DispatchQueue.main.async {
                guard done, isActive, player === low, hdPlayer === hd else { return }
                hd.isMuted = true
                hd.rate = isPlaying ? playRate : 0
                // 等高清出两帧画面再盖上去，声音同时交接
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    guard player === low, hdPlayer === hd else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { hdVisible = true }
                    low.isMuted = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { finishUpgrade(low, hd) }
                }
            }
        }
    }

    /// 底层也换成高清（上层还盖着，所以不会黑一下），再拆掉低清和上层
    private func finishUpgrade(_ low: AVPlayer, _ hd: AVPlayer) {
        guard player === low, hdPlayer === hd else { return }
        detachObservers()
        low.pause(); low.replaceCurrentItem(with: nil)
        player = hd
        attachObservers(hd)
        bindSeamlessAudio(to: hd, initialPos: hd.currentTime().seconds, active: isActive, playing: isPlaying)
        #if DEBUG
        ddWrite("DDUPGRADE \(id) 高清接管=\(String(format: "%.2f", Date().timeIntervalSince(fastT0)))s")
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if hdPlayer === hd { hdPlayer = nil; hdVisible = false }
        }
    }

    /// 秒开中途滑走：丢掉低清，把高清（停在同一时间点）留作这一页的播放器
    private func revertToHD() {
        guard let hd = hdPlayer, let low = player else { return }
        let t = low.currentTime()
        detachObservers()
        seamAudio.reset()
        low.pause(); low.replaceCurrentItem(with: nil)
        hd.pause(); hd.isMuted = true
        hd.seek(to: t)
        player = hd
        attachObservers(hd)
        bindSeamlessAudio(to: hd, initialPos: t.seconds, active: false, playing: false)
        hdPlayer = nil; hdVisible = false
    }

    private func cancelUpgrade() {
        guard let hd = hdPlayer else { return }
        hd.pause(); hd.replaceCurrentItem(with: nil)
        hdPlayer = nil; hdVisible = false
    }

    private func detachObservers() {
        if let t = timeToken { player?.removeTimeObserver(t); timeToken = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
    }

    /// 提前挂载的相邻页：暂停的 AVPlayer 不会自己解第一帧，画面层一直是黑的，滑进来才开始解 → 「黑屏一下再播」。
    /// 就绪后 preroll（解码首帧、填满开头缓冲）并把画面停在第一帧，滑过来直接有画面。
    @State private var primeObs: NSKeyValueObservation?
    private func primeFirstFrame(_ p: AVPlayer) {
        guard let it = p.currentItem else { return }
        let start = offlineContext?.inLibrary != true
            ? initialResumePosition.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .zero
            : .zero
        func prime() {
            guard player === p, !isActive, p.rate == 0 else { return }
            // 起点 0：开头就是关键帧，直接 preroll（解码首帧 + 缓冲起播所需数据），画面层随即有帧；
            // 有续播位置时才 seek（容差放宽到前后 0.5 秒，落在最近的关键帧上，不做整段解码）
            let preroll = {
                DispatchQueue.main.async {
                    guard player === p, !isActive, p.rate == 0, p.status == .readyToPlay else { return }
                    p.preroll(atRate: 1) { _ in }
                }
            }
            if start == .zero { preroll() }
            else {
                let tol = CMTime(seconds: 0.5, preferredTimescale: 600)
                p.seek(to: start, toleranceBefore: tol, toleranceAfter: tol) { _ in preroll() }
            }
        }
        // 数据一到就登记可播：实测起播 0.10s，比等 preroll 回调快得多。
        // 之前只在 preroll 完成/画面层出帧时登记，登记慢一步，就变成「每次都要滑第二次」。
        func markReady() { DYReadiness.mark(id) }
        if it.status == .readyToPlay { markReady(); prime(); return }
        primeObs = it.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async { primeObs?.invalidate(); primeObs = nil; markReady(); prime() }
        }
    }

    /// 起播看门狗：当前屏 6 秒还没走（网络抖 / 预加载的 item 失效），重建播放项再来一次
    private func watchdog(_ p: AVPlayer) {
        // 起播看门狗：真失败(status=failed)立刻换路；只是还在加载(status=unknown)给到 5 秒再判，
        // 别把正常加载中的长视频误判成卡死（上一版 2 秒就切，切到了已 403 的直连 CDN，反而黑屏 14–28 秒）
        let start = p.currentTime().seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            let active = offlineContext == nil ? isActive : playbackIsActive
            guard active, isPlaying, player === p, !seeking, vlc == nil else { return }
            let failedNow = p.currentItem?.status == .failed
            let position = p.currentTime().seconds
            let waiting = offlineContext != nil && p.timeControlStatus == .waitingToPlayAtSpecifiedRate &&
                (!position.isFinite || position <= start + 0.02)
            let stuck = p.currentItem == nil || failedNow || position < 0.1 || waiting
            guard stuck else { return }
            let st = p.currentItem?.status.rawValue ?? -1
            let err = p.currentItem?.error.map { "\(($0 as NSError).domain)/\(($0 as NSError).code)" } ?? "-"
            DYLiveModel.log("DDSTARTDIAG \(id) status=\(st) err=\(err) host=\(url.host ?? "-") alt=\(altURL?.host ?? "-") retried=\(avRetried)")
            retryPlayback()
        }
    }

    private func retryPlayback() {
        if avRetried {
            startVLC()
        } else {
            avRetried = true
            rebuild()
        }
    }

    private func rebuild() {
        cancelUpgrade()
        teardownPlayerOnly()
        #if DEBUG
        ddWrite("DDREBUILD \(id) alt=\(altURL != nil)")
        #endif
        let source = offlineContext?.localOnly == true
            ? offlineContext?.localURL()
            : (altURL ?? url)
        guard let source else {
            if playbackIsActive { offlineContext?.onFailure() }
            return
        }
        let item = makeItem(asset: DYMedia.asset(source))
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        player = p
        attachObservers(p)
        let localResume = offlineContext?.inLibrary == true ? pendingOfflineSeek ?? (firstFrame ? current : initialResumePosition) : nil
        if let localResume { restorePosition(localResume, using: p) }
        isPlaying = true
        bindSeamlessAudio(to: p, initialPos: localResume, active: isActive, playing: true)
        p.rate = playRate
        watchdog(p)
    }

    /// 失焦/切后台：短视频立即暂停。音频会话由 DDPlayback 统一释放，
    /// 避免把仍在出声的直播会话一起拆掉。「后台播放」打开时这里直接返回。
    private func pauseForBackground() {
        let behindOfflineLibrary = DDPlayback.shared.offlineLibraryPresented && offlineContext?.inLibrary != true
        if behindOfflineLibrary, DDRemoteOwner.instance == playbackID { clearRemote() }
        if !behindOfflineLibrary && !DDPlayback.shared.coverHold && pictureInPicture.keepsPlaybackOnExit {
            // 要进系统画中画：前台变速时声音可能交给了独立引擎，小窗只认 AVPlayer 原生声音 → 先交回再离开。
            // 这里由 DDPlayback.pauseAll 在停引擎之前调用，交回后引擎停了也不影响原生声音。
            seamAudio.returnToNativeAudio(reason: "pip-exit")
            return
        }
        if !behindOfflineLibrary && DDPlayback.bgPlay { return }
        pauseInlineForBackground()
    }

    private func pauseInlineForBackground() {
        #if DEBUG
        ddWrite("DDBG pauseForBackground id=\(id) vlc=\(vlc != nil) av=\(player != nil) rate=\(player?.rate ?? -9) t=\(String(format: "%.1f", player?.currentTime().seconds ?? -1)) active=\(isActive)")
        #endif
        if let v = vlc, v.isPlaying {
            v.pause(); isPlaying = false
            savePosition(v.current)
        }
        if let p = player {
            let pos = seamAudio.currentMediaTime ?? p.currentTime().seconds
            if isPlaying || p.rate != 0 {
                seamAudio.pause()
                p.pause()
                isPlaying = false
                savePosition(pos)
            } else {
                seamAudio.pause()
            }
        }
        hdPlayer?.pause()
        #if DEBUG
        ddWrite("DDBG pauseForBackground id=\(id) vlc=\(vlc != nil) av=\(player != nil) rate=\(player?.rate ?? -9) t=\(String(format: "%.1f", player?.currentTime().seconds ?? -1)) active=\(isActive)")
        #endif
    }

    /// 回到前台：还是当前条就接着播
    private func resumeAfterBackground() {
        #if DEBUG
        ddWrite("DDBG resumeAfterBackground id=\(id) active=\(isActive) av=\(player != nil) t=\(String(format: "%.1f", player?.currentTime().seconds ?? -1))")
        #endif
        // The registration closure can outlive the view value from onAppear.
        // Read the live state so a previously visible clip cannot resume.
        guard canControlPlayback else { return }
        if pictureInPicture.active {
            userPaused = (player?.rate ?? 0) == 0
            isPlaying = !userPaused
        }
        pictureInPicture.returnToInline()
        if DDPlayback.bgPlay && isPlaying {
            seamAudio.syncAfterForeground(rate: playRate, muted: muted)
            return
        }
        guard DYResumePolicy.shouldResumeAfterBackground(userPaused: userPaused) else { return }
        if let v = vlc {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            v.mediaPlayer.audio?.isMuted = muted
            v.resume(); isPlaying = true
            watchVLC(v)
            return
        }
        if let p = player {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            isPlaying = true
            seamAudio.play(rate: playRate, muted: muted)
            hdPlayer?.play()      // 秒开中：高清继续静音陪跑缓冲
            if offlineContext != nil, p.currentItem?.status == .failed || !firstFrame { watchdog(p) }
        }
    }

    /// VLC 软解接管（AVPlayer 两次起不来 / 状态 failed）
    private func startVLC() {
        cancelUpgrade()
        teardownPlayerOnly()
        let source = offlineContext?.localOnly == true ? offlineContext?.localURL() : url
        guard let source else {
            if playbackIsActive { offlineContext?.onFailure() }
            return
        }
        let v = VLCPlayerController()
        var restoreWithVLC = offlineContext?.inLibrary == true ? pendingOfflineSeek ?? (firstFrame ? current : initialResumePosition) : nil
        if let restoreWithVLC { pendingOfflineSeek = restoreWithVLC; current = restoreWithVLC }
        v.onProgress = { [weak v] pos in
            guard let v else { return }
            if let target = restoreWithVLC, pos > 0.02 {
                restoreWithVLC = nil
                pendingOfflineSeek = nil
                v.seekTo(target)
                return
            }
            if !seeking && pendingOfflineSeek == nil { current = pos }
            if !firstFrame, pos > 0.02 { firstFrame = true }
            recordOfflinePosition(pos)
            if v.isPlaying, pos >= playbackRecordThreshold { noteSavedPlayback(completed: false) }
            refreshNowPlaying(pos)
            if playbackIsActive { DDNowPlaying.id = id; DDNowPlaying.time = pos }
            dmClock.sync(pos, playing: v.isPlaying && !seeking, rate: Double(v.mediaPlayer.rate))
            if !rateBoost, v.isPlaying, v.mediaPlayer.rate != Float(effectiveRate) { v.setRate(Float(effectiveRate)) }
            if v.duration > 0 { duration = v.duration }
        }
        v.onEnd = { [weak v] in
            DispatchQueue.main.async {
                guard let v, vlc === v, canControlPlayback, isPlaying else { return }
                noteSavedPlayback(completed: true)
                if completeOfflinePlayback() { return }
                if let onEnded { onEnded() } else { v.seekTo(0); v.resume() }
            }
        }
        vlc = v
        vlcURL = source
        isPlaying = canControlPlayback && !userPaused
        if offlineContext != nil {
            v.onError = { [weak v] in
                guard let v else { return }
                failVLC(v)
            }
        }
        v.play(url: source, autoplay: isPlaying, headers: DYMedia.headers)
        if knownDuration > 0 { v.setKnownDuration(knownDuration) }
        watchVLC(v)
        #if DEBUG
        ddWrite("DDVLC takeover \(id)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { ddWrite("DDVLC \(id) t=\(v.current) playing=\(v.isPlaying)") }
        #endif
    }

    private func watchVLC(_ v: VLCPlayerController) {
        guard offlineContext != nil, playbackIsActive, isPlaying, v.current < 0.1 else { return }
        vlcDeadline?.cancel()
        vlcDeadline = Task { [weak v] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            if let v, v.current < 0.1 { failVLC(v) }
        }
    }

    private func failVLC(_ v: VLCPlayerController) {
        guard vlc === v, playbackIsActive, isPlaying, !userPaused else { return }
        vlcDeadline?.cancel()
        vlcDeadline = nil
        isPlaying = false
        v.mediaPlayer.pause()
        offlineContext?.onFailure()
    }

    private func completeOfflinePlayback() -> Bool {
        guard playbackIsActive, playingLocalFile else { return false }
        return offlineContext?.onFinished?() ?? false
    }

    private var playbackRecordThreshold: Double { min(1, max(0.1, duration * 0.1)) }

    private func noteSavedPlayback(completed: Bool) {
        guard offlineContext != nil, playbackIsActive, !seeking,
              completed ? !savedPlaybackCompleted : !savedPlaybackStarted else { return }
        let source = vlcURL ?? (player?.currentItem?.asset as? AVURLAsset)?.url
        guard let source, source.isFileURL, source == DYOfflineVideoStore.localURL(id) else { return }
        savedPlaybackStarted = true
        if completed { savedPlaybackCompleted = true }
        Task { await DYOfflineDownloads.shared.recordPlayback(of: id, completed: completed) }
    }

    private func attachObservers(_ p: AVPlayer) {
        timeToken = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { t in
            MainActor.assumeIsolated {
                let pos = seamAudio.currentMediaTime ?? t.seconds
                if !seeking && pendingOfflineSeek == nil { current = pos }
                if !firstFrame, t.seconds > 0.02 { firstFrame = true }
                recordOfflinePosition(pos)
                if p.rate > 0, t.seconds >= playbackRecordThreshold { noteSavedPlayback(completed: false) }
                // 往回跳检测：当前页播放中时间倒退（非用户拖动/循环）就记一笔，用来验证「回弹一帧」是否还在
                if isActive, !seeking, p.rate > 0, lastTick > 0.3, t.seconds + 0.12 < lastTick, t.seconds > 0.05 {
                    DYLiveModel.log("DDBACKJUMP \(id.suffix(6)) \(String(format: "%.2f→%.2f", lastTick, t.seconds))")
                }
                lastTick = t.seconds
                // 起播/卡顿等待数据时让缓存下载让路（否则长视频被下载抢死，实测等 12 秒）
                let waiting = player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if playbackIsActive { DYVideoCache.shared.reportPlaybackWaiting(waiting) }
                // 长视频从预存头段起播后，让剩余分段等播放稳定再下载。
                if playbackIsActive, offlineContext?.localOnly != true, !headCompleted, t.seconds > 10, hadStagedHead {
                    headCompleted = true
                    Task { await DYVideoCache.shared.completeLong(id: id) }
                }
                if playbackIsActive { DDNowPlaying.id = id; DDNowPlaying.time = pos }
                dmClock.sync(pos, playing: isPlaying && p.rate > 0 && !seeking, rate: Double(playRate))
                refreshNowPlaying(pos)
                // 原生声音模式下每 0.25s 拉回锁定倍速（交给 seamAudio：能交接给独立引擎就不走会卡一下的原生变速）；
                // engaged 模式下由 seamAudio 的 Soft PLL 维护速率
                if seamAudio.mode == .fallbackAVPlayer, !rateBoost, p.rate > 0, p.rate != Float(effectiveRate), !AVPlayer.softRatePending {
                    seamAudio.setRate(Float(effectiveRate))
                }
                if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
                // 头部缓存 → 在线流：提前预热，到点直接交接（不等 ended，避免尾部没数据干等）
                if offlineContext?.localOnly != true, let h = headEndSeconds, h > 0, !continued {
                    if nextPlayer == nil, t.seconds > h - 4 { primeContinuation() }
                    if t.seconds >= h - 0.12, let np = nextPlayer, np.currentItem?.status == .readyToPlay {
                        DispatchQueue.main.async { if !continued { handOver(to: np, from: p, at: h, primed: true) } }
                    }
                    // 兜底：预估接续点比真实可播长度乐观时，头部数据会先耗尽（rate 掉 0、时间不动），
                    // 这时候立刻交接，不让画面干等
                    if isPlaying, !seeking, p.rate == 0, let np = nextPlayer, np.currentItem?.status == .readyToPlay {
                        stalledTicks += 1
                        if stalledTicks >= 4 {
                            let at = max(t.seconds, 0.5)
                            DispatchQueue.main.async { if !continued { handOver(to: np, from: p, at: at, primed: true) } }
                        }
                    } else {
                        stalledTicks = 0
                    }
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: p.currentItem, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard canControlPlayback, isPlaying, player === p else { return }
                DYLiveModel.log("DDEND id=\(id.suffix(4)) autoNext=\(onEnded != nil) active=\(playbackIsActive)")
                if offlineContext?.localOnly != true, continueFromRemote(p) { return }
                noteSavedPlayback(completed: true)
                if completeOfflinePlayback() { return }
                if let onEnded {
                    onEnded()
                } else {
                    // 抖音同款：单条循环
                    p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        DispatchQueue.main.async {
                            guard canControlPlayback, isPlaying, player === p else { return }
                            if seamAudio.isEngaged {
                                seamAudio.loopToZero(rate: playRate, muted: muted)
                            } else if isPlaying {
                                p.rate = playRate
                            }
                        }
                    }
                }
            }
        }
    }

    private func teardownPlayerOnly() {
        pictureInPicture.invalidate()
        seamAudio.reset()
        if let t = timeToken { player?.removeTimeObserver(t); timeToken = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    // MARK: 锁屏 / 控制中心播放控件（播放暂停、前进后退 10 秒、进度条、倍速）

    private func clearRemote() {
        let c = MPRemoteCommandCenter.shared()
        [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand, c.skipForwardCommand, c.skipBackwardCommand,
         c.changePlaybackPositionCommand, c.changePlaybackRateCommand].forEach { $0.removeTarget(nil); $0.isEnabled = false }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        DDRemoteOwner.instance = nil
    }

    private func bindRemote() {
        guard canControlPlayback else { return }
        guard DDPlayback.bgPlay else { clearRemote(); return }
        let c = MPRemoteCommandCenter.shared()
        DDRemoteOwner.instance = playbackID
        let now = { vlc?.current ?? seamAudio.currentMediaTime ?? player?.currentTime().seconds ?? current }
        func on(_ cmd: MPRemoteCommand, _ f: @escaping (MPRemoteCommandEvent) -> Void) {
            cmd.removeTarget(nil); cmd.isEnabled = true
            cmd.addTarget { e in
                DispatchQueue.main.async {
                    guard canControlPlayback, DDRemoteOwner.instance == playbackID else { return }
                    f(e)
                }
                return .success
            }
        }
        on(c.playCommand) { _ in if !isPlaying { togglePlay() } }
        on(c.pauseCommand) { _ in if isPlaying { togglePlay() } }
        on(c.togglePlayPauseCommand) { _ in togglePlay() }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        on(c.skipForwardCommand) { _ in seekTo(min(max(duration, 1), now() + 10)) }
        on(c.skipBackwardCommand) { _ in seekTo(max(0, now() - 10)) }
        on(c.changePlaybackPositionCommand) { e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { seekTo(e.positionTime) }
        }
        c.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1, 1.25, 1.5, 2]
        on(c.changePlaybackRateCommand) { e in
            if let e = e as? MPChangePlaybackRateCommandEvent {
                // 锁屏/控制中心改的速度算「本条视频」：不污染设置里的全局速度
                if e.playbackRate >= 2 { lockedBoost = true } else { lockedBoost = false; playbackRate = Double(e.playbackRate) }
            }
        }
        lastNowPlaying = -10
        refreshNowPlaying(now())
    }

    /// 约每秒刷新一次锁屏上的标题 / 进度 / 速度
    private func refreshNowPlaying(_ t: Double) {
        guard canControlPlayback, abs(t - lastNowPlaying) >= 1 else { return }
        lastNowPlaying = t
        // 开关中途被切换：开了就补绑控件，关了就清掉
        guard DDPlayback.bgPlay else {
            if DDRemoteOwner.instance == playbackID { clearRemote() }
            return
        }
        if DDRemoteOwner.instance != playbackID { bindRemote(); return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title.isEmpty ? "DouDuo" : title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: t,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playRate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
    }

    private func togglePlay() {
        guard canControlPlayback else { return }
        defer { lastNowPlaying = -10; refreshNowPlaying(vlc?.current ?? seamAudio.currentMediaTime ?? player?.currentTime().seconds ?? current) }   // 锁屏上的播放/暂停状态马上跟上
        if let v = vlc {
            if isPlaying { v.pause() } else { v.resume() }
            isPlaying = v.isPlaying; userPaused = !isPlaying
            dmClock.userToggle(v.current, playing: v.isPlaying, rate: 1)
            if userPaused && offlineContext?.inLibrary == true { savePosition(v.current) }
            return
        }
        guard let p = player else { return }
        if isPlaying {
            seamAudio.pause()
            isPlaying = false
        } else {
            isPlaying = true
            seamAudio.play(rate: playRate, muted: muted)
        }
        userPaused = !isPlaying
        let pos = seamAudio.currentMediaTime ?? p.currentTime().seconds
        dmClock.userToggle(pos, playing: isPlaying, rate: Double(playRate))
        if userPaused && offlineContext?.inLibrary == true { savePosition(pos) }
    }

    private func seekTo(_ pos: Double) {
        guard canControlPlayback else { return }
        DYLiveModel.log("DDSEEK id=\(id.suffix(4)) to=\(String(format: "%.1f", pos))/\(String(format: "%.1f", duration)) playing=\(isPlaying) seam=\(seamAudio.isEngaged) autoNext=\(onEnded != nil)")
        dmClock.seek(pos, playing: isPlaying, rate: Double(playRate))
        if let v = vlc {
            v.seekTo(pos); current = pos
            if offlineContext?.inLibrary == true { pendingOfflineSeek = nil; savePosition(pos) }
            return
        }
        if offlineContext?.inLibrary == true {
            pendingOfflineSeek = pos
            savePosition(pos)
        }
        seamAudio.prepareForSeek()
        let tol = CMTime(seconds: 0.5, preferredTimescale: 600)
        player?.seek(to: CMTime(seconds: pos, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol) { [weak player] done in
            guard done else { return }
            DispatchQueue.main.async {
                guard let player, self.player === player else { return }
                let landed = player.currentTime().seconds
                if pendingOfflineSeek == pos {
                    pendingOfflineSeek = nil
                    if canControlPlayback { savePosition(landed.isFinite ? landed : pos) }
                }
                guard canControlPlayback else { return }
                seamAudio.didFinishVideoSeek(landedSeconds: landed.isFinite ? landed : pos,
                                             resumePlaying: isPlaying, rate: playRate, muted: muted)
            }
        }
        hdPlayer?.seek(to: CMTime(seconds: pos, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol)
        current = pos
    }

    private func requestPreview(_ time: Double) {
        guard let gen = imgGen else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastPreviewAt > 0.15 else { return }
        lastPreviewAt = now
        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: time, preferredTimescale: 600))]) { _, cg, _, result, _ in
            if result == .succeeded, let cg {
                let img = UIImage(cgImage: cg)
                DispatchQueue.main.async { if seeking { previewImage = img } }
            }
        }
    }

    private func teardown() {
        primeObs?.invalidate(); primeObs = nil
        pictureInPicture.invalidate()
        // 秒开陪跑中 / 走 VLC / 头部接续的不归还：手里的不是一份干净的原始播放器
        let returnable = !isActive && hdPlayer == nil && vlc == nil && nextPlayer == nil && headEndSeconds == nil
        cancelUpgrade()
        vlcDeadline?.cancel()
        vlcDeadline = nil
        if let v = vlc {
            savePosition(v.current)
            v.onEnd = nil
            v.onProgress = nil
            v.onError = nil
            v.stop()
            vlc = nil
            vlcURL = nil
        }
        if let p = player { savePosition(seamAudio.currentMediaTime ?? p.currentTime().seconds) }
        seamAudio.reset()
        if let t = timeToken { player?.removeTimeObserver(t); timeToken = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        if let np = nextPlayer { np.pause(); np.replaceCurrentItem(with: nil); nextPlayer = nil }
        player?.pause()
        // 还没轮到播就被回收的相邻页：播放器还给预热池接着缓冲，下次滑过来直接用
        if let p = player, returnable, returnPlayer?(p) == true {
            DYLiveModel.log("DDGIVEBACK \(id.suffix(6)) status=\(p.currentItem?.status.rawValue ?? -1)")
        } else {
            player?.replaceCurrentItem(with: nil)
        }
        player = nil
        imgGen?.cancelAllCGImageGeneration(); imgGen = nil
        isPlaying = false
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s); let h = t / 3600, m = t % 3600 / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}


#if DEBUG
enum DDLaunch { static let t0 = Date() }
/// 调试：播放状态写进 Documents/ddlog.txt，真机上用 devicectl copy 拉回来看
func ddWrite(_ s: String) {
    let line = "\(Date()) \(s)\n"
    DDLogWriter.queue.async { DDLogWriter.append(line) }
}
#endif

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var fillWidth: Bool = true
    /// 画面层第一次有帧可显示时回调（先按同向规则定好铺满方式再回调，不会先小后跳）
    var onReady: (() -> Void)? = nil
    var pictureInPicture: DYPictureInPicture? = nil
    var pictureInPictureEnabled = false
    var onPictureInPictureClose: () -> Void = {}
    var onPictureInPictureUnavailable: () -> Void = {}
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView(player: player)
        v.fillWidth = fillWidth
        v.onReady = onReady
        // 初始用 fit；真正的铺满由 applyGravity 按「是否同向」决定（surface 首帧前隐藏，看不到这中间态）
        v.playerLayer.videoGravity = .resizeAspect
        v.watchSize()
        configurePictureInPicture(v)
        return v
    }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.detached == nil, uiView.playerLayer.player !== player { uiView.playerLayer.player = player; uiView.watchSize() }
        uiView.fillWidth = fillWidth
        uiView.onReady = onReady
        uiView.applyGravity()
        configurePictureInPicture(uiView)
    }
    private func configurePictureInPicture(_ view: PlayerUIView) {
        view.pictureInPicture = pictureInPicture
        pictureInPicture?.attach(to: view.playerLayer, enabled: pictureInPictureEnabled,
                                 onBackgroundClose: onPictureInPictureClose,
                                 onUnavailable: onPictureInPictureUnavailable)
    }
}

final class PlayerUIView: UIView {
    weak var pictureInPicture: DYPictureInPicture?
    var fillWidth = true
    var onReady: (() -> Void)?
    private var readyObs: NSKeyValueObservation?
    /// 后台播放：进后台前把 player 从画面层摘下，系统才不会因「视频不可见」把声音一起停掉；回前台再挂回
    var detached: AVPlayer?
    private var bgObs: [NSObjectProtocol] = []
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black   // 视频留边纯黑（老板定）
        let nc = NotificationCenter.default
        bgObs = [
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                // NotificationCenter delivers this observer on OperationQueue.main.
                MainActor.assumeIsolated {
                    guard DDPlayback.bgPlay, let self, self.pictureInPicture?.keepsVideoLayer != true,
                          let p = self.playerLayer.player else { return }
                    p.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
                    self.detached = p; self.playerLayer.player = nil
                }
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, let p = self.detached else { return }
                self.playerLayer.player = p; self.detached = nil
            },
        ]
        readyObs = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.applyGravity(); self?.onReady?() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { bgObs.forEach(NotificationCenter.default.removeObserver) }

    /// 自适应（仅同向时）：竖屏看竖屏铺满宽度；横屏看横屏铺满高度。竖屏看横屏保持原样。
    /// presentationSize 要等 readyToPlay 才有值，所以 layoutSubviews + KVO 都刷一次。
    override func layoutSubviews() {
        super.layoutSubviews()
        applyGravity()
    }
    private var sizeObs: NSKeyValueObservation?
    func watchSize() {
        sizeObs = playerLayer.player?.currentItem?.observe(\.presentationSize, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyGravity() }
        }
    }
    func applyGravity() {
        guard let size = playerLayer.player?.currentItem?.presentationSize, size.width > 1, size.height > 1,
              bounds.width > 1, bounds.height > 1 else { return }
        let video = size.width / size.height, screen = bounds.width / bounds.height
        // 「自动铺满宽度」只在视频和屏幕同向时铺满（竖屏看竖屏 / 横屏看横屏）；
        // 竖屏看横屏保持完整画面，不裁掉两侧。
        let sameOrientation = DYVideoFit.sameOrientation(videoAspect: video, screenAspect: screen)
        let crop = 1 - min(video, screen) / max(video, screen)
        let g: AVLayerVideoGravity = DYVideoFit.presentation(fillWidth: fillWidth, videoAspect: video, screenAspect: screen) == .aspectFill ? .resizeAspectFill : .resizeAspect
        #if DEBUG
        if playerLayer.videoGravity != g {
            ddWrite("DDGRAVITY video=\(String(format: "%.2f", video)) screen=\(String(format: "%.2f", screen)) bounds=\(bounds.size) fill=\(fillWidth) same=\(sameOrientation) crop=\(String(format: "%.2f", crop)) -> \(g == .resizeAspectFill ? "FILL" : "FIT")")
        }
        #endif
        if playerLayer.videoGravity != g { playerLayer.videoGravity = g }
    }
}


extension AVPlayer {
    private static var softGen = 0
    /// 变速指令已发出、还没真正生效的那 35ms：避免定时拉回重复触发
    static var softRatePending = false
    /// 实测 AVPlayer 换速率会硬切断声音再硬恢复（啪声，恢复处是稳态的 100+ 倍）：
    /// 先 30ms 淡出 → 变速 → 等它内部的静音段过去 → 40ms 淡入，啪声降到与稳态同量级
    func softRate(_ r: Float, fadeOut: Double = 0.03, fadeIn: Double = 0.04) {
        AVPlayer.softGen += 1
        let gen = AVPlayer.softGen, wasPlaying = rate > 0, q = DispatchQueue.main
        AVPlayer.softRatePending = true
        let outSteps = max(3, Int(fadeOut / 0.006)), inSteps = max(4, Int(fadeIn / 0.006))
        for i in 1...outSteps {
            q.asyncAfter(deadline: .now() + fadeOut * Double(i) / Double(outSteps)) { [weak self] in
                if gen == AVPlayer.softGen { self?.volume = Float(outSteps - i) / Float(outSteps) }
            }
        }
        let switchAt = fadeOut + 0.005
        q.asyncAfter(deadline: .now() + switchAt) { [weak self] in
            AVPlayer.softRatePending = false
            guard let self, !(wasPlaying && self.rate == 0 && r > 0) else { return }   // 这段时间里被暂停了就不再拉起
            self.rate = r
        }
        // 等 AVPlayer 换速内部的静音段过去（~185ms）再淡入；本项目静音用 isMuted、不调 volume，所以淡入终点固定为 1
        let inStart = switchAt + 0.185
        for i in 1...inSteps {
            q.asyncAfter(deadline: .now() + inStart + fadeIn * Double(i) / Double(inSteps)) { [weak self] in
                if gen == AVPlayer.softGen { self?.volume = Float(i) / Float(inSteps) }
            }
        }
    }
}

/// 回到前台的续播规则：只有「被后台/失焦打断」才自动续播。
/// 用户自己按的暂停是明确意图，不能被生命周期回调覆盖。
enum DYResumePolicy {
    static func shouldResumeAfterBackground(userPaused: Bool) -> Bool { !userPaused }
}


/// 诊断：长按加速/松手前后 1 秒的掉帧与播放器状态（DDBOOST）
@MainActor enum DYBoostProbe {
    private static var link: CADisplayLink?
    private static var last: CFTimeInterval = 0
    private static var start: CFTimeInterval = 0
    private static var maxGap: CFTimeInterval = 0
    private static var drops = 0
    private static var label = ""
    private static weak var player: AVPlayer?
    private static var stallAt: [Int] = []
    private static var lastT: Double = -1
    private static var frozen = 0
    private static var frozenEarly = 0
    private static var maxJump: Double = 0
    private static let target = Tick()

    static func begin(_ what: String, mode: String, player p: AVPlayer?) {
        link?.invalidate()
        label = "\(what) mode=\(mode)"; player = p
        start = CACurrentMediaTime(); last = 0; maxGap = 0; drops = 0; stallAt = []; lastT = -1; frozen = 0; frozenEarly = 0; maxJump = 0
        let l = CADisplayLink(target: target, selector: #selector(Tick.tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { finish() }
    }
    fileprivate static func frame(_ ts: CFTimeInterval) {
        if last > 0 {
            let g = ts - last
            maxGap = max(maxGap, g)
            if g > 0.025 { drops += 1 }
        }
        last = ts
        if let p = player, p.timeControlStatus != .playing { stallAt.append(Int((ts - start) * 1000)) }
        if let p = player {
            let t = p.currentTime().seconds
            if lastT >= 0, last > 0 {
                let dt = t - lastT
                if dt <= 0.0001 {                         // 画面时间没走 = 视觉上卡住
                    frozen += 1
                    if ts - start < 0.3 { frozenEarly += 1 }
                }
                maxJump = max(maxJump, dt)
            }
            lastT = t
        }
    }
    private static func finish() {
        guard link != nil else { return }
        link?.invalidate(); link = nil
        let stall = stallAt.isEmpty ? "-" : "\(stallAt.first!)..\(stallAt.last!)ms(n=\(stallAt.count))"
        DYLiveModel.log("DDBOOST \(label) maxGap=\(Int(maxGap * 1000))ms drops=\(drops) notPlaying=\(stall) frozenFrames=\(frozen) early300=\(frozenEarly) maxStep=\(Int(maxJump * 1000))ms rate=\(player?.rate ?? -1)")
    }
    private final class Tick: NSObject {
        @objc func tick(_ l: CADisplayLink) { MainActor.assumeIsolated { DYBoostProbe.frame(l.timestamp) } }
    }
}
