import SwiftUI

/// 推荐页评论排布：四种界面同一份（老板 2026-11-17 定，见 docs/ui-modes.md）。
///
/// 原样搬自经典推荐页（DYClassicFeedScreen.flatArrangement），一套布局通吃所有状态，且**不换容器**
/// （换容器会重建播放器 → 黑屏 / 重播）：
/// - Duo 外屏 / 内屏竖拿：横屏视频移到顶部，评论在下（DYInlineCommentOverlay）
/// - 平放 / 外屏：够宽时评论从右侧滑出（视频缩窄），窄屏走贴边底部面板（dyBottomSheet）
/// - 半折叠：视频缩到一多半，另一半常驻评论（宽>高→左右分；高>宽→上下分）
/// - 横屏右划 / 下拉关闭：评论面板自带（DYPanelDismissGesture）
///
/// 维护规矩：评论「怎么摆」只改这里。各界面只负责菜单（评论盖住视频时自己把菜单收起）。
struct DYCommentStage<Feed: View, Author: View>: View {
    let geo: GeometryProxy
    let bridge: DouyinBridge
    /// 当前评论对象（推荐 / 关注 / 简介）
    let aweme: DYAweme?
    @Binding var showComments: Bool
    let showSearch: Bool
    let isLive: Bool
    /// 外屏 / 内屏竖拿时把横屏视频叠在评论上方（系统铰链：DYHingeStateRoot）
    let stacksLandscapeComments: Bool
    /// 外屏叠放评论时状态栏让位（经典口径）
    let hidesCommentStatus: Bool
    let horizontalCommentStatus: Bool
    /// 经典简介面板：评论面板顶部显示作者 / 全文
    var showsCaption = false
    /// 右侧作者页（经典内屏）；其它界面传 nil
    var authorPane: (id: String?, workOpen: Bool, supportsSidePanel: Bool)? = nil
    @ViewBuilder var feed: () -> Feed
    @ViewBuilder var author: () -> Author
    /// 布局结果回报给外层（菜单让位、顶栏宽度等）
    var onLayout: (_ resident: Bool, _ bookFold: Bool) -> Void = { _, _ in }

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let authorOpen = authorPane?.id != nil
        let showsAuthorPane = (authorPane?.supportsSidePanel ?? false) && authorOpen
        let placement = showComments && !showSearch && !authorOpen && !isLive
            ? DYInlineCommentPlacement(geo, aweme: aweme, enabled: stacksLandscapeComments,
                                       showsCaption: showsCaption, usesCompactPanel: stacksLandscapeComments)
            : nil
        let layout = DYCommentPaneMetrics(geo, isPresented: !showSearch && (showsAuthorPane || (showComments && placement == nil)),
                                          allowsResident: !showSearch && !isLive,
                                          paneFraction: showsAuthorPane ? 0.5 : nil,
                                          keepsSideBySide: showsAuthorPane && (authorPane?.workOpen ?? false))
        let w = geo.size.width, h = geo.size.height

        return ZStack(alignment: .topLeading) {
            feed()
                .frame(width: layout.videoSize.width, height: layout.videoSize.height, alignment: .topLeading)
                .environment(\.dyRestrictsPlaybackToPane, layout.showsPane && layout.sideBySide)
                // 侧栏评论时视频区要裁边：播放器的环境光底（DYAmbientBackdrop）会铺满整屏宽，盖住右侧评论栏
                //（内屏横屏评论纯黑的根因；dd405e6 拿掉这个裁边后 11-18 晚复发，老板 11-19 指出之前修过）。
                .modifier(DDClipIf(on: layout.showsPane && layout.sideBySide))
            if layout.showsPane {
                Group {
                    if showsAuthorPane {
                        author()
                            .padding(.trailing, layout.trailingInset)
                    } else if let cur = aweme {
                        DYCommentPanel(bridge: bridge, aweme: cur,
                                       onClose: layout.resident && !showsCaption ? nil : { showComments = false },
                                       fillsPane: true,
                                       trailingInset: horizontalCommentStatus ? geo.safeAreaInsets.trailing : layout.trailingInset,
                                       horizontalStatus: horizontalCommentStatus)
                            .id(cur.id)
                    }
                }
                .padding(.top, !DYDuoMetrics.isDuoHardware && layout.sideBySide ? DYDuoMetrics.windowSafeTop : 0)
                .frame(width: layout.paneSize.width, height: layout.paneSize.height)
                .clipped()
                .dyDeskLight(layout.resident && !layout.sideBySide && !authorOpen, videoHeight: layout.videoSize.height)
                .overlay(alignment: .leading) {
                    if layout.sideBySide { Color(uiColor: .separator).frame(width: 0.5) }
                }
                .padding(.leading, layout.paneOrigin.x)
                .padding(.top, layout.paneOrigin.y)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .onChange(of: layout.resident, initial: true) { _, resident in
            onLayout(resident, layout.resident && layout.sideBySide)
        }
        .onChange(of: layout.resident && layout.sideBySide, initial: true) { _, bookFold in
            onLayout(layout.resident, bookFold)
        }
        .background((layout.resident ? Color.black : theme.media.strongScrim.color(for: scheme)).ignoresSafeArea())
        .animation(showSearch ? nil : .snappy, value: layout.resident)
        .animation(!showSearch && layout.sideBySide ? .snappy : nil, value: showComments)
        .animation(showSearch ? nil : .snappy, value: authorPane?.id)
        .modifier(DYInlineCommentOverlay(placement: placement, bridge: bridge, aweme: aweme,
                                         onClose: { showComments = false }))
        .dyBottomSheet(isPresented: Binding(
            get: { !showSearch && showComments && placement == nil && !layout.sideBySide && !layout.resident },
            set: { if placement == nil && !(authorPane?.supportsSidePanel ?? false) && !layout.resident { showComments = $0 } }
        ), kind: .comments, hidesStatusBar: hidesCommentStatus) {
            if let cur = aweme {
                DYCommentSheet(bridge: bridge, aweme: cur, onClose: { showComments = false })
            }
        }
    }
}

extension DYCommentStage where Author == EmptyView {
    init(geo: GeometryProxy, bridge: DouyinBridge, aweme: DYAweme?, showComments: Binding<Bool>,
         showSearch: Bool, isLive: Bool, stacksLandscapeComments: Bool,
         hidesCommentStatus: Bool, horizontalCommentStatus: Bool,
         @ViewBuilder feed: @escaping () -> Feed,
         onLayout: @escaping (_ resident: Bool, _ bookFold: Bool) -> Void = { _, _ in }) {
        self.init(geo: geo, bridge: bridge, aweme: aweme, showComments: showComments, showSearch: showSearch,
                  isLive: isLive, stacksLandscapeComments: stacksLandscapeComments,
                  hidesCommentStatus: hidesCommentStatus, horizontalCommentStatus: horizontalCommentStatus,
                  feed: feed, author: { EmptyView() }, onLayout: onLayout)
    }
}

extension EnvironmentValues {
    /// 评论打开（默认 / 简洁 / 极简）：视频页上的按钮和信息收起
    @Entry var dyCommentsOpen = false
    /// 侧栏评论打开时限制画面和环境光的安全区扩展，保持播放器视图身份。
    @Entry var dyRestrictsPlaybackToPane = false
}

/// 只在 on 时裁边。
/// ⚠️ 已知（议题 #52-2）：两个分支是两种视图类型，内屏横屏开关评论会重建播放器，进度倒退几秒。
/// 别改成常挂超大 clipShape / mask（95ef04d 真机评论区黑屏，已回滚），也别整个拿掉（dd405e6 拿掉后评论纯黑）。
struct DDClipIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View { if on { content.clipped() } else { content } }
}
