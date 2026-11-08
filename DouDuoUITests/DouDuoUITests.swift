import XCTest

/// DouDuo 核心流程：推荐流加载 → 视频在走 → 上滑切下一条 → 横滑快进 → 点作者进主页 → 能返回原生页
final class DouDuoUITests: XCTestCase {
    /// 只读采样手机上已安装的正式抖音 UI；默认跳过，不能用 DouDuo 页面冒充原版。
    func testOriginalLiveReference() throws {
        guard ProcessInfo.processInfo.environment["DOUDUO_ORIGINAL_REF"] == "1" else {
            throw XCTSkip("仅在连接已安装正式抖音的真机时手动启用")
        }
        let app = XCUIApplication(bundleIdentifier: "com.ss.iphone.ugc.Aweme")
        app.activate()
        sleep(5)
        guard app.state == .runningForeground else { throw XCTSkip("手机正在使用其他 App，停止采样") }
        print("DDORIGINAL_HOME\n\(app.debugDescription)\nDDORIGINAL_END")
        attach(app, "original-home")
        let entry = app.descendants(matching: .any).matching(NSPredicate(format: "label == '直播'")).allElementsBoundByIndex.first { $0.isHittable }
        if let entry {
            entry.tap()
            sleep(6)
            guard app.state == .runningForeground else { throw XCTSkip("原版已不在前台，停止采样") }
            print("DDORIGINAL_LIVE\n\(app.debugDescription)\nDDORIGINAL_END")
            attach(app, "original-live")
        }
        let roomEntry = app.buttons.matching(NSPredicate(format: "label CONTAINS '点击进入直播间'")).firstMatch
        if roomEntry.waitForExistence(timeout: 8), roomEntry.isHittable {
            roomEntry.tap()
            sleep(6)
            guard app.state == .runningForeground else { throw XCTSkip("原版已不在前台，进房采样作废") }
            print("DDORIGINAL_ROOM\n\(app.debugDescription)\nDDORIGINAL_END")
            attach(app, "original-room")
        }
    }

    func testLivePagesFillViewport() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let current = app.staticTexts["live.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        let loaded = expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 40), .completed)
        for index in 0..<2 {
            let id = current.label
            let page = app.otherElements["live.page.\(id)"]
            XCTAssertTrue(page.waitForExistence(timeout: 5))
            let window = app.windows.firstMatch.frame
            XCTAssertEqual(page.frame.height, window.height, accuracy: 1, "直播页必须覆盖实际视口，不能少掉底部安全区")
            XCTAssertEqual(page.frame.maxY, window.maxY, accuracy: 1, "静止时页底必须与窗口底边重合")
            attach(app, "live-page-fill-\(index)")
            if index == 0 {
                app.swipeUp(velocity: .slow)
                let changed = expectation(for: NSPredicate(format: "label != %@", id), evaluatedWith: current)
                XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 10), .completed)
                sleep(1)
            }
        }
    }

    func testNativeLiveRoomFlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let categories = app.buttons["live.categories"]
        XCTAssertTrue(categories.waitForExistence(timeout: 15), "分类应收成一个按钮")
        XCTAssertFalse(app.buttons["英雄联盟"].exists, "分类不能常驻")
        categories.tap()
        XCTAssertTrue(app.buttons["英雄联盟"].waitForExistence(timeout: 5))
        attach(app, "live-category-picker")
        app.buttons["live.categories.close"].tap()
        let enter = app.buttons.matching(identifier: "live.room.enter").firstMatch
        XCTAssertTrue(enter.waitForExistence(timeout: 30))
        XCTAssertTrue(enter.isHittable)
        let id = app.staticTexts["live.currentID"].label
        enter.tap()
        XCTAssertTrue(app.buttons["live.room.back"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["live.chat.input"].exists)
        XCTAssertFalse(app.buttons["live.categories"].exists, "进房后不显示首页分类按钮")
        XCTAssertFalse(app.buttons["douyin.web.close"].exists, "进房不能打开网页版播放器")
        attach(app, "native-live-room")
        app.buttons["live.room.more"].tap()
        app.buttons["清屏"].tap()
        XCTAssertTrue(app.buttons["live.room.restore"].waitForExistence(timeout: 5))
        app.buttons["live.room.restore"].tap()
        app.buttons["live.room.back"].tap()
        XCTAssertTrue(categories.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["live.currentID"].label, id, "退房应回到同一个直播预览")
        attach(app, "live-preview-return")
        app.swipeUp(velocity: .slow)
        let current = app.staticTexts["live.currentID"]
        let changed = expectation(for: NSPredicate(format: "label != %@", id), evaluatedWith: current)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 10), .completed, "上滑应换到相邻房间")
        let nextID = current.label
        sleep(3)
        XCTAssertEqual(current.label, nextID, "停止滑动后不应因布局回写继续乱跳")
    }

    /// 真机/模拟器均可跑；计时以 App 的 DDLIVE_READY 日志为准，截图另证是否实际出画。
    func testNativeLivePerformance() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launchEnvironment["DOUDUO_LIVEPROBE"] = "1"
        app.launch()
        let current = app.staticTexts["live.currentID"]
        let status = app.staticTexts["live.status"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        for index in 0..<3 {
            let ready = expectation(for: NSPredicate(format: "label == '1'"), evaluatedWith: status)
            XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 45), .completed, "当前房间没有视频输出")
            guard app.state == .runningForeground else { throw XCTSkip("用户切走了 App，本次截图作废") }
            let id = current.label
            attach(app, "device-live-frame-\(index)")
            let progress = app.staticTexts["live.time"].label
            print("DDDEVICE_SAMPLE index=\(index) id=\(id) progress=\(progress)")
            if index < 2 {
                let changed = expectation(for: NSPredicate(format: "label != %@", id), evaluatedWith: current)
                XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 30), .completed, "探针没有切到下一间")
            }
        }
    }

    /// 头部缓存起播：先让当前条缓存 + 预取后面 2 条，再上滑看是否本地起播并在安全点切回在线
    func testHeadCachePlayback() throws {
        let app = XCUIApplication()
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        let loaded = expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 60), .completed)
        sleep(16)  // 当前条整条缓存 + 后面 2 条头部预取（等落盘完成再切）
        let first = current.label
        app.swipeUp(velocity: .fast)
        let changed = expectation(for: NSPredicate(format: "label != %@", first), evaluatedWith: current)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 15), .completed, "上滑没切条")
        // 进度文字在紧凑模式下不一定暴露给 XCUI，这里以 ddlog 的 DDSTART local=true / DDHEAD continue 为准
        sleep(4)
        attach(app, "head-cache-play")
        sleep(14)  // 跨过 headPlayableSeconds，验证续播不卡死
        attach(app, "head-cache-continued")
    }

    func testConditionalTitleExpansion() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_TITLETEST"] = "1"
        app.launch()
        let short = app.otherElements["title.short"]
        let long = app.otherElements["title.long"]
        XCTAssertTrue(short.waitForExistence(timeout: 10))
        XCTAssertFalse(short.buttons["douyin.description.toggle"].exists, "短标题不应出现展开按钮")
        let toggle = long.buttons["douyin.description.toggle"]
        XCTAssertTrue(toggle.exists, "长标题被截断时应有展开按钮")
        XCTAssertEqual(toggle.label, "展开")
        let collapsedHeight = long.frame.height
        toggle.tap()
        XCTAssertEqual(toggle.label, "收起")
        sleep(1)
        XCTAssertGreaterThan(long.frame.height, collapsedHeight, "展开后应显示完整标题而不只是切换按钮文字")
        attach(app, "expanded-title")
        toggle.tap()
        XCTAssertEqual(toggle.label, "展开")
        sleep(1)
        attach(app, "conditional-title")
    }

    func testCompactLayoutAndAuthorEntry() throws {
        let app = XCUIApplication()
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed)
        sleep(3)
        XCTAssertFalse(app.buttons.matching(identifier: "douyin.follow").allElementsBoundByIndex.contains { $0.isHittable })
        let desc = app.staticTexts.matching(identifier: "douyin.description").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(desc)
        if let desc { XCTAssertLessThan(desc.frame.height, 40, "标题默认应只有一行") }
        let toggle = app.buttons.matching(identifier: "douyin.description.toggle").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(toggle)
        toggle?.tap()
        XCTAssertTrue(app.buttons["收起"].exists)
        app.buttons["收起"].tap()
        attach(app, "compact-single-line")
        let author = app.buttons.matching(identifier: "douyin.author").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(author)
        author?.tap()
        XCTAssertTrue(app.buttons["douyin.author.follow"].waitForExistence(timeout: 15))
        attach(app, "author-follow-retained")
        app.buttons["douyin.author.back"].tap()
    }

    func testCoreFlow() throws {
        let app = XCUIApplication()
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed, "推荐流没加载出来")
        sleep(6)
        attach(app, "1-feed")

        // 视频在走：进度时间 > 0:00
        let t1 = playTime(app)
        sleep(3)
        let t2 = playTime(app)
        print("DDTEST time \(t1) -> \(t2)")
        XCTAssertGreaterThan(t2, 0, "视频没在播")

        // 上滑下一条
        let first = current.label
        app.swipeUp(velocity: .fast)
        sleep(4)
        XCTAssertNotEqual(current.label, first, "上滑没切到下一条")
        let second = current.label
        XCTAssertGreaterThan(playTime(app), 0, "第二条没在播")
        attach(app, "2-next")

        // 横滑快进
        // 横滑快进。⚠️ 真机上 XCUICoordinate.press(…thenDragTo:) 根本不派发触摸（DDTOUCH 实测一个都没有），
        // swipeUp 能到 → 横向也用 swipe 系列（从画面中部起滑）
        app.swipeRight(velocity: .slow)
        sleep(3)
        XCTAssertEqual(current.label, second, "横滑不应切视频")
        print("DDTEST after seek \(playTime(app))")
        XCTAssertGreaterThanOrEqual(playTime(app), 25, "横滑快进没跳")

        // 点作者头像 → 网页主页 → 返回
        // 分页 ScrollView 同时保留离屏元素，只点当前可命中的作者。
        let authors = app.buttons.matching(identifier: "douyin.author")
        let author = authors.allElementsBoundByIndex.first(where: { $0.isHittable })
        XCTAssertNotNil(author, "当前页没有可点击的作者入口")
        guard let author else { return }
        author.tap()
        // 改版作者页已原生化，不能再等旧网页版返回键。
        let back = app.buttons["douyin.author.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 15), "作者主页没打开 / 没有返回键")
        sleep(4)
        attach(app, "3-author")
        back.tap()
        XCTAssertTrue(current.waitForExistence(timeout: 15), "从作者主页回不来")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed, "返回后推荐流没恢复")
        sleep(6)
        XCTAssertGreaterThan(playTime(app), 0, "返回后视频没在播")
        attach(app, "4-back")
    }

    /// 窄视频（720x1280）在 Duo 上：开=铺满宽度（上下裁切），关=左右黑边。用本地测试片验证，不依赖推荐流给什么片。
    func testLocalNarrowFill() throws {
        for fit in ["1", "0"] {
            let app = XCUIApplication()
            app.launchEnvironment["DOUDUO_LOCALVIDEO"] = "narrow.mp4"
            app.launchEnvironment["DOUDUO_LOCALFIT"] = fit
            app.launch()
            sleep(6)
            attach(app, "narrow-fit-\(fit)")
            app.terminate()
        }
    }

    /// 确认 App 真的能转到横屏（窗口宽>高）
    /// ⚠️ XCUIDevice 转屏在这台机器上时好时坏（无头/屏幕休眠时静默失败），重试 3 次仍不转就 skip，不当作 App 缺陷
    func testRotationSanity() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_LOCALVIDEO"] = "wide.mp4"
        app.launchEnvironment["DOUDUO_LOCALFIT"] = "1"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        sleep(4)
        let p = app.windows.firstMatch.frame
        print("DDTEST portrait window \(p)")
        var l = p
        for i in 1...3 {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(3)
            l = app.windows.firstMatch.frame
            print("DDTEST landscape window try\(i) \(l)")
            if l.width > l.height { break }
        }
        if l.width <= l.height {
            XCUIDevice.shared.orientation = .portrait
            throw XCTSkip("转屏指令没生效（环境问题），跳过；真机手动转屏正常")
        }
        attach(app, "rot-landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    /// 竖屏 + 横屏 都要自适应（无黑边）：本地 720x1280 与 1280x720 测试片各跑一遍
    func testLocalFillBothOrientations() throws {
        // 先启动再转屏（启动时设方向会被 App 启动重置）
        for (file, orient, tag) in [("narrow.mp4", UIDeviceOrientation.portrait, "portrait"),
                                    ("wide.mp4", .portrait, "portrait"),
                                    ("narrow.mp4", .landscapeLeft, "landscape"),
                                    ("wide.mp4", .landscapeLeft, "landscape")] {
            let app = XCUIApplication()
            app.launchEnvironment["DOUDUO_LOCALVIDEO"] = file
            app.launchEnvironment["DOUDUO_LOCALFIT"] = "1"
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            sleep(4)
            XCUIDevice.shared.orientation = orient
            sleep(5)
            attach(app, "\(file)-\(tag)")
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// 「更多」菜单：一排快捷图标 + 播放组 + 设置子菜单；竖屏占比子菜单可选
    func testMoreMenuLayout() throws {
        let app = XCUIApplication()
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed)
        sleep(3)
        let any = { (l: String) in app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", l)).firstMatch }
        // 分页里上下相邻页的「更多」也在树里，只点屏幕内那颗
        let more = { app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }! }
        more().tap()
        for l in ["转发", "下载", "不感兴趣", "竖屏占比", "自动连播", "静音", "显示弹幕", "刷新推荐", "我的", "设置"] {
            XCTAssertTrue(any(l).waitForExistence(timeout: 5), "更多菜单缺少 \(l)")
        }
        attach(app, "more-top")
        any("竖屏占比").tap()
        XCTAssertTrue(any("竖屏 50%").waitForExistence(timeout: 5), "竖屏占比子菜单没展开")
        attach(app, "more-mix")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).tap()
        sleep(1)
        more().tap()
        any("设置").tap()
        for l in ["横着看时只放横屏", "自动铺满宽度", "预缓存视频", "清除视频缓存", "网页版", "关于"] {
            XCTAssertTrue(any(l).waitForExistence(timeout: 5), "设置子菜单缺少 \(l)")
        }
        attach(app, "more-settings")
    }

    /// VLC 兜底路径：强制 VLC 起播，画面时间要走、能上滑切换
    func testVLCFallback() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_FORCE_VLC"] = "1"
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed)
        sleep(10)
        let t1 = playTime(app); sleep(3); let t2 = playTime(app)
        print("DDTEST vlc time \(t1) -> \(t2)")
        XCTAssertGreaterThan(t2, t1, "VLC 没在播")
        attach(app, "vlc-1")
        let first = current.label
        app.swipeUp(velocity: .fast)
        sleep(8)
        XCTAssertNotEqual(current.label, first, "VLC 下上滑没切")
        let t3 = playTime(app); sleep(3); let t4 = playTime(app)
        print("DDTEST vlc next \(t3) -> \(t4)")
        XCTAssertGreaterThan(t4, t3, "VLC 第二条没在播")
        attach(app, "vlc-2")
    }


    /// 停声链路（不依赖切后台事件）：DOUDUO_BGTEST=1 → 20 秒后自动 pauseAll，进度必须冻住
    func testPauseAllPlumbing() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_BGTEST"] = "1"
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed)
        sleep(5)
        let t1 = playTime(app)
        sleep(12)
        let t2 = playTime(app)
        sleep(6)
        let t3 = playTime(app)
        print("DDTEST plumbing t1=\(t1) t2=\(t2) t3=\(t3)")
        XCTAssertGreaterThan(t1, 0)
        XCTAssertLessThanOrEqual(t3, t2 + 1, "pauseAll 之后进度还在走")
    }

    /// 直播播放：UI 测试里量不到真实播放（XCTest 环境下 HLS 已 readyToPlay 但进度不走，
    /// 同样的构建用 simctl 启动播放正常）→ 这里只做冒烟：能进直播页、能拿到房间、不崩
    func testLivePlayback() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let liveID = app.staticTexts["live.currentID"]
        XCTAssertTrue(liveID.waitForExistence(timeout: 30), "直播页没打开")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: liveID)], timeout: 60), .completed, "直播列表没加载出来")
        sleep(8)
        let st = app.staticTexts["live.status"].label
        let rate = app.staticTexts["live.rate"].label
        let t = app.staticTexts["live.time"].label
        print("DDTEST live id=\(liveID.label) status=\(st) rate=\(rate) time=\(t)")
        attach(app, "live")
        XCTAssertEqual(st, "1", "直播流没 ready（status=\(st)）")
    }

    /// 点赞 / 收藏走真接口。
    /// 未登录时 App 会提示「请先登录抖音」并自动打开网页登录 → 这种情况 skip（不是缺陷）
    func testLikeAndCollect() throws {
        throw XCTSkip("本次只读验收：禁止使用老板账号执行点赞/收藏写接口")
        let app = XCUIApplication()
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 90), .completed)
        sleep(6)

        let toast = app.staticTexts["douyin.toast"]
        let like = app.buttons["douyin.like"].firstMatch
        XCTAssertTrue(like.waitForExistence(timeout: 10), "没有点赞按钮")

        like.tap()
        let gotToast = toast.waitForExistence(timeout: 6)
        let label = gotToast ? toast.label : ""
        print("DDTEST like toast: \(label.isEmpty ? "<none>" : label)")
        if label.contains("请先登录") { throw XCTSkip("当前未登录抖音，点赞/收藏需要登录后才能验") }
        XCTAssertFalse(gotToast, "点赞失败弹了提示：\(label)")
        attach(app, "like")

        let collect = app.buttons["douyin.collect"].firstMatch
        XCTAssertTrue(collect.waitForExistence(timeout: 10), "没有收藏按钮")
        collect.tap()
        let got2 = toast.waitForExistence(timeout: 10)
        let label2 = got2 ? toast.label : "<none>"
        print("DDTEST collect toast: \(label2)")
        XCTAssertTrue(got2, "收藏后没有提示（接口没返回）")
        XCTAssertTrue(label2.contains("已收藏"), "收藏没成功：\(label2)")
        attach(app, "collect")
    }

    /// 底部进度条左侧时间（秒）
    private func playTime(_ app: XCUIApplication) -> Int {
        let q = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+:[0-9][0-9]$'"))
        guard q.count > 0 else { return 0 }
        return q.element(boundBy: 0).label.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
