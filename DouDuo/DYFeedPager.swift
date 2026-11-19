import SwiftUI

/// 推荐流的竖向分页器：默认 / 简洁 / 极简 / 经典四种界面共用这一份。
/// 以前经典布局（PR #17）各自复制了一份 ScrollView，漏挂 `DYPagingSpeedBridge`，
/// 只有它还在走系统分页的慢收尾，滑起来明显比另外三种拖沓。改分页行为只改这里。
struct DYFeedPager<Page: View>: View {
    let items: [DYAweme]
    @Binding var currentID: String?
    @Binding var scrollID: String?
    @Binding var userScrolling: Bool
    @Binding var scrollEndTask: Task<Void, Never>?
    /// 默认界面打开左右分栏搜索时要跟随窗格宽度，只锁高度；经典布局整页铺满。
    var pageAxes: Axis.Set = .vertical
    /// 第二个参数 = 这一条是不是当前条，用分页器自己读到的 currentID 算。
    /// 别在外层闭包里拿外层的 currentID 比：外层 body 没直接读 currentID，SwiftUI 不会因它变化重算外层，
    /// 闭包里捕获的是旧值（1.6.2 冷启动当前条一直是 nil → 没有一页 active → 视频全不播；
    /// 以前靠启动弹「有新版本/更新内容」顺带重算外层盖住了）。
    @ViewBuilder let page: (DYAweme, Bool) -> Page
    /// 系统「减少动态效果」时分页桥不接管，只能靠 scrollPosition 切当前条
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            pager
            // 切换界面模式后新建的分页器要从中间某条接着播：LazyVStack 首次布局不认 scrollPosition 初值，
            // 会停在第一条（当前条的页面根本没挂上）。出现后显式滚过去一次；当前条就是第一条时什么也不做。
            .onAppear {
                scrollID = currentID
                guard let id = currentID, items.first?.id != id else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var pager: some View {
        ScrollView(.vertical) {
            // 非 Lazy：当前前 1 后 2 条提前挂真页面（第一帧已就绪），其余是轻量占位，见 DYPagerWindow
            DYPagerStack(items: items, currentID: currentID, page: { item in page(item, item.id == currentID) }, pageAxes: pageAxes)
            .scrollTargetLayout()
            // 固定「更快」收尾（0.10s）；系统开了「减少动态效果」时自动退回系统分页。
            .background(DYPagingSpeedBridge(ids: items.map(\.id), currentID: $currentID))
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrollID, anchor: .center)
        .simultaneousGesture(DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                scrollEndTask?.cancel()
                // 只在状态真的变化时写，避免拖动中每帧都触发整屏重算
                if !userScrolling { userScrolling = true }
            }
            .onEnded { _ in
                // 下拉不再触发刷新（顶部点击/轻扫会误判成刷新）；刷新走「更多 → 刷新推荐」。
                scrollEndTask = Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled else { return }
                    // 兜底：万一分页桥没接上（没触发 didSettle），停稳后按实际位置切当前条，别卡在上一条
                    if let s = scrollID, s != currentID, items.contains(where: { $0.id == s }) {
                        DYLiveModel.log("DDSETTLE-FALLBACK \(s.suffix(6))")
                        currentID = s
                    }
                    userScrolling = false
                }
            })
        .onChange(of: scrollID) { _, id in
            guard let id, items.contains(where: { $0.id == id }) else { return }
            // 老板定：滑到位停住才播。滚动位置过中线时不切当前条——由分页桥在收尾动画停住时（didSettle）切。
            // 只有减少动态效果（分页桥不接管）时才沿用系统的过中线即切。
            if userScrolling { if reduceMotion { currentID = id } }
            else if id != currentID { scrollID = currentID }
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
    }
}
