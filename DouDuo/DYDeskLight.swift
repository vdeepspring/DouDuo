import SwiftUI
import UIKit

/// 桌面投光：竖屏半折叠（桌面姿态）时，上半屏视频像一块立着的屏幕，
/// 把画面的光投到下半屏评论区这张「桌面」上。
/// - 光源复用环境光取帧（DYAmbientFrameView，48px 宽、已模糊），不另挂播放器输出。
/// - 2026-11-19 老板给了奈飞实拍照：倒影同宽、翻转、只占视频高度、很暗、半糊（见下面 DYDeskLight 注释）。
/// - 直接把帧推给投光视图，不经过 SwiftUI 状态（12 帧/秒的值挂到视图树上会让整页反复重算）。
@MainActor
enum DYDeskLightHub {
    private static let sinks = NSHashTable<DYDeskLightView>.weakObjects()
    /// 有投光视图在屏幕上时，环境光即使被铺满的画面盖住也继续取帧
    static var wanted: Bool { sinks.allObjects.contains { $0.window != nil } }
    static func add(_ v: DYDeskLightView) { sinks.add(v) }
    static func remove(_ v: DYDeskLightView) { sinks.remove(v) }
    /// image = 已翻转、按距离渐糊渐散的投影；glow = 环境光（极糊的小图）；aspect = 视频宽高比
    static func publish(_ image: CGImage, glow: CGImage?, aspect: CGFloat) {
        for v in sinks.allObjects where v.window != nil { v.show(image, glow: glow, aspect: aspect) }
    }
}

/// 把一帧视频做成「真投影」（2026-11-19 老板对照奈飞：亮处投得明显、暗处几乎不投；离折痕近清楚、远处糊且放大）
/// 全在 Core Image 里做（GPU，72px 宽，12 帧/秒）：
/// 1. 翻转：视频底边贴折痕；
/// 2. 按亮度出光：Gamma 1.9 压掉暗部、保留高光——画面亮的地方投影才明显；
/// 3. 糊度：整体 σ2.4 打底（老板定的上一版糊度），远端再叠 CIMaskedVariableBlur 半径 3.2；
/// 4. 按距离渐大：CIPerspectiveTransform，远端向两侧各放出 25%（光离光源越远越散）。
enum DYDeskProjection {
    static let width: CGFloat = 72   // 老板：模糊度回到 26fdac8 那版（72px + σ2.4）
    /// 远端各向外放出的比例（视图按同样比例摆放）
    static let spread: CGFloat = 0.25

    static func render(_ src: CIImage, ci: CIContext) -> (image: CGImage, glow: CGImage?)? {
        let k = width / max(src.extent.width, 1)
        let small = src.transformed(by: CGAffineTransform(scaleX: k, y: k))
            .transformed(by: CGAffineTransform(translationX: -src.extent.minX * k, y: -src.extent.minY * k))
        let w = small.extent.width, h = small.extent.height
        guard w > 1, h > 1 else { return nil }
        // 1 翻转（CI 坐标 y 向上：翻完后最上面一行 = 原视频最下面一行）
        let flipped = small.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h))
        // 2 亮度 → 光强
        let lit = flipped.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1.9])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.1])
        // 3 距离渐糊：遮罩上黑（折痕，不糊）下白（远端，最糊）
        let mask = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: h), "inputColor0": CIColor.black,
            "inputPoint1": CIVector(x: 0, y: 0), "inputColor1": CIColor.white])?.outputImage?.cropped(to: lit.extent)
        var blurred = lit
        if let mask {
            blurred = lit.clampedToExtent()
                .applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": mask, "inputRadius": 3.2])
                .cropped(to: lit.extent)
        }
        // 底糊 = 上一版（72px + σ2.4）的糊度，折痕处也是这个程度；远端在此基础上再加一点
        blurred = blurred.clampedToExtent().applyingGaussianBlur(sigma: 2.4).cropped(to: lit.extent)
        // 左右边缘各 12% 淡到黑：光斑没有硬边（透视放大后斜边不再是一条线）
        let e = w * 0.12
        if let l = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputColor0": CIColor.black,
                "inputPoint1": CIVector(x: e, y: 0), "inputColor1": CIColor.white])?.outputImage,
           let r = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: w, y: 0), "inputColor0": CIColor.black,
                "inputPoint1": CIVector(x: w - e, y: 0), "inputColor1": CIColor.white])?.outputImage {
            let edge = l.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: r]).cropped(to: lit.extent)
            blurred = blurred.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .black).cropped(to: lit.extent),
                kCIInputMaskImageKey: edge])
        }
        // 4 距离渐大：上边（折痕）不动，下边（远端）两侧各放出 spread
        let d = w * spread
        let persp = blurred.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(x: 0, y: h), "inputTopRight": CIVector(x: w, y: h),
            "inputBottomLeft": CIVector(x: -d, y: 0), "inputBottomRight": CIVector(x: w + d, y: 0)])
        let rect = CGRect(x: -d, y: 0, width: w + 2 * d, height: h)
        guard let image = ci.createCGImage(persp.cropped(to: rect), from: rect) else { return nil }
        // 环境光：同样按亮度出光，缩到 16px 极糊
        let g = 16 / w
        let tiny = lit.transformed(by: CGAffineTransform(scaleX: g, y: g))
        let glow = ci.createCGImage(tiny.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: tiny.extent), from: tiny.extent)
        return (image, glow)
    }
}

struct DYDeskLight: UIViewRepresentable {
    /// 折痕带下沿（倒影从这里往下排）
    var top: CGFloat = 0
    /// 上半屏视频窗格高度，用来算画面实际显示宽度（竖片按高度适配时倒影要同宽）
    var videoHeight: CGFloat = 0
    func makeUIView(context: Context) -> DYDeskLightView { DYDeskLightView() }
    func updateUIView(_ v: DYDeskLightView, context: Context) {
        v.topInset = top; v.videoHeight = videoHeight
    }
}

/// 照奈飞半折叠实拍（老板 2026-11-19 照片）做的「桌面倒影」：
/// - 和上方视频同宽、同比例，左右位置一一对应（不拉伸铺满）；
/// - 上下翻转，只占视频那么高，下面留黑；
/// - 很暗、起点离折痕一小段、先淡入再淡出；
/// - 亮度、糊度、放大都按「真投影」算，见 DYDeskProjection（老板：亮处投得明显，近处清楚、远处糊且大）；
/// - 底下垫一层环境光：同画面缩到 16px 重度模糊，比视频宽 1.5 倍、铺满下半屏后淡出，像屏幕的光洒在桌面上。
final class DYDeskLightView: UIView {
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { setNeedsLayout() } } }
    var videoHeight: CGFloat = 0 { didSet { if videoHeight != oldValue { setNeedsLayout() } } }
    private let glowView = UIImageView()
    private let glowMask = CAGradientLayer()
    private let box = UIView()
    private let imageView = UIImageView()
    private let falloff = CAGradientLayer()
    private var aspect: CGFloat = 16.0 / 9.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
        alpha = 0
        // 环境光：同一画面缩到很小、重度模糊，翻转后向两侧和下方铺开，只留颜色氛围
        glowView.contentMode = .scaleToFill
        glowView.layer.magnificationFilter = .linear
        glowView.alpha = 0.22
        glowMask.startPoint = CGPoint(x: 0.5, y: 0)
        glowMask.endPoint = CGPoint(x: 0.5, y: 1)
        glowMask.colors = [UIColor(white: 1, alpha: 0.9).cgColor,
                           UIColor(white: 1, alpha: 0.45).cgColor,
                           UIColor(white: 1, alpha: 0).cgColor]
        glowMask.locations = [0, 0.45, 1]
        glowView.layer.mask = glowMask
        addSubview(glowView)
        box.clipsToBounds = true
        imageView.contentMode = .scaleToFill
        imageView.layer.magnificationFilter = .linear
        box.addSubview(imageView)
        addSubview(box)
        // 竖向：折痕处先淡入（~12%），峰值约 0.5，之后一路淡出到全黑
        falloff.startPoint = CGPoint(x: 0.5, y: 0)
        falloff.endPoint = CGPoint(x: 0.5, y: 1)
        falloff.colors = [UIColor(white: 1, alpha: 0).cgColor,
                          UIColor(white: 1, alpha: 0.38).cgColor,
                          UIColor(white: 1, alpha: 0.19).cgColor,
                          UIColor(white: 1, alpha: 0).cgColor]
        falloff.locations = [0, 0.07, 0.5, 1]
        box.layer.mask = falloff
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 画面在上半屏里的实际显示宽度：横片适配宽度，竖片按窗格高度适配
        var w = bounds.width
        if videoHeight > 1, aspect > 0 { w = min(w, videoHeight * aspect) }
        let h = w / max(aspect, 0.1)
        let bw = w * (1 + 2 * DYDeskProjection.spread), bh = h * 1.25
        box.frame = CGRect(x: (bounds.width - bw) / 2, y: topInset + 4, width: bw, height: bh)
        // 环境光比倒影宽一圈（溢出屏幕两侧），往下铺满整块下半屏后淡出
        let gw = max(bounds.width, w) * 1.5
        glowView.frame = CGRect(x: (bounds.width - gw) / 2, y: topInset, width: gw, height: max(1, bounds.height - topInset))
        glowMask.frame = glowView.bounds
        imageView.frame = box.bounds
        falloff.frame = box.bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { DYDeskLightHub.add(self) } else { DYDeskLightHub.remove(self); alpha = 0 }
    }

    func show(_ image: CGImage, glow: CGImage?, aspect a: CGFloat) {
        if let glow { glowView.image = UIImage(cgImage: glow) }
        if abs(a - aspect) > 0.01 { aspect = a; setNeedsLayout() }
        imageView.image = UIImage(cgImage: image)
        if alpha == 0 { UIView.animate(withDuration: 0.35) { self.alpha = 1 } }
    }
}

extension View {
    /// 桌面姿态下给评论区加投光；其他姿态原样返回
    @ViewBuilder
    /// videoHeight = 上半屏视频窗格高度（投影按它算画面实际显示宽度）
    func dyDeskLight(_ on: Bool, videoHeight: CGFloat = 0) -> some View {
        if on {
            overlay {
                DYDeskLight(videoHeight: videoHeight)
                    .blendMode(.screen)
                    .opacity(0.8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("douyin.comments.deskLight")
            }
        } else {
            self
        }
    }
}
