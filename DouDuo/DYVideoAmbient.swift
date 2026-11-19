import SwiftUI
import AVFoundation
import CoreImage
import UIKit

/// 视频环境光：从正在播的 AVPlayerItem 取帧（AVPlayerItemVideoOutput），缩成 48px 宽、模糊后铺满背景再压暗。
/// 主色保持黑，颜色跟着画面实时变（TikTok 式）。替代原来的「模糊封面」静态背景。
/// 试过放弃的两条路（2026-11 Duo 真机实测）：
/// - 同一个 AVPlayer 再挂第二个 AVPlayerLayer：第二层一直不出帧（isReadyForDisplay=false）。
/// - 系统 UIBackgroundExtensionView：是把画面边缘镜像拉伸出去，出竖条色带，不是环境光。
enum DYVideoAmbient {
    static let key = "douyin_ambient_dim_v1"
    /// 0 = 关（退回模糊封面）；其余数值 = 压暗百分比
    static let levels = [0, 45, 60, 70, 80]
    static let defaultLevel = 60
    static func title(_ v: Int) -> String {
        switch v { case 0: "关"; case 45: "亮"; case 60: "中"; case 70: "暗"; default: "很暗" }
    }
}

struct DYAmbientBackdrop: UIViewRepresentable {
    let player: AVPlayer
    var active: Bool
    var dim: Double
    var fillWidth: Bool
    func makeUIView(context: Context) -> DYAmbientFrameView { DYAmbientFrameView(player: player) }
    func updateUIView(_ v: DYAmbientFrameView, context: Context) {
        v.player = player
        v.dim = dim
        v.fillWidth = fillWidth
        v.active = active
    }
}

final class DYAmbientFrameView: UIView {
    var player: AVPlayer
    /// 只有当前页取帧；预加载页、滑走的页停掉，不白耗电
    var active = false { didSet { if active != oldValue { updateLink() } } }
    var dim: Double = 0.45 { didSet { dimView.backgroundColor = UIColor.black.withAlphaComponent(dim) } }
    var fillWidth = true
    private let imageView = UIImageView()
    private let dimView = UIView()
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    private weak var attachedItem: AVPlayerItem?
    private var link: CADisplayLink?
    private static let ci = CIContext(options: [.cacheIntermediates: false])

    init(player: AVPlayer) {
        self.player = player
        super.init(frame: .zero)
        // 出第一帧之前透明，下面的模糊封面先顶着
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.layer.magnificationFilter = .linear
        imageView.alpha = 0
        dimView.alpha = 0
        dimView.backgroundColor = UIColor.black.withAlphaComponent(dim)
        addSubview(imageView)
        addSubview(dimView)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { link?.invalidate(); attachedItem?.remove(output) }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        dimView.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachEarly()
        updateLink()
    }

    /// 取帧输出必须在视频「还停着」的时候挂上：给正在起播的 AVPlayerItem 加 VideoOutput 会让播放管线重建，
    /// 画面和声音一起顿一下、往回弹一帧（老板实测「有的视频会、有的不会」= 挂上去的时机碰上了起播）。
    /// 页面一挂载（预热播放器已经接上）就挂，切过去起播时不再动管线。
    private func attachEarly() {
        guard window != nil, let item = player.currentItem, attachedItem !== item else { return }
        attachedItem?.remove(output)
        item.add(output)
        attachedItem = item
    }

    private func updateLink() {
        if active && window != nil {
            guard link == nil else { return }
            let l = CADisplayLink(target: DYAmbientTick(self), selector: #selector(DYAmbientTick.tick))
            // 环境光不用 60 帧，12 帧左右看着就是连续的
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            link?.invalidate(); link = nil
            // 不再在失活时摘掉输出：摘/挂都会动播放管线，留着直到页面销毁（deinit 里摘）
            if window == nil { attachedItem?.remove(output); attachedItem = nil }
            else { attachEarly() }
        }
    }

    /// 铺满模式下画面盖住整页，没有地方露背景，不取帧
    private var covered: Bool {
        guard let s = player.currentItem?.presentationSize, s.width > 1, s.height > 1,
              bounds.width > 1, bounds.height > 1 else { return false }
        return DYVideoFit.presentation(fillWidth: fillWidth, videoAspect: s.width / s.height,
                                       screenAspect: bounds.width / bounds.height) == .aspectFill
    }

    fileprivate func tick() {
        // 画面铺满时背景看不见，但桌面姿态的评论区还在等投光，照样取帧
        guard !covered || DYDeskLightHub.wanted, let item = player.currentItem else { return }
        // 秒开高清接管、头部缓存接在线流都会换 item，跟着换
        if attachedItem !== item {
            attachedItem?.remove(output)
            item.add(output)
            attachedItem = item
        }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t),
              let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        let src = CIImage(cvPixelBuffer: pb)
        let scale = 48 / max(src.extent.width, 1)
        let small = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: small.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85])
        guard let cg = Self.ci.createCGImage(blurred, from: small.extent) else { return }
        imageView.image = UIImage(cgImage: cg)
        // 桌面投影（与 GuoDuo 同一套：按亮度出光、近清远糊、远端扩散、垫环境光；只有投影视图在屏幕上时才算）
        if DYDeskLightHub.wanted, let proj = DYDeskProjection.render(src, ci: Self.ci) {
            DYDeskLightHub.publish(proj.image, glow: proj.glow, aspect: src.extent.width / max(src.extent.height, 1))
        }
        if imageView.alpha == 0 {
            UIView.animate(withDuration: 0.25) { self.imageView.alpha = 1; self.dimView.alpha = 1 }
        }
    }
}

private final class DYAmbientTick: NSObject {
    weak var view: DYAmbientFrameView?
    init(_ v: DYAmbientFrameView) { view = v }
    @objc func tick() { view?.tick() }
}

