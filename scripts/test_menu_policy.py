#!/usr/bin/env python3
"""Read-only menu checks + execute the real Swift feed policy in isolation.

No network, UIKit, simulator, account writes or send callbacks are executed.
SwiftUI wrappers and DYAweme below are test adapters, not API responses.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FEED = (ROOT / "DouDuo/DouyinFeedView.swift").read_text()
UPSTREAM_ROOT = FEED[FEED.index("struct DYUpstreamFeedScreen:"):FEED.index("enum DDChromeMode:")]
UPSTREAM_PAGE = FEED[FEED.index("struct DYUpstreamVideoPage:"):FEED.index("struct DYClassicVideoPage:")]
EXTRAS = (ROOT / "DouDuo/DouyinExtras.swift").read_text()


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def menu_content(source, title):
    for match in re.finditer(r"\bMenu \{", source):
        candidate = block(source[match.start():], "Menu")
        tail = source[match.start() + len(candidate):]
        if re.match(r'\s*label:\s*\{\s*Label\("' + re.escape(title) + r'",', tail):
            return candidate
    raise AssertionError("Menu not found: " + title)


class MenuPolicyTests(unittest.TestCase):
    def test_legacy_direction_state_removed(self):
        for token in ("douyin_portrait_ratio_v1", "douyin_portrait_only_v2",
                      "portraitRatio", "mixLabel", "竖屏占比", "douyin.mix",
                      "douyin_short_ratio_portrait_v1", "douyin_short_ratio_landscape_v1",
                      "shortRatio", "isShort(", "wantedShort"):
            self.assertNotIn(token, FEED)

    def test_live_module_menu_actions_follow_the_selected_module(self):
        menu = block(FEED, "private func minimalModuleButton")
        live = menu.split("if tab == .live", 1)[1]
        self.assertLess(live.index("我的关注"), live.index('minimalMenuRow("搜索"'))
        self.assertLess(live.index("发现更多"), live.index('minimalMenuRow("搜索"'))
        self.assertIn("douyin.module.live.follow", live)
        self.assertIn("douyin.module.live.discover", live)
        self.assertIn("queueLiveModule(.followedLive)", live)
        self.assertIn("queueLiveModule(.discover)", live)
        after_live = live.split('minimalMenuRow("搜索"', 1)[1]
        self.assertNotIn("我的关注", after_live)
        self.assertNotIn("发现更多", after_live)
        self.assertIn("publishQueuedLiveModule()", menu)
        self.assertNotIn("NotificationCenter", menu)
        room = (ROOT / "DouDuo/DouyinLiveRoom.swift").read_text()
        preview = room.split("if !model.entered", 1)[1].split("if placement.role", 1)[0]
        self.assertIn("previewChrome(in: geo, pane: shown.interaction)", preview)
        self.assertNotIn("DYRailReservedNudge", preview)
        chrome = block(room, "private func previewChrome")
        self.assertIn("containedInsets", chrome)
        self.assertIn("avatarStripInsets", chrome)
        self.assertIn("case .followedLive:", room)
        self.assertNotIn("case .followed:", room)
        followed = room.split("case .followedLive:", 1)[1].split("case .discover:", 1)[0]
        self.assertIn("followStripExpanded = true", followed)
        self.assertNotIn("showFollowLive = true", followed)
        self.assertIn("showDiscover = false", followed)
        discover = room.split("case .discover:", 1)[1].split(".onChange(of: classicPreviewChrome)", 1)[0]
        self.assertIn("followStripExpanded = false", discover)
        self.assertIn("showDiscover = true", discover)
        self.assertIn("live.follow.strip.close", room)
        self.assertIn("DYFollowLiveSheet(bridge: bridge)", room)
        self.assertIn("DYRailReservedNudge()", room.split("private struct DYLiveRoomPage", 1)[1])
        self.assertIn("if classicPreviewChrome", preview)
        self.assertIn("discoverBar", preview)
        self.assertIn("followStrip", preview)
        self.assertLess(preview.index("railFollowDismiss"), preview.index("followStrip(scrollTail:"))
        strip = preview.split("followStrip(scrollTail:", 1)[1]
        self.assertLess(strip.index(".padding(.top, 10)"), strip.index("if showDiscover"))
        dismiss = block(room, "private var railFollowDismiss")
        self.assertIn("DYLivePreviewChrome.minTapHeight", dismiss)
        self.assertNotIn("ddGlassCapsule", dismiss)
        self.assertNotIn("discoverBar", preview.split("} else if followStripExpanded", 1)[1].split("if followStripExpanded", 1)[0])
        self.assertIn("classicPreviewChrome: !chromeMode.usesRail", FEED)
        panel = block(room, "private var discoverPanel")
        self.assertIn("live.discover.close", panel)
        self.assertIn("!classicPreviewChrome", panel)
        self.assertNotIn("发现更多", panel)
        pick = block(room, "private func pickCategory")
        self.assertIn("if !classicPreviewChrome", pick)
        self.assertIn("showDiscover = false", pick)
        self.assertIn("func dismissPreviewOverlays()", room)

    def test_top_bar_icons_and_hit_targets(self):
        top = block(UPSTREAM_ROOT, "private func topBarRow")
        self.assertIn("ForEach(DYTab.allCases", top)
        tabs = block(FEED, "enum DYTab:")
        for title in ("关注", "推荐", "直播"):
            self.assertIn('"' + title + '"', tabs)
        self.assertNotIn('Text("信息")', top)
        self.assertNotIn("myUser?.name", top)
        self.assertNotIn("showName", top)
        self.assertIn('Image(systemName: "bubble.left.and.bubble.right")', top)
        self.assertIn("noticeUnread > 0", top)
        self.assertIn("theme.status.danger", top)
        self.assertEqual(top.count(".frame(minWidth: 44, minHeight: 44)"), 2)

    def test_current_item_menu(self):
        menu = block(UPSTREAM_PAGE, "private func moreMenu")
        quick = block(menu, "ControlGroup")
        self.assertIn("DYForwardMenu(item: item, bridge: bridge, foreground: fg)", quick)
        self.assertIn('"下载"', quick)
        self.assertNotIn("ShareLink", menu)
        self.assertNotIn("danmaku", quick.lower())
        # 2026-11-14 老板定：不感兴趣放在转发和下载中间，跟它们同色（不是红色 destructive）
        self.assertLess(quick.index("DYForwardMenu"), quick.index('"不感兴趣"'))
        self.assertLess(quick.index('"不感兴趣"'), quick.index('"下载"'))
        self.assertNotIn("role: .destructive", quick)
        self.assertEqual(menu.count('"不感兴趣"'), 1)
        # 表层：倍速 / 静音 / 听书 / 自动连播 + 发弹幕；刷新推荐、弹幕设置、界面都只在设置页
        for token in ('"douyin.quick.speed"', "$muted", "$bgPlay", "$autoNext", '"douyin.quick.autonext"',
                      '"发弹幕"', "dm.showInput = true", "danmakuFocused = true", "moreExtras"):
            self.assertIn(token, menu)
        for gone in ("DYDanmakuOptions", "$chromeModeRaw", '"刷新推荐"', "界面模式"):
            self.assertNotIn(gone, menu)
        self.assertLess(menu.index('"发弹幕"'), menu.index("moreExtras"))

    def test_danmaku_settings_only_in_settings_screen(self):
        self.assertNotIn("struct DYDanmakuOptions", EXTRAS)
        screen = (ROOT / "DouDuo/DYSettingsScreen.swift").read_text()
        for token in ('Toggle("显示弹幕"', 'Picker("弹幕密度"', 'Toggle("10 秒内重复去重"'):
            self.assertIn(token, screen)

    def test_settings_paths_and_duration_preferences(self):
        # 2026-11-14 老板定：「更多」最后一节只有「设置」，点进完整设置页；刷新推荐 / 弹幕 / 界面都在设置页。
        upstream = block(UPSTREAM_ROOT, "private func moreExtrasMenu")
        classic = block(FEED, "    private var moreExtrasMenu: some View")
        for menu in (upstream, classic):
            self.assertIn("DYSettingsButton()", menu)
            for gone in ("DYHashtagFilterButton", "Label(\"设置\"", "$cacheCount", "播放设置", "内容偏好",
                         '"刷新推荐"', "DYChromeModePicker", "DYDanmakuOptions"):
                self.assertNotIn(gone, menu)
            self.assertNotIn("@State", menu)
        # 经典顶栏「更多」表层：静音 / 听书 / 自动连播
        self.assertIn("$muted", classic)
        self.assertIn("$bgPlay", classic)
        self.assertIn("$autoNext", classic)
        self.assertLess(classic.index("$bgPlay"), classic.index("DYSettingsButton()"))
        self.assertNotIn("struct DYChromeModePicker", FEED)
        screen = (ROOT / "DouDuo/DYSettingsScreen.swift").read_text()
        for section in ('Label("刷新推荐"', 'Section("界面")', 'Text("播放")', 'Text("内容偏好")', 'Text("弹幕")',
                        'Text("缓存")', 'Section("账号")', 'Section("关于")'):
            self.assertIn(section, screen)
        # 2026-11-14 老板定：表层菜单已有的（静音 / 铺满 / 听书 / 自动连播）设置页不重复；短视频占比删除
        for gone in ('"douyin_autoplay_v1"', '"douyin_muted_v1"', '"douyin_autofit_v1"', '"douyin_bg_play_v1"',
                     "short_ratio", "短视频占比", "ratioChoices", 'Toggle("静音"', 'Toggle("自动连播"', 'Toggle("铺满宽度',
                     'Toggle("听书模式', "$autoNext", "$muted", "$autoFit", "$backgroundPlay"):
            self.assertNotIn(gone, screen)
        for token in ("DYVideoAmbient.key", '"douyin_wide_landscape_v1"', 'Toggle("横屏时只放横屏内容"',
                      "DYHashtagFilterScreen(currentTags: [], embedded: true)",
                      '"douyin_danmaku_v1"', "DYDanmakuPolicy.densityKey", "DYDanmakuPolicy.deduplicateKey",
                      "DYVideoCache.countKey", "DYStorageScreen()", "DYOfflineDownloadScreen(candidateSource:", "DDUpdateChecker.repoURL",
                      "DDAppVersion.display", "DDChromeMode.key"):
            self.assertIn(token, screen)
        self.assertEqual(FEED.count(".environment(\\.dyOpenSettings, { showSettings = true })"), 2)
        self.assertEqual(FEED.count("onRefresh: { Task { await refreshRecommendations() } }"), 2)
        # 经典长按面板只留当前视频相关：铺满 / 静音 / 听书 / 自动连播 / 不感兴趣 / 倍速 / 发弹幕
        panel = (ROOT / "DouDuo/DYVideoOptionsPanel.swift").read_text()
        for token in ('"douyin.options.fit"', '"douyin.options.muted"', '"douyin.options.bgplay"', '"douyin.options.autonext"',
                      '"douyin.dislike"', '"douyin.options.rate.', '"发弹幕"'):
            self.assertIn(token, panel)
        for gone in ("ambientLevel", "landscapeOnly", "portraitRatio", "landscapeRatio",
                     "danmakuEnabled", "弹幕密度", "内容偏好"):
            self.assertNotIn(gone, panel)
        load = block(FEED, "func loadMore(_ bridge:")
        self.assertIn("added += fill(want - added)", load)
        # 2026-11-15 老板定：恢复竖着看约 70% 竖屏穿插（原序播放几乎全是横屏）；凑不齐才放宽，横屏限定不放宽
        self.assertIn("if added == 0, !landscapeOnlyActive { added += fill(want, relaxed: true) }", load)
        self.assertIn("static let portraitTarget = 0.7", FEED)

    def test_feed_uses_recommend_endpoint_only(self):
        # 2026-11-14 老板定：只保留网页首页「推荐」(tab/feed)，精选(module/feed)删掉，也不给切换
        fetch = block(FEED, "func fetchFeed()")
        self.assertIn("Self.tabFeedJS", fetch)
        self.assertNotIn("feedJS,", fetch.replace("tabFeedJS", ""))
        self.assertIn("/aweme/v1/web/tab/feed/", FEED)
        self.assertNotIn("private static let feedJS", FEED)
        self.assertNotIn("DYFeedSource", FEED)

    def test_execute_extracted_swift_model(self):
        # Compile production properties + policy/fill/pick/remix/trim, excluding all network code.
        model = FEED[FEED.index("final class DYFeedModel:"):FEED.index("    func loadMore(_ bridge:")]
        model += "}\n"
        clamp = block(FEED, "private extension Double")
        adapters = r'''
import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
}
let suiteName = "DouDuo.MenuPolicyRegression." + UUID().uuidString
let preferences = UserDefaults(suiteName: suiteName)!
@propertyWrapper struct AppStorage<Value> {
    let key: String
    let fallback: Value
    init(wrappedValue: Value, _ key: String) { self.key = key; fallback = wrappedValue }
    var wrappedValue: Value {
        get { preferences.object(forKey: key) as? Value ?? fallback }
        nonmutating set { preferences.set(newValue, forKey: key) }
    }
}
// Explicit in-memory policy fixtures, not captured or synthesized platform responses.
struct DYAweme {
    let id: String
    var desc: String = ""
    var hashtagNames: [String]? = nil
    var images: [String] = []
    var isTallFrame: Bool = false
    var duration: Double = 60
}
'''
        checks = r'''
defer { preferences.removePersistentDomain(forName: suiteName) }
// 1) 竖屏 / 横屏限定关闭：约 70% 竖屏均匀穿插，首条竖屏，同方向内保持推荐原顺序
for (wide, only) in [(false, false), (false, true), (true, false)] {
    preferences.removePersistentDomain(forName: suiteName)
    preferences.set(only, forKey: "douyin_wide_landscape_v1")
    let feed = DYFeedModel()
    feed.screenWide = wide
    // 接口式素材：竖屏只占 1/5
    feed.pool = (0..<100).map { DYAweme(id: "r\($0)", isTallFrame: $0 % 5 == 0) }
    let tallOrder = feed.pool.filter(DYFeedModel.isPortrait).map(\.id)
    let wideOrder = feed.pool.filter { !DYFeedModel.isPortrait($0) }.map(\.id)
    precondition(!feed.landscapeOnlyActive && feed.targetRatio == 0.7)
    let n = feed.fill(20)
    precondition(n == 20, "filled \(n) wide=\(wide) only=\(only)")
    precondition(DYFeedModel.isPortrait(feed.items[0]), "first should be portrait")
    let tall = feed.items.filter(DYFeedModel.isPortrait)
    precondition(tall.count == 14, "portrait \(tall.count)/20")
    precondition(tall.map(\.id) == Array(tallOrder.prefix(14)), "portrait order changed")
    precondition(feed.items.filter { !DYFeedModel.isPortrait($0) }.map(\.id) == Array(wideOrder.prefix(6)), "landscape order changed")
    // 竖屏用完：严格比例停住等下一页，relaxed 才按原顺序补
    let more = feed.fill(20)
    precondition(more < 20 && !feed.pool.contains(where: DYFeedModel.isPortrait), "strict fill should stop when portraits run out: \(more)")
    let before = feed.items.count
    precondition(feed.fill(5, relaxed: true) == 5 && feed.items.count == before + 5)
}
// 2) 横着看 + 只放横屏：只取横屏，保持横屏之间的原顺序，竖屏留在候选池
preferences.removePersistentDomain(forName: suiteName)
let wide = DYFeedModel()
wide.screenWide = true
wide.landscapeWhenWide = true
wide.pool = (0..<20).map { DYAweme(id: "w\($0)", isTallFrame: $0 % 2 == 0) }
precondition(wide.landscapeOnlyActive)
precondition(wide.fill(20) == 10)
precondition(wide.items.map(\.id) == (0..<20).filter { $0 % 2 == 1 }.map { "w\($0)" })
precondition(wide.pool.allSatisfy(DYFeedModel.isPortrait) && wide.pool.count == 10)
// 3) 关掉横屏限定后，池里留着的竖屏按原顺序接着放
wide.landscapeWhenWide = false
precondition(!wide.landscapeOnlyActive && wide.fill(3, relaxed: true) == 3 && wide.items.suffix(3).map(\.id) == ["w0", "w2", "w4"])
// 4) remix：当前条不动，后面的按当前规则重排
let remix = DYFeedModel()
remix.items = [DYAweme(id: "current", isTallFrame: true), DYAweme(id: "upcoming-tall", isTallFrame: true), DYAweme(id: "upcoming-wide")]
remix.screenWide = true
remix.landscapeWhenWide = true
remix.remix(after: 0)
precondition(remix.items.map(\.id) == ["current", "upcoming-wide"])
precondition(remix.pool.map(\.id) == ["upcoming-tall"])
remix.landscapeWhenWide = false
remix.remix(after: 0)
precondition(remix.items.map(\.id) == ["current", "upcoming-tall", "upcoming-wide"], "\(remix.items.map(\.id))")
precondition(DYFeedModel.isPortrait(DYAweme(id: "gallery", images: ["fixture"])))
// 5) 竖着看 + 只放竖屏：只取竖屏（relaxed 也不放横屏），横屏留在候选池；横着看时横屏限定优先
preferences.removePersistentDomain(forName: suiteName)
let tallOnly = DYFeedModel()
tallOnly.portraitOnly = true
tallOnly.pool = (0..<10).map { DYAweme(id: "p\($0)", isTallFrame: $0 % 2 == 0) }
precondition(tallOnly.portraitOnlyActive && tallOnly.targetRatio == 1)
precondition(tallOnly.fill(10) == 5 && tallOnly.items.allSatisfy(DYFeedModel.isPortrait))
precondition(tallOnly.fill(5, relaxed: true) == 0 && tallOnly.pool.count == 5)
tallOnly.screenWide = true
precondition(!tallOnly.portraitOnlyActive && tallOnly.landscapeOnlyActive && tallOnly.targetRatio == 0)
// 6) 只看短视频：超过上限或拿不到时长的视频过滤掉，图集放行
preferences.removePersistentDomain(forName: suiteName)
let short = DYFeedModel(defaults: preferences)
let clips = [DYAweme(id: "s30", duration: 30), DYAweme(id: "s61", duration: 61), DYAweme(id: "s0", duration: 0), DYAweme(id: "g", images: ["x"], duration: 0)]
precondition(short.allowedRecommendations(clips).count == 4)
preferences.set(60, forKey: DYContentPrefs.shortMaxKey)
precondition(short.allowedRecommendations(clips).map(\.id) == ["s30", "g"])
print("PASS 70% portrait interleave; per-orientation order kept; relaxed fallback; landscape-only filter; toggle back; remix; gallery classification; portrait-only; short-only")
'''
        scratch = Path(tempfile.gettempdir())
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="menu-policy-", dir=scratch) as folder:
            source = Path(folder) / "Policy.swift"
            hashtags = (ROOT / "DouDuo/DYHashtag.swift").read_text()
            filters = (ROOT / "DouDuo/DYHashtagFilter.swift").read_text()
            fit = (ROOT / "DouDuo/DYVideoFit.swift").read_text()
            source.write_text(fit + adapters + hashtags + filters + model + clamp + checks)
            result = subprocess.run(["swift", str(source)], text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main(verbosity=2)
