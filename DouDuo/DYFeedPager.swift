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
    @ViewBuilder let page: (DYAweme) -> Page

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    page(item)
                        .containerRelativeFrame(pageAxes)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
            // 固定「更快」收尾（0.10s）；系统开了「减少动态效果」时自动退回系统分页。
            .background(DYPagingSpeedBridge(ids: items.map(\.id), currentID: $currentID))
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrollID, anchor: .center)
        .onAppear { scrollID = currentID }
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
                    if !Task.isCancelled { userScrolling = false }
                }
            })
        .onChange(of: scrollID) { _, id in
            guard let id, items.contains(where: { $0.id == id }) else { return }
            if userScrolling { currentID = id }
            else if id != currentID { scrollID = currentID }
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
    }
}
