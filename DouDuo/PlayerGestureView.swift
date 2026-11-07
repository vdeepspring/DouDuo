import SwiftUI
import UIKit

// MARK: - UIKit 手势宿主：Pan 起手定方向（横=快进/竖=漏给 ScrollView 切视频）+ 单击/双击/长按
// 纯 SwiftUI 的 .gesture/.simultaneousGesture 会吞掉整段手势序列导致竖滑分页失效；
// 下沉 UIKit 用一个 UIPanGestureRecognizer，在 shouldBegin 里按起手速度方向仲裁：
//   · 横向主导 → 本次手势归 seek（我们接管）
//   · 纵向主导 → return false，手势漏给外层 ScrollView 分页切视频
// 起手那一帧定轴，整段锁死，中途不改（=你说的"一发力就定方向"）。
struct PlayerGestureView: UIViewRepresentable {
    var onSingleTap: () -> Void
    var onDoubleTap: (CGFloat, CGFloat) -> Void          // (触点x, 宽度)
    var onLongPress: (Bool) -> Void                       // pressing
    /// 长按中手指往下滑过阈值：锁定 2 倍速（松手后保持），每次长按最多触发一次
    var onLongPressLock: () -> Void = {}
    var onSeekBegan: () -> Void
    var onSeekChanged: (CGFloat, CGFloat) -> Void         // (横向位移, 宽度)
    var onSeekEnded: () -> Void
    var onEdgeChanged: (CGFloat) -> Void = { _ in }        // 左缘右滑过程中：位移跟手
    var onEdgeEnded: (CGFloat, CGFloat, CGFloat) -> Void = { _, _, _ in }  // 松手：(位移, 横向速度, 屏宽)
    /// 竖向优先（抖音短视频：上下滑切视频是主操作，只有明显横向才算快进）；影库保持横向偏置
    var verticalFirst = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true
        let c = context.coordinator
        c.view = v

        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleSingle(_:)))
        single.numberOfTapsRequired = 1
        single.delegate = c

        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleDouble(_:)))
        double.numberOfTapsRequired = 2
        double.delegate = c
        single.require(toFail: double)

        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleLong(_:)))
        long.minimumPressDuration = 0.5
        long.allowableMovement = 12     // 手指移动超 12pt（横滑/竖滑）→ 长按取消，让位给 pan/分页
        long.delegate = c

        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = c
        c.pan = pan

        // 屏幕左缘右滑退出（系统级边缘手势，只在最左 ~20pt 触发，不抢中间区域）
        let edge = UIScreenEdgePanGestureRecognizer(target: c, action: #selector(Coordinator.handleEdge(_:)))
        edge.edges = .left
        edge.delegate = c
        c.edge = edge
        pan.require(toFail: edge)

        v.addGestureRecognizer(single)
        v.addGestureRecognizer(double)
        v.addGestureRecognizer(long)
        v.addGestureRecognizer(pan)
        v.addGestureRecognizer(edge)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self   // 刷新闭包，回调读到最新 @State
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PlayerGestureView
        weak var view: UIView?
        weak var pan: UIPanGestureRecognizer?
        weak var edge: UIScreenEdgePanGestureRecognizer?
        init(_ p: PlayerGestureView) { parent = p }

        /// 长按下滑锁定：下滑超过这个距离就锁
        static let lockDistance: CGFloat = 50
        private var longStart: CGPoint = .zero
        private var longLocked = false
        private var longActive = false
        /// 长按期间临时关掉外层分页滚动，否则「长按后下滑」会被当成翻到上一条
        private weak var pausedScroll: UIScrollView?
        /// 长按中途视图被拆掉（换页 / 退出）收不到 ended：兜底把分页滚动恢复
        deinit { pausedScroll?.isScrollEnabled = true }

        @objc func handleSingle(_ g: UITapGestureRecognizer) { parent.onSingleTap() }

        @objc func handleDouble(_ g: UITapGestureRecognizer) {
            guard let v = view else { return }
            parent.onDoubleTap(g.location(in: v).x, v.bounds.width)
        }

        @objc func handleLong(_ g: UILongPressGestureRecognizer) {
            guard let v = view else { return }
            switch g.state {
            case .began:
                longStart = g.location(in: v)
                longLocked = false
                longActive = true
                lockOuterScroll(true)
                parent.onLongPress(true)
            case .changed:
                let dy = g.location(in: v).y - longStart.y
                if !longLocked, dy > Self.lockDistance {
                    longLocked = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    parent.onLongPressLock()
                }
            case .ended, .cancelled, .failed:
                longActive = false
                lockOuterScroll(false)
                parent.onLongPress(false)
            default: break
            }
        }

        private func lockOuterScroll(_ lock: Bool) {
            if lock {
                var s = view?.superview
                while let cur = s, !(cur is UIScrollView) { s = cur.superview }
                if let sv = s as? UIScrollView, sv.isScrollEnabled {
                    sv.isScrollEnabled = false
                    pausedScroll = sv
                }
            } else {
                pausedScroll?.isScrollEnabled = true
                pausedScroll = nil
            }
        }

        @objc func handleEdge(_ g: UIScreenEdgePanGestureRecognizer) {
            guard let v = view else { return }
            let dx = g.translation(in: v).x
            switch g.state {
            case .began:
                parent.onEdgeChanged(0)
            case .changed:
                parent.onEdgeChanged(max(0, dx))      // 跟手位移上报给容器，画面 1:1 右移
            case .ended, .cancelled, .failed:
                parent.onEdgeEnded(max(0, dx), g.velocity(in: v).x, v.bounds.width)
            default: break
            }
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let v = view else { return }
            switch g.state {
            case .began: parent.onSeekBegan()
            case .changed: parent.onSeekChanged(g.translation(in: v).x, v.bounds.width)
            case .ended, .cancelled, .failed: parent.onSeekEnded()
            default: break
            }
        }

        // 方向仲裁：Pan 起手定轴。横向偏置——除非竖向明显主导才让给 ScrollView 切视频，
        // 否则都判为快进，避免快进时带点下滑分量被误识别成切视频。

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            if g is UIScreenEdgePanGestureRecognizer { return true }   // 边缘退出始终允许
            if longActive, g is UIPanGestureRecognizer { return false } // 长按中（2 倍速 / 下滑锁定）不起快进
            guard let pg = g as? UIPanGestureRecognizer, let v = view else { return true }
            let vel = pg.velocity(in: v)
            // 底部 ~64pt 留给底部进度条手势，避免与全屏横滑重复触发
            let start = pg.location(in: v)
            if start.y > v.bounds.height - 64 { return false }
            // 起手那一帧速度可能是 0（0 >= 0 会被误判成快进，竖滑切不了视频）→ 退回用位移判方向；都为 0 让给分页
            var d = vel
            if abs(d.x) < 1, abs(d.y) < 1 { d = pg.translation(in: v) }
            if abs(d.x) < 0.5, abs(d.y) < 0.5 { return false }
            if parent.verticalFirst {
                // 横向要比竖向大 20% 才算快进，其余一律交给分页切视频
                return abs(d.x) > abs(d.y) * 1.2
            }
            // 竖向速度要比横向大 50% 以上才算"切视频"，否则一律快进（横向偏置，抗误判）
            return abs(d.x) * 1.5 >= abs(d.y)
        }

        // 手势互斥：Pan 已激活（横向快进）→ 独占，不允许 ScrollView 同时响应
        // Pan 被拒绝（竖向）→ 返回 true 让 ScrollView 接管分页
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if let pg = pan, pg.state == .began || pg.state == .changed {
                return false   // 正在拖进度，独占
            }
            if longActive { return false }   // 长按中：下滑是「锁定 2 倍速」，不能同时让分页滚走
            return true        // Pan 还没开始或已结束，让 ScrollView 自由分页
        }
    }
}
