import SwiftUI

/// 完整设置页：「更多 → 设置」点进来。所有全局偏好集中在这里，菜单里不再层层嵌套。
/// 当前视频相关的操作（转发 / 不感兴趣 / 下载 / 倍速 / 静音 / 听书 / 自动连播 / 发弹幕）和铺满宽度都在表层菜单，这里不重复。
struct DYSettingsScreen: View {
    @AppStorage(DYCommentKeyboard.autoFocusKey) private var replyAutoKeyboard = true
    /// 打开「网页版 / 登录」：由宿主页面负责弹出网页并在关闭后重载签名页
    var onOpenWeb: () -> Void
    /// 刷新推荐：先收起设置页再刷，刷完 toast 由宿主页面显示
    var onRefresh: () -> Void = {}
    /// 清缓存后让宿主把当前视频重新挂回播放器
    var onCacheCleared: () -> Void = {}
    var offlineCandidateSource: ((Int) async throws -> [DYAweme])?
    var offlineInteractionBridge: DouyinBridge?

    @Environment(\.dismiss) private var dismiss
    // 界面
    @AppStorage(DDAppearance.key) private var appearance = DDAppearance.dark.rawValue
    @AppStorage(DDChromeMode.key) private var chromeMode = DDChromeMode.classic.rawValue
    // 播放
    @AppStorage(DYVideoAmbient.key) private var ambientLevel = DYVideoAmbient.defaultLevel
    @AppStorage(DYAutoPiP.storageKey) private var autoPiP = false
    // 内容
    @AppStorage("douyin_wide_landscape_v1") private var landscapeOnly = true
    @AppStorage(DYContentPrefs.portraitOnlyKey) private var portraitOnly = false
    @AppStorage(DYContentPrefs.shortMaxKey) private var shortMax = 0
    @AppStorage(DYContentPrefs.feedIsClientKey) private var feedIsClient = false
    @AppStorage(DYHashtagFilter.storageKey) private var blockedHashtags = ""
    // 弹幕
    @AppStorage("douyin_danmaku_v1") private var danmakuEnabled = true
    @AppStorage(DYDanmakuPolicy.densityKey) private var density = DYDanmakuPolicy.Density.standard.rawValue
    @AppStorage(DYDanmakuPolicy.deduplicateKey) private var deduplicate = true
    // 缓存
    @AppStorage(DYVideoCache.countKey) private var cacheCount = DYVideoCache.defaultCount
    @AppStorage(DYDMNotificationSettings.notifyKey) private var dmNotifications = false
    @AppStorage(DYDMNotificationSettings.detailKey) private var dmDetail = false
    @State private var showNotes = false
    @AppStorage(DYWebComposer.enabledKey) private var commentViaWebUI = false
    @State private var clearing = false
    @State private var cacheNote: String?

    private static let cacheChoices: [(Int, String)] = [(5, "5 条"), (10, "10 条"), (20, "20 条"), (50, "50 条"), (100, "100 条"), (0, "关闭")]

    var body: some View {
        NavigationStack {
            Form {
                // 排序（老板 11-19 要求重排）：最常调的在上，偶尔用的在下。
                // 1 界面  2 播放与弹幕  3 推荐与内容  4 评论与私信  5 缓存与离线  6 账号  7 关于
                Section {
                    Picker("外观", selection: $appearance) {
                        ForEach(DDAppearance.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.appearance")
                    Picker("界面模式", selection: $chromeMode) {
                        ForEach(DDChromeMode.availableCases) { m in
                            Label(m.title, systemImage: m.symbol).tag(m.rawValue)
                        }
                    }
                    .accessibilityIdentifier("settings.chrome")
                } header: {
                    Text("界面")
                }

                Section {
                    Picker("环境光", selection: $ambientLevel) {
                        ForEach(DYVideoAmbient.levels, id: \.self) { Text(DYVideoAmbient.title($0)).tag($0) }
                    }
                    .accessibilityIdentifier("settings.ambient")
                    Toggle("离开应用时自动画中画", isOn: $autoPiP)
                        .accessibilityIdentifier("settings.autoPip")
                    Toggle("显示弹幕", isOn: $danmakuEnabled).accessibilityIdentifier("douyin.danmaku.enabled")
                    Picker("弹幕密度", selection: $density) {
                        ForEach(DYDanmakuPolicy.Density.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .disabled(!danmakuEnabled)
                    .accessibilityIdentifier("douyin.danmaku.density")
                    Toggle("10 秒内重复弹幕去重", isOn: $deduplicate)
                        .disabled(!danmakuEnabled)
                        .accessibilityIdentifier("douyin.danmaku.deduplicate")
                } header: {
                    Text("播放与弹幕")
                } footer: {
                    Text("环境光：视频没铺满时，四周跟着画面颜色变化。弹幕显示在屏幕上方 1/3。倍速、静音、听书、自动连播、铺满宽度、发弹幕在播放页菜单里。\n自动画中画：打开后离开 DouDuo 时，当前短视频会尝试进入系统画中画（由系统决定能否启动）；清屏时的画中画保持原样。")
                }

                Section {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onRefresh() }
                    } label: {
                        Label("刷新推荐", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("settings.refresh")
                    NavigationLink {
                        DYHashtagFilterScreen(currentTags: [], embedded: true)
                    } label: {
                        LabeledContent("按标签过滤视频") {
                            let n = DYHashtagFilter(rawValue: blockedHashtags).tags.count
                            Text(n == 0 ? "未设置" : "已屏蔽 \(n) 个")
                        }
                    }
                    .accessibilityIdentifier("douyin.hashtags.manage")
                    Toggle("横屏时只放横屏内容", isOn: $landscapeOnly).accessibilityIdentifier("douyin.landscape.only")
                    Toggle("竖屏时只放竖屏内容", isOn: $portraitOnly).accessibilityIdentifier("douyin.portrait.only")
                    Picker("只看短视频", selection: $shortMax) {
                        ForEach(DYContentPrefs.shortChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .accessibilityIdentifier("douyin.short.only")
                    Toggle("实验：按电脑客户端请求推荐", isOn: $feedIsClient).accessibilityIdentifier("douyin.feed.isClient")
                } header: {
                    Text("推荐与内容")
                } footer: {
                    Text("刷新推荐会换一批，当前在看的这条保留。竖着看且开启「只放竖屏内容」时跳过横屏视频（默认约七成竖屏穿插）；「只看短视频」按时长过滤，图集不受影响。标签过滤与这些开关只作用于推荐页。「按电脑客户端请求推荐」是实验开关（推荐请求标记 is_client=true），改完点上面的「刷新推荐」生效。")
                }

                Section {
                    Toggle("点回复时自动弹出键盘", isOn: $replyAutoKeyboard)
                        .accessibilityIdentifier("douyin.comment.autoKeyboard")
                    Toggle("用网页评论框发送", isOn: $commentViaWebUI)
                        .accessibilityIdentifier("douyin.comment.webUI")
                    Toggle("应用内私信通知", isOn: $dmNotifications)
                        .accessibilityIdentifier("settings.dm.notify")
                    Toggle("通知里显示会话名称与头像", isOn: $dmDetail)
                        .disabled(!dmNotifications)
                        .accessibilityIdentifier("settings.dm.detail")
                } header: {
                    Text("评论与私信")
                } footer: {
                    Text("网页评论框：文字评论和回复填进抖音网页自己的评论框再点发送，和手动发一样，每条多等几秒；带图评论仍按原方式发。")
                }

                Section {
                    Picker("预缓存数量", selection: $cacheCount) {
                        ForEach(Self.cacheChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .accessibilityIdentifier("settings.cache.count")
                    NavigationLink {
                        DYOfflineDownloadScreen(candidateSource: offlineCandidateSource, interactionBridge: offlineInteractionBridge)
                    } label: {
                        Label("离线视频", systemImage: "tray.and.arrow.down")
                    }
                    .accessibilityIdentifier("settings.cache.offline")
                    NavigationLink {
                        DYStorageScreen()
                    } label: {
                        Label("储存空间", systemImage: "internaldrive")
                    }
                    .accessibilityIdentifier("settings.storage")
                    Button(role: .destructive) {
                        clearing = true
                        Task {
                            let b = await DYVideoCache.shared.clear()
                            cacheNote = "已清除 \(b / 1024 / 1024) MB"
                            clearing = false
                            onCacheCleared()
                        }
                    } label: {
                        LabeledContent(clearing ? "清除中…" : "清除视频缓存") {
                            if let cacheNote { Text(cacheNote) }
                        }
                    }
                    .disabled(clearing)
                    .accessibilityIdentifier("settings.cache.clear")
                } header: {
                    Text("缓存与离线")
                }

                Section {
                    Button {
                        dismiss()
                        // 先收起设置页再弹网页，避免两层全屏叠在一起
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpenWeb() }
                    } label: {
                        Label("网页版 / 登录", systemImage: "safari")
                    }
                    .accessibilityIdentifier("settings.web")
                } header: {
                    Text("账号")
                }

                Section {
                    LabeledContent("当前版本", value: DDAppVersion.display)
                        .accessibilityIdentifier("douyin.about.version")
                    Button {
                        showNotes = true
                    } label: {
                        Label("本版更新内容", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("douyin.about.notes")
                    .sheet(isPresented: $showNotes) {
                        DDReleaseNotesSheet(mode: .whatsNew(DDUpdateChecker.currentVersion))
                    }
                    Button {
                        UIApplication.shared.open(DDUpdateChecker.repoURL)
                    } label: {
                        Label("开源仓库", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityIdentifier("douyin.about")
                } header: {
                    Text("关于")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.ddBackground)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("settings.done")
                }
            }
        }
    }
}

/// 「更多」菜单里的设置入口：点一下打开完整设置页（不再是层层子菜单）。
struct DYSettingsButton: View {
    @Environment(\.dyOpenSettings) private var open
    var body: some View {
        if let open {
            Button("设置", systemImage: "gearshape") { open() }
                .accessibilityIdentifier("douyin.settings")
        }
    }
}

extension EnvironmentValues {
    @Entry var dyOpenSettings: (() -> Void)? = nil
}


/// 评论键盘相关的设置键
enum DYCommentKeyboard {
    static let autoFocusKey = "douyin_comment_reply_autokeyboard_v1"
}
