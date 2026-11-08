import SwiftUI
import AVKit
import AVFoundation
// VLC 软解兜底（来自 無為 影库播放器）：AVPlayer 解不了 / 起播失败时接管。依赖 tylerjonesio/vlckit-spm。
import VLCKitSPM

// MARK: - VLC 播放器 UIKit 包装（软解 HEVC 等苹果硬解不认的格式）

struct VLCPlayerSurface: UIViewRepresentable {
    let controller: VLCPlayerController
    var fillWidth: Bool = true
    func makeUIView(context: Context) -> VLCPlayerUIView {
        let v = VLCPlayerUIView()
        v.controller = controller
        v.fillWidth = fillWidth
        controller.mediaPlayer.drawable = v
        controller.drawableAttached()   // drawable 就绪后才真正 play，避免「有声无画」
        return v
    }
    /// 页面被拆掉时把 drawable 摘掉：直播切房间后旧页的视图已离屏，不能让新流画到它上面
    static func dismantleUIView(_ uiView: VLCPlayerUIView, coordinator: ()) {
        if let c = uiView.controller, c.mediaPlayer.drawable as? UIView === uiView { c.mediaPlayer.drawable = nil }
    }
    func updateUIView(_ uiView: VLCPlayerUIView, context: Context) {
        // ⚠️ 不要每次 updateUIView 都重设 drawable（@State 0.25s 变一次会反复触发，
        // 频繁 attach/detach 视频输出 → 画面冻结）。仅在 drawable 丢失时补挂。
        if controller.mediaPlayer.drawable == nil {
            controller.mediaPlayer.drawable = uiView
            controller.drawableAttached()
        }
        uiView.controller = controller
        uiView.fillWidth = fillWidth
        uiView.applyFill()   // videoSize 要播起来才有，靠 0.25s 刷新补上
    }
}

final class VLCPlayerUIView: UIView {
    weak var controller: VLCPlayerController?
    var fillWidth = true
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 自适应（仅同向时）：竖屏看竖屏按宽度铺满、横屏看横屏按高度铺满。竖屏看横屏保持完整画面。
    override func layoutSubviews() {
        super.layoutSubviews()
        applyFill()
    }
    func applyFill() {
        guard let mp = controller?.mediaPlayer, bounds.width > 1, bounds.height > 1 else { return }
        let vs = mp.videoSize
        guard vs.width > 1, vs.height > 1 else { layer.transform = CATransform3DIdentity; return }
        // VLC 按等比 fit 渲染（必有黑边）。把渲染层放大到「刚好铺满」即可：竖屏视频按宽度、横屏按高度，
        // 超出屏幕部分看不见（居中缩放，裁切对称）。
        let video = vs.width / vs.height, screen = bounds.width / bounds.height
        // 只在视频和屏幕同向时放大：竖屏看竖屏铺满宽度、横屏看横屏铺满高度；竖屏看横屏保持原样
        let sameOrientation = (video < 1) == (screen < 1)
        let s = (fillWidth && sameOrientation) ? max(screen / video, video / screen) : 1
        let t = CATransform3DMakeScale(s, s, 1)
        if !CATransform3DEqualToTransform(layer.transform, t) { layer.transform = t }
    }
}

// MARK: - VLC 播放控制器（管理 VLCMediaPlayer 生命周期 + 进度回调）

@MainActor
final class VLCPlayerController: NSObject, VLCMediaPlayerDelegate, ObservableObject {
    let mediaPlayer: VLCMediaPlayer
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var videoSize: CGSize = .zero

    var onProgress: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    var onError: (() -> Void)?
    private var seekTarget: Double?       // seek 后短暂屏蔽回调防抖
    private var lastReported: Double = 0  // 上次回调值，防回退抖动
    private var pendingURL: URL?          // 等 drawable 就绪再 play
    private var pendingAutoplay = false

    override init() {
        // 开 VideoToolbox 硬件解码 + 网络缓存调优，避免 h264/hevc 软解卡顿（一卡一卡）
        let options: [String] = [
            "--codec=videotoolbox,avcodec",   // 优先 VideoToolbox 硬解，失败再回退软解
            "--avcodec-hw=videotoolbox",       // 强制 avcodec 走硬件加速
            "--network-caching=1500",          // 网络流缓存 1.5s，抗抖动
            "--file-caching=1500",
            "--clock-jitter=0",                // 关时钟抖动补偿
            "--clock-synchro=0"
            // ⚠️ 不要加 --no-drop-late-frames / --no-skip-frames：解码一跟不上就死等 → 进度卡住不走。
            // 默认丢帧才能保持进度持续推进。
        ]
        mediaPlayer = VLCMediaPlayer(options: options)
        super.init()
        mediaPlayer.delegate = self
        mediaPlayer.scaleFactor = 0  // 适应窗口
    }

    /// 设 media 但**不立即 play**——必须等 VLCPlayerSurface 把 drawable 挂上后
    /// 再由 drawableAttached() 触发，否则 VLC 解码无视频输出目标 → 有声无画。
    func play(url: URL, autoplay: Bool = true, headers: [String: String] = [:], cachingMs: Int32 = 1500) {
        let media = VLCMedia(url: url)
        // 抖音 CDN 不带浏览器 UA + Referer 会 403
        if let ua = headers["User-Agent"] { media.addOption(":http-user-agent=\(ua)") }
        if let ref = headers["Referer"] { media.addOption(":http-referrer=\(ref)") }
        // 逐 media 再声明一次硬解，确保 VideoToolbox 生效
        media.addOption(":avcodec-hw=videotoolbox")
        media.addOption(":codec=videotoolbox,avcodec")
        media.addOption(":network-caching=\(cachingMs)")
        media.addOption(":live-caching=\(cachingMs)")
        // 换视频必须清掉上个流的进度/尺寸，否则单调防抖会把新流前几十秒都吞掉。
        lastReported = 0; seekTarget = nil; current = 0; duration = 0; videoSize = .zero
        mediaPlayer.media = media
        pendingURL = url
        pendingAutoplay = autoplay
        isPlaying = autoplay
        // ⚠️ drawable 已经在（复用同一个渲染层）时必须立刻 play：
        // 只靠 drawableAttached() 的话，stop() 之后再播会永远等不到回调 → 有声无画 / 完全不出画
        if mediaPlayer.drawable != nil, autoplay {
            pendingURL = nil
            mediaPlayer.play()
        }
    }

    /// drawable（渲染层）就绪后调用：首帧真正 play；或渲染层重连时恢复画面。
    func drawableAttached() {
        if pendingURL != nil {
            pendingURL = nil
            if pendingAutoplay {
                mediaPlayer.play()
                isPlaying = true
            }
        } else if isPlaying && [.stopped, .paused, .ended, .error].contains(mediaPlayer.state) {
            // drawable 丢失后重挂 → 恢复渲染。正在打开/缓冲时别再 play：直播切房间时会把刚起的流打断
            mediaPlayer.play()
        }
    }

    func pause() {
        mediaPlayer.pause()
        isPlaying = false
    }

    func togglePlay() {
        if mediaPlayer.isPlaying {
            mediaPlayer.pause()
            isPlaying = false
        } else {
            mediaPlayer.play()
            isPlaying = true
        }
    }

    /// 外部（JellyfinPlayerView）可用 Jellyfin 已知时长预置，避免 media.length 未解析时 seek 失效
    func setKnownDuration(_ d: Double) {
        if duration <= 0, d > 0 { duration = d }
    }

    func seekTo(_ pos: Double) {
        seekTarget = pos
        current = pos
        let wasPlaying = mediaPlayer.isPlaying
        if duration > 0 {
            mediaPlayer.position = Float(max(0, min(1, pos / duration)))
        } else {
            // 时长未知：用 VLC 的绝对时间跳转（毫秒）
            mediaPlayer.time = VLCTime(int: Int32(pos * 1000))
        }
        if wasPlaying { mediaPlayer.play() }
    }

    func setRate(_ rate: Float) {
        mediaPlayer.rate = rate
    }

    func stop() {
        pendingURL = nil; pendingAutoplay = false
        mediaPlayer.stop()
        isPlaying = false
    }

    // VLCMediaPlayerDelegate
    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in
            guard mediaPlayer.isPlaying else { return }
            let raw = Double(mediaPlayer.time.intValue) / 1000.0
            let dur = mediaPlayer.media?.length.intValue ?? 0
            if dur > 0 { duration = Double(dur) / 1000.0 }

            // seek 防抖：seek 后 0.5 秒内忽略回调（VLC seek 后会报旧位置）
            if let target = seekTarget {
                if abs(raw - target) < 2.0 { seekTarget = nil }
                else { return }  // 还是旧值，跳过
            }

            // 单调递增防抖：回调值比上次小超过 1 秒 = 异常回退，跳过
            if raw < lastReported - 1.0 { return }
            lastReported = raw
            current = raw
            onProgress?(raw)
        }
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in
            switch mediaPlayer.state {
            case .playing:
                isPlaying = true
                let w = mediaPlayer.videoSize
                if w.width > 0, w.height > 0 {
                    videoSize = CGSize(width: w.width, height: w.height)
                }
            case .paused:
                isPlaying = false
            case .ended:
                isPlaying = false
                onEnd?()
            case .error:
                isPlaying = false
                onError?()
            case .stopped:
                // stop()/换流不是自然播完，不能触发自动下一条或循环回调。
                isPlaying = false
            default:
                break
            }
        }
    }
}
