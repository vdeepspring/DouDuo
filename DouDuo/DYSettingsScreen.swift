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
    // 内容
    @AppStorage("douyin_wide_landscape_v1") private var landscapeOnly = true
    @AppStorage(DYContentPrefs.portraitOnlyKey) private var portraitOnly = false
    @AppStorage(DYContentPrefs.shortMaxKey) private var shortMax = 0
    @AppStorage(DYHashtagFilter.storageKey) private var blockedHashtags = ""
    // 弹幕
    @AppStorage("douyin_danmaku_v1") private var danmakuEnabled = true
    @AppStorage(DYDanmakuPolicy.densityKey) private var density = DYDanmakuPolicy.Density.standard.rawValue
    @AppStorage(DYDanmakuPolicy.deduplicateKey) private var deduplicate = true
    // 缓存
    @AppStorage(DYVideoCache.countKey) private var cacheCount = DYVideoCache.defaultCount
    @AppStorage(DYDMNotificationSettings.notifyKey) private var dmNotifications = false
    @AppStorage(DYDMNotificationSettings.detailKey) private var dmDetail = false
    @State private var clearing = false
    @State private var cacheNote: String?

    private static let cacheChoices: [(Int, String)] = [(5, "5 条"), (10, "10 条"), (20, "20 条"), (50, "50 条"), (100, "100 条"), (0, "关闭")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onRefresh() }
                    } label: {
                        Label("刷新推荐", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("settings.refresh")
                } footer: {
                    Text("换一批推荐，当前在看的这条保留。")
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
                    Text("缓存")
                }

                Section("界面") {
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
                }

                Section {
                    Picker("环境光", selection: $ambientLevel) {
                        ForEach(DYVideoAmbient.levels, id: \.self) { Text(DYVideoAmbient.title($0)).tag($0) }
                    }
                    .accessibilityIdentifier("settings.ambient")
                } header: {
                    Text("播放")
                } footer: {
                    Text("环境光：视频没铺满时，四周跟着画面颜色实时变化，底色跟随外观。倍速、静音、听书、自动连播、铺满宽度在播放页菜单里直接切换。")
                }

                Section {
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
                } header: {
                    Text("内容偏好")
                } footer: {
                    Text("推荐按抖音推荐顺序播放；横着看且开启「只放横屏内容」时跳过竖屏视频，竖着看且开启「只放竖屏内容」时跳过横屏视频（默认约七成竖屏穿插）。「只看短视频」按时长过滤，图集不受影响。标签过滤与这些开关只作用于推荐页。")
                }

                Section {
                    Toggle("显示弹幕", isOn: $danmakuEnabled).accessibilityIdentifier("douyin.danmaku.enabled")
                    Picker("弹幕密度", selection: $density) {
                        ForEach(DYDanmakuPolicy.Density.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .accessibilityIdentifier("douyin.danmaku.density")
                    Toggle("10 秒内重复去重", isOn: $deduplicate).accessibilityIdentifier("douyin.danmaku.deduplicate")
                } header: {
                    Text("弹幕")
                } footer: {
                    Text("显示区域：屏幕上方 1/3。发弹幕在「更多」里。")
                }

                Section {
                    Toggle("点评论回复时自动弹出键盘", isOn: $replyAutoKeyboard)
                        .accessibilityIdentifier("douyin.comment.autoKeyboard")
                } header: { Text("评论") } footer: {
                    Text("关掉后点名字只进入「回复 @某人」，点输入框才弹键盘。无论开关：往下拖评论列表、点输入框旁的键盘按钮、或再点一次同一条评论，都能收起键盘。")
                }
                Section {
                    Toggle("应用内私信通知", isOn: $dmNotifications)
                        .accessibilityIdentifier("settings.dm.notify")
                    Toggle("显示会话名称与头像", isOn: $dmDetail)
                        .disabled(!dmNotifications)
                        .accessibilityIdentifier("settings.dm.detail")
                } header: {
                    Text("私信")
                } footer: {
                    Text("使用 DouDou 期间收到新私信活动时显示提醒。显示会话名称与头像关闭后仅显示匿名私信提醒。")
                }

                Section("账号") {
                    Button {
                        dismiss()
                        // 先收起设置页再弹网页，避免两层全屏叠在一起
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpenWeb() }
                    } label: {
                        Label("网页版 / 登录", systemImage: "safari")
                    }
                    .accessibilityIdentifier("settings.web")
                }

                Section("关于") {
                    LabeledContent("当前版本", value: DDAppVersion.display)
                        .accessibilityIdentifier("douyin.about.version")
                    Button {
                        UIApplication.shared.open(DDUpdateChecker.repoURL)
                    } label: {
                        Label("开源仓库", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityIdentifier("douyin.about")
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
