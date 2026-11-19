// DouDuo 三姿态：外屏 / 半折叠 / 内屏平放。
// iOS 27.1 用 ArrangementView.overlay（书本：视频 leading、评论 trailing；桌面：视频在上、评论在下）。
// 更低版本回退容器宽度 wide>=700，不读方向、不读 UIScreen。
import SwiftUI

enum DYDuoMetrics {
    /// 合屏竖屏视频左贴边试验；展开内屏与横屏内容不移动。
    static func closedPortraitVideoOffset(viewport: CGSize, videoAspect: Double,
                                          fills: Bool, isDuo: Bool, isClosed: Bool) -> CGFloat {
        guard isDuo, isClosed, viewport.height > viewport.width,
              videoAspect > 0, videoAspect < 1, !fills else { return 0 }
        let fittedWidth = min(viewport.width, viewport.height * videoAspect)
        return -(viewport.width - fittedWidth) / 2
    }

    static func hingeSplit(_ geo: GeometryProxy) -> (video: CGRect, panel: CGRect, book: Bool)? {
        guard DYDuoMetrics.foldIsActive(geo) else { return nil }
        guard #available(iOS 27.1, *) else { return nil }
        let divisions = geo.reservedRegions(kind: .division).map {
            DYLiveDivision(frame: $0.frame, isActive: $0.isActive)
        }
        guard let p = DYLiveAdaptiveLayoutEngine.hingePanes(
            bounds: CGRect(origin: .zero, size: geo.size), divisions: divisions) else { return nil }
        return (p.first, p.second, p.book)
    }

    static func videoCommentPanes(_ geo: GeometryProxy) -> (video: CGRect, panel: CGRect, book: Bool)? {
        guard let hinge = hingeSplit(geo) else { return nil }
        let panes = DYLiveAdaptiveLayoutEngine.videoCommentPanes(
            video: hinge.video, panel: hinge.panel, book: hinge.book)
        return (panes.video, panes.panel, hinge.book)
    }

    /// 窗格右侧被系统遮挡区（状态栏时间/信号）占掉的宽度，最多让 120pt。
    static func trailingOcclusionInset(_ geo: GeometryProxy, pane: CGRect) -> CGFloat {
        guard #available(iOS 27.1, *) else { return 0 }
        var inset: CGFloat = 0
        for region in geo.reservedRegions(kind: .occlusion) where region.isActive {
            let f = region.frame
            guard f.width > 1, f.height > 1, f.intersects(pane), f.midX > pane.midX else { continue }
            inset = max(inset, pane.maxX - f.minX)
        }
        return min(max(0, inset), 120)
    }


    static func actionRailHorizontalOffset(isRegular: Bool, trailingInset: CGFloat,
                                          columnWidth: CGFloat, outerPadding: CGFloat,
                                          opticalLeadingInset: CGFloat = 0) -> CGFloat {
        guard isRegular, trailingInset > 0 else { return 0 }
        return outerPadding + columnWidth / 2 - trailingInset / 2 - opticalLeadingInset
    }


    /// Full-bleed media and sheets deliberately extend past SwiftUI's safe
    /// area. Their controls still clear the physical home-indicator region.
    static var windowBottomInset: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.safeAreaInsets.bottom ?? 0
    }

    static func bottomSafeAreaExtension(in geo: GeometryProxy) -> CGFloat {
        let inset = geo.safeAreaInsets.bottom
        let physicalBottom = windowBottomInset
        return inset <= physicalBottom + 1 ? min(inset, physicalBottom) : 0
    }

    static func mediaBottomPadding(_ containerInset: CGFloat) -> CGFloat {
        // The progress line sits 8 pt above its view's bottom. Lift the info
        // and progress together, retaining their existing music/line spacing.
        max(max(containerInset - 16, 8), windowBottomInset - 8)
    }

    static func bottomSafeAreaOverlap(in proxy: GeometryProxy) -> CGFloat {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return 0 }
        let inset = window.safeAreaInsets.bottom
        return min(inset, max(0, proxy.frame(in: .global).maxY - (window.bounds.maxY - inset)))
    }

    /// iOS 17–27.0 的宽屏回退，和改版前同一条线。
    static let legacyWideMin: CGFloat = 700

    /// 是不是 iPhone Duo 真机/模拟器（iPhone19,4）。
    /// 外屏顶栏的 -80 贴顶只对 Duo 成立：Duo 外屏窗口内容区比物理屏顶端低约 80pt；
    /// 普通 iPhone 窗口从物理顶端开始，再往上推 80 就把顶栏推出屏幕（issue #16：点不到）。
    static let isDuoHardware: Bool = {
        #if targetEnvironment(simulator)
        let id = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        #else
        var s = utsname()
        uname(&s)
        let id = withUnsafeBytes(of: &s.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #endif
        return id == "iPhone19,4"
    }()

    /// 窗口顶部安全区（状态栏 / 灵动岛高度）。播放页整层忽略了安全区，GeometryProxy 量到的 top 为 0，只能读窗口。
    @MainActor static var windowSafeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.top ?? 0
    }

    /// A system split or floating window can still receive the display's
    /// active hinge region. Only use it to lay out an app occupying the display.
    static var canUseFoldLayout: Bool {
        guard #available(iOS 27.1, *),
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first(where: { $0.keyWindow != nil }) else { return false }
        let space = scene.effectiveGeometry.coordinateSpace
        let display = scene.screen.coordinateSpace
        return DYLiveAdaptiveLayoutEngine.occupiesDisplay(
            scene: display.convert(space.bounds, from: space), display: display.bounds)
    }

    /// 折痕是否处于激活状态（半折叠）。iOS 27.1 以下恒为 false。
    static func foldIsActive(_ proxy: GeometryProxy) -> Bool {
        #if DEBUG
        // 演示/截图用：模拟器没有物理折痕，用环境变量强制进入半折叠布局
        if ProcessInfo.processInfo.environment["DOUDUO_FOLD"] == "1" { return true }
        #endif
        if #available(iOS 27.1, *) {
            return canUseFoldLayout && proxy.reservedRegions(kind: .division).contains { $0.isActive }
        }
        return false
    }

    /// 顶栏左移量：合屏时前摄挖孔压在右上，整排往左让出它的宽度，避免「推荐/直播」被啃掉。
    /// 只认靠上且靠右的 occlusion；下方/居中的（如外屏下缘）不动顶栏。
    static func topBarLeftShift(_ proxy: GeometryProxy) -> CGFloat {
        guard #available(iOS 27.1, *) else { return 0 }
        let w = proxy.size.width
        var shift: CGFloat = 0
        for r in proxy.reservedRegions(kind: .occlusion) where r.isActive {
            let f = r.frame
            guard f.height > 1, f.width > 1 else { continue }
            // 顶部 140pt 内、且位于右半边 → 认定为前摄
            if f.minY < 140, f.minX > w * 0.5 {
                shift = max(shift, f.width)
            }
        }
        return min(shift, 56)
    }
}

struct DYFeedRailEntry {
    let id: String
    let tab: DYTab
    let actions: AnyView
}

struct DYFeedRailPreference: PreferenceKey {
    static var defaultValue: [DYFeedRailEntry] { [] }
    static func reduce(value: inout [DYFeedRailEntry], nextValue: () -> [DYFeedRailEntry]) {
        value.append(contentsOf: nextValue())
    }
}

/// 输入区独立提升到 feed 最前层，不能留在视频页里被根菜单栏 overlay 盖住。
struct DYFeedComposerEntry {
    let id: String
    let tab: DYTab
    let content: AnyView
}
struct DYFeedInputActivePreference: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
extension EnvironmentValues {
    @Entry var dyRailInputActive = false
}

struct DYFeedComposerPreference: PreferenceKey {
    static var defaultValue: [DYFeedComposerEntry] { [] }
    static func reduce(value: inout [DYFeedComposerEntry], nextValue: () -> [DYFeedComposerEntry]) {
        value.append(contentsOf: nextValue())
    }
}

/// 键盘状态独立于菜单栏视图生命周期；输入内容更新 preference 时，不能重置禁用状态。
/// 只靠 willShow/willHide 会卡死：第三方键盘、程序化收起、切到后台再回来都可能不发 willHide，
/// 一旦卡在 true，菜单栏就永久变灰且点不动。所以同时以「当前是否真有输入框在编辑」为准。
@MainActor
final class DYKeyboardInputState: ObservableObject {
    static let shared = DYKeyboardInputState()
    @Published private(set) var visible = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let nc = NotificationCenter.default
        func apply(_ value: Bool) {
            MainActor.assumeIsolated { if self.visible != value { self.visible = value } }
        }
        func height(_ note: Notification) -> CGFloat {
            (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
        }
        observers = [
            nc.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { note in
                apply(height(note) > 0)
            },
            // 第三方键盘 / 分屏键盘常见只发 changeFrame，不发 willHide
            nc.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { note in
                apply(height(note) > 0)
            },
            nc.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { _ in
                apply(false)
            },
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DYKeyboardInputState.shared.reconcile() }
            },
            nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
                apply(false)
            }
        ]
    }

    /// 以真实第一响应者为准；键盘其实已经收了就立刻恢复菜单栏。
    func reconcile() {
        if visible, !Self.isEditingText() { visible = false }
    }

    /// 当前有没有文本输入框是第一响应者（网页编辑器、原生输入框都算）。
    static func isEditingText() -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for window in scenes.flatMap(\.windows) {
            if let responder = window.dyTextFirstResponder { _ = responder; return true }
        }
        return false
    }
}

private extension UIView {
    var dyTextFirstResponder: UIView? {
        if isFirstResponder, self is UITextField || self is UITextView || self is UISearchBar { return self }
        for sub in subviews { if let found = sub.dyTextFirstResponder { return found } }
        return nil
    }
}

/// 输入期间整列变灰且不响应点击；位置、尺寸和分屏边缘不变。
/// 每次出现 / 回前台都对一次真实焦点，避免状态残留把菜单栏锁灰。
struct DYRailInputLock: ViewModifier {
    @Environment(\.appTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var keyboard = DYKeyboardInputState.shared
    @Environment(\.dyRailInputActive) private var composerActive
    private var inactive: Bool { keyboard.visible || composerActive }
    func body(content: Content) -> some View {
        content
            .opacity(inactive ? theme.media.inputInactiveRailOpacity : 1)
            .disabled(inactive)
            .allowsHitTesting(!inactive)
            .onAppear { keyboard.reconcile() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { keyboard.reconcile() } }
            .onChange(of: keyboard.visible) { _, _ in keyboard.reconcile() }
    }
}

/// 键盘弹出时把这一列钉回原位。
/// 键盘会让信息页的容器变矮（也会被系统当成「遮挡区」），贴底排的右侧栏就整列往上、往左跑。
/// 这里在键盘没弹时记下这一列的位置，弹出后按位置差把它推回去——offset 不改变布局尺寸，
/// 所以测量不会自己追自己。

/// Read the system bar edge beside the controls; older systems keep the trailing rail.
struct DYAdaptiveActionRail<Content: View>: View {
    @ViewBuilder var content: (HorizontalEdge) -> Content

    var body: some View {
        if #available(iOS 27.1, *) {
            DYSystemActionRail(content: content)
        } else {
            content(.trailing)
        }
    }
}

@available(iOS 27.1, *)
private struct DYSystemActionRail<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var systemEdge
    @ViewBuilder var content: (HorizontalEdge) -> Content

    private var edge: HorizontalEdge {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_RAIL_EDGE"] == "leading" { return .leading }
        #endif
        return systemEdge ?? .trailing
    }

    var body: some View { content(edge) }
}

// MARK: - 折痕 / 摄像头：整组小幅平移，不大挪

/// 自定义按钮栏避开 active 的 occlusion（外屏摄像头）和 division（折痕）。
/// 测量放在未平移的布局框上，平移只作用于内容，避免来回抖。
struct DYRailReservedNudge: ViewModifier {
    var railEdge: HorizontalEdge? = nil
    var verticalSpace: ClosedRange<CGFloat>? = nil
    var disabled = false
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *), !disabled {
            DYRailReservedNudgeBox(railEdge: railEdge, verticalSpace: verticalSpace) { content }
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
private struct DYRailReservedNudgeBox<Content: View>: View {
    var railEdge: HorizontalEdge?
    var verticalSpace: ClosedRange<CGFloat>?
    @Environment(\.layoutDirection) private var layoutDirection
    @ViewBuilder var content: () -> Content
    @State private var nudge: CGSize = .zero

    var body: some View {
        content()
            .offset(nudge)
            // Observe geometry changes, including reserved-region changes without a resize.
            // Measure the unshifted wrapper so our own translation cannot cause feedback.
            .background {
                Color.clear
                    .onGeometryChange(for: CGSize.self) { proxy in
                        DYReservedNudge.offset(in: proxy, railEdge: railEdge, layoutDirection: layoutDirection, verticalSpace: verticalSpace)
                    } action: { new in
                        if hypot(new.width - nudge.width, new.height - nudge.height) > 0.5 { nudge = new }
                    }
            }
    }
}

@available(iOS 27.1, *)
enum DYReservedNudge {
    /// 在视图自己的坐标里，把和遮挡区相交的部分挪到最近的一侧。摄像头优先向下，符合外屏「小幅下移」。
    static func offset(in proxy: GeometryProxy, railEdge: HorizontalEdge? = nil,
                       layoutDirection: LayoutDirection = .leftToRight, verticalSpace: ClosedRange<CGFloat>? = nil) -> CGSize {
        let local = CGRect(origin: .zero, size: proxy.size)
        guard local.width > 1, local.height > 1 else { return .zero }
        var box = local
        var acc = CGSize.zero
        for region in proxy.reservedRegions(kind: .occlusion, layoutDirectionBehavior: .fixed) where region.isActive && region.frame.intersects(box) {
            let d = clear(box, region.frame, preferDown: true, railEdge: railEdge, layoutDirection: layoutDirection, verticalSpace: verticalSpace.map { ($0.lowerBound - acc.height)...($0.upperBound - acc.height) })
            acc.width += d.width
            acc.height += d.height
            box = box.offsetBy(dx: d.width, dy: d.height)
        }
        for region in proxy.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed) where region.isActive && region.frame.intersects(box) {
            let d = clear(box, region.frame, preferDown: false, railEdge: railEdge, layoutDirection: layoutDirection, verticalSpace: verticalSpace.map { ($0.lowerBound - acc.height)...($0.upperBound - acc.height) })
            acc.width += d.width
            acc.height += d.height
            box = box.offsetBy(dx: d.width, dy: d.height)
        }
        return acc
    }

    private static func clear(_ box: CGRect, _ region: CGRect, preferDown: Bool,
                              railEdge: HorizontalEdge?, layoutDirection: LayoutDirection, verticalSpace: ClosedRange<CGFloat>?) -> CGSize {
        let left = CGSize(width: region.minX - box.maxX, height: 0)
        let right = CGSize(width: region.maxX - box.minX, height: 0)
        let up = CGSize(width: 0, height: region.minY - box.maxY)
        let down = CGSize(width: 0, height: region.maxY - box.minY)
        let mag: (CGSize) -> CGFloat = { abs($0.width) + abs($0.height) }
        // Edge rails must move inward rather than taking a shorter path offscreen.
        let candidates: [CGSize]
        if let railEdge {
            let onLeft = (railEdge == .leading) == (layoutDirection == .leftToRight)
            // Occlusions above an edge rail move it down within the same column.
            if preferDown {
                if verticalSpace?.contains(down.height) ?? true { return down }
                if verticalSpace?.contains(up.height) ?? true { return up }
                // No vertical slot can fit the complete rail: keep every control onscreen.
                return onLeft ? right : left
            }
            candidates = [onLeft ? right : left, up, down].filter {
                verticalSpace?.contains($0.height) ?? true
            }
        } else {
            candidates = [left, right, up, down]
        }
        let best = candidates.min { mag($0) < mag($1) } ?? .zero
        if preferDown, (verticalSpace?.contains(down.height) ?? true), mag(down) <= mag(best) + 24 { return down }
        return best
    }
}

// MARK: - Shared comments presentation

enum DYBottomSheetKind {
    case comments, share, options
}

struct DYSheetDragActions {
    let update: (CGFloat) -> Void
    let finish: (Bool) -> Void
}

extension EnvironmentValues {
    @Entry var dySheetDrag: DYSheetDragActions? = nil
}

/// Shared dismissal arbitration. A vertical scroll that began below the top
/// never becomes a dismissal; a horizontal gesture can close from any row.
struct DYPanelDismissGesture: ViewModifier {
    @Environment(\.dySheetDrag) private var sheetDrag
    var isAtTop = true
    var allowsSwipeRight = false
    var onClose: (() -> Void)?
    @State private var direction: Axis?
    @State private var startedAtTop = false

    func body(content: Content) -> some View {
        content.simultaneousGesture(DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                guard onClose != nil else { return }
                if direction == nil {
                    startedAtTop = isAtTop
                    direction = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                if direction == .vertical, startedAtTop,
                   value.translation.height > abs(value.translation.width) {
                    sheetDrag?.update(value.translation.height)
                }
            }
            .onEnded { value in
                defer { direction = nil }
                guard let onClose else { return }
                let dx = value.translation.width, dy = value.translation.height
                let right = allowsSwipeRight && direction == .horizontal && dx > abs(dy) * 1.2 &&
                    (dx > 70 || (dx > 25 && value.predictedEndTranslation.width > 160))
                let down = direction == .vertical && startedAtTop && dy > abs(dx) * 1.2 &&
                    (dy > 70 || (dy > 20 && value.predictedEndTranslation.height > 150))
                if right || down { onClose() }
                else { sheetDrag?.finish(false) }
            }, including: onClose == nil ? .none : .all)
    }
}

/// Compact descriptions use the same viewport as the in-place comment pane.
struct DYInlineCommentPlacement {
    let videoFrame: CGRect?
    let panelHeight: CGFloat
    let panelTop: CGFloat
    let panelWidth: CGFloat

    static func applies(to aweme: DYAweme?, enabled: Bool) -> Bool {
        guard enabled, let aweme,
              aweme.images.isEmpty, aweme.play != nil else { return false }
        return aweme.videoAspect.isFinite && aweme.videoAspect > 1
    }

    @MainActor init?(_ geo: GeometryProxy, aweme: DYAweme?, enabled: Bool, showsCaption: Bool,
                     usesCompactPanel: Bool) {
        guard !DYDuoMetrics.foldIsActive(geo), let aweme else { return nil }
        let liftsVideo = Self.applies(to: aweme, enabled: enabled)
        let compactCaption = showsCaption && (enabled || geo.size.width < DYDuoMetrics.legacyWideMin)
        guard liftsVideo || compactCaption || usesCompactPanel else { return nil }

        let bounds = geo.frame(in: .global)
        let bottom = bounds.maxY + DYDuoMetrics.bottomSafeAreaExtension(in: geo)
        let split: CGFloat
        if liftsVideo {
            let available = CGSize(width: bounds.width, height: max(0, bottom) * 0.38)
            let fitted = DYVideoFit.contentSize(container: available, videoAspect: aweme.videoAspect, fillWidth: false)
            let frame = CGRect(x: bounds.minX, y: 0, width: bounds.width, height: fitted.height)
            videoFrame = frame
            split = frame.maxY
        } else {
            videoFrame = nil
            split = bounds.minY + (bottom - bounds.minY) * 0.38
        }
        panelTop = split - bounds.minY
        panelHeight = max(0, bottom - split)
        panelWidth = bounds.width
    }
}

extension EnvironmentValues {
    @Entry var dyCommentVideoFrame: CGRect? = nil
    @Entry var dyInlineCommentVisible = false
    @Entry var dyUsesClassicVideoLayout = false
    @Entry var dyStacksLandscapeComments = false
    @Entry var dyDuoLandscapeWindow = false
}

struct DYInlineCommentOverlay: ViewModifier {
    let placement: DYInlineCommentPlacement?
    let bridge: DouyinBridge
    let aweme: DYAweme?
    var focus: DYCommentFocus? = nil
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.dyCommentVideoFrame, placement?.videoFrame)
            .environment(\.dyInlineCommentVisible, placement != nil)
            .allowsHitTesting(placement == nil)
            .accessibilityHidden(placement != nil)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if let placement, let aweme {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: onClose)
                            .accessibilityHidden(true)
                        DYEdgePanelSurface(width: placement.panelWidth, height: placement.panelHeight,
                                           onClose: onClose) {
                            DYCommentPanel(bridge: bridge, aweme: aweme, onClose: onClose, focus: focus)
                                .id(aweme.id)
                        }
                        .offset(y: placement.panelTop)
                        .transition(reduceMotion ? .identity : .offset(y: placement.panelHeight))
                        .accessibilityAddTraits(.isModal)
                    }
                }
                .animation(reduceMotion ? nil : .snappy, value: placement != nil)
            }
    }
}

extension View {
    func dyBottomSheet<Panel: View>(isPresented: Binding<Bool>, kind: DYBottomSheetKind,
                                   hidesStatusBar: Bool = false,
                                   @ViewBuilder content: @escaping () -> Panel) -> some View {
        modifier(DYBottomSheetPresenter(isPresented: isPresented, kind: kind,
                                        hidesStatusBar: hidesStatusBar, panel: content))
    }

    @ViewBuilder
    func dyCommentStatusVisibility(hidden: Bool) -> some View {
        if #available(iOS 27.0, *) {
            toolbarVisibility(hidden ? .hidden : .automatic, for: .statusBar)
        } else {
            self
        }
    }
}

struct DYCommentBarPolicy: ViewModifier {
    let hidesStatus: Bool
    let usesHorizontalStatus: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content
                .toolbarVerticalBehavior(usesHorizontalStatus || hidesStatus ? .disabled : .automatic)
                .dyCommentStatusVisibility(hidden: hidesStatus)
        } else {
            content
        }
    }
}

/// Compact presentations reach the display edges. A full-screen presentation
/// supplies modal focus/dismissal; only its bottom panel draws Liquid Glass.
private struct DYBottomSheetPresenter<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let kind: DYBottomSheetKind
    let hidesStatusBar: Bool
    @ViewBuilder var panel: () -> Panel

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented) {
            DYEdgeBottomPanel(kind: kind, panel: panel)
                .presentationBackground(.clear)
                .dyCommentStatusVisibility(hidden: hidesStatusBar)
        }
    }
}

struct DYBottomPanelContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DYEdgeBottomPanel<Panel: View>: View {
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat?
    let kind: DYBottomSheetKind
    @ViewBuilder var panel: () -> Panel

    var body: some View {
        GeometryReader { geo in
            let panelHeight: CGFloat = switch kind {
            case .comments: min(geo.size.height, (geo.size.height + geo.safeAreaInsets.bottom) * 0.62)
            case .options: min(geo.size.height * 0.78, contentHeight ?? 320)
            case .share: min(geo.size.height, contentHeight ?? DDTheme.shareSheetHeight)
            }
            let trailingHalf = kind != .comments && geo.size.width >= DYDuoMetrics.legacyWideMin
            let panelWidth = trailingHalf ? geo.size.width / 2 : geo.size.width
            ZStack(alignment: .bottomTrailing) {
                Color.clear.ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismiss() }
                    .accessibilityHidden(true)
                DYEdgePanelSurface(width: panelWidth, height: panelHeight, onClose: { dismiss() }) {
                    panel()
                        .onPreferenceChange(DYBottomPanelContentHeightKey.self) { height in
                            if height > 0 { contentHeight = height }
                        }
                }
            }
        }
        // Respect the keyboard, while the glass reaches the physical edges.
        .ignoresSafeArea(.container)
        .dyDisableVerticalToolbar()
    }
}

private struct DYEdgePanelSurface<Panel: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0
    let width: CGFloat
    let height: CGFloat
    let onClose: () -> Void
    @ViewBuilder var panel: () -> Panel

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: DDTheme.sheetCornerRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: DDTheme.sheetCornerRadius)
        VStack(spacing: 0) {
            panel()
                .environment(\.dySheetDrag, DYSheetDragActions(update: { offset in
                    dragOffset = min(height, max(0, offset))
                }, finish: { shouldClose in
                    if shouldClose { onClose() }
                    else { withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { dragOffset = 0 } }
                }))
        }
        .frame(width: width, height: height, alignment: .top)
        .dyPanelGlass(in: shape)
        .clipShape(shape)
        .offset(y: dragOffset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.sheet.edgeSurface")
    }
}

/// Every entry shares the same comment content; the presenter owns its surface.
struct DYCommentSheet: View {
    let bridge: DouyinBridge
    let aweme: DYAweme
    let onClose: () -> Void
    var focus: DYCommentFocus? = nil

    var body: some View {
        DYCommentPanel(bridge: bridge, aweme: aweme, onClose: onClose, focus: focus)
            .dyDisableVerticalToolbar()
    }
}

/// Shared geometry for recommendation, following, profile/search works and
/// comment links from messages. Changing pane size never replaces the pager.
struct DYCommentPaneMetrics {
    let resident: Bool
    let sideBySide: Bool
    let showsPane: Bool
    let videoSize: CGSize
    let paneSize: CGSize
    let paneOrigin: CGPoint
    let trailingInset: CGFloat

    init(_ geo: GeometryProxy, isPresented: Bool, allowsResident: Bool = true,
         paneFraction: CGFloat? = nil, keepsSideBySide: Bool = false) {
        let w = geo.size.width, h = geo.size.height
        resident = allowsResident && DYDuoMetrics.foldIsActive(geo)
        if resident, let hinge = DYDuoMetrics.videoCommentPanes(geo) {
            sideBySide = hinge.book
            showsPane = true
            videoSize = hinge.video.size
            // The hinge panes are measured inside the navigation safe area.
            // Extend the comment surface to the physical edges, just like the
            // video, instead of leaving a black border around a smaller card.
            let bottomExtension = DYDuoMetrics.bottomSafeAreaExtension(in: geo)
            if hinge.book {
                let split = hinge.panel.minX
                paneOrigin = CGPoint(x: split, y: -geo.safeAreaInsets.top)
                paneSize = CGSize(width: w + geo.safeAreaInsets.trailing - split,
                                  height: h + geo.safeAreaInsets.top + bottomExtension)
                trailingInset = max(geo.safeAreaInsets.trailing,
                    DYDuoMetrics.trailingOcclusionInset(geo, pane: hinge.panel))
            } else {
                let split = hinge.panel.minY
                paneOrigin = CGPoint(x: -geo.safeAreaInsets.leading, y: split)
                paneSize = CGSize(width: w + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                                  height: h + bottomExtension - split)
                trailingInset = geo.safeAreaInsets.trailing
            }
            return
        }
        let tableFold = resident && w <= h
        sideBySide = keepsSideBySide || w >= DYDuoMetrics.legacyWideMin || (resident && w > h)
        showsPane = resident || (sideBySide && isPresented)
        // Preserve v1.3.11's comment width. Author panes still split in half.
        let paneW: CGFloat
        if showsPane && sideBySide {
            if let paneFraction {
                paneW = max(0, (w + geo.safeAreaInsets.trailing) * paneFraction - geo.safeAreaInsets.trailing)
            } else {
                paneW = resident ? w * 0.45 : min(380, w * 0.42)
            }
        } else {
            paneW = 0
        }
        let paneH = tableFold ? h * 0.45 : 0
        videoSize = CGSize(width: w - paneW, height: h - paneH)
        trailingInset = geo.safeAreaInsets.trailing
        // Keyboard insets must not be added back to the panel height. Keep the
        // input above the keyboard while the background reaches the screen edge.
        let bottom = DYDuoMetrics.bottomSafeAreaExtension(in: geo)
        paneSize = CGSize(width: sideBySide ? paneW + trailingInset : w,
                          height: tableFold ? paneH : h + geo.safeAreaInsets.top + bottom)
        paneOrigin = CGPoint(x: sideBySide ? videoSize.width : 0,
                             y: tableFold ? videoSize.height : -geo.safeAreaInsets.top)
    }
}

/// Used by the list player opened from My, author/search grids and message links.
struct DYCommentPlayerLayout<Video: View>: View {
    let bridge: DouyinBridge
    let aweme: DYAweme?
    @Binding var showComments: Bool
    @State private var captionItem: DYAweme?
    @State private var openedCommentsManually = false
    @State private var bookFoldComments = false
    @State private var cleanScreen = false
    var focus: DYCommentFocus? = nil
    var onBack: () -> Void
    var backIdentifier = "douyin.list.back"
    var allowsComments = true
    var allowsResidentComments = true
    @AppStorage(DDChromeMode.key) private var chromeModeRaw = DDChromeMode.classic.rawValue
    @Environment(\.dySearchPresented) private var searchPresented
    @Environment(\.dyStacksLandscapeComments) private var stacksLandscapeComments
    @Environment(\.dyDuoLandscapeWindow) private var duoLandscapeWindow
    @Environment(\.dyHingeClosed) private var hingeClosed
    @ViewBuilder var video: (EdgeInsets) -> Video

    private var usesClassicLayout: Bool {
        if #available(iOS 27.1, *) { return chromeModeRaw == DDChromeMode.duoClassic.rawValue }
        return false
    }

    private var commentItem: DYAweme? { allowsComments ? aweme ?? captionItem : nil }
    private var showsComments: Bool { showComments && !searchPresented && commentItem != nil }

    /// 评论四种界面统一用经典那套（老板 2026-11-17）：外屏横屏视频上移、内屏右侧滑出、半折常驻、贴边底部面板。
    /// 只有菜单（经典的系统导航栏 / 原生按钮）和简介面板按模式分，见 docs/ui-modes.md「必须分开」。
    var body: some View {
        Group {
            if usesClassicLayout { classicBody } else { sharedBody }
        }
    }

    /// 默认 / 简洁 / 极简：同一套评论几何，没有系统导航栏；简介照旧原地展开
    private var sharedBody: some View {
        playerLayout
            .onChange(of: showComments) { _, shown in if shown { openedCommentsManually = true } }
    }

    private var horizontalCommentStatus: Bool {
        (bookFoldComments && !searchPresented && commentItem != nil) || (duoLandscapeWindow && showsComments)
    }

    private var hidesCommentStatus: Bool {
        (hingeClosed || stacksLandscapeComments) && showsComments
    }

    private var presentsLandscapeComments: Bool {
        showsComments && (focus == nil || openedCommentsManually || captionItem != nil)
            && DYInlineCommentPlacement.applies(to: commentItem, enabled: stacksLandscapeComments)
    }

    private var classicBody: some View {
        NavigationStack { playerLayout }
            .modifier(DYCommentBarPolicy(hidesStatus: hidesCommentStatus,
                                         usesHorizontalStatus: horizontalCommentStatus))
            .environment(\.dyExpandedCaptionID, captionItem == nil ? nil : commentItem?.id)
            .environment(\.dyExpandVideoCaption, { item in
                guard allowsComments else { return }
                captionItem = item
                showComments = true
            })
            .onChange(of: showComments) { _, shown in
                if shown { openedCommentsManually = true }
                else { captionItem = nil }
            }
    }

    private var playerLayout: some View {
        GeometryReader { geo in
            let placement = showsComments
                ? DYInlineCommentPlacement(geo, aweme: commentItem, enabled: presentsLandscapeComments,
                                          showsCaption: captionItem != nil, usesCompactPanel: stacksLandscapeComments)
                : nil
            let layout = DYCommentPaneMetrics(geo, isPresented: showsComments && placement == nil,
                                              allowsResident: !searchPresented && allowsComments && allowsResidentComments)
            ZStack(alignment: .topLeading) {
                video(geo.safeAreaInsets)
                    .environment(\.dyStandaloneBack, onBack)
                    .environment(\.dyStandaloneBackIdentifier, backIdentifier)
                    .environment(\.duoInlineVideoNavigation, layout.showsPane || showsComments)
                    .environment(\.duoCleanScreen, cleanScreen)
                    .environment(\.dyCommentsOpen, showsComments || layout.showsPane)
                    .frame(width: layout.videoSize.width, height: layout.videoSize.height)
                    .environment(\.dyRestrictsPlaybackToPane, layout.showsPane && layout.sideBySide)
                    // 侧栏评论时裁边：播放器环境光底铺满整屏，会盖住右侧评论栏（同推荐页 DYCommentStage）
                    .modifier(DDClipIf(on: layout.showsPane && layout.sideBySide))
                if layout.showsPane, let aweme = commentItem {
                    DYCommentPanel(bridge: bridge, aweme: aweme,
                                   onClose: layout.resident && captionItem == nil ? nil : { showComments = false },
                                   focus: focus, fillsPane: true,
                                   trailingInset: horizontalCommentStatus ? geo.safeAreaInsets.trailing : layout.trailingInset,
                                   horizontalStatus: horizontalCommentStatus)
                        .id(aweme.id)
                        .frame(width: layout.paneSize.width, height: layout.paneSize.height)
                        .clipped()
                        .dyDeskLight(layout.resident && !layout.sideBySide, videoHeight: layout.videoSize.height)
                        .overlay(alignment: .leading) {
                            if layout.sideBySide { Color(uiColor: .separator).frame(width: 0.5) }
                        }
                        .offset(x: layout.paneOrigin.x, y: layout.paneOrigin.y)
                        .accessibilityIdentifier("douyin.list.commentPane")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .background(Color.ddBackground.ignoresSafeArea())
            .overlayPreferenceValue(DYActiveVideoActionsKey.self) { actions in
                if #available(iOS 27.1, *), usesClassicLayout {
                    DYNativeVideoActions(actions: showsComments || layout.showsPane ? nil : actions,
                                         isClean: cleanScreen, onToggleClean: { cleanScreen.toggle() },
                                         onBack: onBack, backIdentifier: backIdentifier)
                        .id(horizontalCommentStatus || hidesCommentStatus)
                        .frame(width: layout.videoSize.width)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .modifier(DYStandaloneBarPolicy(classic: usesClassicLayout))
            .onChange(of: layout.resident && layout.sideBySide, initial: true) { _, bookFold in
                bookFoldComments = bookFold
            }
            .animation(!searchPresented && layout.sideBySide ? .snappy : nil, value: showComments)
            .animation(searchPresented ? nil : .snappy, value: layout.resident)
            .modifier(DYInlineCommentOverlay(placement: placement, bridge: bridge, aweme: commentItem,
                                             focus: focus, onClose: { showComments = false }))
            .dyBottomSheet(isPresented: Binding(
                get: { showsComments && placement == nil && !layout.sideBySide && !layout.resident },
                set: { if placement == nil && !layout.sideBySide && !layout.resident { showComments = $0 } }
            ), kind: .comments, hidesStatusBar: hidesCommentStatus) {
                if let aweme = commentItem {
                    DYCommentSheet(bridge: bridge, aweme: aweme, onClose: { showComments = false }, focus: focus)
                }
            }
        }
        .ignoresSafeArea(.container, edges: presentsLandscapeComments ? [.top, .horizontal]
                         : hidesCommentStatus ? .horizontal : [])
        .modifier(DYCommentBarPolicy(hidesStatus: hidesCommentStatus,
                                     usesHorizontalStatus: horizontalCommentStatus))
    }
}


extension View {
    @ViewBuilder func dyDisableVerticalToolbar() -> some View {
        if #available(iOS 27.1, *) { self.toolbarVerticalBehavior(.disabled) }
        else { self }
    }
    @ViewBuilder func dyPanelGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) { self.glassEffect(.regular, in: shape) }
        else { self.background(.ultraThinMaterial, in: shape) }
    }
}

private struct DYStandaloneBarPolicy: ViewModifier {
    let classic: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 27.1, *), classic {
            content.toolbarVisibility(.hidden, for: .tabBar)
                .toolbarVisibility(.visible, for: .navigationBar)
                .toolbarVerticalCompressionBehavior(.prefersToolbarItems)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        } else {
            content.toolbar(.hidden, for: .navigationBar)
        }
    }
}


struct DYScrollTopObserver: ViewModifier {
    @Binding var atTop: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top <= 1
            } action: { _, top in atTop = top }
        } else {
            // iOS 17 retains header-drag/right-swipe dismissal; a list scroll
            // must never dismiss a panel without reliable scroll-position data.
            content.onAppear { atTop = false }
        }
    }
}

/// 只在系统确认铰链 closed 时启用左贴边；不能拿窄视频窗格宽度猜外屏。
/// 铰链状态由根视图 `DYHingeStateRoot` 统一读取后经环境下发：
/// `onHingeChange` 只在状态「变化」时回调，而且只回给当时已经在屏上的那一个视图——
/// 以前每个视频页各挂一份，只有启动时第一页收到 closed，往后滑出来的新页永远停在默认 false（居中）。
struct DYClosedPortraitAlignment: ViewModifier {
    @Environment(\.dyHingeClosed) private var hingeClosed
    let viewport: CGSize
    let videoAspect: Double
    let fills: Bool
    func body(content: Content) -> some View {
        content.offset(x: DYDuoMetrics.closedPortraitVideoOffset(viewport: viewport, videoAspect: videoAspect,
                       fills: fills, isDuo: DYDuoMetrics.isDuoHardware, isClosed: hingeClosed))
    }
}

/// 挂在 App 根视图：整个 App 只读一次铰链状态，放进环境给所有页面用。
struct DYHingeStateRoot: ViewModifier {
    @State private var closed = false
    @State private var fullyOpen = false
    @State private var compactWindow = false

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content
                .environment(\.dyHingeClosed, closed)
                .environment(\.dyStacksLandscapeComments,
                             DYDuoMetrics.isDuoHardware && (closed || (fullyOpen && compactWindow)))
                .environment(\.dyDuoLandscapeWindow,
                             DYDuoMetrics.isDuoHardware && fullyOpen && !compactWindow)
                .onGeometryChange(for: Bool.self) { geo in
                    // Use the app window, including half-width Split View panes.
                    let insets = geo.safeAreaInsets
                    let width = geo.size.width + insets.leading + insets.trailing
                    let height = geo.size.height + insets.top + insets.bottom
                    return width < DYDuoMetrics.legacyWideMin || width < height
                } action: { compactWindow = $0 }
                .onHingeChange { _, context in
                    closed = context.hinge?.status == .closed
                    fullyOpen = context.hinge?.status == .fullyOpen
                    DYLiveModel.log("DDHINGE root status=\(String(describing: context.hinge?.status))")
                }
        } else {
            content
        }
    }
}
