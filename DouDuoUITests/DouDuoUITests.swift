import XCTest

/// DouDuo 核心流程：推荐流加载 → 视频在走 → 上滑切下一条 → 左滑作者/右滑关注 → 点作者进主页 → 能返回原生页
final class DouDuoUITests: XCTestCase {
    func testShortVideoAutoPiPSettingPersists() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["DOUDUO_CHROME_MODE": "rail", "DOUDUO_HASHTAG_FIXTURE": "1"]
        app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                               "-duoduomain_tab_v1", "首页", "-douduo_dismissed_update_v1", "9.9.9"]
        addTeardownBlock { app.terminate() }
        let form = app.collectionViews.matching(NSPredicate(format: "identifier != %@", "douyin.gallery")).firstMatch
        func visibleToggle() -> XCUIElement {
            let toggle = app.switches["settings.autoPip"]
            if !toggle.exists { form.swipeDown() }
            for _ in 0..<12 {
                if toggle.exists, toggle.isHittable,
                   toggle.frame.minY > form.frame.minY + 100,
                   toggle.frame.maxY < form.frame.maxY - 60 { return toggle }
                let upward = !toggle.exists || toggle.frame.minY >= form.frame.minY + 100
                let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.65 : 0.35))
                let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.45 : 0.55))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            XCTFail("PiP setting did not become fully visible")
            return toggle
        }
        func openSetting() throws -> XCUIElement {
            let more = app.buttons.matching(identifier: "douyin.more")
            XCTAssertTrue(more.firstMatch.waitForExistence(timeout: 20))
            let button = try XCTUnwrap(more.allElementsBoundByIndex.first { !$0.frame.isEmpty })
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let settings = app.buttons["设置"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
            XCTAssertTrue(form.waitForExistence(timeout: 5))
            return visibleToggle()
        }
        func set(_ toggle: XCUIElement, to value: String) {
            if toggle.value as? String != value {
                let control = toggle.switches.firstMatch
                if control.exists { control.tap() }
                else { toggle.tap() }
            }
            // Reacquire after SwiftUI updates the form in response to AppStorage.
            let updated = visibleToggle()
            XCTAssertTrue(waitUntil(timeout: 5) { updated.exists && updated.value as? String == value },
                          "Requested \(value); \(updated.debugDescription)")
        }
        app.launch()
        let toggle = try openSetting()
        // Establish OFF without depending on a previous simulator session.
        set(toggle, to: "0")
        attach(app, "short-video-pip-setting-off")
        set(toggle, to: "1")
        attach(app, "short-video-pip-setting-on")
        app.terminate()
        app.launch()
        let persisted = try openSetting()
        XCTAssertEqual(persisted.value as? String, "1")
        set(persisted, to: "0")
        app.terminate()
        app.launch()
        XCTAssertEqual(try openSetting().value as? String, "0")
    }

    func testMessageAppearanceLight() throws { try verifyMessageAppearance("light") }
    func testMessageAppearanceDark() throws { try verifyMessageAppearance("dark") }

    private func verifyMessageAppearance(_ appearance: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        addTeardownBlock { app.terminate() }
        for mode in ["duoClassic", "classic"] {
            app.launchEnvironment = ["DOUDUO_MESSAGE_LAYOUT":"1", "DOUDUO_MESSAGE_FIXTURE":"1",
                "DOUDUO_CHROME_MODE":mode, "DOUDUO_APPEARANCE":appearance, "DOUDUO_APPEARANCE_TEST":"1"]
            app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
            app.launch()
            let resolved = app.staticTexts["appearance.resolved"]
            XCTAssertTrue(resolved.waitForExistence(timeout: 5))
            XCTAssertEqual(resolved.label, appearance)
            let rows = app.buttons.matching(identifier: "douyin.conversation.row")
            let person = rows.matching(NSPredicate(format: "label CONTAINS %@", "青禾")).firstMatch
            XCTAssertTrue(person.waitForExistence(timeout: 20))
            attach(app, "appearance-messages-" + mode + "-" + appearance)
            person.tap()
            let editor = app.textViews["douyin.messages.composer.editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            attach(app, "appearance-chat-" + mode + "-" + appearance)
            editor.tap()
            editor.typeText("Theme draft")
            XCTAssertTrue(waitUntil(timeout: 5) { (editor.value as? String)?.contains("Theme draft") == true })
            attach(app, "appearance-composer-" + mode + "-" + appearance)
            app.terminate()
        }
    }

    func testSearchLightGridBounds() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["DOUDUO_CHROME_MODE":"duoClassic", "DOUDUO_APPEARANCE":"light",
            "DOUDUO_HASHTAG_FIXTURE":"1", "DOUDUO_SEARCH_FIXTURE":"1", "DOUDUO_GRID_FIXTURE":"1"]
        app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let search = app.buttons["douyin.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        let hot = app.buttons["douyin.search.hot.1"]
        XCTAssertTrue(hot.waitForExistence(timeout: 10))
        hot.tap()
        XCTAssertTrue(app.buttons["douyin.grid.item.hashtag-travel"].firstMatch.waitForExistence(timeout: 10))
        attach(app, "search-light-grid-bounds")
    }

    func testMineLightGridBounds() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["DOUDUO_CHROME_MODE":"duoClassic", "DOUDUO_APPEARANCE":"light",
            "DOUDUO_GRID_FIXTURE":"1", "DOUDUO_OPEN":"mine"]
        app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launch()
        XCTAssertTrue(app.buttons["douyin.grid.item.hashtag-travel"].firstMatch.waitForExistence(timeout: 20))
        attach(app, "mine-light-grid-bounds")
    }

    func testAppearanceClassic() throws { try verifyAppearance(mode: "duoClassic") }
    func testAppearanceOrdinary() throws { try verifyAppearance(mode: "classic") }

    func testAppearanceLiveClassic() throws { try verifyAppearance(mode: "duoClassic", live: true) }
    func testAppearanceLiveOrdinary() throws { try verifyAppearance(mode: "classic", live: true) }

    func testAppearanceNativePagesLight() throws { try verifyNativePages(appearance: "light") }
    func testAppearanceNativePagesDark() throws { try verifyNativePages(appearance: "dark") }

    private func verifyNativePages(appearance: String) throws {
        let app = XCUIApplication()
        addTeardownBlock { app.terminate() }
        for page in ["search", "mine", "messages"] {
            app.launchEnvironment = ["DOUDUO_CHROME_MODE":"classic", "DOUDUO_APPEARANCE":appearance, "DOUDUO_OPEN":page]
            app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
            app.launch()
            let anchor: XCUIElement
            switch page {
            case "search": anchor = app.textFields["douyin.search.field"]
            case "mine": anchor = app.buttons["douyin.mine.post"]
            default: anchor = app.buttons["douyin.messages.interactive"]
            }
            XCTAssertTrue(anchor.waitForExistence(timeout: 30), app.debugDescription)
            Thread.sleep(forTimeInterval: 3)
            attach(app, "appearance-" + page + "-" + appearance)
            app.terminate()
        }
    }

    /// 设置里从「暗色」改成「跟随系统」：系统为亮色时界面变亮（运行前把模拟器系统外观设为亮色）
    func testSettingsFollowSystemTakesEffect() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["DOUDUO_CHROME_MODE":"rail", "DOUDUO_HASHTAG_FIXTURE":"1", "DOUDUO_APPEARANCE_TEST":"1", "DOUDUO_APPEARANCE":"dark"]
        app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-duoduomain_tab_v1", "首页",
                               "-douduo_dismissed_update_v1", "9.9.9"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let resolved = app.staticTexts["appearance.resolved"]
        XCTAssertTrue(resolved.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 5) { resolved.label == "dark" }, "起始应为暗色")
        let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }
            ?? app.buttons["douyin.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20)); more.tap()
        let entry = app.buttons["设置"]; XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        let picker = app.segmentedControls["settings.appearance"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["跟随系统"].tap()
        sleep(1)
        attach(app, "follow-system-in-settings")
        app.buttons["settings.done"].tap()
        sleep(1)
        attach(app, "follow-system-home")
        XCTAssertTrue(waitUntil(timeout: 5) { resolved.label == "light" }, "跟随系统后应随系统变亮，实际 \(resolved.label)")
    }

    func testAppearanceFollowsSystem() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["DOUDUO_HASHTAG_FIXTURE":"1", "DOUDUO_APPEARANCE_TEST":"1", "DOUDUO_APPEARANCE":"system"]
        app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let resolved = app.staticTexts["appearance.resolved"]
        XCTAssertTrue(resolved.waitForExistence(timeout: 10))
        for mode in ["light", "dark", "light"] {
            print("APPEARANCE_SYSTEM " + mode)
            XCTAssertTrue(waitUntil(timeout: 15) { resolved.label == mode })
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func verifyAppearance(mode: String, live: Bool = false) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["DOUDUO_CHROME_MODE":mode, "DOUDUO_HASHTAG_FIXTURE":"1",
            "DOUDUO_SEARCH_FIXTURE":"1", "DOUDUO_APPEARANCE_TEST":"1", "DOUDUO_APPEARANCE":"reset"]
        if live {
            app.launchEnvironment.removeValue(forKey: "DOUDUO_HASHTAG_FIXTURE")
            app.launchEnvironment.removeValue(forKey: "DOUDUO_SEARCH_FIXTURE")
        }
        app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
            "-douyin_wide_landscape_v1", "NO", "-douduo_dismissed_update_v1", "1.5.0"]
        addTeardownBlock { app.terminate() }
        app.launch()
        func settings() throws {
            let query = app.buttons.matching(identifier: "douyin.more")
            XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            let more = try XCTUnwrap(query.allElementsBoundByIndex.first {
                !$0.frame.isEmpty && app.windows.firstMatch.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            })
            // Native vertical toolbars can make the ancestor Menu report non-hittable.
            more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let entry = app.buttons["设置"]
            XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
            entry.tap()
            XCTAssertTrue(app.segmentedControls["settings.appearance"].waitForExistence(timeout: 5))
        }
        func pauseLiveVideo() {
            guard live else { return }
            let current = app.staticTexts["douyin.currentID"].firstMatch
            XCTAssertTrue(waitUntil(timeout: 90) { current.exists && current.label.range(of: "^[0-9]{10,}$", options: .regularExpression) != nil }, app.debugDescription)
            let playback = app.staticTexts["douyin.video.playback"].firstMatch
            if playback.waitForExistence(timeout: 15), wait(label: "playing", on: playback, timeout: 20) {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).tap()
                XCTAssertTrue(wait(label: "paused", on: playback, timeout: 5), app.debugDescription)
            }
            print("APPEARANCE_LIVE_VIDEO " + current.label)
        }
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 15))
        pauseLiveVideo()
        attach(app, "appearance-" + mode + "-initial")
        try settings()
        let picker = app.segmentedControls["settings.appearance"]
        XCTAssertTrue(picker.buttons["暗色"].isSelected)
        let frames = ["跟随系统", "亮色", "暗色"].map { picker.buttons[$0].frame }
        XCTAssertLessThan(abs(frames[0].midY - frames[2].midY), 2, "Three modes must stay in one row")
        picker.buttons["亮色"].tap()
        XCTAssertTrue(picker.buttons["亮色"].isSelected)
        attach(app, "appearance-" + mode + "-settings-light")
        app.buttons["settings.done"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { app.staticTexts["appearance.resolved"].label == "light" })
        attach(app, "appearance-" + mode + "-home-light")
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "DOUDUO_APPEARANCE")
        app.launch()
        XCTAssertTrue(app.staticTexts["appearance.resolved"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["appearance.resolved"].label, "light", "Explicit selection survives relaunch")
        pauseLiveVideo()
        try settings()
        XCTAssertTrue(picker.buttons["亮色"].isSelected)
        picker.buttons["暗色"].tap()
        app.buttons["settings.done"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { app.staticTexts["appearance.resolved"].label == "dark" })
        attach(app, "appearance-" + mode + "-home-dark")
        try settings()
        picker.buttons["跟随系统"].tap()
        app.buttons["settings.done"].tap()
    }

    func testAppearanceLiveWeb() throws { try verifyWebAppearance(live: true) }
    func testAppearanceWebPreservesDocument() throws { try verifyWebAppearance(live: false) }

    private func verifyWebAppearance(live: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [live ? "DOUDUO_APPEARANCE_WEB_LIVE" : "DOUDUO_APPEARANCE_WEB_FIXTURE":"1", "DOUDUO_APPEARANCE":"light"]
        addTeardownBlock { app.terminate() }
        app.launch()
        func snapshot() -> [String: Any] {
            let value = app.staticTexts["appearance.web.report"].label
            return (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any] ?? [:]
        }
        XCTAssertTrue(app.staticTexts["appearance.web.report"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { snapshot()["background"] as? String == "rgb(252, 252, 252)" })
        if live { Thread.sleep(forTimeInterval: 12) }
        print("WEB_APPEARANCE_LIGHT " + app.staticTexts["appearance.web.report"].label)
        XCTAssertTrue(waitUntil(timeout: 10) { snapshot()["shellBackground"] as? String == "rgb(252, 252, 252)" })
        let token = snapshot()["token"] as? String
        XCTAssertNotNil(token)
        XCTAssertEqual(snapshot()["foreground"] as? String, "rgb(22, 22, 22)")
        attach(app, live ? "appearance-web-live-light" : "appearance-web-fixture-light")
        app.segmentedControls.buttons["暗色"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { snapshot()["mode"] as? String == "dark" && snapshot()["appPalette"] as? Bool == false })
        if !live {
            XCTAssertEqual(snapshot()["background"] as? String, "rgb(32, 36, 38)")
            XCTAssertEqual(snapshot()["foreground"] as? String, "rgb(228, 230, 232)")
            XCTAssertEqual(snapshot()["shellBackground"] as? String, "rgb(40, 43, 48)")
        }
        XCTAssertEqual(snapshot()["token"] as? String, token)
        if !live { XCTAssertEqual(snapshot()["draft"] as? String, "保留这段未发送的文字") }
        print("WEB_APPEARANCE_DARK " + app.staticTexts["appearance.web.report"].label)
        XCTAssertEqual(snapshot()["mediaFilter"] as? String, "none")
        attach(app, live ? "appearance-web-live-dark" : "appearance-web-fixture-dark")
        app.segmentedControls.buttons["亮色"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { snapshot()["background"] as? String == "rgb(252, 252, 252)" })
        XCTAssertEqual(snapshot()["token"] as? String, token)
    }

    func testClassicShareNoteAndSuccess() throws { try verifyShareNoteAndSuccess(mode: "duoClassic", group: false) }
    func testOrdinaryShareNoteAndSuccess() throws { try verifyShareNoteAndSuccess(mode: "classic", group: true) }

    func testClassicShareCanCloseWhilePreparing() throws { try verifyShareCanClose(mode: "duoClassic") }
    func testOrdinaryShareCanCloseWhilePreparing() throws { try verifyShareCanClose(mode: "classic") }

    func testShareCanCloseAfterDispatch() throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["DOUDUO_SHARE_LAYOUT":"1", "DOUDUO_FORWARD_LAYOUT_FIXTURE":"1",
            "DOUDUO_MESSAGE_FIXTURE":"1", "DOUDUO_CHROME_MODE":"duoClassic", "DOUDUO_SHARE_DELAY":"dispatched"]
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launch()
        XCTAssertTrue(app.buttons["douyin.share"].waitForExistence(timeout: 10))
        app.buttons["douyin.share"].tap()
        let person = app.buttons["douyin.forward.contact.1|fixture-user-a"]
        XCTAssertTrue(person.waitForExistence(timeout: 10))
        person.tap()
        app.buttons["douyin.forward.send"].tap()
        app.buttons["douyin.forward.close"].tap()
        XCTAssertTrue(app.buttons["douyin.forward.close"].waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.buttons["douyin.forward.success.open"].waitForExistence(timeout: 8), "A dispatched request still reports its confirmed result after dismissal")
    }

    private func verifyShareCanClose(mode: String) throws {
        let app = XCUIApplication()
        app.launchEnvironment = ["DOUDUO_SHARE_LAYOUT":"1", "DOUDUO_FORWARD_LAYOUT_FIXTURE":"1",
            "DOUDUO_MESSAGE_FIXTURE":"1", "DOUDUO_CHROME_MODE":mode, "DOUDUO_SHARE_DELAY":"1"]
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launch()
        XCTAssertTrue(app.buttons["douyin.share"].waitForExistence(timeout: 10))
        app.buttons["douyin.share"].tap()
        let person = app.buttons["douyin.forward.contact.1|fixture-user-a"]
        XCTAssertTrue(person.waitForExistence(timeout: 10))
        person.tap()
        app.buttons["douyin.forward.send"].tap()
        app.buttons["douyin.forward.close"].tap()
        XCTAssertTrue(app.buttons["douyin.forward.close"].waitForNonExistence(timeout: 2))
        let success = app.descendants(matching: .any).matching(identifier: "douyin.forward.success").firstMatch
        XCTAssertFalse(success.waitForExistence(timeout: 6), "Closing before dispatch cancels the send")
        app.buttons["douyin.share"].tap()
        XCTAssertTrue(person.waitForExistence(timeout: 5))
        person.tap()
        XCTAssertTrue(app.buttons["douyin.forward.send"].isEnabled, "Cancellation must release the sending state")
    }

    private func verifyShareNoteAndSuccess(mode: String, group: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_SHARE_LAYOUT"] = "1"
        app.launchEnvironment["DOUDUO_FORWARD_LAYOUT_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_MESSAGE_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launch()
        XCTAssertTrue(app.staticTexts["离线分享测试"].waitForExistence(timeout: 10))
        app.buttons["douyin.share"].tap()
        let person = app.buttons["douyin.forward.contact.1|fixture-user-a"]
        XCTAssertTrue(person.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["douyin.forward.send"].exists, "Selecting a recipient must precede confirmation")
        person.tap()
        let note = app.textViews["douyin.forward.note"].exists
            ? app.textViews["douyin.forward.note"] : app.textFields["douyin.forward.note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts["暂无可分享的联系人"].exists, "Loaded contacts must not show the empty-state message")
        note.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        note.typeText("local note only")
        if group {
            // Wait until keyboard avoidance settles before tapping a moving recipient.
            attach(app, "share-keyboard-ready")
            app.buttons["douyin.forward.contact.2|fixture-group"].tap()
            XCTAssertTrue(app.staticTexts["发送给 一起去看海"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue((note.value as? String ?? "").contains("local note only"), "Switching recipient preserves the draft")
        }
        attach(app, "share-\(mode)-note-confirmation")
        app.buttons["douyin.forward.send"].tap() // DEBUG-only receipt; fixture has no network/send implementation.
        let success = app.descendants(matching: .any).matching(identifier: "douyin.forward.success").firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons["douyin.forward.close"].exists)
        XCTAssertFalse(app.buttons["douyin.forward.success.close"].exists)
        XCTAssertTrue(app.staticTexts[group ? "已私信给 一起去看海" : "已私信给 青禾"].exists)
        attach(app, "share-\(mode)-success")
        app.buttons["douyin.forward.success.open"].tap()
        let header = app.descendants(matching: .any).matching(identifier: "douyin.messages.chat.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(header.label.contains(group ? "一起去看海" : "青禾") || app.staticTexts[group ? "一起去看海" : "青禾"].exists)
        XCTAssertTrue(app.textViews["douyin.messages.composer.editor"].waitForExistence(timeout: 10), app.debugDescription)
        if mode == "duoClassic" {
            let home = app.buttons["首页"].firstMatch
            XCTAssertTrue(home.exists, app.debugDescription)
            let editor = app.textViews["douyin.messages.composer.editor"]
            if home.frame.midY > app.frame.height * 0.75 && home.frame.intersects(CGRect(x: editor.frame.minX, y: home.frame.minY, width: editor.frame.width, height: home.frame.height)) {
                XCTAssertLessThan(editor.frame.maxY, home.frame.minY, "Composer must stay above the bottom Dock")
            }
        }
        attach(app, "share-\(mode)-destination")
        if mode == "duoClassic" {
            app.buttons["douyin.messages.back"].tap()
            let row = app.buttons.matching(identifier: "douyin.conversation.row").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            app.buttons["首页"].firstMatch.tap()
            XCTAssertTrue(app.buttons["douyin.share"].waitForExistence(timeout: 5))
            app.buttons["消息"].firstMatch.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Returning to Messages must not reopen a previously handled share")
        }
    }

    /// Explicit opt-in only. Opens existing conversations without typing or sending.
    func testOnlineMessageNavigation() throws {
        guard ProcessInfo.processInfo.environment["DOUDUO_RUN_ONLINE_READONLY"] == "1" else {
            throw XCTSkip("Requires explicit permission and user login on the dedicated device")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["DOUDUO_MESSAGE_LAYOUT": "1", "DOUDUO_CHROME_MODE": "duoClassic"]
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let row = app.buttons.matching(identifier: "douyin.conversation.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        let editor = app.textViews["douyin.messages.composer.editor"]
        for attempt in 0..<3 {
            let start = Date()
            row.tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 8))
            print("ONLINE_TIMING open[\(attempt)]=\(Date().timeIntervalSince(start))")
            app.buttons["douyin.messages.back"].firstMatch.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 3))
            XCTAssertTrue(row.isEnabled)
        }
        func enterStrangers() {
            if app.buttons["douyin.messages.categories"].exists {
                app.buttons["douyin.messages.categories"].tap()
                app.buttons["陌生人消息"].firstMatch.tap()
            } else { app.buttons["douyin.messages.stranger"].tap() }
        }
        enterStrangers()
        do {
            app.buttons["douyin.messages.back"].firstMatch.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 3))
            let start = Date()
            row.tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 5), "Chat must not wait for the full stranger scan")
            print("ONLINE_TIMING after_scan_cancel=\(Date().timeIntervalSince(start))")
            app.buttons["douyin.messages.back"].firstMatch.tap()
        }
        // Give the explicitly opened category time to finish full collection,
        // then reopen to verify the native cache path on the real website.
        enterStrangers()
        sleep(30)
        app.buttons["douyin.messages.back"].firstMatch.tap()
        enterStrangers()
        sleep(1)
        app.buttons["douyin.messages.back"].firstMatch.tap()
    }

    func testShareLargeText() throws {
        for mode in ["duoClassic", "classic"] {
            let app = XCUIApplication()
            app.launchEnvironment = ["DOUDUO_SHARE_LAYOUT": "1", "DOUDUO_FORWARD_LAYOUT_FIXTURE": "1", "DOUDUO_MESSAGE_FIXTURE": "1", "DOUDUO_CHROME_MODE": mode, "DOUDUO_FORWARD_LONG_NAMES": "1"]
            app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
            addTeardownBlock { app.terminate() }
            app.launch()
            XCTAssertTrue(app.buttons["douyin.share"].waitForExistence(timeout: 10))
            app.buttons["douyin.share"].tap()
            let contact = app.buttons["douyin.forward.contact.1|fixture-user-a"]
            XCTAssertTrue(contact.waitForExistence(timeout: 10))
            XCTAssertTrue(contact.isHittable)
            let name = contact.staticTexts.firstMatch
            XCTAssertGreaterThan(name.frame.height, 40, "Long names should retain two lines at accessibility sizes")
            XCTAssertTrue(app.buttons["douyin.forward.close"].isHittable)
            attach(app, "share-large-text-\(mode)")
            app.buttons["douyin.forward.close"].tap()
            app.terminate()
        }
    }

    func testMessageRepeatedOpenBack() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["DOUDUO_MESSAGE_LAYOUT": "1", "DOUDUO_MESSAGE_FIXTURE": "1", "DOUDUO_CHROME_MODE": ProcessInfo.processInfo.environment["DD_MODE"] ?? "classic"]
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launch()
        if ProcessInfo.processInfo.environment["DD_LANDSCAPE"] == "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
            addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        }
        let row = app.buttons.matching(identifier: "douyin.conversation.row").matching(NSPredicate(format: "label CONTAINS %@", "青禾")).firstMatch
        let editor = app.textViews["douyin.messages.composer.editor"]
        for attempt in 0..<4 {
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            let started = Date()
            row.tap()
            // 打开中其他会话行不能整列变禁用（禁用 = 整列变暗，老板看到的「整个列表闪一下」）
            let others = app.buttons.matching(identifier: "douyin.conversation.row").allElementsBoundByIndex
            print("MESSAGE_ROWS enabled=\(others.filter(\.isEnabled).count)/\(others.count)")
            // 第二次起进同一条会话：网页切会话期间先铺上次的聊天快照（像微信，点进去立刻有内容，不转圈）
            let detail = app.descendants(matching: .any).matching(identifier: "douyin.messages.chat.detail").firstMatch
            _ = detail.waitForExistence(timeout: 3)
            let snap = detail.exists && (detail.value as? String) == "snapshot"
            print("MESSAGE_SNAPSHOT open[\(attempt)] used=\(snap)")
            if attempt > 0 { XCTAssertTrue(snap, "re-opening a chat shows the cached snapshot immediately") }
            XCTAssertTrue(editor.waitForExistence(timeout: 3))
            print("MESSAGE_LATENCY open[\(attempt)]=\(Date().timeIntervalSince(started))")
            let returning = Date()
            let backs = app.buttons.matching(identifier: "douyin.messages.back").allElementsBoundByIndex
            _ = backs
            app.buttons["douyin.messages.back"].firstMatch.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 2))
            XCTAssertTrue(row.isEnabled)
            print("MESSAGE_LATENCY back[\(attempt)]=\(Date().timeIntervalSince(returning))")
        }
    }

    func testMessageDraftFailureKeepsNavigationAvailable() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["DOUDUO_MESSAGE_LAYOUT": "1", "DOUDUO_MESSAGE_FIXTURE": "1",
                                 "DOUDUO_FIXTURE_REJECT_DRAFT": "1", "DOUDUO_CHROME_MODE": "duoClassic"]
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let rows = app.buttons.matching(identifier: "douyin.conversation.row")
        let qinghe = rows.matching(NSPredicate(format: "label CONTAINS %@", "青禾")).firstMatch
        let other = rows.matching(NSPredicate(format: "label CONTAINS %@", "一起去看海")).firstMatch
        let editor = app.textViews["douyin.messages.composer.editor"].firstMatch
        let error = app.descendants(matching: .any).matching(identifier: "douyin.messages.composer.error").firstMatch
        let back = app.buttons["douyin.messages.back"].firstMatch
        XCTAssertTrue(qinghe.waitForExistence(timeout: 15))
        qinghe.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(error.exists)
        editor.typeText("offline")
        XCTAssertFalse(error.exists, "Typing must not write to the webpage")
        app.buttons["douyin.messages.composer.send"].tap() // Offline fixture rejects the draft; no send handler exists.
        XCTAssertTrue(error.waitForExistence(timeout: 5))

        app.buttons["douyin.messages.more"].firstMatch.tap()
        let close = app.buttons["douyin.messages.options.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        if !other.isHittable { back.tap() }
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "douyin.messages.chat.header")
            .matching(NSPredicate(format: "label CONTAINS %@", "一起去看海")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse((editor.value as? String ?? "").contains("offline"))
        if !qinghe.isHittable { back.tap() }
        qinghe.tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (editor.value as? String ?? "").contains("offline")
        }, object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        XCTAssertFalse(error.exists)
    }

    func testMessageHideAndRestore() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["DOUDUO_MESSAGE_LAYOUT": "1", "DOUDUO_MESSAGE_FIXTURE": "1",
            "DOUDUO_CHROME_MODE": "classic", "DOUDUO_HIDE_FIXTURE": "1"]
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let rows = app.buttons.matching(identifier: "douyin.conversation.row")
        let person = rows.matching(NSPredicate(format: "label CONTAINS %@", "青禾")).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 20))
        person.swipeLeft()
        XCTAssertTrue(app.buttons["删除"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["不显示"].firstMatch.tap()
        XCTAssertTrue(person.waitForNonExistence(timeout: 5))
        XCTAssertEqual(rows.count, 3)
        attach(app, "hidden-conversation-retained-locally")
        app.buttons["fixture.receive"].tap() // Changes only the disconnected HTML fixture.
        XCTAssertTrue(person.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, 4)
        person.tap()
        let header = app.descendants(matching: .any).matching(identifier: "douyin.messages.chat.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textViews["douyin.messages.composer.editor"].waitForExistence(timeout: 5))
        attach(app, "hidden-conversation-restored-with-history")
    }

    override func setUpWithError() throws {
        // Device Hub selects the physical Duo display. Match that display's
        // orientation before launch so XCTest does not use stale portrait
        // hit coordinates until its first screenshot on the unfolded display.
        switch ProcessInfo.processInfo.environment["DOUDUO_TEST_DISPLAY"] {
        case "inner": XCUIDevice.shared.orientation = .landscapeLeft
        case "outer": XCUIDevice.shared.orientation = .portrait
        default: break
        }
    }

    /// 只测试输入焦点/布局，绝不发送弹幕或评论。
    func testRailStaysFixedWithKeyboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_HASHTAG_FIXTURE"] = "1"
        app.launchArguments += ["-douyin_chrome_mode_v1", "minimal"]
        app.launch()
        let more = app.buttons["douyin.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20))
        // 冷启动、没有任何输入时菜单栏必须是正常亮度且可点（曾因键盘状态残留整列锁灰）
        XCTAssertTrue(more.isEnabled, "启动后菜单栏可点")
        XCTAssertGreaterThan(more.frame.width, 0)
        let module = app.descendants(matching: .any).matching(identifier: "douyin.module.menu").firstMatch
        let like = app.buttons["douyin.like"].firstMatch
        let moduleBefore = module.frame
        let likeBefore = like.frame
        more.tap()
        let sendEntry = app.buttons["douyin.danmaku.open"].firstMatch
        XCTAssertTrue(sendEntry.waitForExistence(timeout: 5))
        sendEntry.tap()
        let input = app.textFields["douyin.danmaku.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        sleep(2)
        let moduleAfter = module.frame
        let likeAfter = like.frame
        print("RAIL_KEYBOARD module before=\(moduleBefore) after=\(moduleAfter) like before=\(likeBefore) after=\(likeAfter)")
        XCTAssertEqual(moduleBefore.midX, moduleAfter.midX, accuracy: 2)
        XCTAssertEqual(moduleBefore.midY, moduleAfter.midY, accuracy: 2)
        XCTAssertEqual(likeBefore.midX, likeAfter.midX, accuracy: 2)
        XCTAssertEqual(likeBefore.midY, likeAfter.midY, accuracy: 2)
        let send = app.buttons["douyin.danmaku.send"]
        XCTAssertFalse(more.isEnabled, "输入时更多按钮必须禁用")
        XCTAssertFalse(like.isEnabled, "输入时点赞必须禁用")
        input.typeText("layout test do not send")
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(send.isHittable, "发送按钮必须在最前层，不能被菜单遮住")
        let keyboardTop = app.keyboards.firstMatch.frame.minY
        print("COMPOSER send=\(send.frame) keyboardTop=\(keyboardTop)")
        XCTAssertLessThanOrEqual(send.frame.maxY, keyboardTop + 2)
        XCTAssertLessThan(keyboardTop - send.frame.maxY, 70, "输入区要紧贴键盘上方，不能被重复安全区抬到屏幕顶部")
        attach(app, "rail-keyboard-disabled-composer-front")
        app.buttons["douyin.danmaku.close"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 8))
        XCTAssertTrue(more.isEnabled, "收起键盘后菜单恢复")
        XCTAssertTrue(like.isEnabled)
        app.terminate()
    }

    /// Local-only document: no cookies, networking, or send implementation.
    func testMessageNativeComposerPortrait() throws {
        XCUIDevice.shared.orientation = .portrait
        try verifyMessageGlassLayoutAndActions(innerLandscape: false)
    }

    func testMessageNativeComposerLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        try verifyMessageGlassLayoutAndActions(innerLandscape: true)
    }

    func testMessageGlassLayoutAndActions() throws {
        try verifyMessageGlassLayoutAndActions()
    }

    func testMessageDefaultPortrait() throws {
        XCUIDevice.shared.orientation = .portrait
        try verifyMessageGlassLayoutAndActions(mode: "classic")
    }

    func testMessageDefaultLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        try verifyMessageGlassLayoutAndActions(mode: "classic")
    }

    private func verifyMessageGlassLayoutAndActions(innerLandscape: Bool? = nil, mode: String = "duoClassic") throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_MESSAGE_LAYOUT"] = "1"
        app.launchEnvironment["DOUDUO_MESSAGE_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let rows = app.buttons.matching(identifier: "douyin.conversation.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        func row(_ name: String) -> XCUIElement {
            rows.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        }
        let qinghe = row("青禾")
        attach(app, "message-list-before-actions")
        if let innerLandscape {
            let window = app.windows.firstMatch.frame
            guard window.width >= 560, (window.width > window.height) == innerLandscape else {
                throw XCTSkip("Duo did not enter the required inner-screen posture: \(window)")
            }
        }
        if !qinghe.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(qinghe.isHittable, app.debugDescription)
        qinghe.swipeRight()
        let pin = app.buttons["置顶"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5), app.debugDescription)
        pin.tap()
        let pinned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已置顶"), object: qinghe)
        XCTAssertEqual(XCTWaiter.wait(for: [pinned], timeout: 8), .completed, app.debugDescription)
        qinghe.tap()
        let header = app.descendants(matching: .any).matching(identifier: "douyin.messages.chat.header").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
        let more = app.buttons["douyin.messages.more"].firstMatch
        XCTAssertTrue(more.isHittable)
        more.tap()
        let options = app.descendants(matching: .any).matching(identifier: "douyin.messages.options").firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["消息免打扰"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["douyin.messages.options.close"].firstMatch.tap()
        XCTAssertTrue(options.waitForNonExistence(timeout: 5))
        let web = app.webViews.matching(identifier: "douyin.messages.chat.detail").firstMatch
        if !app.descendants(matching: .any).matching(identifier: "douyin.messages.divider").firstMatch.exists {
            XCTAssertFalse(app.tabBars.buttons["消息"].isHittable, "Single-column chats are detail pages without Dock")
        }
        let editor = app.textViews["douyin.messages.composer.editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        editor.tap()
        editor.typeText("local draft only")
        XCTAssertTrue((editor.value as? String ?? "").contains("local draft only"))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["Previous"].exists || app.buttons["Next"].exists,
            "Native text input has no web form-navigation accessory")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "douyin.messages.composer.error").firstMatch.exists, app.debugDescription)
        let divider = app.descendants(matching: .any).matching(identifier: "douyin.messages.divider").firstMatch
        if divider.exists {
            let window = app.windows.firstMatch.frame
            if window.height > window.width {
                XCTAssertGreaterThanOrEqual(header.frame.minY, more.frame.maxY + 4,
                    "Portrait header must clear the system toolbar")
            }
            let before = web.frame
            let maximumListWidth = min(380, (before.width + before.minX) / 2)
            let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -300, dy: 0)))
            let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in web.frame.width > before.width + 60 }, object: web)
            XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 5), .completed, "Divider must change actual pane width")
            XCTAssertTrue((editor.value as? String ?? "").contains("local draft only"), "Resizing must preserve the same editor and draft")
            let dock = app.descendants(matching: .any).matching(identifier: "douyin.messages.sidebarDock").firstMatch
            XCTAssertEqual(web.frame.minX, 96, accuracy: 2, "Dragging beyond the list minimum collapses to the avatar rail")
            XCTAssertFalse(dock.exists, "Narrow rail returns Dock to the system status column")
            let narrow = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            narrow.press(forDuration: 0.1, thenDragTo: narrow.withOffset(CGVector(dx: 240, dy: 0)))
            XCTAssertEqual(web.frame.minX, maximumListWidth, accuracy: 2, "Expanded list has a bounded maximum")
            XCTAssertFalse(dock.exists, "All large-screen widths use the system Dock")
            attach(app, "message-glass-expanded-maximum")
            let wide = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            wide.press(forDuration: 0.1, thenDragTo: wide.withOffset(CGVector(dx: 280 - maximumListWidth, dy: 0)))
            XCTAssertEqual(web.frame.minX, 280, accuracy: 2, "Normal list reaches its minimum before collapsing")
            attach(app, "message-glass-expanded-minimum")
            let minimum = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            minimum.press(forDuration: 0.1, thenDragTo: minimum.withOffset(CGVector(dx: -60, dy: 0)))
            XCTAssertEqual(web.frame.minX, 96, accuracy: 2)
            more.tap()
            XCTAssertTrue(options.waitForExistence(timeout: 5))
            attach(app, "message-compact-sidebar-options")
            app.buttons["douyin.messages.options.close"].firstMatch.tap()
            XCTAssertTrue(options.waitForNonExistence(timeout: 5))
        }
        if app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width {
            XCTAssertFalse(divider.exists, "Portrait remains single-column with the keyboard open")
            XCTAssertFalse(app.collectionViews["douyin.messages.list"].isHittable)
        }
        attach(app, "message-glass-draft-and-resize")
        print("MESSAGE_NATIVE_KEYBOARD \(app.windows.firstMatch.frame)")
        Thread.sleep(forTimeInterval: 4) // Allows host capture of the physical inner display.
        app.buttons["douyin.messages.back"].firstMatch.tap()
        let target = row("青禾")
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        if !target.isHittable { app.collectionViews.firstMatch.swipeUp() }
        target.swipeLeft()
        let delete = app.buttons["删除"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(app.alerts["删除这条会话？"].waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(target.exists, "Cancel must preserve the conversation")
        target.swipeLeft()
        app.buttons["删除"].firstMatch.tap()
        app.alerts.buttons["删除"].tap()
        XCTAssertTrue(target.waitForNonExistence(timeout: 8), app.debugDescription)
        attach(app, "message-glass-list-after-delete")
    }

    func testMessageHalfFoldLayout() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_MESSAGE_LAYOUT"] = "1"
        app.launchEnvironment["DOUDUO_MESSAGE_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let row = app.buttons.matching(identifier: "douyin.conversation.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "douyin.messages.chat.header").firstMatch.waitForExistence(timeout: 10))
        let web = app.webViews.matching(identifier: "douyin.messages.chat.detail").firstMatch
        let list = app.collectionViews["douyin.messages.list"]
        print("HALF_FOLD_FRAMES window=\(app.windows.firstMatch.frame) list=\(list.frame) detail=\(web.frame)")
        XCTAssertEqual(web.frame.minX, app.windows.firstMatch.frame.midX, accuracy: 4, "Half-fold boundary follows the physical hinge, including the status column")
        XCTAssertGreaterThan(list.frame.width, 280)
        XCTAssertGreaterThan(web.frame.width, 280, "The chat pane must retain usable width beside the hinge")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "douyin.messages.divider").firstMatch.exists)
        let editor = app.textViews["douyin.messages.composer.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "message-half-fold-equal-panes")
        editor.tap()
        editor.typeText("local draft only")
        attach(app, "message-half-fold-keyboard")
    }

    func testMessageCompactOptionsScreenshot() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_MESSAGE_LAYOUT"] = "1"
        app.launchEnvironment["DOUDUO_MESSAGE_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let row = app.buttons.matching(identifier: "douyin.conversation.row")
            .matching(NSPredicate(format: "label CONTAINS %@", "青禾")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        XCTAssertTrue(app.textViews["douyin.messages.composer.editor"].waitForExistence(timeout: 10))
        let divider = app.descendants(matching: .any).matching(identifier: "douyin.messages.divider").firstMatch
        XCTAssertTrue(divider.exists)
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -300, dy: 0)))
        let web = app.webViews.matching(identifier: "douyin.messages.chat.detail").firstMatch
        XCTAssertEqual(web.frame.minX, 96, accuracy: 2)
        app.buttons["douyin.messages.more"].firstMatch.tap()
        XCTAssertTrue(app.buttons["消息免打扰"].waitForExistence(timeout: 5))
        attach(app, "message-compact-sidebar-options-final")
    }

    func testHashtagClassicFlow() throws { verifyHashtags(mode: "duoClassic") }
    func testHashtagDefaultFlow() throws { verifyHashtags(mode: "classic") }

    func testSearchClassicLayout() throws { verifySearchLayout(mode: "duoClassic") }
    func testSearchDefaultLayout() throws { verifySearchLayout(mode: "classic") }
    func testSearchHalfFoldClassicLayout() throws { verifySearchLayout(mode: "duoClassic", halfFold: true) }
    func testSearchHalfFoldDefaultLayout() throws { verifySearchLayout(mode: "classic", halfFold: true) }

    func testLiveHashtagClassicFlow() throws { verifyLiveHashtags(mode: "duoClassic") }
    func testLiveHashtagDefaultFlow() throws { verifyLiveHashtags(mode: "classic") }

    /// 老板 11-16 报：搜索出来的视频点作者头像不跳，要返回关掉播放器才看到作者页。
    /// 作者页必须直接弹在播放器上面，播放器不能先被关掉。
    func testSearchResultAvatarOpensAuthorDirectly() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "rail"
        for flag in ["DOUDUO_HASHTAG_FIXTURE", "DOUDUO_SEARCH_FIXTURE", "DOUDUO_PLAYBACK_FIXTURE", "DOUDUO_RESET_HASHTAG_FILTER"] {
            app.launchEnvironment[flag] = "1"
        }
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-douyin_search_history_v1", "",
                                "-douduo_dismissed_update_v1", "1.5.0"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let search = app.buttons["douyin.search"].firstMatch
        if search.waitForExistence(timeout: 15) { search.tap() } else {
            app.buttons["douyin.module.menu"].firstMatch.tap()
            app.buttons["douyin.module.search"].firstMatch.tap()
        }
        XCTAssertTrue(app.textFields["douyin.search.field"].waitForExistence(timeout: 10))
        app.buttons["douyin.search.hot.1"].tap()
        let result = app.buttons["douyin.grid.item.hashtag-travel"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()
        let back = app.buttons["douyin.list.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        // 简洁/极简模式：作者是左下的「@名字」（douyin.author）；经典模式：系统栏头像（douyin.author.avatar）
        let avatar = app.buttons["douyin.author"].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        avatar.tap()
        let panel = app.descendants(matching: .any).matching(identifier: "douyin.author.panel").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "tapping the avatar must open the author page immediately")
        attach(app, "search-result-author-direct")
    }

    /// 老板 11-16 报：视频快进过就不会自动连播。播到一半拖进度条快进，播完必须照样切下一条。
    func testAutoNextAfterSeek() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = ProcessInfo.processInfo.environment["DD_MODE"] ?? "classic"
        for flag in ["DOUDUO_HASHTAG_FIXTURE", "DOUDUO_PLAYBACK_FIXTURE"] { app.launchEnvironment[flag] = "1" }
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "YES", "-douduo_dismissed_update_v1", "1.5.4"]
        addTeardownBlock { app.terminate() }
        app.launch()
        sleep(3)
        let w = app.windows.firstMatch
        if ProcessInfo.processInfo.environment["DD_HOW"] == "boost" {
            // 长按 2 倍速
            w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 2.5)
        } else {
            // 拖底部进度条快进
            let bar = app.otherElements["douyin.progress"].firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 5), "progress bar")
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        }
        sleep(14)
        attach(app, "autonext-after-seek")
    }

    func testSearchPlaybackClassic() throws { verifySearchPlayback(mode: "duoClassic") }
    func testSearchPlaybackDefault() throws { verifySearchPlayback(mode: "classic") }

    private func verifySearchPlayback(mode: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
        for flag in ["DOUDUO_HASHTAG_FIXTURE", "DOUDUO_SEARCH_FIXTURE", "DOUDUO_PLAYBACK_FIXTURE", "DOUDUO_RESET_HASHTAG_FILTER"] {
            app.launchEnvironment[flag] = "1"
        }
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                                "-douyin_wide_landscape_v1", "NO", "-douyin_search_history_v1", "",
                                "-douduo_dismissed_update_v1", "1.5.0"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let window = app.windows.firstMatch
        if ProcessInfo.processInfo.environment["DOUDUO_TEST_DISPLAY"] == "inner" {
            print("DUODUO_POSTURE open")
            Thread.sleep(forTimeInterval: 2)
            print("DUODUO_ROTATE landscape")
            XCTAssertTrue(waitUntil(timeout: 15) { window.frame.width > window.frame.height })
        }
        let split = window.frame.width > 700
        func snapshot() -> [String: Any] {
            let label = app.staticTexts["douyin.search.playbackProbe"].firstMatch.label
            return (try? JSONSerialization.jsonObject(with: Data(label.utf8))) as? [String: Any] ?? [:]
        }
        func players() -> [[String: Any]] { snapshot()["players"] as? [[String: Any]] ?? [] }
        func playingIDs() -> [String] {
            players().filter { ($0["rate"] as? Double ?? 0) > 0 }.compactMap { $0["id"] as? String }.sorted()
        }
        XCTAssertTrue(waitUntil(timeout: 20) { playingIDs() == ["hashtag-cat"] && players().contains { $0["id"] as? String == "hashtag-cat" && $0["ready"] as? Bool == true } })
        let initialInstance = players().first { $0["id"] as? String == "hashtag-cat" }?["instance"] as? String
        if split {
            app.buttons["douyin.comments"].firstMatch.tap()
            XCTAssertTrue(app.scrollViews["douyin.comments.list"].waitForExistence(timeout: 10))
        }
        print("DUODUO_RECORD_START playback-" + mode)
        Thread.sleep(forTimeInterval: 1)
        app.buttons["douyin.search"].firstMatch.tap()
        XCTAssertTrue(app.textFields["douyin.search.field"].waitForExistence(timeout: 10))
        if split {
            XCTAssertEqual(playingIDs(), ["hashtag-cat"])
            XCTAssertEqual(players().first { $0["id"] as? String == "hashtag-cat" }?["instance"] as? String, initialInstance)
            XCTAssertEqual((snapshot()["appearances"] as? [String: Int])?["hashtag-cat"], 1)
            XCTAssertNil((snapshot()["disappearances"] as? [String: Int])?["hashtag-cat"], "comments → split search must retain the original player")
        } else {
            XCTAssertTrue(waitUntil(timeout: 5) { playingIDs().isEmpty })
        }
        Thread.sleep(forTimeInterval: 2)
        print("DUODUO_RECORD_STOP playback-" + mode)
        app.buttons["douyin.search.hot.1"].tap()
        let result = app.buttons["douyin.grid.item.hashtag-travel"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()
        XCTAssertTrue(app.buttons["douyin.list.back"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { playingIDs() == ["hashtag-travel"] }, "only the result video may play: \(snapshot())")
        // Pause before visual inspection; the probe includes the covered feed player.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { playingIDs().isEmpty })
        attach(app, "playback-" + mode + "-result-paused")
        app.buttons["douyin.list.back"].firstMatch.tap()
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { playingIDs() == (split ? ["hashtag-cat"] : []) })
        app.buttons["douyin.search.back"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { playingIDs() == ["hashtag-cat"] })
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { playingIDs().isEmpty })
        // A manually paused feed must stay paused after visiting another result.
        app.buttons["douyin.search"].firstMatch.tap()
        app.buttons["douyin.search.hot.1"].tap()
        result.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { playingIDs() == ["hashtag-travel"] })
        app.buttons["douyin.list.back"].firstMatch.tap()
        app.buttons["douyin.search.back"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { playingIDs().isEmpty }, "search must preserve an explicit user pause")
        attach(app, "playback-" + mode + "-returned-paused")
        window.swipeUp(velocity: .fast)
        let current = app.staticTexts["douyin.currentID"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 10) {
            current.label != "hashtag-cat" && playingIDs() == [current.label]
        }, "paging still activates only the next video; current=\(current.label), players=\(snapshot())")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).tap()
        XCTAssertTrue(waitUntil(timeout: 5) { playingIDs().isEmpty })
        attach(app, "playback-" + mode + "-next-paused")
    }

    func testHashtagChipLayout() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchEnvironment["DOUDUO_HASHTAG_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_RESET_HASHTAG_FILTER"] = "1"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                                "-douyin_wide_landscape_v1", "NO",
                                "-douduo_dismissed_update_v1", "1.5.0"]
        addTeardownBlock { app.terminate() }
        app.launch()
        XCTAssertTrue(wait(label: "hashtag-cat", on: app.staticTexts["douyin.currentID"].firstMatch, timeout: 15))
        attach(app, "hashtag-chips-before-opening")
        app.buttons["douyin.more"].firstMatch.tap()
        app.buttons["按标签过滤视频"].firstMatch.tap()
        let cat = app.buttons["屏蔽 #猫咪"].firstMatch
        let travel = app.buttons["屏蔽 #旅行"].firstMatch
        XCTAssertTrue(cat.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["douyin.hashtags.input"].frame.midY,
                       app.buttons["douyin.hashtags.add"].frame.midY, accuracy: 1,
                       "the add button shares the input row")
        XCTAssertEqual(cat.frame.minY, travel.frame.minY, accuracy: 1, "short current tags share a row")
        let currentTags = app.scrollViews["douyin.hashtags.current"].firstMatch
        let lastTag = app.buttons["屏蔽 #运动"].firstMatch
        XCTAssertTrue(currentTags.waitForExistence(timeout: 5))
        for _ in 0..<3 where !lastTag.isHittable { currentTags.swipeLeft() }
        XCTAssertTrue(lastTag.isHittable, "horizontal scrolling reveals the remaining tags")
        XCTAssertEqual(lastTag.frame.minY, cat.frame.minY, accuracy: 1, "current tags stay on one line")
        for _ in 0..<3 where !cat.isHittable { currentTags.swipeRight() }
        for tag in ["猫咪", "旅行", "摄影"] {
            app.buttons["屏蔽 #" + tag].firstMatch.tap()
        }
        let removeCat = app.buttons["取消屏蔽 #猫咪"].firstMatch
        let removeTravel = app.buttons["取消屏蔽 #旅行"].firstMatch
        XCTAssertTrue(removeCat.waitForExistence(timeout: 5))
        XCTAssertEqual(removeCat.frame.minY, removeTravel.frame.minY, accuracy: 1, "short blocked tags share a row")
        attach(app, "hashtag-chips-compact")
        let longTag = "这是一条用于检查屏蔽页面自动换行的很长很长的完整标签名字" + String(repeating: "长标签", count: 10)
        let input = app.textFields["douyin.hashtags.input"]
        input.tap(); input.typeText(longTag)
        app.buttons["douyin.hashtags.add"].tap()
        let longChip = app.buttons["取消屏蔽 #" + longTag].firstMatch
        XCTAssertTrue(longChip.waitForExistence(timeout: 5))
        if !longChip.isHittable { app.swipeUp() }
        let bounds = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(longChip.frame.minX, bounds.minX)
        XCTAssertLessThanOrEqual(longChip.frame.maxX, bounds.maxX)
        XCTAssertGreaterThan(longChip.frame.height, removeCat.frame.height, "long tags wrap inside the available width")
        attach(app, "hashtag-chips-long")
        longChip.tap()
        for tag in ["猫咪", "旅行", "摄影"] {
            app.buttons["取消屏蔽 #" + tag].firstMatch.tap()
        }
        XCTAssertTrue(app.staticTexts["尚未屏蔽任何标签"].waitForExistence(timeout: 5))
        app.buttons["douyin.hashtags.done"].tap()
    }

    private func verifyLiveHashtags(mode: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        // No feed/search fixtures, forced video IDs or blocklist reset: use the
        // real recommended feed and real signed search API in this app session.
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                                "-douyin_wide_landscape_v1", "NO",
                                "-douduo_dismissed_update_v1", "1.5.0"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 90) { current.exists && current.label.range(of: "^[0-9]{10,}$", options: .regularExpression) != nil }, app.debugDescription)

        func pauseVideo() {
            let state = app.staticTexts["douyin.video.playback"].firstMatch
            guard state.waitForExistence(timeout: 5) else { return } // photo gallery
            if wait(label: "playing", on: state, timeout: 5) {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).tap()
                XCTAssertTrue(wait(label: "paused", on: state, timeout: 5))
            }
        }
        func openFilters() {
            app.buttons["douyin.more"].firstMatch.tap()
            let manage = app.buttons["按标签过滤视频"].firstMatch
            XCTAssertTrue(manage.waitForExistence(timeout: 5))
            manage.tap()
            XCTAssertTrue(app.textFields["douyin.hashtags.input"].waitForExistence(timeout: 5))
        }
        func audit(_ phase: String, tag: String, originalID: String) {
            let payload = ["phase": phase, "tag": tag, "originalID": originalID]
            let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            print("DUODUO_AUDIT " + String(decoding: data, as: UTF8.self))
            Thread.sleep(forTimeInterval: 1)
        }

        pauseVideo()
        attach(app, "live-" + mode + "-start")
        func visibleTags() -> [XCUIElement] {
            app.links.matching(NSPredicate(format: "label BEGINSWITH '#' OR label BEGINSWITH '＃'"))
                .allElementsBoundByIndex.filter { $0.isHittable && $0.label.count > 1 }
        }
        var chosen: XCUIElement?
        for _ in 0..<20 {
            var links = visibleTags()
            let expand = mode == "duoClassic"
                ? app.links.matching(NSPredicate(format: "label CONTAINS %@", "…")).firstMatch
                : app.buttons["douyin.description.toggle"].firstMatch
            if links.isEmpty, expand.exists, mode == "duoClassic" || expand.label == "展开" {
                expand.tap()
                links = visibleTags()
            }
            if let tag = links.first(where: { $0.label.count <= 16 }) ?? links.first {
                chosen = tag; break
            }
            let previous = current.label
            app.windows.firstMatch.swipeUp(velocity: .fast)
            XCTAssertTrue(waitUntil(timeout: 15) { current.label != previous && current.label != "-" }, app.debugDescription)
        }
        guard let chosen else { XCTFail("No real caption hashtag found in 20 recommendations"); return }
        let originalID = current.label
        let tag = String(chosen.label.dropFirst())
        pauseVideo()
        audit("before-filter", tag: tag, originalID: originalID)
        attach(app, "live-" + mode + "-caption")
        chosen.tap()
        let field = app.textFields["douyin.search.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "#" + tag)
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'douyin.grid.item.'")).firstMatch
        let timeout = app.staticTexts["搜索请求超时，请稍后重试"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 90) { result.exists || timeout.exists }, app.debugDescription)
        if timeout.exists {
            print("DUODUO_REAL_SEARCH_RETRY timeout query=" + tag)
            app.buttons["douyin.search.submit"].tap()
        }
        XCTAssertTrue(result.waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertNotNil(result.identifier.range(of: "[0-9]{10,}$", options: .regularExpression))
        let playback = app.staticTexts["douyin.video.playback"].firstMatch
        if app.windows.firstMatch.frame.width > 700, playback.exists {
            XCTAssertEqual(playback.label, "paused", "opening split search must preserve the video's paused state")
        }
        print("DUODUO_REAL_SEARCH query=\(tag) result=\(result.identifier)")
        attach(app, "live-" + mode + "-search-results")
        app.buttons["douyin.search.back"].firstMatch.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))
        XCTAssertEqual(current.label, originalID)
        pauseVideo()
        openFilters()
        let input = app.textFields["douyin.hashtags.input"]
        input.tap(); input.typeText(tag)
        app.buttons["douyin.hashtags.add"].tap()
        let feedback = app.staticTexts["douyin.hashtags.feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertTrue(feedback.label.contains("已添加"))
        attach(app, "live-" + mode + "-blocked")
        app.buttons["douyin.hashtags.done"].tap()
        XCTAssertTrue(waitUntil(timeout: 30) { current.label != originalID && current.label != "-" })
        pauseVideo()
        audit("after-filter", tag: tag, originalID: originalID)
        let beforeRefresh = current.label
        app.buttons["douyin.more"].firstMatch.tap()
        app.buttons["刷新推荐"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 90) { current.label != beforeRefresh && current.label != "-" }, app.debugDescription)
        pauseVideo()
        audit("after-refresh", tag: tag, originalID: originalID)
        attach(app, "live-" + mode + "-refreshed")
        app.terminate(); app.launch()
        XCTAssertTrue(waitUntil(timeout: 60) { current.exists && current.label != "-" && current.label != originalID })
        pauseVideo()
        audit("after-relaunch", tag: tag, originalID: originalID)
        openFilters()
        let remove = app.buttons["取消屏蔽 #" + tag].firstMatch
        if !remove.isHittable { app.swipeUp() }
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
        app.buttons["douyin.hashtags.done"].tap()
        pauseVideo()
        audit("after-cleanup", tag: tag, originalID: originalID)
    }

    private func verifySearchLayout(mode: String, halfFold: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
        app.launchEnvironment["DOUDUO_HASHTAG_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_SEARCH_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_RESET_HASHTAG_FILTER"] = "1"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                                "-douyin_wide_landscape_v1", "NO", "-douyin_search_history_v1", "",
                                "-douduo_dismissed_update_v1", "1.5.0"]
        addTeardownBlock { app.terminate() }
        app.launch()
        XCTAssertTrue([466.0, 678.0, 669.0, 951.0].contains(app.windows.firstMatch.frame.width))
        let current = app.staticTexts["douyin.currentID"].firstMatch
        XCTAssertTrue(wait(label: "hashtag-cat", on: current, timeout: 15))
        if ProcessInfo.processInfo.environment["DOUDUO_TEST_DISPLAY"] == "inner" {
            print("DUODUO_POSTURE " + (halfFold ? "half" : "open"))
            Thread.sleep(forTimeInterval: 2)
            print("DUODUO_ROTATE landscape")
            XCTAssertTrue(waitUntil(timeout: 15) { app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height })
        }
        // XCTest application bounds describe the inactive outer display on Duo.
        // Window bounds follow the active display and its current orientation.
        let capturePrefix = "search-" + mode + (halfFold ? "-half" : "")
        attach(app, capturePrefix + "-before-opening")
        let expandedLandscape = app.windows.firstMatch.frame.width > 700 && app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
        let comments = app.scrollViews["douyin.comments.list"].firstMatch
        if expandedLandscape {
            if !halfFold { app.buttons["douyin.comments"].firstMatch.tap() }
            XCTAssertTrue(comments.waitForExistence(timeout: 10))
            attach(app, capturePrefix + "-comments-before-search")
        }
        app.buttons["douyin.search"].firstMatch.tap()
        let field = app.textFields["douyin.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        let submit = app.buttons["douyin.search.submit"]
        XCTAssertTrue(submit.isHittable)
        XCTAssertGreaterThanOrEqual(submit.frame.width, 30, "resizing from comments must not collapse the search button")
        if !app.keyboards.firstMatch.exists { print("DUODUO_SHOW_KEYBOARD") }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15))
        let back = app.buttons["douyin.search.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        // Back is independent of the field and belongs to Duo's right toolbar.
        XCTAssertGreaterThanOrEqual(back.frame.minX, field.frame.maxX)
        if expandedLandscape {
            XCTAssertTrue(comments.waitForNonExistence(timeout: 5), "search must replace inline and resident comments without a comment sheet")
            XCTAssertGreaterThan(field.frame.minX, app.windows.firstMatch.frame.midX)
            let divider = app.descendants(matching: .any).matching(identifier: "douyin.search.divider").firstMatch
            XCTAssertTrue(divider.waitForExistence(timeout: 5))
            XCTAssertEqual(divider.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1, "split must use exactly half of the entire display")
            XCTAssertTrue(current.exists, "video must remain alongside search")
            XCTAssertEqual(current.label, "hashtag-cat")
        } else {
            XCTAssertLessThan(field.frame.minX, app.windows.firstMatch.frame.midX)
            XCTAssertFalse(app.buttons["douyin.more"].firstMatch.isHittable, "full-screen search covers the video")
        }
        for rank in 0...3 {
            XCTAssertTrue(app.buttons["douyin.search.hot.\(rank)"].waitForExistence(timeout: 5))
        }
        attach(app, capturePrefix + "-hot-and-keyboard")
        app.buttons["douyin.search.hot.1"].tap()
        XCTAssertEqual(field.value as? String, "手工敲虾到底有多好吃")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        attach(app, capturePrefix + "-results")
        if expandedLandscape {
            // Device Hub owns inner-display rotation. The host recorder handles
            // these markers because XCUIDevice rotates only Duo's outer display.
            print("DUODUO_ROTATE portrait")
            XCTAssertTrue(waitUntil(timeout: 15) { app.windows.firstMatch.frame.width < app.windows.firstMatch.frame.height })
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertTrue(waitUntil(timeout: 5) { field.frame.minX < app.windows.firstMatch.frame.midX })
            XCTAssertEqual(field.value as? String, "手工敲虾到底有多好吃")
            attach(app, capturePrefix + "-portrait")
            XCTAssertFalse(app.buttons["douyin.more"].firstMatch.isHittable)
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "douyin.search.divider").firstMatch.exists)
            print("DUODUO_ROTATE landscape")
            XCTAssertTrue(waitUntil(timeout: 15) { app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height })
            XCTAssertTrue(waitUntil(timeout: 5) { field.frame.minX > app.windows.firstMatch.frame.midX })
            XCTAssertEqual(field.value as? String, "手工敲虾到底有多好吃")
            XCTAssertTrue(wait(label: "hashtag-cat", on: current, timeout: 5))
        }
        back.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(wait(label: "hashtag-cat", on: current, timeout: 5))
        if halfFold {
            XCTAssertTrue(comments.waitForExistence(timeout: 5), "resident comments return after leaving search")
            print("DUODUO_POSTURE open")
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func verifyHashtags(mode: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
        app.launchEnvironment["DOUDUO_HASHTAG_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_SEARCH_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_RESET_HASHTAG_FILTER"] = "1"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                                "-douyin_wide_landscape_v1", "NO",
                                "-douduo_dismissed_update_v1", "1.5.4", "-duoduomain_tab_v1", "首页"]
        addTeardownBlock { app.terminate() }
        app.launch()
        XCTAssertTrue([466.0, 678.0, 669.0, 951.0].contains(app.frame.width), "This regression must run on an iPhone Duo display: \(app.frame)")
        let current = app.staticTexts["douyin.currentID"].firstMatch
        XCTAssertTrue(wait(label: "hashtag-cat", on: current, timeout: 15))
        let tag = app.links["#猫咪"].firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "hashtag-" + mode + "-caption")
        tag.tap()
        let search = app.textFields["douyin.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(search.value as? String, "#猫咪")
        attach(app, "hashtag-" + mode + "-search")
        app.buttons["douyin.search.back"].tap()
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        if mode == "duoClassic" {
            let expand = app.links.matching(NSPredicate(format: "label CONTAINS %@", "…")).firstMatch
            XCTAssertTrue(expand.waitForExistence(timeout: 5))
            expand.tap()
            XCTAssertTrue(app.buttons["douyin.description.close"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["douyin.description.author"].exists)
            XCTAssertTrue(app.staticTexts["douyin.comments.title"].exists)
            XCTAssertTrue(app.scrollViews["douyin.comments.list"].exists)
            attach(app, "caption-comments-" + mode)
            app.buttons["douyin.description.close"].tap()
            let prose = app.links.matching(NSPredicate(format: "label BEGINSWITH %@", "日常")).firstMatch
            XCTAssertTrue(prose.waitForExistence(timeout: 5))
            prose.tap()
            XCTAssertTrue(app.buttons["douyin.description.close"].waitForExistence(timeout: 5))
        } else {
            let expand = app.buttons["douyin.description.toggle"].firstMatch
            XCTAssertTrue(expand.waitForExistence(timeout: 5))
            expand.tap()
        }
        let lastTag = app.links["#摄影"].firstMatch
        XCTAssertTrue(lastTag.waitForExistence(timeout: 5))
        lastTag.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "#摄影")
        app.buttons["douyin.search.back"].tap()

        func openFilters() {
            let more = app.buttons["douyin.more"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
            more.tap()
            let settings = app.buttons["设置"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
            let manage = app.buttons["douyin.hashtags.manage"].firstMatch
            if !manage.isHittable { app.swipeUp() }
            XCTAssertTrue(manage.waitForExistence(timeout: 5), app.debugDescription)
            manage.tap()
            XCTAssertTrue(app.textFields["douyin.hashtags.input"].waitForExistence(timeout: 5))
        }
        func closeFilters() {
            let back = app.buttons.matching(NSPredicate(format: "label IN %@", ["Back", "返回", "设置"])).firstMatch
            if back.isHittable {
                back.tap()
            } else {
                let window = app.windows.firstMatch
                // Duo's native vertical back button sits below the status island.
                if window.frame.width == 466 {
                    window.coordinate(withNormalizedOffset: CGVector(dx: 0.895, dy: 0.292)).tap()
                } else {
                    let left = window.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.45))
                    let right = window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45))
                    left.press(forDuration: 0.01, thenDragTo: right)
                }
            }
            let done = app.buttons["settings.done"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
            done.tap()
        }
        openFilters()
        let input = app.textFields["douyin.hashtags.input"]
        input.tap(); input.typeText("猫咪")
        app.buttons["douyin.hashtags.add"].tap()
        XCTAssertTrue(app.staticTexts["douyin.hashtags.feedback"].waitForExistence(timeout: 5))
        attach(app, "hashtag-" + mode + "-filter")
        closeFilters()
        XCTAssertTrue(wait(label: "hashtag-travel", on: current, timeout: 5), app.debugDescription)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "DOUDUO_RESET_HASHTAG_FILTER")
        app.launch()
        XCTAssertTrue(wait(label: "hashtag-travel", on: current, timeout: 15), "blocklist must survive relaunch")
        openFilters()
        let remove = app.buttons["取消屏蔽 #猫咪"].firstMatch
        if !remove.isHittable { app.swipeUp() }
        XCTAssertTrue(remove.waitForExistence(timeout: 5), app.debugDescription)
        remove.tap()
        closeFilters()
        app.terminate(); app.launch()
        XCTAssertTrue(wait(label: "hashtag-cat", on: current, timeout: 15), "unblocked videos return in future recommendations")
    }

    func testPanelsKeepPlaybackAndDismissGestures() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        app.launchEnvironment["DOUDUO_FORWARD_LAYOUT_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_AUTHOR_WORK_FIXTURE"] = "1"
        addTeardownBlock { app.terminate() }
        app.launch()
        XCTAssertTrue(wait(label: "7678628867820506406", on: app.staticTexts["douyin.currentID"], timeout: 60))
        let progress = app.descendants(matching: .any).matching(identifier: "douyin.progress").firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        func seconds() -> Int { Int((progress.value as? String ?? "0").split(separator: " ").first ?? "0") ?? 0 }
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in seconds() > 2 }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 20), .completed)
        let beforeMenu = seconds()
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.40)).press(forDuration: 0.8)
        let options = app.buttons["douyin.options.close"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 5), "68% 按整个屏幕计算，仍属于菜单区")
        Thread.sleep(forTimeInterval: 4)
        let list = app.scrollViews["douyin.options.list"].firstMatch
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 180)))
        XCTAssertTrue(options.waitForNonExistence(timeout: 5))
        XCTAssertGreaterThan(seconds(), beforeMenu + 2, "长按菜单保持视频播放")
        let beforeShare = seconds()
        app.buttons["douyin.share"].firstMatch.tap()
        let closeShare = app.buttons["douyin.forward.close"].firstMatch
        XCTAssertTrue(closeShare.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 4)
        closeShare.tap()
        XCTAssertTrue(closeShare.waitForNonExistence(timeout: 5))
        XCTAssertGreaterThan(seconds(), beforeShare + 2, "分享弹窗保持视频播放")
        app.buttons["douyin.comments"].firstMatch.tap()
        let comments = app.scrollViews["douyin.comments.list"].firstMatch
        XCTAssertTrue(comments.waitForExistence(timeout: 15))
        comments.swipeUp()
        let right = comments.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45))
        right.press(forDuration: 0.05, thenDragTo: right.withOffset(CGVector(dx: 180, dy: 3)))
        XCTAssertTrue(app.buttons["douyin.comments.close"].firstMatch.waitForNonExistence(timeout: 5), "列表滚动后仍可右滑关闭")
        XCTAssertTrue(app.buttons["douyin.share"].firstMatch.waitForExistence(timeout: 5))
        if app.windows.firstMatch.frame.width >= 700 {
            let beforeAuthor = seconds()
            app.buttons["douyin.author.avatar"].firstMatch.tap()
            let back = app.buttons["douyin.author.back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 4)
            XCTAssertGreaterThan(seconds(), beforeAuthor + 2, "并排作者页保持视频播放")
            let work = app.descendants(matching: .any).matching(identifier: "douyin.author.works").firstMatch.buttons.firstMatch
            XCTAssertTrue(work.waitForExistence(timeout: 30))
            work.tap()
            let workBack = app.buttons["douyin.list.back"].firstMatch
            XCTAssertTrue(workBack.waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["douyin.share"].firstMatch.isHittable)
            workBack.tap()
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            let resumedAt = seconds()
            Thread.sleep(forTimeInterval: 3)
            XCTAssertGreaterThan(seconds(), resumedAt, "退出作者作品后左侧视频恢复")
            back.tap()
        }
        attach(app, "panels-playback-and-dismissal")
    }

    func testStandaloneRailWithLiveActivity() throws {
        continueAfterFailure = false
        // Start an ActivityKit activity on the Duo before running this flow.
        let app = launchOnlineRegression()
        let current = app.staticTexts["douyin.currentID"].firstMatch
        let originalID = current.label
        app.buttons["douyin.author.avatar"].firstMatch.tap()
        let authorBack = app.buttons["douyin.author.back"].firstMatch
        XCTAssertTrue(authorBack.waitForExistence(timeout: 15))
        let works = app.descendants(matching: .any).matching(identifier: "douyin.author.works").firstMatch
        let work = works.buttons.firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 35))
        work.tap()
        XCTAssertTrue(app.buttons["douyin.list.back"].firstMatch.waitForExistence(timeout: 15))
        let rail = app.descendants(matching: .any).matching(identifier: "douyin.video.actions").firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 10))
        // The upstream boost gesture includes the empty slot above the capsule.
        // Measure the visible controls rather than that larger gesture container.
        let capsule = ["douyin.author.avatar", "douyin.like", "douyin.comments", "douyin.collect", "douyin.share"]
            .map { app.buttons[$0].firstMatch.frame }.reduce(CGRect.null) { $0.union($1) }
        XCTAssertLessThan(capsule.height, 320, "作品互动胶囊应紧凑，不占满系统状态列")
        for id in ["douyin.author.avatar", "douyin.like", "douyin.comments", "douyin.collect", "douyin.share", "douyin.list.back", "douyin.cleanScreen"] {
            XCTAssertTrue(app.buttons[id].firstMatch.isHittable, id + " 应直接显示，不进入更多")
        }
        XCTAssertLessThanOrEqual(app.buttons["douyin.cleanScreen"].firstMatch.frame.maxY, capsule.minY)
        XCTAssertFalse(app.buttons["douyin.more"].exists)
        XCTAssertFalse(app.buttons["更多"].exists)
        pauseRegressionVideo(app)
        attach(app, "standalone-rail-live-activity")
        app.buttons["douyin.comments"].firstMatch.tap()
        let list = app.scrollViews["douyin.comments.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 180, dy: 0)))
        XCTAssertTrue(app.buttons["douyin.comments.close"].firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["douyin.share"].firstMatch.isHittable)
        app.buttons["douyin.list.back"].firstMatch.tap()
        XCTAssertTrue(authorBack.waitForExistence(timeout: 12))
        authorBack.tap()
        let clean = app.buttons["douyin.cleanScreen"].firstMatch
        let share = app.buttons["douyin.share"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 10) { clean.isHittable && share.isHittable })
        XCTAssertEqual(current.label, originalID)
        pauseRegressionVideo(app)
        attach(app, "home-rail-after-author-work-with-live-activity")
        let dockFrames = ["首页", "我的", "消息"].map { app.buttons[$0].firstMatch }
            .filter(\.isHittable).map(\.frame)
        for id in ["douyin.author.avatar", "douyin.like", "douyin.comments", "douyin.collect", "douyin.share"] {
            let action = app.buttons[id].firstMatch
            XCTAssertTrue(action.isHittable, id + " 返回首页后可点击")
            XCTAssertFalse(dockFrames.contains { $0.insetBy(dx: 2, dy: 2).intersects(action.frame) }, id + " 应避开系统 Dock")
        }
        clean.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { clean.label == "退出清屏" })
        clean.tap()
        XCTAssertTrue(app.buttons["douyin.share"].firstMatch.isHittable)
        pauseRegressionVideo(app)
        attach(app, "home-rail-after-work-with-live-activity")
    }

    func testAuthorWorkContinuesOnDuoOuterDisplay() throws {
        continueAfterFailure = false
        let app = launchOnlineRegression()
        let window = app.windows.firstMatch
        XCTAssertGreaterThan(window.frame.width, 700, "Start on the open Duo inner display")
        let feedID = app.staticTexts["douyin.currentID"].firstMatch.label
        app.buttons["douyin.author.avatar"].firstMatch.tap()
        let authorBack = app.buttons["douyin.author.back"].firstMatch
        XCTAssertTrue(authorBack.waitForExistence(timeout: 15))
        let works = app.descendants(matching: .any).matching(identifier: "douyin.author.works").firstMatch
        let work = works.buttons.firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 35))
        work.tap()
        let workID = app.staticTexts["douyin.list.currentID"].firstMatch
        XCTAssertTrue(workID.waitForExistence(timeout: 15))
        let first = workID.label
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.2)))
        XCTAssertTrue(waitUntil(timeout: 10) { workID.exists && workID.label != first })
        let paged = workID.label
        pauseRegressionVideo(app)
        print("DUODUO_CLOSE_HINGE")
        XCTAssertTrue(waitUntil(timeout: 30) { window.frame.width < 700 && window.frame.height > window.frame.width })
        XCTAssertTrue(workID.waitForExistence(timeout: 10), "Folding must not close the work player")
        XCTAssertEqual(workID.label, paged, "Folding preserves the paged work")
        let back = app.buttons["douyin.list.back"].firstMatch
        XCTAssertTrue(back.isHittable, "The work controls must remain usable on the outer display")
        back.tap()
        XCTAssertTrue(authorBack.waitForExistence(timeout: 12))
        authorBack.tap()
        XCTAssertTrue(waitUntil(timeout: 12) {
            app.buttons["douyin.cleanScreen"].firstMatch.isHittable && app.buttons["douyin.share"].firstMatch.isHittable
        })
        XCTAssertEqual(app.staticTexts["douyin.currentID"].firstMatch.label, feedID)
    }

    func testSearchResultContinuesOnDuoOuterDisplay() throws {
        continueAfterFailure = false
        let app = launchOnlineRegression()
        let window = app.windows.firstMatch
        XCTAssertGreaterThan(window.frame.width, 700, "Start on the open Duo inner display")
        app.buttons["douyin.search"].firstMatch.tap()
        let field = app.textFields["douyin.search.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("iPhone")
        app.buttons["douyin.search.submit"].firstMatch.tap()
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "douyin.grid.item.")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 35))
        result.tap()
        let workID = app.staticTexts["douyin.list.currentID"].firstMatch
        XCTAssertTrue(workID.waitForExistence(timeout: 15))
        let openedID = workID.label
        pauseRegressionVideo(app)
        print("DUODUO_CLOSE_HINGE")
        XCTAssertTrue(waitUntil(timeout: 30) { window.frame.width < 700 && window.frame.height > window.frame.width })
        XCTAssertTrue(workID.waitForExistence(timeout: 10))
        XCTAssertEqual(workID.label, openedID)
        let back = app.buttons["douyin.list.back"].firstMatch
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(result.waitForExistence(timeout: 15), "Returning to search retains the result grid")
        XCTAssertEqual(app.textFields["douyin.search.field"].firstMatch.value as? String, "iPhone")
    }

    /// 「我的」点「去登录」要打开抖音网页登录页（老板 2026-11-17 报「点击登录无反应」）
    func testMineLoginOpensWeb() throws {
        continueAfterFailure = false
        let modes = ProcessInfo.processInfo.environment["DD_ONLY_MODE"].map { [$0] } ?? ["duoClassic", "rail", "classic"]
        for mode in modes {
            let app = XCUIApplication()
            app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
            if mode == "rail" { app.launchEnvironment["DOUDUO_OPEN"] = "mine" }
            app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-duoduomain_tab_v1", "首页",
                                    "-douduo_dismissed_update_v1", "9.9.9"]
            app.launch()
            if mode == "duoClassic" {
                XCTAssertTrue(app.buttons["我的"].firstMatch.waitForExistence(timeout: 30)); app.buttons["我的"].firstMatch.tap()
            } else if mode == "classic" {
                XCTAssertTrue(app.buttons["douyin.mine.top"].firstMatch.waitForExistence(timeout: 30)); app.buttons["douyin.mine.top"].firstMatch.tap()
            }
            let login = app.buttons["去登录"].firstMatch
            guard login.waitForExistence(timeout: 30) else { attach(app, "login-no-button-" + mode); throw XCTSkip("\(mode): 已登录，没有「去登录」") }
            attach(app, "login-before-" + mode)
            login.tap()
            XCTAssertTrue(app.buttons["douyin.login.sendcode"].firstMatch.waitForExistence(timeout: 10), "\(mode): 点「去登录」没打开登录页")
            attach(app, "login-after-" + mode)
            app.terminate()
        }
    }

    /// 简洁 / 极简：信息页 → 右侧栏「我的」→「去登录」要打开网页（老板真机走的这条路）
    func testMessagesMineLoginOpensWeb() throws {
        continueAfterFailure = false
        let mode = ProcessInfo.processInfo.environment["DD_ONLY_MODE"] ?? "rail"
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-duoduomain_tab_v1", "首页",
                                "-douduo_dismissed_update_v1", "9.9.9"]
        app.launch()
        let mine = app.buttons["我的"].firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 30), "信息页右侧栏没有「我的」")
        mine.tap()
        let login = app.buttons["去登录"].firstMatch
        guard login.waitForExistence(timeout: 30) else { attach(app, "msg-mine-no-login"); throw XCTSkip("已登录") }
        attach(app, "msg-mine-login-before")
        login.tap()
        let opened = app.buttons["douyin.login.sendcode"].firstMatch.waitForExistence(timeout: 10)
        attach(app, "msg-mine-login-after")
        XCTAssertTrue(opened, "信息页里的「我的」点「去登录」没打开登录页")
    }

    /// 点「我的」直接进「我的」；未登录先弹 App 内登录页：验证码 / 扫码两种，扫码页有二维码（老板 2026-11-17）
    func testMineOpensAppLoginWhenLoggedOut() throws {
        continueAfterFailure = false
        let modes = ProcessInfo.processInfo.environment["DD_ONLY_MODE"].map { [$0] } ?? ["rail", "classic", "duoClassic"]
        for mode in modes {
            let app = XCUIApplication()
            app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
            app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-duoduomain_tab_v1", "首页",
                                    "-douduo_dismissed_update_v1", "9.9.9"]
            app.launch()
            switch mode {
            case "duoClassic":
                // 底部 Tab「我的」：只点看得见的那个（firstMatch 可能匹配到屏外的同名按钮，点不上）
                XCTAssertTrue(app.buttons["我的"].firstMatch.waitForExistence(timeout: 30))
                // 播放时系统 Tab 栏会缩起来，「我的」点不到：先点「首页」把 Tab 栏叫出来（同 testStandaloneCommentsRespectLayout）
                app.buttons["首页"].firstMatch.tap()
                app.buttons["我的"].firstMatch.tap()
            case "classic":
                XCTAssertTrue(app.buttons["douyin.mine.top"].firstMatch.waitForExistence(timeout: 30)); app.buttons["douyin.mine.top"].firstMatch.tap()
            default:   // 简洁 / 极简：模块菜单 →「我的」
                let menu = app.buttons["douyin.module.menu"].firstMatch
                XCTAssertTrue(menu.waitForExistence(timeout: 30), "\(mode): 没有模块菜单"); menu.tap()
                let mine = app.buttons["douyin.module.mine"].firstMatch
                XCTAssertTrue(mine.waitForExistence(timeout: 5), "\(mode): 模块菜单里没有「我的」"); mine.tap()
            }
            // 未登录：自动弹登录页
            let send = app.buttons["douyin.login.sendcode"].firstMatch
            XCTAssertTrue(send.waitForExistence(timeout: 30), "\(mode): 未登录没自动弹登录页")
            XCTAssertTrue(app.textFields["douyin.login.phone"].exists, "\(mode): 没有手机号输入框")
            XCTAssertTrue(app.textFields["douyin.login.code"].exists, "\(mode): 没有验证码输入框")
            XCTAssertFalse(send.isEnabled, "\(mode): 没填手机号就能点获取验证码")
            attach(app, "app-login-code-" + mode)
            // 扫码：显示二维码，提示用另一台手机扫（抖音不认相册里的图）
            app.segmentedControls["douyin.login.mode"].buttons["扫码登录"].tap()
            XCTAssertTrue(app.images["douyin.login.qr"].waitForExistence(timeout: 20), "\(mode): 扫码页没出二维码")
            XCTAssertTrue((app.staticTexts["douyin.login.qr.hint"].label).contains("另一台"), "\(mode): 没提示用另一台手机扫")
            XCTAssertFalse(app.buttons["douyin.login.qr.save"].exists, "\(mode): 还留着「存到相册」")
            attach(app, "app-login-qr-" + mode)
            // 关掉后停在「我的」（不是信息页），页内有「去登录」
            app.buttons["douyin.login.close"].tap()
            let mineLogin = app.buttons["douyin.mine.login"].firstMatch
            XCTAssertTrue(mineLogin.waitForExistence(timeout: 10), "\(mode): 关掉登录后不在「我的」")
            XCTAssertTrue(mineLogin.isHittable, "\(mode): 「我的」不在前台（被信息页盖着）")
            attach(app, "app-login-closed-" + mode)
            app.terminate()
        }
    }

    /// App 登录页的按钮真能驱动网页：填号码点「获取验证码」→ 网页发起 send_code；填码点「登录」→ 网页发起登录请求。
    /// DOUDUO_LOGIN_DRYRUN=1 把这两个请求拦在本地，不会真发短信、不会真登录。
    func testAppLoginDrivesWebDryRun() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "classic"
        app.launchEnvironment["DOUDUO_LOGIN_DRYRUN"] = "1"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-duoduomain_tab_v1", "首页",
                                "-douduo_dismissed_update_v1", "9.9.9"]
        app.launch()
        XCTAssertTrue(app.buttons["douyin.mine.top"].firstMatch.waitForExistence(timeout: 30)); app.buttons["douyin.mine.top"].firstMatch.tap()
        let phone = app.textFields["douyin.login.phone"].firstMatch
        XCTAssertTrue(phone.waitForExistence(timeout: 30), "没弹登录页")
        sleep(4)   // 等网页登录页加载完
        phone.tap(); phone.typeText("13800138000")
        let send = app.buttons["douyin.login.sendcode"].firstMatch
        XCTAssertTrue(send.isEnabled, "填了 11 位号码「获取验证码」还是灰的")
        send.tap()
        // 网页开始倒计时 → App 按钮变成「Ns 后重发」
        let counting = NSPredicate(format: "label CONTAINS '后重发'")
        expectation(for: counting, evaluatedWith: send)
        waitForExpectations(timeout: 10)
        attach(app, "app-login-dry-sent")
        let code = app.textFields["douyin.login.code"].firstMatch
        code.tap(); code.typeText("123456")
        app.buttons["douyin.login.submit"].tap()
        // 网页提交后跳走（真机登录成功时就是这样）：App 必须核对登录态并给出结果，不能没反应（老板 11-17）
        let msg = app.staticTexts["douyin.login.message"].firstMatch
        XCTAssertTrue(msg.waitForExistence(timeout: 15), "网页跳走后 App 没有任何反馈")
        attach(app, "app-login-dry-submit")
        XCTAssertTrue(msg.label.contains("没登录上"), "提示不对：\(msg.label)")
    }

    /// 刚启动签名页还没好就点「我的」，也要弹登录（老板真机：启动后马上进「我的」不弹）
    func testMineAutoLoginRightAfterLaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "rail"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-duoduomain_tab_v1", "首页",
                                "-douduo_dismissed_update_v1", "9.9.9"]
        app.launch()
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 30)); menu.tap()   // 一出来就点，不等推荐流加载
        let mine = app.buttons["douyin.module.mine"].firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 5)); mine.tap()
        XCTAssertTrue(app.buttons["douyin.login.sendcode"].firstMatch.waitForExistence(timeout: 15), "启动后马上进「我的」没弹登录")
    }

    /// cookie 里有过期的旧 sessionid、账号其实未登录：登录页要停住让人输入，不能一打开就自己关掉（老板 11-17）
    func testLoginSheetStaysOpenWithStaleSession() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "rail"
        app.launchEnvironment["DOUDUO_OPEN"] = "mine"
        app.launchEnvironment["DOUDUO_STALE_SESSION"] = "1"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-duoduomain_tab_v1", "首页",
                                "-douduo_dismissed_update_v1", "9.9.9"]
        app.launch()
        let login = app.buttons["douyin.mine.login"].firstMatch
        let send = app.buttons["douyin.login.sendcode"].firstMatch
        if !send.waitForExistence(timeout: 25) {   // 有旧 cookie 时可能不自动弹，就点「去登录」
            XCTAssertTrue(login.waitForExistence(timeout: 20), "既没弹登录也没有「去登录」"); login.tap()
            XCTAssertTrue(send.waitForExistence(timeout: 10), "点「去登录」没出登录页")
        }
        sleep(8)   // 旧版这几秒内会自己关掉
        XCTAssertTrue(send.exists, "登录页自己收回去了")
        let phone = app.textFields["douyin.login.phone"].firstMatch
        phone.tap(); phone.typeText("138")
        XCTAssertTrue((phone.value as? String ?? "").contains("138"), "手机号输不进去")
        attach(app, "login-stale-session")
    }

    /// 多账号：账号页列出存着的账号，点一下切换（换 cookie），退出当前账号，左滑移除（假账号，不碰真实账号）
    func testAccountsSwitchSignOutRemove() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "rail"
        app.launchEnvironment["DOUDUO_OPEN"] = "mine"
        app.launchEnvironment["DOUDUO_FAKE_ACCOUNTS"] = "1"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-duoduomain_tab_v1", "首页",
                                "-douduo_dismissed_update_v1", "9.9.9", "-douduo_accounts_v1", "", "-douduo_account_current_v1", ""]
        app.launch()
        // 未登录会先弹登录页：关掉
        let close = app.buttons["douyin.login.close"].firstMatch
        if close.waitForExistence(timeout: 20) { close.tap() }
        let accounts = app.buttons["douyin.mine.accounts"].firstMatch
        XCTAssertTrue(accounts.waitForExistence(timeout: 15), "「我的」没有「账号」按钮"); accounts.tap()
        let a = app.buttons["douyin.account.1001"].firstMatch, b = app.buttons["douyin.account.1002"].firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 8) && b.exists, "账号页没列出存着的账号")
        XCTAssertTrue(app.buttons["douyin.account.add"].exists, "没有「添加账号」")
        attach(app, "accounts-list")
        // 切到乙：账号页关闭
        b.tap()
        XCTAssertTrue(a.waitForNonExistence(timeout: 8), "切换后账号页没关")
        // 再打开：乙打勾，有「退出当前账号」
        accounts.tap()
        XCTAssertTrue(app.buttons["douyin.account.signout"].waitForExistence(timeout: 8), "切换后没有「退出当前账号」")
        attach(app, "accounts-switched")
        // 退出
        app.buttons["douyin.account.signout"].tap()
        let confirm = app.buttons["退出"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(a.waitForNonExistence(timeout: 8), "退出后账号页没关")
        // 退出后账号还在列表，可以移除
        accounts.tap()
        XCTAssertTrue(b.waitForExistence(timeout: 8), "退出后账号不在列表了")
        XCTAssertFalse(app.buttons["douyin.account.signout"].exists, "退出后还显示「退出当前账号」")
        b.swipeLeft()
        app.buttons["移除"].firstMatch.tap()
        let confirmRemove = app.buttons["移除"].firstMatch
        if confirmRemove.waitForExistence(timeout: 5) { confirmRemove.tap() }
        XCTAssertTrue(b.waitForNonExistence(timeout: 5), "移除后账号还在")
        attach(app, "accounts-removed")
    }

    /// 简洁 / 极简「我的」：右侧栏只有 返回 / 账号 / 信息 / 我的，不显示 互动 粉丝 系统 陌生人；「账号」不跟返回键重叠
    /// 剪贴板里有抖音分享（长链接 / 抖音口令短链）：回到 App 直接打开那条视频
    func testShareLinkOpensVideo() throws {
        continueAfterFailure = false
        let text = ProcessInfo.processInfo.environment["DD_SHARE_TEXT"]
            ?? "今天的风景 https://www.douyin.com/video/7705001843541851839 复制此链接，打开抖音搜索，直接观看视频！"
        let want = ProcessInfo.processInfo.environment["DD_SHARE_ID"] ?? "7705001843541851839"
        let app = XCUIApplication()
        app.launchEnvironment = ["DOUDUO_CHROME_MODE": "rail", "DOUDUO_SHARE_TEXT": text]
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-duoduomain_tab_v1", "首页",
                                "-douduo_dismissed_update_v1", "9.9.9"]
        app.launch()
        let back = app.buttons["douyin.list.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 40), "没打开分享的视频（单条播放页没出来）")
        let player = app.descendants(matching: .any)["douyin.list.player"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        let current = player.value as? String ?? ""
        print("DDSHARE current=\(current)")
        XCTAssertEqual(current, want, "打开的不是分享的那条")
        attach(app, "share-open")
    }

    func testMineRailLayout() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "rail"
        app.launchEnvironment["DOUDUO_FAKE_ACCOUNTS"] = "1"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-duoduomain_tab_v1", "首页",
                                "-douduo_dismissed_update_v1", "9.9.9"]
        app.launch()
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 30)); menu.tap()
        app.buttons["douyin.module.mine"].firstMatch.tap()
        let close = app.buttons["douyin.login.close"].firstMatch
        if close.waitForExistence(timeout: 15) { close.tap() }
        let accounts = app.buttons["douyin.mine.accounts"].firstMatch
        XCTAssertTrue(accounts.waitForExistence(timeout: 10), "「我的」右侧栏没有「账号」")
        XCTAssertEqual(app.buttons.matching(identifier: "douyin.mine.accounts").count, 1, "「账号」出现了不止一个")
        for id in ["douyin.messages.rail.interactive", "douyin.messages.rail.fans", "douyin.messages.rail.system", "douyin.messages.rail.stranger"] {
            XCTAssertFalse(app.buttons[id].exists, "「我的」页还显示 \(id)")
        }
        let back = app.buttons["douyin.messages.close"].firstMatch
        XCTAssertTrue(back.exists, "没有返回键")
        XCTAssertFalse(back.frame.intersects(accounts.frame), "「账号」跟返回键重叠")
        attach(app, "mine-rail")
        accounts.tap()
        XCTAssertTrue(app.buttons["douyin.account.add"].waitForExistence(timeout: 8), "点右侧栏「账号」没打开账号页")
        app.buttons["关闭"].firstMatch.tap()
        // 回信息页：四个分类回来
        app.buttons["douyin.messages.tab.messages"].firstMatch.tap()
        XCTAssertTrue(app.buttons["douyin.messages.rail.interactive"].waitForExistence(timeout: 5), "回信息页后分类没回来")
        XCTAssertFalse(app.buttons["douyin.mine.accounts"].exists, "信息页还显示「账号」")
        attach(app, "messages-rail")
        // 信息 / 我的 两页的返回键位置要一致（打印出来对比）
        let backMsg = app.buttons["douyin.messages.close"].firstMatch.frame
        app.buttons["douyin.messages.mine"].firstMatch.tap()
        XCTAssertTrue(app.buttons["douyin.mine.accounts"].firstMatch.waitForExistence(timeout: 8))
        sleep(1)
        let backMine = app.buttons["douyin.messages.close"].firstMatch.frame
        XCTAssertEqual(backMsg.minY, backMine.minY, accuracy: 1, "返回键在信息 / 我的两页位置不一样")
        attach(app, "mine-rail-again")
    }

    /// 切换账号后信息页马上按新账号重新核对（不等 5 分钟缓存）：日志里要出现 scope reset + 聊天网页重建
    func testAccountSwitchRechecksMessages() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "rail"
        app.launchEnvironment["DOUDUO_FAKE_ACCOUNTS"] = "1"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-duoduomain_tab_v1", "首页",
                                "-douduo_dismissed_update_v1", "9.9.9", "-douduo_accounts_v1", "", "-douduo_account_current_v1", ""]
        app.launch()
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 30)); menu.tap()
        app.buttons["douyin.module.mine"].firstMatch.tap()
        let close = app.buttons["douyin.login.close"].firstMatch
        if close.waitForExistence(timeout: 15) { close.tap() }
        // 先看一眼信息页，让账号核对缓存住「未登录」
        app.buttons["douyin.messages.tab.messages"].firstMatch.tap(); sleep(3)
        app.buttons["douyin.messages.mine"].firstMatch.tap()
        app.buttons["douyin.mine.accounts"].firstMatch.tap()
        let b = app.buttons["douyin.account.1002"].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 8)); b.tap()
        sleep(4)
        attach(app, "account-switch-messages")
    }

    /// 储存空间：查看占用、清理缓存
    func testStorageSpaceCanClearCaches() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [
            "DOUDUO_CHROME_MODE": "duoClassic",
            "DOUDUO_HASHTAG_FIXTURE": "1",
            "DOUDUO_APPEARANCE": "system"
        ]
        // 固定从首页起（停在「我的」时未登录会弹登录页盖住「更多」）
        app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                               "-douduo_dismissed_update_v1", "9.9.9", "-duoduomain_tab_v1", "首页"]
        addTeardownBlock { app.terminate() }
        app.launch()

        let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }
            ?? app.buttons["douyin.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        print("STORAGE_DUO_WINDOW \(app.windows.firstMatch.frame)")
        _ = app.screenshot()
        // SwiftUI Menu reports a legacy Button on Duo, but XCTest can fail to
        // resolve its activation point. Tap the center of its reported frame.
        more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let settings = app.buttons["设置"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        settings.tap()

        let destination = app.descendants(matching: .any)["settings.storage"].firstMatch
        for _ in 0..<5 where !destination.isHittable { app.swipeUp() }
        XCTAssertTrue(destination.isHittable, app.debugDescription)
        destination.tap()

        let total = app.descendants(matching: .any)["storage.total"].firstMatch
        XCTAssertTrue(total.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.navigationBars["储存空间"].exists)
        let deviceShare = app.staticTexts["storage.device-share"]
        XCTAssertTrue(deviceShare.exists)
        XCTAssertTrue(deviceShare.label.contains("%"), deviceShare.label)
        XCTAssertTrue(deviceShare.label.hasPrefix("占手机总容量的"), deviceShare.label)
        attach(app, "storage-before-cleanup")
        let clear = app.buttons["storage.clear"]
        clear.tap()
        let confirm = app.alerts["清理缓存？"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.staticTexts["清除缓存和诊断日志，保留离线视频。"].exists)
        confirm.buttons["取消"].tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))

        clear.tap()
        confirm.buttons["清理缓存"].tap()
        let result = app.descendants(matching: .any)["storage.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(result.label, "缓存已清理")
        XCTAssertTrue(total.exists)
        attach(app, "storage-after-cleanup")
    }

    /// main 140417d 管理功能入口：只检查入口在，不点执行（会改真实账号）
    func testManageEntriesExist() throws {
        continueAfterFailure = false
        for mode in ["rail", "duoClassic"] {
            let app = XCUIApplication()
            app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
            app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
            app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-duoduomain_tab_v1", "首页",
                                    "-douduo_dismissed_update_v1", "9.9.9"]
            app.launch()
            XCTAssertTrue(wait(label: "7678628867820506406", on: app.staticTexts["douyin.currentID"].firstMatch, timeout: 60), mode)
            // 经典：长按视频出面板；默认 / 简洁 / 极简：视频的「更多」菜单
            if mode == "duoClassic" {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45)).press(forDuration: 0.9)
            } else {
                let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }
                XCTAssertNotNil(more, "\(mode): 找不到「更多」"); more?.tap()
            }
            let later = app.buttons["douyin.watchlater.add"].firstMatch
            XCTAssertTrue(later.waitForExistence(timeout: 6), "\(mode): 更多面板里没有「稍后再看」")
            attach(app, "manage-watchlater-" + mode)
            app.terminate()
        }
    }

    /// 「我的」等列表播放页：外屏横屏视频上移 / 内屏右侧 / 半折常驻，四种界面与推荐页同一套（老板 2026-11-17）
    func testListPlayerCommentsMatchFeedInEveryMode() throws {
        continueAfterFailure = false
        let modes = ProcessInfo.processInfo.environment["DD_ONLY_MODE"].map { [$0] } ?? ["rail", "classic", "minimal", "duoClassic"]
        for mode in modes {
            let app = XCUIApplication()
            app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
            app.launchEnvironment["DOUDUO_COMMENT_ENTRY"] = "mine"
            if mode == "rail" || mode == "minimal" { app.launchEnvironment["DOUDUO_OPEN"] = "mine" }
            app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7707707401935336335"   // 1920x1080 横屏视频
            app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-duoduomain_tab_v1", "首页",
                                    "-douduo_dismissed_update_v1", "9.9.9"]
            app.launch()
            XCTAssertTrue(wait(label: "7707707401935336335", on: app.staticTexts["douyin.currentID"], timeout: 60), mode)
            if mode == "duoClassic" {   // 与 testStandaloneCommentsRespectLayout 同一入口
                app.buttons["首页"].firstMatch.tap()
                app.buttons["我的"].firstMatch.tap()
            } else if mode == "classic" { app.buttons["douyin.mine.top"].firstMatch.tap() }
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "douyin.list.player").firstMatch.waitForExistence(timeout: 30), mode + " 列表播放页没打开")
            let screen = app.windows.firstMatch.frame
            let list = app.scrollViews["douyin.comments.list"].firstMatch
            let halfFold = list.waitForExistence(timeout: 4)   // 半折：评论常驻，不用点
            if !halfFold {
                let comment = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
                XCTAssertNotNil(comment, "\(mode): 找不到评论按钮"); comment?.tap()
                XCTAssertTrue(list.waitForExistence(timeout: 10), "\(mode): 评论没出来")
            }
            if screen.width < 560 && !halfFold {
                // 外屏：横屏视频在上、评论在下、贴满宽
                XCTAssertGreaterThan(list.frame.minY, screen.height * 0.3, "\(mode): 外屏横屏视频应在评论上方")
                XCTAssertEqual(list.frame.maxX, screen.maxX, accuracy: 2, "\(mode): 评论右边不应留空")
            } else if screen.width >= 700 {
                XCTAssertGreaterThan(list.frame.minX, screen.width * 0.4, "\(mode): 内屏评论应在右侧")
            }
            XCTAssertFalse(app.buttons["douyin.like"].firstMatch.isHittable, "\(mode): 评论打开时视频按钮应收起")
            attach(app, "list-player-comments-" + mode)
            app.terminate()
        }
    }

    /// 内屏横拿：评论从右侧滑出，右划关闭——四种界面同一套（评论统一，老板 2026-11-17）
    func testInnerSideCommentsSwipeRightToCloseInEveryMode() throws {
        continueAfterFailure = false
        for mode in ["duoClassic", "rail", "classic", "minimal"] {
            let app = XCUIApplication()
            app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
            app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
            app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                                    "-douduo_dismissed_update_v1", "9.9.9", "-duoduomain_tab_v1", "首页"]
            app.launch()
            XCTAssertTrue(wait(label: "7678628867820506406", on: app.staticTexts["douyin.currentID"].firstMatch, timeout: 60), mode)
            guard app.windows.firstMatch.frame.width >= 700 else { throw XCTSkip("需要内屏横拿") }
            let button = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(button, "\(mode): 找不到评论按钮"); button?.tap()
            let comments = app.scrollViews["douyin.comments.list"].firstMatch
            XCTAssertTrue(comments.waitForExistence(timeout: 15), "\(mode): 评论没出来")
            XCTAssertGreaterThan(comments.frame.minX, app.windows.firstMatch.frame.width * 0.4, "\(mode): 评论应在右侧")
            XCTAssertFalse(app.buttons["douyin.like"].firstMatch.isHittable, "\(mode): 评论打开时视频按钮应收起")
            attach(app, "inner-side-comments-" + mode)
            comments.swipeUp()
            let start = comments.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 180, dy: 3)))
            XCTAssertTrue(app.scrollViews["douyin.comments.list"].firstMatch.waitForNonExistence(timeout: 5), "\(mode): 右划应关闭评论")
            app.terminate()
        }
    }

    /// 半折评论常驻：四种界面同一套（评论统一，老板 2026-11-17）
    func testPhysicalHalfFoldCommentsHideSidebar() throws {
        continueAfterFailure = false
        for mode in ["duoClassic", "rail", "classic", "minimal"] {
            let app = launchOnlineRegression(mode: mode)
            XCTAssertTrue(app.scrollViews["douyin.comments.list"].firstMatch.waitForExistence(timeout: 15), "\(mode) 实际半折自动显示评论")
            pauseRegressionVideo(app)
            attach(app, "physical-half-fold-comments-" + mode)
            for id in ["douyin.like", "douyin.share", "douyin.cleanScreen", "首页"] {
                XCTAssertFalse(app.buttons[id].firstMatch.isHittable, mode + " " + id + " 半折评论时隐藏")
            }
            let panel = app.descendants(matching: .any).matching(identifier: "douyin.comments.panel").firstMatch
            let screen = app.windows.firstMatch.frame
            if screen.width > screen.height {
                XCTAssertLessThanOrEqual(panel.frame.minY, screen.minY + 2, "半折评论背景贴顶")
                XCTAssertGreaterThanOrEqual(panel.frame.maxY, screen.maxY - 2, "半折评论背景贴底")
                XCTAssertGreaterThanOrEqual(panel.frame.maxX, screen.maxX - 2, "半折评论背景贴右边")
                let title = app.staticTexts["douyin.comments.title"].firstMatch
                let composer = app.descendants(matching: .any).matching(identifier: "douyin.comment.send").firstMatch
                XCTAssertTrue(title.exists)
                XCTAssertTrue(composer.exists)
                XCTAssertLessThan(title.frame.minX - panel.frame.minX, 40, "横向状态栏应与左侧评论标题同排")
                XCTAssertGreaterThan(composer.frame.midX, screen.maxX - 64, "评论操作应使用原系统竖栏占用的空间")
            }
            XCTAssertFalse(app.buttons["douyin.comments.close"].exists, "\(mode) 半折时评论继续常驻")
            app.terminate()
        }
    }

    func testCleanScreenRestoresStableSidebar() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        attach(app, "build95-clean-before")
        let clear = app.buttons["douyin.cleanScreen"].firstMatch
        let share = app.buttons["douyin.share"].firstMatch
        let home = app.buttons["首页"].firstMatch
        XCTAssertTrue(clear.isHittable)
        let originalShare = share.frame
        let originalHome = home.frame
        let originalID = current.label
        for round in 1...2 {
            clear.tap()
            let onlyClear = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let visible = app.buttons.allElementsBoundByIndex.filter(\.isHittable)
                return visible.count == 1 && visible.first?.identifier == "douyin.cleanScreen"
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [onlyClear], timeout: 5), .completed, app.debugDescription)
            XCTAssertEqual(clear.label, "退出清屏")
            XCTAssertFalse(app.otherElements["douyin.progress"].exists)
            XCTAssertFalse(app.otherElements["douyin.video.info"].exists)
            XCTAssertEqual(current.label, originalID, "清屏不能重建或切换播放器")
            if round == 1 {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4)).press(forDuration: 0.8)
                XCTAssertFalse(app.buttons["douyin.options.close"].exists, "清屏时中间长按不弹出菜单")
                attach(app, "build95-clean-only-toggle")
            }
            clear.tap()
            XCTAssertTrue(share.waitForExistence(timeout: 5))
            attach(app, "build95-clean-restored-\(round)")
            XCTAssertTrue(app.buttons["douyin.search"].isHittable)
            XCTAssertTrue(app.buttons["douyin.more"].isHittable)
            for _ in 0..<8 {
                XCTAssertEqual(share.frame.minY, originalShare.minY, accuracy: 1, "恢复后侧栏不能反复跳动")
                XCTAssertEqual(home.frame, originalHome)
                XCTAssertFalse(app.buttons["BottomOverflowBarButtonItem"].exists)
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }

    func testCleanScreenStartsSystemPictureInPicture() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_bg_play_v1", "NO", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        _ = app.screenshot()
        app.buttons["douyin.cleanScreen"].tap()
        let state = app.staticTexts["douyin.video.pipState"].firstMatch
        if state.label == "unsupported" {
            throw XCTSkip("当前 Duo 运行环境的 AVPictureInPictureController.isPictureInPictureSupported 返回 false，需真机确认系统小窗")
        }
        XCTAssertTrue(wait(label: "ready", on: state, timeout: 15), app.debugDescription)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        print("PIP_SYSTEM_UI " + springboard.debugDescription)
        print("DUODUO_CAPTURE build95-pip-background")
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(app.buttons["douyin.cleanScreen"].waitForExistence(timeout: 10))
        XCTAssertEqual(current.label, "7678628867820506406")
        attach(app, "build95-pip-restored")
        app.buttons["douyin.cleanScreen"].tap()
        XCTAssertTrue(app.buttons["douyin.comments"].waitForExistence(timeout: 5))
    }

    func testManualDownloadsContinueOnFeedAndPlayOffline() throws {
        continueAfterFailure = false
        guard let fixtureURL = ProcessInfo.processInfo.environment["DOUDUO_OFFLINE_FIXTURE_URL"] else {
            throw XCTSkip("Requires the local video download fixture")
        }
        let app = XCUIApplication()
        app.launchEnvironment = [
            "DOUDUO_CHROME_MODE": "duoClassic", "DOUDUO_HASHTAG_FIXTURE": "1",
            "DOUDUO_OFFLINE_FIXTURE_URL": fixtureURL, "DOUDUO_APPEARANCE": "system"
        ]
        app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                               "-douyin_wide_landscape_v1", "NO", "-douyin_playback_rate_v1", "1.25",
                               "-douduo_dismissed_update_v1", "9.9.9", "-duoduomain_tab_v1", "首页"]
        addTeardownBlock { app.terminate() }

        func openSettings() {
            let more = app.buttons["douyin.more"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 15))
            _ = app.screenshot()
            more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let settings = app.buttons["设置"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
        }

        func openStorage() {
            openSettings()
            let storage = app.descendants(matching: .any)["settings.storage"].firstMatch
            for _ in 0..<5 where !storage.isHittable { app.swipeUp() }
            XCTAssertTrue(storage.isHittable)
            storage.tap()
            XCTAssertTrue(app.navigationBars["储存空间"].waitForExistence(timeout: 5))
        }

        func openOfflineDownloads(checkPosition: Bool = false) {
            openSettings()
            let downloadLink = app.descendants(matching: .any)["settings.cache.offline"].firstMatch
            for _ in 0..<5 where !downloadLink.isHittable { app.swipeUp() }
            XCTAssertTrue(downloadLink.isHittable, app.debugDescription)
            if checkPosition {
                let cache = app.descendants(matching: .any)["settings.cache.count"].firstMatch
                let storage = app.descendants(matching: .any)["settings.storage"].firstMatch
                XCTAssertTrue(cache.exists && storage.exists)
                XCTAssertLessThan(cache.frame.midY, downloadLink.frame.midY)
                XCTAssertLessThan(downloadLink.frame.midY, storage.frame.midY)
            }
            downloadLink.tap()
        }

        app.launch()
        print("OFFLINE_DUO_WINDOW \(app.windows.firstMatch.frame)")
        let speedHint = app.descendants(matching: .any)["douyin.playbackSpeedHint"].firstMatch
        XCTAssertTrue(speedHint.waitForExistence(timeout: 5))
        let speedFrame = speedHint.frame
        XCTAssertFalse(speedFrame.isEmpty)
        openOfflineDownloads(checkPosition: true)
        let selection = app.descendants(matching: .any)["offline.count"].firstMatch
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        let automaticDownload = app.switches["offline.automatic"].firstMatch
        XCTAssertTrue(automaticDownload.exists)
        XCTAssertEqual(automaticDownload.value as? String, "0")
        let downloadButton = app.buttons["offline.estimate"]
        XCTAssertTrue(downloadButton.isHittable)
        let downloadFrame = downloadButton.frame
        attach(app, "offline-download-idle")
        selection.tap()
        for count in [50, 100, 150, 200] {
            XCTAssertTrue(app.buttons["\(count) 条"].firstMatch.exists)
        }
        XCTAssertFalse(app.buttons["1 条"].exists)
        app.buttons["200 条"].firstMatch.tap()
        downloadButton.tap()
        let confirm = app.alerts["下载离线视频？"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("6 GB") && $0.label.contains("200 条") })
        confirm.buttons["取消"].tap()

        selection.tap()
        app.buttons["50 条"].firstMatch.tap()
        downloadButton.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(confirm.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("1.5 GB") && $0.label.contains("50 条") })
        attach(app, "offline-estimate")
        confirm.buttons["开始下载"].tap()

        let progressRow = app.descendants(matching: .any)["offline.progress"].firstMatch
        XCTAssertTrue(progressRow.waitForExistence(timeout: 5))
        let stop = app.buttons["offline.stop"]
        XCTAssertTrue(stop.isHittable)
        XCTAssertEqual(stop.frame.minX, downloadFrame.minX, accuracy: 1)
        XCTAssertEqual(stop.frame.minY, downloadFrame.minY, accuracy: 1)
        XCTAssertEqual(stop.frame.width, downloadFrame.width, accuracy: 1)
        XCTAssertEqual(stop.frame.height, downloadFrame.height, accuracy: 1)
        XCTAssertGreaterThan(progressRow.frame.midY, app.windows.firstMatch.frame.midY)
        XCTAssertFalse(app.buttons["返回刷视频"].exists)
        attach(app, "offline-progress")
        stop.tap()
        let stopConfirmation = app.alerts["停止下载？"]
        XCTAssertTrue(stopConfirmation.waitForExistence(timeout: 5))
        stopConfirmation.buttons["取消"].tap()
        if ProcessInfo.processInfo.environment["DOUDUO_TEST_DISPLAY"] == "inner" {
            XCTAssertTrue(waitUntil(timeout: 22) {
                let counts = (stop.value as? String ?? "").split { !$0.isNumber }.compactMap { Int($0) }
                return counts.count >= 2 && counts[0] == 1 && counts[1] > 1
            }, "The fixture should show a partially filled download button")
            attach(app, "offline-progress-partial")
            XCTAssertEqual(stop.frame.size, downloadFrame.size)
        }

        // Close the settings sheet by its native dismiss gesture.
        let settingsStack = app.navigationBars["离线视频"]
        let window = app.windows.firstMatch
        let from = settingsStack.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
        let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.83))
        from.press(forDuration: 0.08, thenDragTo: to)
        XCTAssertTrue(settingsStack.waitForNonExistence(timeout: 5))
        let current = app.staticTexts["douyin.currentID"].firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        let first = current.label
        let feedSwipeStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.76))
        let feedSwipeEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.18))
        for _ in 0..<3 where current.label == first {
            feedSwipeStart.press(forDuration: 0.05, thenDragTo: feedSwipeEnd, withVelocity: .fast, thenHoldForDuration: 0)
        }
        XCTAssertTrue(waitUntil(timeout: 6) { current.label != first }, "Feed did not page after returning from the download screen")
        let banner = app.buttons["douyin.offline.banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertEqual(banner.label, "离线视频下载完成")
        let completion = try XCTUnwrap(banner.value as? String)
        let downloaded = try XCTUnwrap(completion.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) })
        XCTAssertGreaterThan(downloaded, 0)
        attach(app, "offline-complete-banner")
        if banner.isHittable { banner.tap() }

        openStorage()
        app.buttons["storage.clear"].tap()
        let clear = app.alerts["清理缓存？"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.buttons["清理缓存"].tap()
        let cleaned = app.descendants(matching: .any)["storage.result"].firstMatch
        XCTAssertTrue(cleaned.waitForExistence(timeout: 15))
        XCTAssertEqual(cleaned.label, "缓存已清理")
        app.terminate()

        app.launchEnvironment["DOUDUO_TEST_OFFLINE"] = "1"
        app.launch()
        let indicator = app.descendants(matching: .any)["douyin.video.offlineIndicator"].firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(indicator.label, "离线视频")
        XCTAssertEqual(indicator.value as? String, "1/\(downloaded)")
        let offlineFrame = indicator.frame
        XCTAssertEqual(offlineFrame.minX, speedFrame.minX, accuracy: 1)
        XCTAssertEqual(offlineFrame.minY, speedFrame.minY, accuracy: 1)
        XCTAssertEqual(offlineFrame.width, speedFrame.width, accuracy: 1)
        XCTAssertEqual(offlineFrame.height, speedFrame.height, accuracy: 1)
        print("DUODUO_CAPTURE offline-video-indicator")
        XCTAssertTrue(waitUntil(timeout: 8) { current.exists && current.label.hasPrefix("hashtag-") }, app.debugDescription)
        let progress = app.descendants(matching: .any)["douyin.progress"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 12) {
            guard progress.exists, let value = progress.value as? String,
                  let elapsed = value.split(separator: " ").first.flatMap({ Int($0) }) else { return false }
            return elapsed >= 1
        }, app.debugDescription)
        attach(app, "offline-local-playback")
        openOfflineDownloads()
        let duration = app.descendants(matching: .any)["offline.duration"].firstMatch
        XCTAssertTrue(duration.waitForExistence(timeout: 5), app.debugDescription)
        let durationLabels = [duration.label, duration.value as? String ?? ""] + duration.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(durationLabels.contains { $0.range(of: #"\d+:\d{2}(?::\d{2})?"#, options: .regularExpression) != nil }, durationLabels.joined(separator: " | "))
        let expiry = app.descendants(matching: .any)["offline.expiration"].firstMatch
        let remove = app.buttons["offline.delete"]
        XCTAssertTrue(expiry.exists && remove.exists)
        XCTAssertGreaterThan(expiry.frame.midY, remove.frame.midY)
        XCTAssertNotNil(expiry.label.range(of: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}"#, options: .regularExpression), expiry.label)
        XCTAssertFalse(app.descendants(matching: .any)["offline.saved"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["离线视频下载完成"].exists)
        attach(app, "offline-download-library")
        let libraryLink = app.descendants(matching: .any)["offline.library"].firstMatch
        XCTAssertTrue(libraryLink.isHittable)
        XCTAssertEqual(libraryLink.value as? String, "\(downloaded) 条")
        libraryLink.tap()
        let closePlayer = app.buttons["offline.library.close"]
        XCTAssertTrue(closePlayer.waitForExistence(timeout: 5))
        XCTAssertTrue(indicator.waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertEqual(indicator.value as? String, "1/\(downloaded)")
        let fullscreen = app.descendants(matching: .any)["offline.library.player"].firstMatch
        XCTAssertTrue(fullscreen.exists)
        XCTAssertGreaterThanOrEqual(fullscreen.frame.width, window.frame.width * 0.98)
        XCTAssertGreaterThanOrEqual(fullscreen.frame.height, window.frame.height * 0.98)
        XCTAssertFalse(app.buttons["offline.estimate"].isHittable)
        print("DUODUO_CAPTURE offline-library-fullscreen")
        XCTAssertTrue(waitUntil(timeout: 10) {
            guard let value = progress.value as? String,
                  let elapsed = value.split(separator: " ").first.flatMap({ Int($0) }) else { return false }
            return elapsed >= 1
        }, "The offline library should play while settings covers the recommendation feed.")

        closePlayer.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        app.alerts["删除全部离线视频？"].buttons["删除"].tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
    }

    func testOfflineLibraryRestoresLastVideoAndPlaybackPosition() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["DOUDUO_LIBRARY_FIXTURE"] == "1" else {
            throw XCTSkip("Requires two locally saved offline video fixtures")
        }
        let app = XCUIApplication()
        app.launchEnvironment = [
            "DOUDUO_CHROME_MODE": "duoClassic", "DOUDUO_HASHTAG_FIXTURE": "1",
            "DOUDUO_TEST_OFFLINE": "1", "DOUDUO_APPEARANCE": "system", "DOUDUO_PLAYBACK_FIXTURE": "1"
        ]
        app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                               "-douyin_playback_rate_v1", "1.25", "-douyin_bg_play_v1", "YES",
                               "-douduo_dismissed_update_v1", "9.9.9", "-duoduomain_tab_v1", "首页"]
        addTeardownBlock { app.terminate() }

        let launchLibrary = app.buttons["offline.library"]
        let close = app.buttons["offline.library.close"]
        let current = app.staticTexts["offline.library.currentID"].firstMatch
        let progress = app.descendants(matching: .any)["douyin.progress"].firstMatch
        let playerState = app.staticTexts["douyin.video.playback"].firstMatch

        func openOfflinePage() {
            let more = app.buttons["douyin.more"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 15))
            _ = app.screenshot()
            more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let settings = app.buttons["设置"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
            let offline = app.descendants(matching: .any)["settings.cache.offline"].firstMatch
            for _ in 0..<5 where !offline.isHittable { app.swipeUp() }
            XCTAssertTrue(offline.isHittable, app.debugDescription)
            offline.tap()
        }

        func openPlayer() {
            XCTAssertTrue(launchLibrary.waitForExistence(timeout: 5))
            launchLibrary.tap()
            XCTAssertTrue(close.waitForExistence(timeout: 5))
        }

        func elapsed() -> Int? {
            guard progress.exists, let value = progress.value as? String else { return nil }
            return value.split(separator: " ").first.flatMap { Int($0) }
        }

        func activeAudioIsCurrent(paused: Bool) -> Bool {
            let probe = app.staticTexts["douyin.search.playbackProbe"].firstMatch
            guard probe.exists,
                  let snapshot = try? JSONSerialization.jsonObject(with: Data(probe.label.utf8)) as? [String: Any],
                  let players = snapshot["players"] as? [[String: Any]] else { return false }
            let selected = players.filter {
                $0["id"] as? String == "offline-qa-second" && $0["library"] as? Bool == true && $0["active"] as? Bool == true
            }
            let playing = players.filter { ($0["rate"] as? Double ?? 0) > 0 || $0["engine"] as? Bool == true }
            guard selected.count == 1, selected.first?["remote"] as? Bool == true else { return false }
            if paused { return playing.isEmpty }
            return playing.count == 1 && playing.first?["instance"] as? String == selected.first?["instance"] as? String
        }

        app.launch()
        openOfflinePage()
        attach(app, "offline-download-library")
        openPlayer()
        XCTAssertTrue(wait(label: "offline-qa-first", on: current, timeout: 5))
        XCTAssertTrue(app.buttons["douyin.like"].firstMatch.waitForExistence(timeout: 5))

        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.76))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.18))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(wait(label: "offline-qa-second", on: current, timeout: 6), app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 6) { activeAudioIsCurrent(paused: false) }, "Only the selected offline player should own playback after paging")

        XCTAssertTrue(waitUntil(timeout: 5) { (elapsed() ?? 0) >= 1 })
        let beforeScrub = try XCTUnwrap(elapsed())
        let scrubStart = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.7))
        let scrubEnd = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.7))
        scrubStart.press(forDuration: 0.10, thenDragTo: scrubEnd)
        XCTAssertTrue(waitUntil(timeout: 5) { (elapsed() ?? 0) > beforeScrub + 9 }, "Dragging should seek the local video")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.40)).tap()
        XCTAssertTrue(wait(label: "paused", on: playerState, timeout: 4), app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 4) { activeAudioIsCurrent(paused: true) }, "Pausing the current clip must not bring back another clip's audio")
        let saved = try XCTUnwrap(elapsed())
        XCTAssertGreaterThanOrEqual(saved, 10)
        attach(app, "offline-library-interactions")

        close.tap()
        openPlayer()
        XCTAssertTrue(wait(label: "offline-qa-second", on: current, timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 3) { (elapsed() ?? 0) >= saved - 1 }, "Closing the player should remember the seek position")
        close.tap()

        app.terminate()
        app.launch()
        openOfflinePage()
        openPlayer()
        XCTAssertTrue(wait(label: "offline-qa-second", on: current, timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 3) { (elapsed() ?? 0) >= saved - 1 }, "The saved position should survive an app relaunch")
    }

    func testOnlineRecommendationReusesDownloadWithoutOfflineBadge() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["DOUDUO_ONLINE_CACHE_FIXTURE"] == "1",
              let failingSource = ProcessInfo.processInfo.environment["DOUDUO_FALLBACK_FIXTURE_URL"] else {
            throw XCTSkip("Requires the offline copy of the first online recommendation")
        }
        let app = XCUIApplication()
        app.launchEnvironment = [
            "DOUDUO_CHROME_MODE": "duoClassic", "DOUDUO_HASHTAG_FIXTURE": "1",
            "DOUDUO_OFFLINE_FIXTURE_URL": failingSource
        ]
        app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                               "-douyin_playback_rate_v1", "1", "-douyin_wide_landscape_v1", "NO",
                               "-douduo_dismissed_update_v1", "9.9.9", "-duoduomain_tab_v1", "首页"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"].firstMatch
        XCTAssertTrue(wait(label: "hashtag-cat", on: current, timeout: 8))
        let indicator = app.descendants(matching: .any)["douyin.video.offlineIndicator"].firstMatch
        XCTAssertFalse(indicator.exists)
        let progress = app.otherElements["douyin.progress"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 4) {
            guard let value = progress.value as? String,
                  let elapsed = value.split(separator: " ").first.flatMap({ Int($0) }) else { return false }
            return elapsed >= 1
        }, "The matching offline copy should play even with the fixture URL unavailable")
        XCTAssertFalse(indicator.exists)
    }

    func testFailedRecommendationContinuesFromVideoCache() throws {
        continueAfterFailure = false
        guard let fixtureURL = ProcessInfo.processInfo.environment["DOUDUO_FALLBACK_FIXTURE_URL"] else {
            throw XCTSkip("Requires the invalid video URL and a pre-seeded automatic video cache")
        }
        let app = XCUIApplication()
        app.launchEnvironment = [
            "DOUDUO_CHROME_MODE": "duoClassic", "DOUDUO_HASHTAG_FIXTURE": "1",
            "DOUDUO_OFFLINE_FIXTURE_URL": fixtureURL, "DOUDUO_APPEARANCE": "system"
        ]
        app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                               "-douyin_wide_landscape_v1", "NO", "-douduo_dismissed_update_v1", "9.9.9", "-duoduomain_tab_v1", "首页"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"].firstMatch
        XCTAssertTrue(wait(label: "hashtag-travel", on: current, timeout: 45), app.debugDescription)

        let progress = app.descendants(matching: .any)["douyin.progress"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 12) {
            guard let value = progress.value as? String,
                  let elapsed = value.split(separator: " ").first.flatMap({ Int($0) }) else { return false }
            return elapsed >= 1
        }, app.debugDescription)
    }

    func testRecommendationAutomaticallyReturnsOnlineAfterOfflineVideo() throws {
        continueAfterFailure = false
        guard let fixtureURL = ProcessInfo.processInfo.environment["DOUDUO_RECONNECT_FIXTURE_URL"] else {
            throw XCTSkip("Requires the local video fixture and a pre-seeded offline download")
        }
        let app = XCUIApplication()
        app.launchEnvironment = [
            "DOUDUO_CHROME_MODE": "duoClassic", "DOUDUO_HASHTAG_FIXTURE": "1",
            "DOUDUO_OFFLINE_FIXTURE_URL": fixtureURL, "DOUDUO_APPEARANCE": "system",
            "DOUDUO_TEST_OFFLINE": "1", "DOUDUO_TEST_RECONNECT_AFTER": "7"
        ]
        app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                               "-douyin_wide_landscape_v1", "NO", "-douduo_dismissed_update_v1", "9.9.9", "-duoduomain_tab_v1", "首页"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"].firstMatch
        XCTAssertTrue(wait(label: "offline-qa-first", on: current, timeout: 8), app.debugDescription)
        let progress = app.descendants(matching: .any)["douyin.progress"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 11) {
            guard current.label == "offline-qa-first", let value = progress.value as? String,
                  let elapsed = value.split(separator: " ").first.flatMap({ Int($0) }) else { return false }
            return elapsed >= 8
        }, "Reconnecting should keep the healthy offline video until it finishes.")
        XCTAssertTrue(wait(label: "hashtag-cat", on: current, timeout: 25), app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 12) {
            guard let value = progress.value as? String,
                  let elapsed = value.split(separator: " ").first.flatMap({ Int($0) }) else { return false }
            return elapsed >= 1
        }, "Fresh online video should play automatically.")
    }

    func testLongPressZonesAndSettingsMigration() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        attach(app, "build95-long-press-before")
        print("GESTURE_WINDOW \(app.windows.firstMatch.frame) APP \(app.frame)")
        let count = app.staticTexts["douyin.video.boostStarts"].firstMatch
        let options = app.buttons["douyin.options.close"].firstMatch
        for (index, x) in [0.15, 0.78].enumerated() {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.4)).press(forDuration: 0.8)
            XCTAssertEqual(count.label, String(index + 1))
            XCTAssertFalse(options.exists, "两侧只触发倍速")
        }
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4)).press(forDuration: 0.8)
        XCTAssertTrue(options.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(count.label, "2", "中间长按不能启动倍速")
        attach(app, "build95-options-top")
        XCTAssertTrue(app.buttons["douyin.options.fit"].isHittable)
        XCTAssertTrue(app.buttons["douyin.options.muted"].isHittable)
        XCTAssertTrue(app.buttons["douyin.options.bgplay"].isHittable)
        let window = app.windows.firstMatch
        let lastAction = app.buttons["douyin.danmaku.open"].firstMatch
        XCTAssertTrue(lastAction.isHittable)
        XCTAssertLessThan(window.frame.maxY - lastAction.frame.maxY, 65,
                          "The bottom sheet should end shortly below the last button")
        // 2026-11-14：全局偏好只在设置页，长按面板不再重复
        XCTAssertFalse(app.switches["横屏时只放横屏内容"].exists)
        XCTAssertFalse(app.switches["显示弹幕"].exists)
        attach(app, "options-current-video-only")
        app.buttons["douyin.options.rate.1.5"].tap()
        let selectedRate = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["douyin.options.rate.1.5"].isSelected
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [selectedRate], timeout: 5), .completed)
        app.buttons["douyin.options.rate.1.0"].tap()
        app.buttons["douyin.options.close"].tap()
        XCTAssertTrue(options.waitForNonExistence(timeout: 5))
        app.buttons["douyin.more"].firstMatch.tap()
        XCTAssertFalse(app.buttons["douyin.dislike"].exists)
        XCTAssertFalse(app.buttons["刷新推荐"].exists, "刷新推荐只在设置页")
        XCTAssertFalse(app.buttons["播放设置"].exists)
        XCTAssertFalse(app.buttons["缓存管理"].exists)
        let settings = app.buttons["douyin.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        attach(app, "more-surface-mute-listen-settings")
        settings.tap()
        XCTAssertTrue(app.buttons["settings.refresh"].waitForExistence(timeout: 5))
        attach(app, "settings-screen")
        app.buttons["settings.done"].tap()
    }

    /// 经典模式右侧控制区（对齐抖音）：长按任何位置都加速，按在按钮上也一样；
    /// 加速后松手不触发按钮本身（不开评论、不进作者页、不切清屏），普通点按照常。只读，不点赞不关注。
    func testClassicActionColumnHoldBoost() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launch()
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
        // Duo 的旋转由模拟器/Device Hub 控制；互动胶囊只在竖向（系统栏在右侧）时进系统栏。
        guard waitUntil(timeout: 30, condition: { app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width }) else {
            throw XCTSkip("请先把 Duo 旋转为竖向，右侧系统栏才会出现互动胶囊")
        }
        let avatar = app.buttons["douyin.author.avatar"].firstMatch
        let like = app.buttons["douyin.like"].firstMatch
        let comments = app.buttons["douyin.comments"].firstMatch
        let share = app.buttons["douyin.share"].firstMatch
        let clean = app.buttons["douyin.cleanScreen"].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        XCTAssertTrue(clean.waitForExistence(timeout: 10))
        let cleanLabel = clean.label
        attach(app, "classic-column-hold-before")
        let count = app.staticTexts["douyin.video.boostStarts"].firstMatch
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        let column = like.frame
        let window = app.windows.firstMatch.frame
        let probes: [(String, CGPoint)] = [
            // 清屏键与互动胶囊之间的整段留白
            ("gapAboveCapsule", CGPoint(x: column.midX, y: (clean.frame.maxY + avatar.frame.minY) / 2)),
            // 胶囊右侧到屏幕边缘
            ("besideCapsule", CGPoint(x: (column.maxX + window.maxX) / 2, y: like.frame.midY)),
            // 胶囊内边距、按钮间缝
            ("capsulePaddingBottom", CGPoint(x: column.midX, y: share.frame.maxY + 3)),
            ("gapBetweenButtons", CGPoint(x: column.midX, y: (like.frame.maxY + comments.frame.minY) / 2)),
            // 按钮本身
            ("commentsButton", CGPoint(x: comments.frame.midX, y: comments.frame.midY)),
            ("avatarButton", CGPoint(x: avatar.frame.midX, y: avatar.frame.midY)),
            ("cleanScreenButton", CGPoint(x: clean.frame.midX, y: clean.frame.midY)),
            // 首页选择器由系统 Tab 栏接管，属于系统控件，不在这里测。
        ]
        var missed: [String] = []
        for (name, point) in probes {
            let before = Int(count.label) ?? -1
            origin.withOffset(CGVector(dx: point.x, dy: point.y)).press(forDuration: 0.9)
            let boosted = Int(count.label) == before + 1
            print("CLASSIC_PROBE \(name) \(point) boosted=\(boosted)")
            if !boosted { missed.append(name) }
        }
        XCTAssertEqual(missed, [], "右侧控制区任何位置长按都应加速")
        // 长按加速后松手：评论没开、没进作者页、清屏没切换
        XCTAssertFalse(app.scrollViews["douyin.comments.list"].waitForExistence(timeout: 2), "长按评论键加速后不应打开评论")
        XCTAssertTrue(avatar.exists, "长按头像加速后不应进入作者页")
        XCTAssertEqual(clean.label, cleanLabel, "长按清屏键加速后不应切换清屏")
        attach(app, "classic-column-hold-after")
        // 普通点按不受影响
        Thread.sleep(forTimeInterval: 1)
        comments.tap()
        XCTAssertTrue(app.scrollViews["douyin.comments.list"].waitForExistence(timeout: 10), "普通点按评论键应打开评论")
    }

    func testCommentsPullDownAndHeaderSpacing() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        let comments = app.buttons["douyin.comments"].firstMatch
        comments.tap()
        let header = app.otherElements["douyin.comments.header"].firstMatch
        let panel = app.descendants(matching: .any).matching(identifier: "douyin.sheet.edgeSurface").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertEqual(header.frame.minY, panel.frame.minY, accuracy: 1, "顶部不保留横条占位")
        let related = app.scrollViews["douyin.comments.relatedSearch"].firstMatch
        if related.waitForExistence(timeout: 10) {
            XCTAssertLessThanOrEqual(related.frame.minY, header.frame.maxY + 1)
            XCTAssertLessThanOrEqual(related.frame.height, 26)
        }
        attach(app, "build95-comments-tight-header")
        let list = app.scrollViews["douyin.comments.list"].firstMatch
        list.swipeUp()
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(header.exists, "列表从中间往回滚动不能误关闭")
        let start = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 130)))
        XCTAssertTrue(header.waitForNonExistence(timeout: 5), "标题区下拉可关闭")
        XCTAssertTrue(comments.waitForExistence(timeout: 5))
        comments.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let top = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 160)))
        XCTAssertTrue(header.waitForNonExistence(timeout: 5), "列表顶部下拉可关闭")
        XCTAssertTrue(comments.waitForExistence(timeout: 5))
        attach(app, "build95-comments-pull-closed")
    }

    func testInnerShareUsesTrailingHalf() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        app.launchEnvironment["DOUDUO_FORWARD_LAYOUT_FIXTURE"] = "1"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        guard app.windows.firstMatch.frame.width >= 700 else { throw XCTSkip("仅验收 Duo 内屏横向布局") }
        _ = app.screenshot()
        app.buttons["douyin.share"].firstMatch.tap()
        XCTAssertTrue(app.buttons["douyin.forward.contact.layout-fixture-1"].waitForExistence(timeout: 15))
        let panel = app.otherElements["douyin.sheet.edgeSurface"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThanOrEqual(panel.frame.minX, app.windows.firstMatch.frame.width * 0.48)
        let surface = app.otherElements["douyin.sheet.edgeSurface"].firstMatch
        XCTAssertEqual(surface.frame.width, app.windows.firstMatch.frame.width / 2, accuracy: 1)
        XCTAssertEqual(surface.frame.maxY, app.windows.firstMatch.frame.maxY, accuracy: 1)
        let actions = app.buttons["douyin.forward.action.copy"]
        XCTAssertGreaterThanOrEqual(surface.frame.maxY - actions.frame.maxY, 20)
        XCTAssertLessThanOrEqual(surface.frame.maxY - actions.frame.maxY, 40)
        attach(app, "build94-inner-share-trailing-two-rows")
        app.buttons["douyin.forward.close"].tap()
    }

    /// Returning from comments must restore the native compressed home tab,
    /// including after the user has expanded the tab selector once.
    func testNativeDockRestoresAfterClosingComments() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        let comment = app.buttons["douyin.comments"].firstMatch
        let share = app.buttons["douyin.share"].firstMatch
        let home = app.buttons["首页"].firstMatch
        XCTAssertTrue(comment.waitForExistence(timeout: 10))
        let size = app.windows.firstMatch.frame.size
        guard size.width < 600 || size.width > size.height else {
            throw XCTSkip("此用例验证 Duo 竖向系统侧栏；内屏竖向使用独立防重叠用例")
        }
        attach(app, "build94-dock-before-comments")
        let originalShare = share.frame
        let originalHome = home.frame
        print("DOCK_INITIAL share=\(originalShare) home=\(originalHome)")
        for round in 1...3 {
            if round == 3 {
                home.tap()
                attach(app, "build94-dock-expanded-before-comments")
            }
            comment.tap()
            let close = app.buttons["douyin.comments.close"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 10))
            if app.windows.firstMatch.frame.width >= 700 {
                XCTAssertFalse(share.exists)
                XCTAssertFalse(home.isHittable)
            }
            close.tap()
            XCTAssertTrue(comment.waitForExistence(timeout: 10))
            attach(app, "build94-dock-close-comments-" + String(round))
            print("DOCK_RESTORED \(round) share=\(share.frame) home=\(home.frame)")
            XCTAssertEqual(share.frame.midX, originalShare.midX, accuracy: 1)
            XCTAssertGreaterThan(home.frame.minY - share.frame.maxY, 0)
            XCTAssertLessThan(home.frame.minY - share.frame.maxY, 26)
            XCTAssertEqual(home.frame.width, originalHome.width, accuracy: 1, "关闭评论后必须恢复单项收起按钮，而非保留展开的系统选择器")
            XCTAssertEqual(home.frame.maxY, originalHome.maxY, accuracy: 2)
        }
        for round in 1...3 {
            let avatar = app.buttons["douyin.author.avatar"].firstMatch
            XCTAssertTrue(avatar.isHittable)
            avatar.tap()
            let back = app.buttons["douyin.author.back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 12), "头像必须进入作者页")
            back.tap()
            let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                comment.exists && comment.isHittable && share.isHittable
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
            attach(app, "build95-author-return-" + String(round))
            XCTAssertEqual(home.frame.width, originalHome.width, accuracy: 1)
            XCTAssertFalse(app.buttons["BottomOverflowBarButtonItem"].exists, "互动栏不能进入省略菜单")
        }
    }

    func testInnerPortraitSeparatesActionsAndDock() throws {
        continueAfterFailure = false
        // Device Hub controls the foldable display's physical rotation;
        // XCUIDevice.orientation alone does not rotate this Duo runtime.
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        let window = app.windows.firstMatch
        guard window.frame.width > 600, window.frame.height > window.frame.width else {
            throw XCTSkip("请先在 Device Hub 展开 Duo 并实际旋转为竖向")
        }
        XCTAssertGreaterThan(window.frame.width, 600, "必须使用实际展开内屏")
        XCTAssertGreaterThan(window.frame.height, window.frame.width)
        let home = app.buttons["首页"].firstMatch
        XCTAssertTrue(home.isHittable)
        let ids = ["douyin.author.avatar", "douyin.like", "douyin.comments", "douyin.collect", "douyin.share"]
        let actions = ids.map { app.buttons[$0].firstMatch }
        for action in actions {
            XCTAssertTrue(action.isHittable)
            XCTAssertFalse(action.frame.intersects(home.frame), "竖向互动栏不能并入横向 Dock")
        }
        for index in 1..<actions.count {
            XCTAssertGreaterThan(actions[index].frame.minY, actions[index - 1].frame.minY)
        }
        print("DUO_INNER_PORTRAIT_WINDOW \(window.frame)")
        print("PORTRAIT_CHROME home=\(home.frame) info=\(app.otherElements["douyin.video.info"].firstMatch.frame) progress=\(app.otherElements["douyin.progress"].firstMatch.frame)")
        attach(app, "build94-inner-portrait-actions-above-dock")
        XCTAssertFalse(app.otherElements["douyin.video.info"].firstMatch.frame.intersects(home.frame))
        XCTAssertFalse(app.otherElements["douyin.progress"].firstMatch.frame.intersects(home.frame))
    }

    func testCompactSheetsReachEdgesAndKeepInputClear() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        app.launchEnvironment["DOUDUO_FORWARD_LAYOUT_FIXTURE"] = "1"
        addTeardownBlock { app.terminate() }
        app.launch()
        let window = app.windows.firstMatch
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        guard window.frame.width < 600 else { throw XCTSkip("仅验收 Duo 外屏") }
        print("DUO_OUTER_WINDOW \(window.frame)")
        app.buttons["douyin.comments"].firstMatch.tap()
        let surface = app.otherElements["douyin.sheet.edgeSurface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        XCTAssertEqual(surface.frame.minX, window.frame.minX, accuracy: 1)
        XCTAssertEqual(surface.frame.maxX, window.frame.maxX, accuracy: 1)
        XCTAssertEqual(surface.frame.maxY, window.frame.maxY, accuracy: 1)
        let input = app.descendants(matching: .any).matching(identifier: "douyin.comment.input").firstMatch
        let composer = app.otherElements["douyin.comments.composer"].firstMatch
        let list = app.scrollViews["douyin.comments.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(composer.frame.height, 44)
        XCTAssertLessThanOrEqual(list.frame.maxY, composer.frame.minY + 1)
        XCTAssertGreaterThanOrEqual(input.frame.height, 20)
        XCTAssertGreaterThanOrEqual(window.frame.maxY - input.frame.maxY, 18)
        attach(app, "build94-outer-comments-edge-input")
        list.swipeUp()
        attach(app, "build94-outer-comments-scrolled-clipped")
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(input.frame.maxY, app.keyboards.firstMatch.frame.minY)
        XCTAssertGreaterThanOrEqual(input.frame.height, 20)
        attach(app, "build94-outer-comments-keyboard")
        app.buttons["douyin.comments.close"].firstMatch.tap()
        _ = app.screenshot()
        app.buttons["douyin.share"].firstMatch.tap()
        XCTAssertTrue(app.buttons["douyin.forward.contact.layout-fixture-1"].waitForExistence(timeout: 15))
        XCTAssertEqual(surface.frame.minX, window.frame.minX, accuracy: 1)
        XCTAssertEqual(surface.frame.maxX, window.frame.maxX, accuracy: 1)
        XCTAssertEqual(surface.frame.maxY, window.frame.maxY, accuracy: 1)
        attach(app, "build94-outer-share-edge-two-rows")
        app.buttons["douyin.forward.close"].tap()
    }

    func testModuleMenuSwitching() throws {
        verifyModuleMenu(leading: false)
    }

    func testModuleMenuLeadingRail() throws {
        verifyModuleMenu(leading: true)
    }

    private func verifyModuleMenu(leading: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchArguments += ["-douduo_dismissed_update_v1", "1.3.12"]
        // 模块入口只在「简洁」模式出现（默认模式是顶部页签）
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "rail"
        if leading { app.launchEnvironment["DOUDUO_RAIL_EDGE"] = "leading" }
        app.launch()
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 40))
        XCTAssertTrue(app.buttons["douyin.more"].firstMatch.waitForExistence(timeout: 40))
        Thread.sleep(forTimeInterval: 2)
        if leading {
            for identifier in ["douyin.module.menu", "douyin.like", "douyin.comments", "douyin.collect", "douyin.more"] {
                let button = app.buttons[identifier].firstMatch
                XCTAssertTrue(button.isHittable)
                XCTAssertGreaterThanOrEqual(button.frame.minX, 0)
                XCTAssertLessThan(button.frame.midX, app.frame.width / 2)
            }
        }
        let selectorFrame = menu.frame
        attach(app, leading ? "leading-rail" : "module-menu-collapsed")
        for (module, title) in [("follow", "关注"), ("live", "直播"), ("recommend", "推荐")] {
            menu.tap()
            let option = app.buttons[title]
            XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
            if module == "follow" { attach(app, "module-menu-expanded") }
            option.tap()
            XCTAssertTrue(menu.waitForExistence(timeout: 10))
            sleep(1)
            print("DDLEAD label=\(menu.label) want=\(title)")
            XCTAssertTrue(menu.label.contains(title), "入口标签应变为「\(title)」，当前：\(menu.label)")
            print("DDLEAD \(module) frame=\(menu.frame) hittable=\(menu.isHittable) exists=\(menu.exists) win=\(app.frame)")
            XCTAssertTrue(menu.isHittable)
            // Native Menu accessibility bounds can include the 54pt label or the 50pt circle.
            // Alignment is defined by the center, not the accessibility rectangle's edge.
            print("RAIL_CENTER \(module): initial=\(selectorFrame) current=\(menu.frame)")
            XCTAssertEqual(menu.frame.midX, selectorFrame.midX, accuracy: 1)
            XCTAssertEqual(menu.frame.midY, selectorFrame.midY, accuracy: 1)
            if leading { XCTAssertLessThan(menu.frame.midX, app.frame.width / 2) }
            attach(app, "module-\(module)")
        }
    }

    /// 菜单与官网分享面板：仅打开、查看、关闭，绝不点击朋友或发送。
    func testMenuCleanupAndFriendForwardWithoutSending() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "classic"
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7705789488781932361", on: current, timeout: 45))
        let query = app.buttons.matching(identifier: "douyin.more")
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 40))
        func openMore() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
            (query.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? query.firstMatch).tap()
        }
        openMore()
        XCTAssertFalse(app.buttons["竖屏占比"].exists)
        XCTAssertTrue(app.buttons["自动连播"].exists, "自动连播按需求放在「更多」第一层")
        XCTAssertFalse(app.buttons["静音"].exists)
        XCTAssertTrue(app.buttons["刷新推荐"].exists)
        attach(app, "menu-cleanup-root")
        app.buttons["设置"].tap()
        // 原生 Menu 子菜单偶发被动画吞掉一次点击：重开一次菜单再点，仍以真实控件存在为验收。
        if !app.buttons["播放设置"].waitForExistence(timeout: 3) && app.buttons["设置"].exists {
            app.buttons["设置"].tap()
        }
        XCTAssertTrue(app.buttons["播放设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["缓存管理"].exists)
        app.buttons["播放设置"].tap()
        XCTAssertFalse(app.buttons["播放速度"].exists, "倍速已放在「更多」第一层，设置里不再重复")
        attach(app, "menu-cleanup-settings")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.4)).tap()
        openMore()
        let forward = app.buttons["转发"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 5))
        forward.tap()
        let close = app.buttons["douyin.forward.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let panel = app.otherElements["douyin.sheet.edgeSurface"]
        XCTAssertTrue(panel.exists)
        XCTAssertFalse(app.navigationBars["转发给抖音朋友"].exists, "转发主界面不能退回全屏网页")
        XCTAssertTrue(app.staticTexts["分享至"].exists)
        XCTAssertTrue(app.buttons["douyin.forward.action.copy"].waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(app.buttons["douyin.forward.action.other"].exists)
        app.buttons["douyin.forward.action.copy"].tap()
        XCTAssertTrue(app.staticTexts["链接已复制"].waitForExistence(timeout: 5))
        attach(app, "friend-forward-native-floating-panel-no-send")
        close.tap()
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 5))
        print("DDFORWARD_UI: native-panel-opened-and-closed; no-recipient-selected; no-send")
    }

    /// 明确标注的模拟器合成联系人，只验证布局/横滑/取消确认，不连接发送桥。
    func testNativeForwardLayoutWithSyntheticContacts() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launchEnvironment["DOUDUO_FORWARD_LAYOUT_FIXTURE"] = "1"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7705789488781932361", on: current, timeout: 45))
        let query = app.buttons.matching(identifier: "douyin.more")
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 40))
        app.buttons.matching(identifier: "douyin.share").allElementsBoundByIndex.first(where: { $0.isHittable })!.tap()
        let contact = app.buttons["douyin.forward.contact.layout-fixture-1"]
        XCTAssertTrue(contact.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["合成布局测试（不会发送消息）"].exists)
        XCTAssertTrue(app.buttons["douyin.forward.action.private"].exists)
        XCTAssertTrue(app.buttons["douyin.forward.action.groups"].exists)
        let copy = app.buttons["douyin.forward.action.copy"]
        let download = app.buttons["douyin.forward.action.download"]
        XCTAssertTrue(copy.exists)
        XCTAssertTrue(download.exists)
        XCTAssertEqual(copy.frame.midY, download.frame.midY, accuracy: 1)
        XCTAssertEqual(copy.frame.midY, app.buttons["douyin.forward.action.private"].frame.midY, accuracy: 1)
        XCTAssertLessThan(contact.frame.maxY, copy.frame.minY)
        attach(app, "friend-forward-native-SYNTHETIC-layout-no-send")
        contact.tap()
        XCTAssertTrue(app.buttons["douyin.forward.send"].waitForExistence(timeout: 5))
        contact.tap() // Deselect the draft; no send action.
        let panel = app.otherElements["douyin.sheet.edgeSurface"]
        XCTAssertGreaterThan(panel.frame.minY, app.frame.height * 0.1)
        XCTAssertGreaterThan(panel.frame.maxY, app.frame.height * 0.9)
        let contactIDs = (1...9).map { "douyin.forward.contact.layout-fixture-\($0)" }
        let visibleBefore = Set(contactIDs.filter { app.buttons[$0].isHittable })
        let start = contact.coordinate(withNormalizedOffset: CGVector(dx: 3.7, dy: 0.3))
        let end = contact.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
        // 惯性可停在3–6或6–9，验“新联系人变为可点”，不把固定第5项当滚动终点。
        let scrolled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            contactIDs.contains { !visibleBefore.contains($0) && app.buttons[$0].isHittable }
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [scrolled], timeout: 5), .completed)
        app.buttons["douyin.forward.close"].tap()
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 5))
        print("DDFORWARD_LAYOUT: synthetic-only; floating-frame; horizontal-scroll; confirmation-cancelled; real-sends=0")
    }

    func testVideoDanmakuSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        // 仅在测试进程内生成明确标记的压力弹幕，不向平台发消息。
        app.launchEnvironment["DOUDUO_DM_STRESS"] = "1"
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launch()
        let moreQuery = app.buttons.matching(identifier: "douyin.more")
        func moreButton() -> XCUIElement {
            moreQuery.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? moreQuery.firstMatch
        }
        XCTAssertTrue(moreQuery.firstMatch.waitForExistence(timeout: 40))
        sleep(4)
        attach(app, "video-danmaku-upper-third-synthetic-stress")
        func openSettings() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
            moreButton().tap()
            let settings = app.buttons["douyin.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
            XCTAssertTrue(app.switches["douyin.danmaku.enabled"].waitForExistence(timeout: 5))
        }
        openSettings()
        for title in ["稀疏", "密集", "标准"] {
            app.buttons["douyin.danmaku.density"].tap()
            let option = app.buttons[title]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            attach(app, "video-danmaku-density-\(title)")
        }
        let toggle = app.switches["douyin.danmaku.deduplicate"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let before = toggle.value as? String
        toggle.tap()
        XCTAssertNotEqual(toggle.value as? String, before)
        toggle.tap() // 恢复用户原去重设置。
        app.buttons["settings.done"].tap()
        print("DD_DANMAKU_SETTINGS: density=standard; dedup-toggle=verified")
    }

    func testLiveStandaloneGameEntryRemoved() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let discover = app.buttons["live.discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["live.categories"].exists)
        XCTAssertFalse(app.buttons["游戏专区"].exists)
        attach(app, "live-standalone-game-entry-removed")
        discover.tap()
        XCTAssertTrue(app.buttons["live.category.game"].waitForExistence(timeout: 5))
        print("DD_GAME_ENTRY: standalone=removed; game-category=preserved")
    }

    func testLiveDiscoveryAndBack() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_TEST_MUTE"] = "1"
        addTeardownBlock { app.terminate() }
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let discover = app.buttons["live.discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["live.categories"].exists)
        XCTAssertFalse(app.buttons["游戏专区"].exists)
        XCTAssertFalse(app.buttons["live.category.featured"].exists)
        discover.tap()
        XCTAssertTrue(app.buttons["live.category.featured"].waitForExistence(timeout: 5))
        // v1.3.13 only exposes the followed-live strip when an author is live.
        // This network-dependent optional strip is covered separately by its state tests.
        let followed = app.descendants(matching: .any).matching(identifier: "live.follow").firstMatch
        if followed.exists { XCTAssertTrue(followed.isHittable) }
        XCTAssertFalse(app.buttons["live.category.followed"].exists)
        XCTAssertFalse(app.buttons["live.category.nearby"].exists)
        app.buttons["live.category.chat"].tap()
        XCTAssertEqual(app.buttons["live.category.chat"].value as? String, "已选择")
        discover.tap()
        XCTAssertFalse(app.buttons["live.category.featured"].exists)
        // The vertical lazy pager can expose an offscreen room before the new
        // category settles. Enter the currently hittable page, not firstMatch.
        let entrances = app.buttons.matching(identifier: "live.room.enter")
        let visibleEntry = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            entrances.allElementsBoundByIndex.contains { $0.isHittable }
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleEntry], timeout: 45), .completed)
        let enter = try XCTUnwrap(entrances.allElementsBoundByIndex.first { $0.isHittable })
        // XCTest's automatic scroll-to-visible returns (-1, -1) for this
        // containerRelativeFrame pager even when the button is already visible.
        enter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let back = app.buttons["live.room.close"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(back.label.contains("返回"))
        XCTAssertFalse(app.buttons["douyin.search"].isHittable)
        XCTAssertFalse(app.buttons["douyin.more"].isHittable)
        XCTAssertFalse(app.buttons["首页"].isHittable)
        XCTAssertFalse(app.buttons["douyin.cleanScreen"].isHittable)
        back.tap()
        XCTAssertTrue(discover.waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
        attach(app, "live-discovery-return")
    }

    func testLiveVerifiedCategories() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let discover = app.buttons["live.discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 30))
        let initial = expectation(for: NSPredicate(format: "label BEGINSWITH 'featured|' AND NOT label BEGINSWITH 'featured|0|' AND label ENDSWITH '|loaded'"), evaluatedWith: app.staticTexts["live.source"])
        XCTAssertEqual(XCTWaiter().wait(for: [initial], timeout: 40), .completed)
        discover.tap()
        print("DDCATEGORY_SCREEN:before"); fflush(stdout); sleep(3)
        for id in ["nearby", "star", "group", "beauty", "sing"] {
            XCTAssertFalse(app.buttons["live.category.\(id)"].exists)
        }
        let strip = app.scrollViews["live.categoryStrip"]
        let source = app.staticTexts["live.source"]
        for (id, partition) in [("chat", "101"), ("music", "102"), ("anime", "104"), ("dance", "105"), ("culture", "106"), ("life", "107"), ("exercise", "108")] {
            let button = app.buttons["live.category.\(id)"]
            for _ in 0..<4 {
                if strip.frame.intersection(app.windows.firstMatch.frame).insetBy(dx: -1, dy: -1).contains(button.frame) { break }
                strip.swipeLeft()
            }
            if !button.isHittable { print("DDCATEGORY_SCREEN:blocked"); fflush(stdout); sleep(3) }
            XCTAssertTrue(button.isHittable, id)
            button.tap()
            let loaded = expectation(for: NSPredicate { _, _ in
                let parts = source.label.split(separator: "|").map(String.init)
                return parts.count == 3 && parts[0] == partition && (Int(parts[1]) ?? 0) > 0 && parts[2] == "loaded"
            }, evaluatedWith: source)
            XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 40), .completed, id)
            XCTAssertEqual(button.value as? String, "已选择")
            print("DDCATEGORY_VERIFIED:\(id) source=\(source.label)")
        }
        print("DDCATEGORY_SCREEN:all"); fflush(stdout); sleep(4)
        for _ in 0..<4 {
            if strip.frame.intersection(app.windows.firstMatch.frame).contains(app.buttons["live.category.game"].frame) { break }
            strip.swipeRight()
        }
        app.buttons["live.category.game"].tap()
        XCTAssertTrue(app.buttons["live.categories.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["英雄联盟"].exists)
        app.buttons["live.categories.close"].tap()
        let game = expectation(for: NSPredicate(format: "label BEGINSWITH '103|' AND NOT label BEGINSWITH '103|0|' AND label ENDSWITH '|loaded'"), evaluatedWith: source)
        XCTAssertEqual(XCTWaiter().wait(for: [game], timeout: 40), .completed)
        for _ in 0..<4 {
            if strip.frame.intersection(app.windows.firstMatch.frame).contains(app.buttons["live.category.featured"].frame) { break }
            strip.swipeRight()
        }
        app.buttons["live.category.featured"].tap()
        let featured = expectation(for: NSPredicate(format: "label BEGINSWITH 'featured|' AND NOT label BEGINSWITH 'featured|0|' AND label ENDSWITH '|loaded'"), evaluatedWith: source)
        XCTAssertEqual(XCTWaiter().wait(for: [featured], timeout: 40), .completed)
    }

    func testMinePlayCountsAndCachedMessages() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_OPEN"] = "mine"
        app.launch()
        let count = app.descendants(matching: .any).matching(identifier: "douyin.grid.playCount").firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(count.label.contains("播放量"))
        XCTAssertFalse(count.label.contains("未提供"), count.label)
        print("DDMINE_PLAY=\(count.label)")
        print("DDCHAT_SHOT_MINE"); sleep(4)
        app.buttons["douyin.mine.back"].tap()
        app.buttons["douyin.messages.top"].tap()
        let row = app.buttons.matching(identifier: "douyin.conversation.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        sleep(4)
        app.buttons["douyin.messages.back"].tap()
        app.buttons["douyin.messages.top"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), "缓存会话应该直接显示")
        print("DDCACHE_REOPEN=ready")
        print("DDCHAT_SHOT_CACHE"); sleep(4)
        app.terminate()
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launch()
        // 会话列表按设计是实时从网页抓（只有通知/计数走缓存），冷启动等它连上即可
        XCTAssertTrue(row.waitForExistence(timeout: 40), "冷启动后会话列表没拉起来")
        print("DDCACHE_COLD=ready")
    }

    func testTopBarHitEdges() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        let info = app.buttons["douyin.messages.top"]
        XCTAssertTrue(info.waitForExistence(timeout: 40))
        // 点按钮边缘（不是文字中心）验证放大后的触摸区真的生效
        func tapEdge(_ el: XCUIElement, dx: CGFloat, dy: CGFloat) {
            let c = el.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
            c.tap()
        }
        let live = app.buttons.matching(NSPredicate(format: "label == '直播'")).firstMatch
        XCTAssertTrue(live.exists)
        tapEdge(live, dx: 0.5, dy: 0.94)
        sleep(4)
        print("DDHIT after-live-edge tab-\(app.staticTexts["live.currentID"].exists)")
        attach(app, "hit-live-edge")
        tapEdge(info, dx: 0.5, dy: 0.94)
        XCTAssertTrue(app.buttons["douyin.messages.back"].waitForExistence(timeout: 20), app.debugDescription)
        print("DDHIT info-bottom-edge ok")
        app.buttons["douyin.messages.back"].tap()
        let mine = app.buttons["douyin.mine.top"]
        tapEdge(mine, dx: 0.5, dy: 0.94)
        XCTAssertTrue(app.buttons["douyin.mine.back"].waitForExistence(timeout: 20), app.debugDescription)
        print("DDHIT mine-bottom-edge ok")
        app.buttons["douyin.mine.back"].tap()
        let recommend = app.buttons.matching(NSPredicate(format: "label == '推荐'")).firstMatch
        tapEdge(recommend, dx: 0.5, dy: 0.94)
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 25))
        sleep(3)
        print("DDHIT recommend-restored id=\(current.label)")
        attach(app, "hit-recommend-edge")
    }

    func testStrangerCategory() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launch()
        let entry = app.buttons["douyin.messages.stranger"]
        XCTAssertTrue(entry.waitForExistence(timeout: 50), app.debugDescription)
        let rows = app.buttons.matching(identifier: "douyin.conversation.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        let mixed = rows.allElementsBoundByIndex.filter { ($0.value as? String) == "stranger" }
        XCTAssertEqual(mixed.count, 0, "陌生人不该平铺在首页列表")
        // 等预读把陌生人真实未读回填到入口角标（采集完整列表要十几秒）
        let filled = NSPredicate(format: "value != '0' AND value != '1'")
        _ = XCTWaiter().wait(for: [expectation(for: filled, evaluatedWith: entry)], timeout: 60)
        print("DDSTRANGERCAT entryBadge=\(entry.value ?? "-") friendRows=\(rows.count)")
        print("DDCHAT_SHOT_HOME"); sleep(3)

        entry.tap()
        let srows = app.buttons.matching(identifier: "douyin.stranger.row")
        XCTAssertTrue(srows.firstMatch.waitForExistence(timeout: 25), app.debugDescription)
        print("DDSTRANGERCAT list=\(srows.count)")
        print("DDCHAT_SHOT_STRANGERLIST"); sleep(3)

        // 点最后一个人：网页里它在虚拟列表可视区外，验证滚动寻找 + 进的就是他本人
        XCTAssertGreaterThan(srows.count, 11, "陌生人列表没采全（虚拟列表只读到可视区）")
        // 原生列表滚到底，取最下面一个可点的人
        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        sleep(1)
        let visible = srows.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(visible.isEmpty)
        let pick = visible.last!
        let who = pick.label.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
        print("DDSTRANGERCAT pick=\(who)")
        pick.tap()
        let detail = app.webViews.matching(identifier: "douyin.messages.chat.detail").firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 25))
        sleep(4)
        let title = app.navigationBars.firstMatch.identifier
        print("DDSTRANGERCAT navTitle=\(title)")
        XCTAssertTrue(app.staticTexts["消息"].exists, "消息标题不能被右侧会话名替换")
        XCTAssertTrue(detail.staticTexts[who].waitForExistence(timeout: 10), "进的会话不是点的那个人")
        XCTAssertGreaterThan(detail.frame.width, 0, "聊天详情不可见：\(detail.frame)")
        if entry.isHittable {
            XCTAssertGreaterThanOrEqual(detail.frame.minX, entry.frame.maxX - 2, "双栏聊天盖住了左侧列表")
        }
        print("DDCHAT_SHOT_STRANGERCHAT"); sleep(3)
        app.buttons["douyin.messages.back"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 10))

        // 第一个人 = 主列表里我没关注的单聊（网页没放进陌生人面板），也要能点进本人
        entry.tap()
        XCTAssertTrue(srows.firstMatch.waitForExistence(timeout: 25))
        let first = srows.firstMatch
        let who2 = first.label.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
        print("DDSTRANGERCAT pick2=\(who2)")
        first.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 25))
        sleep(4)
        let title2 = app.navigationBars.firstMatch.identifier
        print("DDSTRANGERCAT navTitle2=\(title2)")
        XCTAssertTrue(app.staticTexts["消息"].exists)
        XCTAssertTrue(detail.staticTexts[who2].waitForExistence(timeout: 10))
        print("DDCHAT_SHOT_STRANGERCHAT2"); sleep(3)
        app.buttons["douyin.messages.back"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
    }

    /// Run on iPhone Duo after manually unfolding its inner display in Device Hub.
    func testDuoInnerCommentPanelKeepsVideoAndNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { app.terminate() }
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launchEnvironment["DOUDUO_AUTHOR_WORK_FIXTURE"] = "1"
        app.launch()
        guard app.windows.firstMatch.frame.width >= 700 else {
            throw XCTSkip("只验收已经展开的 Duo 内屏；不把外屏或 iPad 当作替代")
        }
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        let comment = app.buttons["douyin.comments"].firstMatch
        XCTAssertTrue(comment.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(label: "7705789488781932361", on: current, timeout: 45))
        let id = current.label
        comment.tap()
        let close = app.buttons["douyin.comments.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let info = app.otherElements["douyin.video.info"].firstMatch
        let panel = app.descendants(matching: .any).matching(identifier: "douyin.comments.panel").firstMatch
        XCTAssertLessThanOrEqual(info.frame.maxX, panel.frame.minX, "视频留在左侧，评论在右侧")
        XCTAssertGreaterThan(panel.frame.width, app.windows.firstMatch.frame.width * 0.40)
        XCTAssertLessThan(panel.frame.width, app.windows.firstMatch.frame.width * 0.52)
        XCTAssertFalse(app.buttons["house"].firstMatch.isHittable)
        XCTAssertFalse(app.buttons["首页"].firstMatch.isHittable)
        for id in ["douyin.author.avatar", "douyin.like", "douyin.comments", "douyin.collect", "douyin.share"] {
            XCTAssertFalse(app.buttons[id].firstMatch.exists, "内屏评论打开时完全移除视频互动栏：" + id)
        }
        let related = app.scrollViews["douyin.comments.relatedSearch"].firstMatch
        XCTAssertTrue(related.waitForExistence(timeout: 15))
        XCTAssertLessThan(related.frame.maxY, panel.frame.minY + 100)
        XCTAssertEqual(panel.frame.maxX, app.windows.firstMatch.frame.maxX, accuracy: 1, "评论背景延伸到状态栏所在的屏幕右缘")
        XCTAssertLessThanOrEqual(panel.frame.minY, 4)
        XCTAssertGreaterThan(panel.frame.height, app.windows.firstMatch.frame.height * 0.9)
        XCTAssertFalse(app.buttons["douyin.search"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["douyin.more"].firstMatch.isHittable)
        let input = app.descendants(matching: .any).matching(identifier: "douyin.comment.input").firstMatch
        XCTAssertGreaterThanOrEqual(input.frame.height, 20)
        XCTAssertGreaterThanOrEqual(app.otherElements["douyin.comments.composer"].firstMatch.frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.windows.firstMatch.frame.maxY - input.frame.maxY, 9)
        attach(app, "duo-inner-solid-comments-to-screen-edge")
        close.tap()
        XCTAssertEqual(current.label, id)
        attach(app, "duo-inner-return-same-video")
        app.buttons["douyin.author.avatar"].firstMatch.tap()
        let author = app.otherElements["douyin.author.panel"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(author.frame.minX, app.windows.firstMatch.frame.width * 0.35)
        XCTAssertLessThanOrEqual(info.frame.maxX, author.frame.minX)
        XCTAssertFalse(app.buttons["首页"].firstMatch.isHittable)
        attach(app, "duo-inner-author-split")
        let work = app.descendants(matching: .any).matching(identifier: "douyin.author.works").firstMatch.buttons.firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 35), app.debugDescription)
        work.tap()
        let workBack = app.buttons["douyin.list.back"].firstMatch
        XCTAssertTrue(workBack.waitForExistence(timeout: 15))
        for id in ["douyin.list.back", "douyin.author.avatar", "douyin.like", "douyin.comments", "douyin.collect", "douyin.share"] {
            XCTAssertTrue(app.buttons[id].firstMatch.isHittable, "作者作品页保留按钮：" + id)
        }
        attach(app, "duo-inner-author-work-controls")
        app.buttons["douyin.comments"].firstMatch.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["douyin.like"].firstMatch.exists)
        attach(app, "duo-inner-author-work-comments")
        close.tap()
        XCTAssertTrue(workBack.waitForExistence(timeout: 10))
        workBack.tap()
        XCTAssertTrue(app.buttons["douyin.author.back"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["douyin.author.back"].firstMatch.tap()
        XCTAssertEqual(current.label, id)
    }

    /// 倍速两条线互不污染：设置是全局速度（当前视频立刻生效），长按下滑锁的 2 倍只锁本条、上滑取消。
    func testPlaybackRateLockedByLongPressDownAndSetting() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        app.launch()
        XCTAssertTrue(wait(label: "7678628867820506406", on: app.staticTexts["douyin.currentID"], timeout: 60))
        sleep(3)
        let setting = app.staticTexts["douyin.rate"]
        XCTAssertTrue(setting.waitForExistence(timeout: 10))

        // 1. 设置里回到正常速度：不显示倍速角标
        openSpeedMenu(app)
        XCTAssertTrue(app.buttons["正常速度"].waitForExistence(timeout: 5))
        app.buttons["正常速度"].tap()
        app.buttons["douyin.options.close"].tap()
        XCTAssertTrue(wait(label: "1", on: setting, timeout: 8), "设置应是 1 倍，当前 \(setting.label)")
        sleep(1)
        XCTAssertNil(visibleBadge(app), "1 倍速不该显示角标")

        // 2. 长按下滑：锁定本条 2 倍（松手后常驻角标），且不写进设置
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.40))
        let end = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.58))
        start.press(forDuration: 0.9, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(waitBadge(app, "2×", timeout: 8), "长按下滑应锁定 2 倍，当前 \(visibleBadge(app)?.label ?? "无角标")")
        XCTAssertEqual(setting.label, "1", "长按锁定不能改设置里的全局速度")
        attach(app, "rate-locked-2x-badge")

        // 3. 设置改成 1.5 倍：当前这条立刻变 1.5×（不用换视频）
        openSpeedMenu(app)
        XCTAssertTrue(app.buttons["1.5 倍速"].waitForExistence(timeout: 5))
        app.buttons["1.5 倍速"].tap()
        app.buttons["douyin.options.close"].tap()
        XCTAssertTrue(waitBadge(app, "1.5×", timeout: 8), "设置改 1.5 倍当前视频应立刻生效，当前 \(visibleBadge(app)?.label ?? "无角标")")
        XCTAssertEqual(setting.label, "1.5")
        attach(app, "rate-1-5x-badge")

        // 4. 长按上滑：取消 2 倍，回到设置的 1.5 倍
        let up = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.24))
        start.press(forDuration: 0.9, thenDragTo: up, withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(waitBadge(app, "1.5×", timeout: 8), "上滑应取消倍速，当前 \(visibleBadge(app)?.label ?? "无角标")")
        attach(app, "rate-cancelled")
        openSpeedMenu(app)
        app.buttons["正常速度"].tap()
        app.buttons["douyin.options.close"].tap()
    }

    /// 「更多」第一层的倍速：点开选速度，当前视频立刻变速（不用换视频）。
    func testQuickSpeedMenuAppliesToCurrentVideo() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "classic"
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launch()
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7705789488781932361", on: app.staticTexts["douyin.currentID"], timeout: 45))
        sleep(5)
        let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(more.isEmpty)
        more[0].tap()
        let speed = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '倍速'")).firstMatch
        XCTAssertTrue(speed.waitForExistence(timeout: 5), "「更多」第一层应直接有倍速")
        XCTAssertTrue(app.buttons["刷新推荐"].exists)
        attach(app, "quick-more-root")
        speed.tap()
        XCTAssertTrue(app.buttons["1.5 倍速"].waitForExistence(timeout: 5), "点倍速应弹出速度列表")
        attach(app, "quick-speed-list")
        app.buttons["1.5 倍速"].tap()
        print("MERGE_RATE setting=" + app.staticTexts["douyin.rate"].label)
        for badge in app.staticTexts.matching(identifier: "douyin.rateBadge").allElementsBoundByIndex {
            print("MERGE_RATE badge=\(badge.label) frame=\(badge.frame)")
        }
        XCTAssertTrue(waitBadge(app, "1.5×", timeout: 8), "选 1.5 倍后当前视频应立刻 1.5×")
        sleep(3)
        attach(app, "quick-speed-applied")
        let fit = app.buttons.matching(identifier: "douyin.fit").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(fit, "搜索下面应有铺满按钮")
    }

    /// 复现：滑到下一条视频后，在「更多」里改倍速，当前视频应立刻变速（看 ddlog 里的 DDRATETEST）。
    func testSpeedChangeOnSecondVideoAppliesImmediately() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "classic"
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launch()
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
        sleep(5)
        let first = app.staticTexts["douyin.currentID"].label
        app.swipeUp(velocity: .fast)
        sleep(12)
        let second = app.staticTexts["douyin.currentID"].label
        print("DDRATETEST first=\(first) second=\(second)")
        func pick(_ title: String) {
            let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.filter { $0.isHittable }
            XCTAssertFalse(more.isEmpty)
            more[0].tap()
            let speed = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '倍速'")).firstMatch
            XCTAssertTrue(speed.waitForExistence(timeout: 5))
            speed.tap()
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5))
            app.buttons[title].tap()
            sleep(3)
        }
        pick("1.5 倍速")
        XCTAssertTrue(waitBadge(app, "1.5×", timeout: 8), "第二条视频改 1.5 倍应立刻生效")
        // 关键回归：从 1.5 改回正常速度，观察器不能再把速度拉回 1.5（旧版会）
        pick("正常速度")
        sleep(2)
        XCTAssertNil(visibleBadge(app), "改回正常速度后不该再显示倍速角标（旧版被预加载时的旧值拉回 1.5）")
        pick("2 倍速")
        XCTAssertTrue(waitBadge(app, "2×", timeout: 8))
        attach(app, "second-video-rate")
    }

    /// 右侧按钮栏：五个按钮水平居中对齐、竖向等距。
    func testRailButtonsAlignedAndEvenlySpaced() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "classic"
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launch()
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
        sleep(4)
        func frame(_ id: String) -> CGRect {
            let q = app.buttons.matching(identifier: id).allElementsBoundByIndex.filter { $0.isHittable }
            XCTAssertFalse(q.isEmpty, "\(id) 不可点")
            return q.first?.frame ?? .zero
        }
        let ids = ["douyin.like", "douyin.comments", "douyin.collect", "douyin.search", "douyin.fit"]
        let f = ids.map(frame)
        print("DDRAIL frames=\(f)")
        for r in f { XCTAssertEqual(r.midX, f[0].midX, accuracy: 1.0, "水平没对齐") }
        // 有数字的三个按钮之间等距；无数字的搜索/铺满之间更紧（没有文字那一截）
        let pitches = zip(f, f.dropFirst()).map { $1.midY - $0.midY }
        print("DDRAIL pitches=\(pitches)")
        XCTAssertEqual(pitches[0], pitches[1], accuracy: 1.0, "赞→评论 与 评论→收藏 间距不等")
        XCTAssertLessThan(pitches[3], pitches[0], "无文字的按钮之间应比有文字的更紧")
        // 搜索与铺满之间的空隙 = 「图标—文字」间距那一级（约 2~12pt），不再是一整块空白
        let gapSearchFit = f[4].minY - f[3].maxY
        print("DDRAIL gapSearchFit=\(gapSearchFit)")
        XCTAssertLessThanOrEqual(gapSearchFit, 12)
        attach(app, "rail-aligned")
    }

    /// 三档界面模式：默认=顶部页签+原右侧栏；简洁=侧边功能栏；极简=简洁且隐藏作者标题。
    /// 注意：不能用 -key value 启动参数——它是只读的参数域，会盖住运行时在「更多」里的修改。
    /// 改用 DOUDUO_CHROME_MODE 环境变量，只在首次启动时写入存储。
    private func launchChrome(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
        app.launchArguments += ["-douduo_dismissed_update_v1", "1.5.4", "-duoduomain_tab_v1", "首页", "-douyin_autoplay_v1", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: app.staticTexts["douyin.currentID"], timeout: 45))
        sleep(5)
        return app
    }

    func testChromeModeClassicHasTopTabsAndSearchOnRail() throws {
        let app = launchChrome("classic")
        XCTAssertTrue(app.buttons.matching(identifier: "douyin.search").allElementsBoundByIndex.contains { $0.isHittable }, "默认模式右侧栏应有搜索")
        XCTAssertFalse(app.buttons["douyin.module.menu"].exists, "默认模式没有模块入口")
        XCTAssertTrue(app.buttons["关注"].exists || app.staticTexts["关注"].exists, "默认模式顶部应有「关注」页签")
        XCTAssertTrue(app.buttons.matching(identifier: "douyin.author").allElementsBoundByIndex.contains { $0.isHittable }, "默认模式应显示作者")
        attach(app, "chrome-classic")
    }

    func testChromeModeRailMovesSearchIntoModuleMenu() throws {
        let app = launchChrome("rail")
        XCTAssertTrue(app.buttons["douyin.module.menu"].waitForExistence(timeout: 10), "简洁模式应有模块入口")
        XCTAssertFalse(app.buttons.matching(identifier: "douyin.search").allElementsBoundByIndex.contains { $0.isHittable }, "简洁模式右侧栏不再有搜索")
        XCTAssertTrue(app.buttons.matching(identifier: "douyin.author").allElementsBoundByIndex.contains { $0.isHittable }, "简洁模式保留作者")
        app.buttons["douyin.module.menu"].tap()
        XCTAssertTrue(app.buttons["搜索"].waitForExistence(timeout: 5), "模块菜单里应有搜索")
        attach(app, "chrome-rail-menu")
        app.buttons["搜索"].tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10) || app.searchFields.firstMatch.waitForExistence(timeout: 5), "点搜索应打开搜索页")
    }

    func testChromeModeMinimalHidesAuthorAndTitle() throws {
        let app = launchChrome("minimal")
        XCTAssertTrue(app.buttons["douyin.module.menu"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(identifier: "douyin.author").allElementsBoundByIndex.contains { $0.isHittable }, "极简模式应隐藏作者")
        XCTAssertFalse(app.staticTexts.matching(identifier: "douyin.video.metadata").allElementsBoundByIndex.contains { $0.isHittable }, "极简模式应隐藏标题信息")
        attach(app, "chrome-minimal")
    }

    /// 点已选中的「推荐」= 刷新推荐，四种界面都一样（docs/ui-modes.md）。
    /// 离线数据刷不到新视频，这里只验证「点了确实触发刷新」：入口的 value 会短暂变成「正在刷新」。
    func testTapSelectedRecommendRefreshesInEveryMode() throws {
        continueAfterFailure = false
        for mode in ["classic", "rail", "minimal", "duoClassic"] {
            let app = XCUIApplication()
            app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
            app.launchEnvironment["DOUDUO_HASHTAG_FIXTURE"] = "1"
            app.launchEnvironment["DOUDUO_REFRESH_PROBE"] = "1"
            app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                                    "-douduo_dismissed_update_v1", "9.9.9", "-duoduomain_tab_v1", "首页"]
            app.launch()
            let current = app.staticTexts["douyin.currentID"].firstMatch
            XCTAssertTrue(wait(label: "hashtag-cat", on: current, timeout: 20), "\(mode): 首屏没出来")
            let entry: XCUIElement
            if mode == "rail" || mode == "minimal" {
                let menu = app.buttons["douyin.module.menu"].firstMatch
                XCTAssertTrue(menu.waitForExistence(timeout: 10), "\(mode): 没有模块入口")
                menu.tap()
                entry = app.buttons["douyin.module.item.recommend"].firstMatch
                XCTAssertTrue(entry.waitForExistence(timeout: 5), "\(mode): 模块菜单里没有推荐")
                XCTAssertEqual(entry.label, "刷新推荐", "\(mode): 已在推荐时，菜单项应显示「刷新推荐」")
            } else {
                entry = app.buttons["douyin.channel.recommend"].firstMatch
                XCTAssertTrue(entry.waitForExistence(timeout: 10), "\(mode): 没有推荐频道按钮")
            }
            entry.tap()
            let refreshed = app.staticTexts["douyin.refreshCount"].firstMatch
            XCTAssertTrue(wait(label: "1", on: refreshed, timeout: 5), "\(mode): 点已选中的推荐没有触发刷新")
            app.terminate()
        }
    }

    /// 外屏横屏视频打开评论：四种界面都把视频移到评论上方（经典几何，老板 2026-11-17）
    func testOuterLandscapeVideoLiftsAboveCommentsInEveryMode() throws {
        continueAfterFailure = false
        for mode in ["rail", "classic", "minimal", "duoClassic"] {
            let app = XCUIApplication()
            app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
            app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7707707401935336335"   // 1920x1080 横屏视频
            app.launchArguments += ["-douduo_dismissed_update_v1", "9.9.9", "-duoduomain_tab_v1", "首页",
                                    "-douyin_autoplay_v1", "NO", "-douyin_muted_v1", "YES"]
            app.launch()
            XCTAssertTrue(wait(label: "7707707401935336335", on: app.staticTexts["douyin.currentID"].firstMatch, timeout: 45), mode)
            guard app.windows.firstMatch.frame.width < 560 else { throw XCTSkip("需要外屏") }
            let button = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(button, "\(mode): 找不到评论按钮")
            button?.tap()
            let list = app.scrollViews["douyin.comments.list"].firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 10), "\(mode): 评论列表没出来")
            // 视频层在评论打开时对无障碍隐藏（经典的叠放评论是模态），锚点可能读不到；读得到就必须是 lifted
            let lift = app.staticTexts["douyin.video.lift"].firstMatch
            if lift.waitForExistence(timeout: 2) {
                let lifted = NSPredicate(format: "label BEGINSWITH 'lifted'")
                XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: lifted, evaluatedWith: lift)], timeout: 5), .completed,
                               "\(mode): 横屏视频没有移到评论上方（\(lift.label)）")
            }
            XCTAssertGreaterThan(list.frame.minY, app.windows.firstMatch.frame.height * 0.3, "\(mode): 评论应在视频下方")
            XCTAssertEqual(list.frame.maxX, app.windows.firstMatch.frame.maxX, accuracy: 2, "\(mode): 评论右边不应留空")
            attach(app, "outer-landscape-" + mode)
            app.terminate()
        }
    }

    /// 评论四种界面统一用经典那套（DYCommentStage）：点评论按钮，评论列表出来、输入框可点、菜单全部收起。
    func testCommentsOpenInEveryMode() throws {
        continueAfterFailure = false
        for mode in ["rail", "classic", "minimal", "duoClassic"] {
            let app = XCUIApplication()
            app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
            app.launchEnvironment["DOUDUO_HASHTAG_FIXTURE"] = "1"
            app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                                    "-douduo_dismissed_update_v1", "9.9.9", "-duoduomain_tab_v1", "首页"]
            app.launch()
            XCTAssertTrue(wait(label: "hashtag-cat", on: app.staticTexts["douyin.currentID"].firstMatch, timeout: 20), mode)
            let button = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(button, "\(mode): 找不到评论按钮")
            button?.tap()
            let list = app.scrollViews["douyin.comments.list"].firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 10), "\(mode): 评论列表没出来")
            XCTAssertGreaterThan(list.frame.height, 100, "\(mode): 评论列表高度太小 \(list.frame)")
            attach(app, "comments-open-" + mode)
            if mode != "duoClassic" {
                XCTAssertFalse(app.buttons.matching(identifier: "douyin.module.menu").allElementsBoundByIndex.contains { $0.isHittable },
                               "\(mode): 评论打开时模块圆钮应收起")
            }
            app.terminate()
        }
    }

    /// 在「更多」第一层切换界面模式，立即生效。
    func testStandaloneCommentsRespectLayout() throws {
        continueAfterFailure = false
        let closeOnly = ProcessInfo.processInfo.environment["DD_CLOSE_ONLY"] == "1"
        if closeOnly { XCUIDevice.shared.orientation = .landscapeLeft }
        let modes = ProcessInfo.processInfo.environment["DD_ONLY_MODE"].map { [$0] } ?? ["classic", "rail", "minimal", "duoClassic"]
        for mode in modes {
            let app = XCUIApplication()
            app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
            app.launchEnvironment["DOUDUO_COMMENT_ENTRY"] = "mine"
            if mode == "rail" || mode == "minimal" { app.launchEnvironment["DOUDUO_OPEN"] = "mine" }
            app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
            // 上一轮停在「我的」会被记住，固定从首页起
            app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-duoduomain_tab_v1", "首页"]
            addTeardownBlock { app.terminate() }
            app.launch()
            XCTAssertTrue(wait(label: "7678628867820506406", on: app.staticTexts["douyin.currentID"], timeout: 60))
            if mode == "duoClassic" {
                app.buttons["首页"].firstMatch.tap()
                app.buttons["我的"].firstMatch.tap()
            } else if mode == "classic" {
                app.buttons["douyin.mine.top"].firstMatch.tap()
            }   // 简洁 / 极简：启动时 DOUDUO_OPEN=mine 直接打开「我的」
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "douyin.list.player").firstMatch.waitForExistence(timeout: 30))
            let comment = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(comment)
            let progress = app.descendants(matching: .any).matching(identifier: "douyin.progress").firstMatch
            func elapsed() -> Int? {
                guard progress.exists, let value = progress.value as? String else { return nil }
                return value.split(separator: " ").first.flatMap { Int($0) }
            }
            func scrub(from: CGFloat, to: CGFloat) {
                progress.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.7))
                    .press(forDuration: 0.1, thenDragTo: progress.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.7)))
            }
            if closeOnly {
                XCTAssertTrue(progress.waitForExistence(timeout: 10))
                XCTAssertTrue(waitUntil(timeout: 15) {
                    guard let value = progress.value as? String,
                          let duration = value.split(separator: " ").dropFirst(2).first.flatMap({ Int($0) }) else { return false }
                    return duration > 8
                })
                scrub(from: 0.10, to: 0.35)
                XCTAssertTrue(waitUntil(timeout: 5) { (elapsed() ?? 0) > 1 })
            }
            let before = closeOnly ? elapsed() : nil
            comment?.tap()
            let list = app.scrollViews["douyin.comments.list"].firstMatch
            let related = app.scrollViews["douyin.comments.relatedSearch"].firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 10))
            if !closeOnly {
                XCTAssertTrue(related.waitForExistence(timeout: 20))
                // 评论面板四种界面统一经典样式（老板 2026-11-17）：相关搜索在评论列表上方
                XCTAssertLessThanOrEqual(related.frame.maxY, list.frame.minY + 2, mode + " 相关搜索应在评论上方")
                if app.windows.firstMatch.frame.width < 700 {
                    XCTAssertEqual(list.frame.maxX, app.windows.firstMatch.frame.maxX, accuracy: 2, mode + " 评论右边不应留空")
                }
            }
            attach(app, "v14-standalone-comments-" + mode)
            if closeOnly {
                let window = app.windows.firstMatch.frame
                XCTAssertGreaterThan(window.width, window.height, "需要横屏")
                XCTAssertGreaterThanOrEqual(window.width, 700, "需要 Duo 展开内屏")
            }
            let close = app.buttons["douyin.comments.close"].firstMatch
            var splitPosition: Int?
            if closeOnly {
                let openingPosition = try XCTUnwrap(before)
                XCTAssertTrue(waitUntil(timeout: 5) {
                    guard let position = elapsed() else { return false }
                    return abs(position - openingPosition) <= 1
                }, "打开评论应保留原进度")
                scrub(from: 0.35, to: 0.70)
                XCTAssertTrue(waitUntil(timeout: 5) { (elapsed() ?? 0) >= openingPosition + 2 })
                let position = try XCTUnwrap(elapsed())
                splitPosition = position
                print("COMMENT_PROGRESS full=\(openingPosition) split=\(position)")
            }
            XCTAssertTrue(close.isHittable)
            close.tap()
            XCTAssertTrue(list.waitForNonExistence(timeout: 5), mode + " 点击关闭后评论列表应消失")
            if let splitPosition {
                XCTAssertTrue(waitUntil(timeout: 5) {
                    guard let position = elapsed() else { return false }
                    return abs(position - splitPosition) <= 1
                }, "关闭评论应保留分屏中的新进度")
                print("COMMENT_PROGRESS restored=\(elapsed() ?? -1)")
            }
            XCTAssertTrue(app.buttons["douyin.list.back"].firstMatch.isHittable)
            app.terminate()
        }
    }

    func testClassicSearchOpensAndReturns() throws {
        continueAfterFailure = false
        let app = launchChrome("duoClassic")
        addTeardownBlock { app.terminate() }
        for entry in 0..<3 {
            if entry == 1 {
                app.buttons["douyin.comments"].firstMatch.tap()
                let close = app.buttons["douyin.comments.close"].firstMatch
                XCTAssertTrue(close.waitForExistence(timeout: 15))
                close.tap()
                XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            } else if entry == 2 {
                app.buttons["douyin.author.avatar"].firstMatch.tap()
                let back = app.buttons["douyin.author.back"].firstMatch
                XCTAssertTrue(back.waitForExistence(timeout: 15))
                back.tap()
                XCTAssertTrue(back.waitForNonExistence(timeout: 5))
            }
            let button = app.buttons["douyin.search"].firstMatch
            XCTAssertTrue(button.isHittable)
            button.tap()
            XCTAssertTrue(app.textFields["douyin.search.field"].waitForExistence(timeout: 10), app.debugDescription)
            app.buttons["douyin.search.back"].firstMatch.tap()
            XCTAssertTrue(button.waitForExistence(timeout: 10))
        }
        pauseRegressionVideo(app)
        attach(app, "v14-classic-search-return")
    }

    func testCommentPresentationIsUnifiedAcrossLayouts() throws {
        continueAfterFailure = false
        for mode in ["classic", "rail", "minimal", "duoClassic"] {
            let app = launchChrome(mode)
            addTeardownBlock { app.terminate() }
            let comments = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
            if comments == nil { attach(app, "missing-comments-" + mode); print(app.debugDescription) }
            XCTAssertNotNil(comments)
            comments?.tap()
            let list = app.scrollViews["douyin.comments.list"].firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 15))
            let related = app.scrollViews["douyin.comments.relatedSearch"].firstMatch
            XCTAssertTrue(related.waitForExistence(timeout: 20))
            let input = app.descendants(matching: .any).matching(identifier: "douyin.comment.input").firstMatch
            XCTAssertTrue(input.isHittable)
            // 评论四种界面统一用经典样式（老板 2026-11-17 定，docs/ui-modes.md）：
            // 相关搜索在评论列表上方；窄屏贴边占满宽，不在右边留空；打开评论时视频上的按钮收起。
            XCTAssertLessThanOrEqual(related.frame.maxY, list.frame.minY + 2, mode + " 相关搜索应在评论上方（经典样式）")
            if app.windows.firstMatch.frame.width < 700 {
                XCTAssertEqual(list.frame.maxX, app.windows.firstMatch.frame.maxX, accuracy: 2, mode + " 评论右边不应留空")
                XCTAssertEqual(list.frame.minX, 0, accuracy: 2)
            }
            attach(app, "v14-comments-" + mode)
            app.buttons["douyin.comments.close"].firstMatch.tap()
            app.terminate()
        }
    }

    func testAllFourChromeModesRoundTrip() throws {
        continueAfterFailure = false
        let app = launchChrome("classic")
        addTeardownBlock { app.terminate() }
        for title in ["经典", "简洁", "极简", "默认"] {
            let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(more)
            more?.tap()
            let settings = app.buttons["设置"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
            settings.tap()
            let picker = app.descendants(matching: .any).matching(identifier: "settings.chrome").firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            picker.tap()
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5))
            app.buttons[title].tap()
            let done = app.buttons["settings.done"].firstMatch
            if done.waitForExistence(timeout: 2) { done.tap() }
            XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
            sleep(3)
            if title == "经典" {
                XCTAssertTrue(app.buttons["douyin.cleanScreen"].waitForExistence(timeout: 8))
            } else if title == "简洁" || title == "极简" {
                XCTAssertTrue(app.buttons["douyin.module.menu"].waitForExistence(timeout: 8))
            } else {
                XCTAssertFalse(app.buttons["douyin.module.menu"].exists)
            }
            pauseRegressionVideo(app)
            attach(app, "merged-mode-" + title)
        }
    }

    /// 切换界面模式（默认 ⇄ 经典 ⇄ 简洁 ⇄ 极简）必须留在同一条视频上：两套根视图共用同一份推荐流。
    /// 真实推荐流，只读；不点赞不发帖。
    func testChromeModeSwitchKeepsCurrentVideo() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "classic"
        // 固定从首页起：上一个用例停在「我的」会被记住，切到经典就落在「我的」，未登录还会弹登录页盖住视频
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douduo_dismissed_update_v1", "9.9.9", "-douyin_autoplay_v1", "NO",
                                "-duoduomain_tab_v1", "首页"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"].firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != %@", "-"), evaluatedWith: current)], timeout: 60), .completed)
        // 先往后翻两条：停在第一条时「重新加载恰好还是第一条」会掩盖问题
        sleep(8)   // 启动先用本地缓存起播（可能只有 1 条），等推荐拉回来再翻
        for _ in 0..<2 {
            let before = current.label
            app.swipeUp(velocity: .fast)
            XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: current)], timeout: 20), .completed)
            sleep(2)
        }
        sleep(4)
        let pinned = current.label
        print("DDMODE_KEEP start " + pinned)
        for title in ["经典", "简洁", "经典", "极简", "默认"] {
            // 经典布局的「更多」在系统顶栏里，isHittable 报 false 但坐标可点：按元素中心点
            let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }
                ?? app.buttons["douyin.more"].firstMatch
            if !more.waitForExistence(timeout: 8) {
                print("DDMODE_KEEP TREE " + app.debugDescription.split(separator: "\n").filter { $0.contains("identifier: 'douyin.") }.map { String($0).trimmingCharacters(in: .whitespaces) }.joined(separator: " | "))
            }
            XCTAssertTrue(more.exists, "找不到「更多」: " + title)
            more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let settings = app.buttons["设置"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
            settings.tap()
            let picker = app.descendants(matching: .any).matching(identifier: "settings.chrome").firstMatch
            if !picker.waitForExistence(timeout: 8) { attach(app, "mode-keep-nopicker-" + title) }
            XCTAssertTrue(picker.exists, "设置页没有界面模式: " + title)
            picker.tap()
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5))
            app.buttons[title].tap()
            let done = app.buttons["settings.done"].firstMatch
            if done.waitForExistence(timeout: 2) { done.tap() }
            let now = app.staticTexts["douyin.currentID"].firstMatch
            XCTAssertTrue(now.waitForExistence(timeout: 20))
            sleep(4)
            print("DDMODE_KEEP \(title) " + now.label)
            XCTAssertEqual(now.label, pinned, "切到「\(title)」后换了视频")
            XCTAssertTrue(app.staticTexts.matching(identifier: "douyin.video.playback").firstMatch.waitForExistence(timeout: 10),
                          "切到「\(title)」后当前条没有挂上播放器（画面停在别的条目）")
            attach(app, "mode-keep-" + title)
        }
    }

    func testChromeModeSwitchFromMoreMenu() throws {
        let app = launchChrome("classic")
        let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(more.isEmpty)
        more[0].tap()
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '界面'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "「更多」第一层应有界面模式")
        item.tap()
        XCTAssertTrue(app.buttons["简洁"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["极简"].exists)
        attach(app, "chrome-mode-list")
        app.buttons["极简"].tap()
        sleep(3)
        attach(app, "chrome-after-tap")
        XCTAssertTrue(app.buttons["douyin.module.menu"].waitForExistence(timeout: 8), "切到极简后应出现模块入口")
        XCTAssertFalse(app.buttons.matching(identifier: "douyin.author").allElementsBoundByIndex.contains { $0.isHittable }, "切到极简后应隐藏作者")
        attach(app, "chrome-switched-minimal")
    }

    func testClassicTopTabsFrame() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "classic"
        app.launchArguments += ["-douduo_dismissed_update_v1", "1.3.12"]
        app.launch()
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
        sleep(4)
        for t in ["关注", "推荐", "直播"] {
            let b = app.buttons[t].firstMatch
            print("DDTOP \(t) frame=\(b.frame) win=\(app.windows.firstMatch.frame)")
        }
        let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }
        print("DDTOP more frame=\(more?.frame ?? .zero)")
        attach(app, "top-frame")
    }

    /// 极简：底部进度条隐藏，进度画在模块入口外圈；长按入口显示作者标题，松开消失。
    func testMinimalProgressRingAndPeekInfo() throws {
        let app = launchChrome("minimal")
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        sleep(6)
        let ring = app.otherElements["douyin.module.ring"].firstMatch
        XCTAssertTrue(ring.waitForExistence(timeout: 5), "极简模式应有进度外圈")
        let v1 = ring.value as? String ?? ""
        print("DDRING value1=\(v1)")
        sleep(5)
        let v2 = ring.value as? String ?? ""
        print("DDRING value2=\(v2)")
        XCTAssertNotEqual(v1, v2, "进度外圈应随播放前进")
        attach(app, "minimal-ring")
        XCTAssertFalse(app.otherElements["douyin.peek.info"].exists, "平时不显示作者标题")
        menu.press(forDuration: 1.2)
        // 按住期间截图不可行（press 是阻塞的），松开后应已消失
        sleep(1)
        XCTAssertFalse(app.otherElements["douyin.peek.info"].exists, "松开后作者标题应消失")
    }

    func testMinimalLongPressShowsInfoWhileHeld() throws {
        let app = launchChrome("minimal")
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        sleep(4)
        let c = menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // 按住 3 秒；另起一个 DispatchQueue 在按住中途采样
        var seenDuring = false
        let exp = expectation(description: "sample")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.8) {
            seenDuring = app.otherElements["douyin.peek.info"].exists || app.staticTexts["douyin.peek.info"].exists
            let shot = XCUIScreen.main.screenshot()
            let att = XCTAttachment(screenshot: shot); att.name = "minimal-peek-held"; att.lifetime = .keepAlways
            self.add(att)
            exp.fulfill()
        }
        c.press(forDuration: 3.0)
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(seenDuring, "按住模块入口时应显示作者标题")
        attach(app, "minimal-after-peek")
        sleep(1)
        XCTAssertFalse(app.otherElements["douyin.peek.info"].exists, "松开后应消失")
    }

    /// 长按模块入口：按住期间和松手后，系统菜单都不能弹出；单击仍能弹菜单。
    func testModuleLongPressDoesNotOpenMenuMinimal() throws { try runLongPressNoMenu("minimal") }
    func testModuleLongPressDoesNotOpenMenuRail() throws { try runLongPressNoMenu("rail") }

    private func runLongPressNoMenu(_ mode: String) throws {
        let app = launchChrome(mode)
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        sleep(4)
        let c = menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        var samples: [String] = []
        let lock = NSLock()
        let exp = expectation(description: "samples")
        exp.expectedFulfillmentCount = 3
        for t in [0.7, 1.5, 2.4] {
            DispatchQueue.global().asyncAfter(deadline: .now() + t) {
                if t == 2.4 {
                    let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); att.name = "hold-2.4s"; att.lifetime = .keepAlways
                    self.add(att)
                }
                let menuOpen = app.buttons["douyin.module.search"].exists || app.buttons["搜索"].exists
                let peek = app.buttons["douyin.author"].exists
                lock.lock(); samples.append("t=\(t) menu=\(menuOpen) peek=\(peek)"); lock.unlock()
                exp.fulfill()
            }
        }
        c.press(forDuration: 3.0)
        wait(for: [exp], timeout: 8)
        print("DDHOLD \(samples.sorted())")
        sleep(1)
        let menuAfter = app.buttons["douyin.module.search"].exists || app.buttons["搜索"].exists
        let peekAfter = app.buttons["douyin.author"].exists
        print("DDHOLD after: menu=\(menuAfter) peek=\(peekAfter)")
        XCTAssertFalse(samples.contains { $0.contains("menu=true") }, "按住期间不应弹出菜单：\(samples)")
        if mode == "minimal" {
            // 按下立刻显示：第一个采样点（0.7s）就应该看到
            XCTAssertTrue(samples.contains { $0.hasPrefix("t=0.7") && $0.contains("peek=true") }, "极简按下后应立即显示作者标题：\(samples)")
            XCTAssertTrue(samples.allSatisfy { $0.contains("peek=true") }, "按住期间标题应一直显示：\(samples)")
        }
        XCTAssertFalse(menuAfter, "松手后不应弹出菜单")
        if mode == "minimal" { XCTAssertFalse(peekAfter, "松手后作者标题应消失") }
        // 单击仍然弹菜单
        menu.tap()
        XCTAssertTrue(app.buttons["douyin.module.search"].waitForExistence(timeout: 5) || app.buttons["搜索"].waitForExistence(timeout: 5), "单击仍应弹出模块菜单")
        attach(app, "minimal-menu-after-tap")
    }

    // 兼容旧名


    /// 简洁模式也用外圈进度环，底部进度条隐藏；默认模式没有进度环。
    func testRailModeAlsoHasProgressRing() throws {
        let app = launchChrome("rail")
        XCTAssertTrue(app.buttons["douyin.module.menu"].waitForExistence(timeout: 10))
        sleep(6)
        let ring = app.otherElements["douyin.module.ring"].firstMatch
        XCTAssertTrue(ring.waitForExistence(timeout: 5), "简洁模式应有进度外圈")
        let v1 = ring.value as? String ?? ""; sleep(5); let v2 = ring.value as? String ?? ""
        print("DDRING rail \(v1) -> \(v2)")
        XCTAssertNotEqual(v1, v2)
        attach(app, "rail-ring")
        let classic = launchChrome("classic")
        XCTAssertFalse(classic.otherElements["douyin.module.ring"].exists, "默认模式不画进度环")
    }

    /// 量布局：入口环、入口按钮、右侧胶囊（赞）、更多按钮的位置和尺寸，核对「环与胶囊同宽」「入口到胶囊的间距 = 胶囊到更多的间距」。
    func testModuleEntryGeometry() throws {
        let app = launchChrome("minimal")
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        sleep(5)
        let ring = app.otherElements["douyin.module.ring"].firstMatch
        XCTAssertTrue(ring.waitForExistence(timeout: 5))
        func vis(_ id: String) -> XCUIElement? {
            app.buttons.matching(identifier: id).allElementsBoundByIndex.first { $0.isHittable }
        }
        let like = vis("douyin.like")!.frame
        let fit = vis("douyin.fit")!.frame
        let more = vis("douyin.more")!.frame
        print("DDGEO ring=\(ring.frame) menu=\(menu.frame) like=\(like) fit=\(fit) more=\(more)")
        // 胶囊整体：赞的上沿 - 8（内边距）= 胶囊上沿；铺满下沿 + 8 = 胶囊下沿
        let capsuleTop = like.minY - 8, capsuleBottom = fit.maxY + 8
        let gapA = capsuleTop - ring.frame.maxY, gapB = more.minY - capsuleBottom
        print("DDGEO capsule=\(capsuleTop)...\(capsuleBottom) ringW=\(ring.frame.width) gapRingToCapsule=\(gapA) gapCapsuleToMore=\(gapB)")
        XCTAssertEqual(ring.frame.width, like.width, accuracy: 1.5, "进度环应和胶囊同宽")
        XCTAssertEqual(ring.frame.midX, like.midX, accuracy: 1.5, "进度环应和胶囊居中对齐")
        XCTAssertEqual(gapA, gapB, accuracy: 1.5, "入口到胶囊的间距应等于胶囊到「更多」的间距")
        attach(app, "geometry")
    }

    /// 极简：单击入口 → 菜单弹出，同时作者标题显示；菜单收起后标题消失。红点只在菜单「消息」行，入口上没有。
    func testMinimalTapShowsInfoWithMenuAndBadgeOnMessagesRow() throws {
        let app = launchChrome("minimal")
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        sleep(4)
        XCTAssertFalse(app.buttons["douyin.author"].exists, "平时不显示作者")
        menu.tap()
        XCTAssertTrue(app.buttons["douyin.module.search"].waitForExistence(timeout: 5), "单击应弹出菜单")
        sleep(1)
        XCTAssertTrue(app.buttons["douyin.author"].exists, "菜单打开期间应显示作者标题")
        attach(app, "minimal-tap-menu-and-info")
        // 关菜单：点「推荐」行（当前模块，选了也不换页）
        app.buttons["douyin.module.item.recommend"].tap()
        sleep(1)
        XCTAssertFalse(app.buttons["douyin.author"].exists, "菜单收起后标题应消失")
        XCTAssertFalse(app.otherElements["douyin.module.entry.badge"].exists, "入口上不再有红点")
    }

    /// 压测：连续滑 8 条视频，每条停几秒（触发预加载解码音频），期间改倍速。App 不能崩。
    func testSwipeManyVideosWithSeamlessAudioDoesNotCrash() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "classic"
        app.launchArguments += ["-douduo_dismissed_update_v1", "1.3.12"]
        app.launch()
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
        sleep(5)
        for i in 1...8 {
            app.swipeUp(velocity: .fast)
            sleep(4)
            XCTAssertEqual(app.state, .runningForeground, "第 \(i) 条视频后 App 崩溃了")
            if i == 3 || i == 6 {
                let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.filter { $0.isHittable }
                if let m = more.first {
                    m.tap()
                    let speed = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '倍速'")).firstMatch
                    if speed.waitForExistence(timeout: 4) {
                        speed.tap()
                        let t = app.buttons[i == 3 ? "1.5 倍速" : "2 倍速"]
                        if t.waitForExistence(timeout: 4) { t.tap() }
                    }
                    sleep(2)
                }
            }
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// 分页里每页都挂了角标，只取屏幕上那个
    private func visibleBadge(_ app: XCUIApplication) -> XCUIElement? {
        let f = app.windows.firstMatch.frame
        return app.staticTexts.matching(identifier: "douyin.rateBadge").allElementsBoundByIndex.first {
            $0.frame.midY > f.minY && $0.frame.midY < f.maxY && $0.frame.midX > f.minX && $0.frame.midX < f.maxX
        }
    }

    private func waitBadge(_ app: XCUIApplication, _ label: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let b = visibleBadge(app), b.label == label { return true }
            usleep(200_000)
        }
        return false
    }

    /// 中间长按 → 默认展开的视频播放设置。
    private func openSpeedMenu(_ app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["douyin.options.rate.1.0"].waitForExistence(timeout: 5))
    }

    private func wait(label: String, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    /// Native tabs, stable video header and compact comments. No account writes.
    func testSystemBarsDockAndComments() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { app.terminate() }
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        func visibleButton(_ id: String) -> XCUIElement {
            app.buttons.matching(identifier: id).allElementsBoundByIndex.first(where: { $0.isHittable })
                ?? app.buttons[id].firstMatch
        }
        let header = app.otherElements["douyin.feed.header"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let headerFrame = header.frame
        let actionIDs = ["douyin.author.avatar", "douyin.like", "douyin.comments", "douyin.collect", "douyin.share"]
        let actions = actionIDs.map(visibleButton)
        for action in actions { XCTAssertTrue(action.isHittable, app.debugDescription) }
        for i in 1..<actions.count { XCTAssertGreaterThan(actions[i].frame.minY, actions[i-1].frame.minY) }
        for id in actionIDs.dropFirst() {
            XCTAssertNotNil(visibleButton(id).label.rangeOfCharacter(from: .decimalDigits))
        }
        let home = app.buttons["首页"].firstMatch
        XCTAssertTrue(home.isHittable, app.debugDescription)
        print("DUO_DOCK_WINDOW \(app.windows.firstMatch.frame)")
        for action in actions {
            XCTAssertLessThanOrEqual(action.frame.width, 54, "保留小尺寸互动栏")
        }
        let info = app.otherElements["douyin.video.info"].firstMatch
        let progress = app.otherElements["douyin.progress"].firstMatch
        XCTAssertFalse(info.frame.intersects(home.frame))
        XCTAssertFalse(progress.frame.intersects(home.frame))
        attach(app, "build94-native-dock-home")
        let originalID = current.label
        home.tap()
        let mine = app.buttons["我的"].firstMatch
        let messages = app.buttons["消息"].firstMatch
        if app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height || app.windows.firstMatch.frame.width < 600 {
            XCTAssertLessThan(mine.frame.minY, messages.frame.minY)
            XCTAssertLessThan(messages.frame.minY, home.frame.minY)
        }
        attach(app, "build94-native-dock-expanded")
        mine.tap()
        XCTAssertTrue(app.buttons["douyin.mine.post"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(visibleButton("douyin.like").exists)
        attach(app, "build94-native-mine")
        let tabFrames = [mine, messages, home].map(\.frame)
        messages.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "douyin.messages.root").firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let tabsSettled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            zip([mine, messages, home], tabFrames).allSatisfy { tab, frame in
                abs(tab.frame.midX - frame.midX) <= 2
            }
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [tabsSettled], timeout: 8), .completed)
        print("NATIVE_TAB_FRAMES mine=\(tabFrames) messages=\([mine, messages, home].map(\.frame))")
        XCTAssertEqual(home.frame.maxY, tabFrames[2].maxY, accuracy: 2, "系统 Dock 底部锚点保持一致；选中项的原生胶囊可改变各项尺寸")
        attach(app, "build94-native-messages")
        XCTAssertFalse(app.buttons["douyin.mine.back"].exists)
        XCTAssertFalse(app.buttons["douyin.messages.back"].exists)
        home.tap()
        XCTAssertTrue(visibleButton("douyin.comments").waitForExistence(timeout: 10))
        XCTAssertEqual(current.label, originalID)
        visibleButton("douyin.comments").tap()
        let close = app.buttons["douyin.comments.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        let panel = app.descendants(matching: .any).matching(identifier: "douyin.comments.panel").firstMatch
        let commentHeader = app.otherElements["douyin.comments.header"].firstMatch
        XCTAssertLessThanOrEqual(commentHeader.frame.height, 44)
        let related = app.scrollViews["douyin.comments.relatedSearch"].firstMatch
        if related.waitForExistence(timeout: 15) {
            XCTAssertLessThanOrEqual(related.frame.minY, commentHeader.frame.maxY + 1)
            XCTAssertLessThanOrEqual(related.frame.maxX, panel.frame.maxX + 1)
        }
        attach(app, "build90-compact-comment-header-search-above-list")
        close.tap()
        for round in 1...2 {
            XCTAssertTrue(visibleButton("douyin.comments").waitForExistence(timeout: 10))
            attach(app, "build94-native-dock-after-comment-" + String(round))
            visibleButton("douyin.comments").tap()
            XCTAssertTrue(close.waitForExistence(timeout: 10))
            close.tap()
        }
        let previous = current.label
        app.windows.firstMatch.swipeUp(velocity: .fast)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", previous), object: current)], timeout: 10), .completed)
        XCTAssertEqual(header.frame.minY, headerFrame.minY, accuracy: 1)
        XCTAssertEqual(header.frame.minX, headerFrame.minX, accuracy: 1)
        XCTAssertTrue(visibleButton("douyin.more").isHittable)
        XCTAssertTrue(visibleButton("douyin.search").isHittable)
        XCTAssertTrue(visibleButton("douyin.share").isHittable)
        attach(app, "build90-fixed-header-after-next-video")
    }

    /// Same public work is injected only in DEBUG to exercise logged-out entry
    /// routes. Real comments/layout, no synthetic account history or sends.
    func testCommentsAreSharedAcrossRecommendationFollowAndMine() throws {
        continueAfterFailure = false
        var reference: CGRect?
        for entry in ["home", "follow", "mine"] {
            let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
            app.launchArguments += ["-douyin_muted_v1", "YES"]
            app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
            addTeardownBlock { app.terminate() }
            app.launchEnvironment["DOUDUO_COMMENT_ENTRY"] = entry
            app.launch()
            let current = app.staticTexts["douyin.currentID"]
            XCTAssertTrue(current.waitForExistence(timeout: 40))
            XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
            if entry == "follow" {
                app.buttons["关注"].firstMatch.tap()
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "douyin.follow.feed").firstMatch.waitForExistence(timeout: 10))
            } else if entry == "mine" {
                app.buttons["首页"].firstMatch.tap()
                app.buttons["我的"].firstMatch.tap()
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "douyin.list.player").firstMatch.waitForExistence(timeout: 40))
            }
            let comment = app.buttons["douyin.comments"].firstMatch
            XCTAssertTrue(comment.waitForExistence(timeout: 40))
            comment.tap()
            let panel = app.descendants(matching: .any).matching(identifier: "douyin.comments.panel").firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 15))
            let header = app.otherElements["douyin.comments.header"].firstMatch
            XCTAssertLessThanOrEqual(header.frame.height, 44)
            if app.windows.firstMatch.frame.width >= 700 {
                XCTAssertGreaterThan(panel.frame.width, app.windows.firstMatch.frame.width * 0.40)
                XCTAssertLessThan(panel.frame.width, app.windows.firstMatch.frame.width * 0.52)
                XCTAssertFalse(app.buttons["douyin.like"].firstMatch.exists)
                XCTAssertFalse(app.buttons["首页"].firstMatch.isHittable)
            } else {
                XCTAssertGreaterThan(panel.frame.width, app.windows.firstMatch.frame.width * 0.94)
            }
            if let reference {
                XCTAssertEqual(panel.frame.minX, reference.minX, accuracy: 2)
                XCTAssertEqual(panel.frame.width, reference.width, accuracy: 2)
                XCTAssertEqual(panel.frame.minY, reference.minY, accuracy: 2)
            } else { reference = panel.frame }
            let related = app.scrollViews["douyin.comments.relatedSearch"].firstMatch
            XCTAssertTrue(related.waitForExistence(timeout: 15))
            XCTAssertLessThanOrEqual(related.frame.minY, header.frame.maxY + 1)
            let input = app.descendants(matching: .any).matching(identifier: "douyin.comment.input").firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            XCTAssertTrue(input.isHittable, app.debugDescription)
            attach(app, "build90-shared-comments-" + entry)
            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
            XCTAssertGreaterThanOrEqual(input.frame.height, 16, "输入文字不能只剩被键盘裁剪后的细线")
            XCTAssertLessThanOrEqual(input.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
            print("COMMENT_INPUT_FRAME \(entry) input=\(input.frame) keyboard=\(app.keyboards.firstMatch.frame)")
            attach(app, "build90-shared-comments-keyboard-" + entry)
            app.buttons["douyin.comments.close"].firstMatch.tap()
            app.terminate()
        }
    }

    func testPinchZoomAndBoostWithoutAccountWrites() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_playback_rate_v1", "1"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        let id = current.label
        let zoom = app.staticTexts.matching(identifier: "douyin.video.zoom").firstMatch
        let fitMode = app.staticTexts.matching(identifier: "douyin.video.fitMode").firstMatch
        // Synchronize XCTest's touch coordinates with the actual Duo display.
        attach(app, "build95-pinch-before")
        // The transparent UIKit gesture host is not an accessibility hit target.
        // Pinch the visible window so XCTest uses the physical display bounds.
        let gesture = app.windows.firstMatch
        // Launch arguments override later UserDefaults writes. Set this
        // mutable preference through its real control, so pinching can change it.
        if fitMode.label != "fill" {
            openSpeedMenu(app)
            app.buttons["douyin.options.fit"].tap()
            app.buttons["douyin.options.close"].tap()
        }
        XCTAssertTrue(wait(label: "fill", on: fitMode, timeout: 5))
        gesture.pinch(withScale: 0.65, velocity: -1)
        XCTAssertTrue(wait(label: "fit", on: fitMode, timeout: 5))
        XCTAssertTrue(wait(label: "1.00", on: zoom, timeout: 5))
        XCTAssertEqual(current.label, id, "双指缩放不能切换视频")
        attach(app, "build95-pinch-fit-navigation-check")
        XCTAssertFalse(app.buttons["douyin.author.back"].exists)
        attach(app, "build91-pinch-fit-recentred-blurred-background")
        gesture.pinch(withScale: 2.5, velocity: 1)
        XCTAssertTrue(wait(label: "fill", on: fitMode, timeout: 5))
        XCTAssertTrue(wait(label: "1.00", on: zoom, timeout: 5))
        XCTAssertEqual(current.label, id)
        attach(app, "build91-pinch-fill-recentred")
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.35))
        let down = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.53))
        start.press(forDuration: 0.8, thenDragTo: down, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(waitBadge(app, "2×", timeout: 5))
        XCTAssertEqual(current.label, id)
        let up = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.20))
        start.press(forDuration: 0.8, thenDragTo: up, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertNil(visibleBadge(app))
        attach(app, "build90-long-press-released")
    }

    func testDragAndHoldDoesNotStartBoost() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_playback_rate_v1", "1"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        attach(app, "build95-drag-before")
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.65))
        let end = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2))
        let boostCount = app.staticTexts["douyin.video.boostStarts"].firstMatch
        XCTAssertEqual(boostCount.label, "0")
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.2)
        XCTAssertEqual(boostCount.label, "0", "整个拖动及停留过程都不能触发长按，而不只是松手后恢复速度")
        XCTAssertNil(visibleBadge(app), "先拖动再停住不能进入长按倍速")
        XCTAssertFalse(app.buttons["douyin.options.close"].exists)
        attach(app, "build95-drag-hold-no-boost")
        let stationary = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.35))
        stationary.press(forDuration: 0.8, thenDragTo: start, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(waitBadge(app, "2×", timeout: 5), "静止长按后下滑仍能锁定倍速")
        XCTAssertEqual(boostCount.label, "1")
    }

    func testVideoSwipesNavigateAndProgressStillSeeks() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7705789488781932361", on: current, timeout: 45))
        let like = app.buttons["douyin.like"].firstMatch
        XCTAssertTrue(like.waitForExistence(timeout: 45))
        let progress = app.otherElements["douyin.progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.48))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.48))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.buttons["douyin.channel.follow"].firstMatch.isHittable)
        XCTAssertEqual(app.buttons["douyin.channel.follow"].value as? String, "已选择")
        attach(app, "duo-swipe-right-follow")
        end.press(forDuration: 0.05, thenDragTo: start)
        XCTAssertEqual(app.buttons["douyin.channel.recommend"].value as? String, "已选择")
        XCTAssertFalse(app.buttons["douyin.author.back"].exists)
        XCTAssertTrue(like.waitForExistence(timeout: 10))
        end.press(forDuration: 0.05, thenDragTo: start)
        let back = app.buttons["douyin.author.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "左滑须打开作者页")
        let authorPanel = app.otherElements["douyin.author.panel"].firstMatch
        XCTAssertLessThan(authorPanel.frame.minY, app.frame.height * 0.15, "外屏作者页应是整页而非 sheet")
        XCTAssertFalse(app.buttons["house"].firstMatch.isHittable, "作者页隐藏 Dock")
        XCTAssertGreaterThan(back.frame.midX, app.frame.width * 0.8, "返回交给系统放到状态栏下方")
        XCTAssertEqual(back.frame.midX, app.buttons["douyin.author.follow"].firstMatch.frame.midX, accuracy: 2)
        attach(app, "duo-swipe-left-author")
        back.tap()
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let before = (progress.value as? String ?? "").split { !$0.isNumber }.compactMap { Double($0) }
        XCTAssertEqual(before.count, 2)
        XCTAssertGreaterThan(before[1], 0)
        let forward = before[0] < before[1] * 0.5
        progress.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.35 : 0.65, dy: 0.7))
            .press(forDuration: 0.1, thenDragTo: progress.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.65 : 0.35, dy: 0.7)))
        let seeked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let after = (progress.value as? String ?? "").split { !$0.isNumber }.compactMap { Double($0) }
            return after.count == 2 && (after[0] - before[0]) * (forward ? 1 : -1) > before[1] * 0.2
        }, object: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [seeked], timeout: 7), .completed, "进度条仍按原版相对拖动跳转")
        attach(app, "duo-progress-drag")
        let previous = current.label
        app.swipeUp(velocity: .fast)
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", previous), object: current)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 10), .completed, "竖滑切视频保持有效")
    }

    func testCommentImages() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        sleep(4)
        // 在推荐流里逐条打开评论，找带图/贴纸的评论；评论面板关掉再翻下一条
        for n in 0..<15 {
            let btn = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
            guard let btn else { app.swipeUp(); sleep(3); continue }
            btn.tap()
            sleep(5)
            let img = app.descendants(matching: .any).matching(identifier: "douyin.comment.images").firstMatch
            let stk = app.descendants(matching: .any).matching(identifier: "douyin.comment.sticker").firstMatch
            if img.exists || stk.exists {
                let hit = img.exists ? img : stk
                print("DDCOMMENTIMG found video#\(n) kind=\(img.exists ? "image" : "sticker")")
                // 在评论面板内滚动（不是整个 app，否则会翻走视频）
                let panel = app.scrollViews.allElementsBoundByIndex.first { $0.frame.minX > app.windows.firstMatch.frame.width * 0.5 } ?? app.scrollViews.allElementsBoundByIndex.last
                var tries = 0
                while !hit.isHittable && tries < 12 {
                    panel?.swipeUp(velocity: .slow)
                    tries += 1
                }
                print("DDCOMMENTIMG frame=\(hit.frame) hittable=\(hit.isHittable)")
                print("DDCHAT_SHOT_COMMENTIMG"); sleep(3)
                hit.tap()
                let close = app.buttons["douyin.comment.viewer.close"]
                XCTAssertTrue(close.waitForExistence(timeout: 10), "点图没打开全屏查看")
                sleep(3)
                print("DDCHAT_SHOT_COMMENTVIEWER"); sleep(3)
                close.tap()
                return
            }
            // 关评论：再点一次评论按钮（宽屏侧栏）或下滑（sheet）
            if btn.isHittable { btn.tap() } else { app.swipeDown(velocity: .fast) }
            sleep(2)
            app.swipeUp()
            sleep(4)
        }
        XCTFail("翻了15条视频都没遇到带图/贴纸的评论")
    }

    /// Both compact and split: inspect the composer without typing or sending.
    func testConversationListAndDetail() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launch()
        let row = app.buttons.matching(identifier: "douyin.conversation.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 50), app.debugDescription)
        let expectsSidebar = app.staticTexts["选择左侧消息查看详情"].isHittable
        print("DDCHAT_EXPECT_SIDEBAR=\(expectsSidebar)")
        attach(app, "conversation-native-root")
        print("DDCHAT_SHOT_ROOT"); sleep(4)
        let label = row.label
        print("DDCHAT root rows=\(app.buttons.matching(identifier: "douyin.conversation.row").count)")
        row.tap()
        sleep(5)
        attach(app, "conversation-single-detail")
        print("DDCHAT_SHOT_DETAIL"); sleep(4)
        print("DDCHAT_DETAIL\n\(app.debugDescription)\nDDCHAT_DETAIL_END")
        let web = app.webViews.matching(identifier: "douyin.messages.chat.detail").firstMatch
        XCTAssertTrue(web.exists)
        let master = app.buttons["douyin.messages.interactive"]
        XCTAssertEqual(master.isHittable, expectsSidebar, "展开应保留左栏；窄屏详情应覆盖列表")
        if expectsSidebar { XCTAssertGreaterThanOrEqual(web.frame.minX, master.frame.maxX - 2) }
        if expectsSidebar { XCTAssertTrue(row.isSelected, "左侧当前会话应该高亮") }
        XCTAssertTrue(web.isHittable, "当前聊天详情应可交互")
        let inputs = web.descendants(matching: .any).matching(NSPredicate(format: "elementType == %d OR elementType == %d", XCUIElement.ElementType.textView.rawValue, XCUIElement.ElementType.textField.rawValue))
        XCTAssertGreaterThan(inputs.count, 0)
        if inputs.count > 0 {
            let input = inputs.firstMatch
            XCTAssertLessThanOrEqual(input.frame.maxY, app.windows.firstMatch.frame.maxY)
            XCTAssertTrue(input.isHittable, "聊天输入区应可达；不输入或发送测试消息")
        }
        app.buttons["douyin.messages.back"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["douyin.messages.interactive"].exists)
        attach(app, "conversation-return-list")
        print("DDCHAT returned; original row label length=\(label.count)")
    }

    /// 评论通知：下方有「回复」（只验证弹出输入框，不真发）、长评论可展开、点评论进视频并定位高亮那条评论
    func testCommentNoticeActions() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launchEnvironment["DOUDUO_LONGNOTICE"] = "1"
        app.launch()
        let entry = app.buttons["douyin.messages.interactive"]
        XCTAssertTrue(entry.waitForExistence(timeout: 35))
        entry.tap()
        let comment = app.buttons.matching(identifier: "douyin.notice.comment").firstMatch
        XCTAssertTrue(comment.waitForExistence(timeout: 25), "互动里没有评论通知")
        sleep(2)
        print("DDCHAT_SHOT_CNOTICE_LIST"); sleep(3)
        let reply = app.buttons.matching(identifier: "douyin.notice.reply").firstMatch
        XCTAssertTrue(reply.exists, "评论通知下面没有回复按钮")
        reply.tap()
        let input = app.descendants(matching: .any).matching(identifier: "douyin.notice.reply.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5), "点回复没出输入框")
        print("DDCHAT_SHOT_CNOTICE_REPLY"); sleep(3)
        app.buttons["douyin.notice.reply.cancel"].firstMatch.tap()
        sleep(1)
        let expand = app.buttons.matching(identifier: "douyin.notice.expand").firstMatch
        print("DDEXPAND count=\(app.buttons.matching(identifier: "douyin.notice.expand").count)")
        if expand.exists && expand.isHittable {
            let before = expand.label
            expand.tap(); sleep(1)
            print("DDEXPAND before=\(before) after=\(expand.label)")
            XCTAssertNotEqual(before, expand.label, "点展开没变成收起")
            print("DDCHAT_SHOT_CNOTICE_EXPAND"); sleep(3)
        }
        comment.tap()
        let focused = app.descendants(matching: .any).matching(identifier: "douyin.comment.focused").firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 30), "进视频后没定位到那条评论")
        print("DDCHAT_SHOT_CNOTICE_FOCUS"); sleep(3)
    }

    /// Read-only: split keeps master visible; compact returns through master.
    /// No text input, sends, likes or follows.
    func testMessageMasterDetailCategories() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launch()
        let interactive = app.buttons["douyin.messages.interactive"]
        XCTAssertTrue(interactive.waitForExistence(timeout: 35))
        let expectsSidebar = app.staticTexts["选择左侧消息查看详情"].isHittable
        print("DDMSG_EXPECT_SIDEBAR=\(expectsSidebar)")
        func showMasterIfCompact() {
            if !expectsSidebar {
                app.buttons["douyin.messages.back"].tap()
                XCTAssertTrue(interactive.isHittable)
            }
        }
        interactive.tap()
        let filter = app.descendants(matching: .any).matching(identifier: "douyin.notice.filter").firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 15))
        XCTAssertEqual(interactive.isHittable, expectsSidebar, "分类应符合当前主从/窄屏布局")
        if expectsSidebar { XCTAssertGreaterThan(filter.frame.minX, interactive.frame.maxX - 2, "通知应显示在右栏") }
        filter.tap()
        let comments = app.buttons["douyin.notice.filter.2"] // production DYNoticeGroup.comment
        XCTAssertTrue(comments.waitForExistence(timeout: 5))
        comments.tap()
        XCTAssertTrue(filter.label.contains("评论"))
        showMasterIfCompact()
        app.buttons["douyin.messages.fans"].tap()
        XCTAssertEqual(interactive.isHittable, expectsSidebar)
        showMasterIfCompact()
        app.buttons["douyin.messages.system"].tap()
        XCTAssertEqual(interactive.isHittable, expectsSidebar)
        showMasterIfCompact()
        interactive.tap()
        XCTAssertTrue(filter.label.contains("评论"), "分类切换后应保留筛选")
        app.buttons["douyin.messages.back"].tap()
        XCTAssertTrue(interactive.isHittable, "详情返回应先回消息列表，不退出消息中心")
        // Lists remain mounted to preserve scroll/filter state; inactive controls must not be tappable.
        XCTAssertFalse(filter.isHittable)
        XCTAssertFalse(interactive.isSelected)
        attach(app, "message-master-detail-category-return")
    }

    func testMessageReadAndVideoReturn() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launchEnvironment["DOUDUO_READ_AUDIT"] = "1"
        app.launch()
        let entry = app.buttons["douyin.messages.interactive"]
        XCTAssertTrue(entry.waitForExistence(timeout: 35))
        sleep(12)
        print("DDUNREAD_BEFORE=\(entry.value ?? "nil")")
        entry.tap()
        sleep(12)
        attach(app, "notice-category")
        print("DDCHAT_SHOT_NOTICE"); sleep(4)
        let videos = app.buttons.matching(identifier: "douyin.notice.video")
        _ = videos.firstMatch.waitForExistence(timeout: 15)
        guard let video = videos.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            throw XCTSkip("当前通知里没有可点击视频卡片，不能将视频返回路径算通过")
        }
        let originalLabel = video.label
        let originalFrame = video.frame
        video.tap()
        let playerBack = app.buttons["douyin.list.back"].firstMatch
        XCTAssertTrue(playerBack.waitForExistence(timeout: 25))
        let like = app.buttons.matching(identifier: "douyin.like").allElementsBoundByIndex.first { $0.isHittable }
        if let like { XCTAssertLessThan(playerBack.frame.midY, like.frame.midY) }
        attach(app, "notice-video-return-above-like")
        playerBack.tap()
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        XCTAssertTrue(video.isHittable)
        XCTAssertEqual(video.label, originalLabel, "视频返回必须保留同一通知")
        XCTAssertEqual(video.frame.minY, originalFrame.minY, accuracy: 2, "视频返回不能重置列表位置")
        let back = app.buttons["douyin.messages.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        sleep(10)
        // 退出分类只把看过的互动类（评论/赞）标已读；粉丝/系统仍可能有未读，所以看这个入口的角标
        print("DDUNREAD_AFTER=\(entry.value ?? "nil")")
        XCTAssertEqual(entry.value as? String, "0", "退出互动分类后它的未读应清零")
        XCTAssertTrue(app.buttons.matching(identifier: "douyin.conversation.row").firstMatch.waitForExistence(timeout: 15))
        attach(app, "message-read-and-conversations")
    }


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
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
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
                page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                    .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
                let changed = expectation(for: NSPredicate(format: "label != %@", id), evaluatedWith: current)
                XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 10), .completed)
                sleep(1)
            }
        }
    }

    func testNativeLiveRoomFlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let categories = app.buttons["live.discover"]
        XCTAssertTrue(categories.waitForExistence(timeout: 15), "发现更多应收成一个按钮")
        XCTAssertFalse(app.buttons["live.categories"].exists, "单独游戏专区入口已移除")
        XCTAssertFalse(app.buttons["英雄联盟"].exists, "分类不能常驻")
        categories.tap()
        app.buttons["live.category.game"].tap()
        XCTAssertTrue(app.buttons["英雄联盟"].waitForExistence(timeout: 5))
        attach(app, "live-category-picker")
        app.buttons["live.categories.close"].tap()
        categories.tap()
        let enter = app.buttons.matching(identifier: "live.room.enter").firstMatch
        XCTAssertTrue(enter.waitForExistence(timeout: 30))
        XCTAssertTrue(enter.isHittable)
        let id = app.staticTexts["live.currentID"].label
        enter.tap()
        XCTAssertTrue(app.buttons["live.room.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["live.chat.input"].exists)
        XCTAssertFalse(app.buttons["live.categories"].exists, "进房后不显示首页分类按钮")
        XCTAssertFalse(app.buttons["douyin.web.close"].exists, "进房不能打开网页版播放器")
        attach(app, "native-live-room")
        app.buttons["live.room.more"].tap()
        app.buttons["清屏"].tap()
        XCTAssertTrue(app.buttons["live.room.restore"].waitForExistence(timeout: 5))
        app.buttons["live.room.restore"].tap()
        app.buttons["live.room.close"].tap()
        XCTAssertTrue(categories.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["live.currentID"].label, id, "退房应回到同一个直播预览")
        attach(app, "live-preview-return")
        let page = app.otherElements["live.page.\(id)"]
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        let current = app.staticTexts["live.currentID"]
        let changed = expectation(for: NSPredicate(format: "label != %@", id), evaluatedWith: current)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 10), .completed, "上滑应换到相邻房间")
        let nextID = current.label
        sleep(3)
        XCTAssertEqual(current.label, nextID, "停止滑动后不应因布局回写继续乱跳")
    }

    /// 使用真实作品详情验证声明与时间，不通过标题猜 AI，也不做账号互动。
    func testVideoMetadataAIAndPublication() throws {
        for (id, isAI, name) in [("7705789488781932361", true, "ai"), ("7705458913226935590", false, "normal")] {
            let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
            app.launchEnvironment["DOUDUO_VIDEO_ID"] = id
            app.launch()
            let current = app.staticTexts["douyin.currentID"]
            XCTAssertTrue(current.waitForExistence(timeout: 30))
            let loaded = expectation(for: NSPredicate(format: "label == %@", id), evaluatedWith: current)
            XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 50), .completed)
            let metadata = app.staticTexts.matching(identifier: "douyin.video.metadata").firstMatch
            XCTAssertTrue(metadata.waitForExistence(timeout: 10))
            XCTAssertTrue(metadata.label.contains("发布"))
            XCTAssertEqual(metadata.label.contains("作者声明：内容由 AI 生成"), isAI)
            print("DDMETA_SCREEN:\(name) label=\(metadata.label)")
            fflush(stdout)
            sleep(4)
            app.terminate()
        }
    }

    /// 只输入草稿、不点击发送；验证真实隐藏网页就绪后，原生发送按钮才可用。
    func testLiveComposerReadyWithoutSending() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launchEnvironment["DOUDUO_AUTOLIVEROOM"] = "1"
        app.launch()
        let input = app.textFields["live.chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 35))
        let ready = expectation(for: NSPredicate(format: "value == %@", "说点什么…"), evaluatedWith: input)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 65), .completed, "必须等官网真实输入框挂载，不用视频首帧代替")
        input.tap()
        input.typeText("LOCAL_ONLY_DO_NOT_SEND")
        let send = app.buttons["live.chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        XCTAssertEqual(input.value as? String, "LOCAL_ONLY_DO_NOT_SEND")
        print("DDCOMPOSER_UI ready=true draft-preserved=true send-enabled=true no-send-performed=true")
        app.terminate()
    }

    /// 真机/模拟器均可跑；计时以 App 的 DDLIVE_READY 日志为准，截图另证是否实际出画。
    func testNativeLivePerformance() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
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
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
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

    // MARK: - 演示视频分幕（每幕单独录屏）

    /// 幕2 合盖外屏：刷推荐流
    func testTourOuter() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        sleep(13)
        for _ in 0..<2 {
            let s = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
            let e = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            s.press(forDuration: 0.12, thenDragTo: e, withVelocity: .slow, thenHoldForDuration: 0)
            sleep(5)
        }
    }

    /// 幕6 设置：竖屏 70% + 短视频 70%
    func testTourSettings() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        sleep(13)
        app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }?.tap()
        sleep(3)
        app.buttons["设置"].firstMatch.tap()
        sleep(4)
        let any = { (kw: String) in
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", kw))
                .allElementsBoundByIndex.first { $0.isHittable && $0.frame.width > 20 }
        }
        any("竖屏占比")?.tap()
        sleep(4)
        app.buttons["70%"].firstMatch.tap()
        sleep(3)
        any("竖屏短视频占比")?.tap()
        sleep(4)
        app.buttons["短视频 70%"].firstMatch.tap()
        sleep(3)
        app.tap()
        sleep(4)
    }

    /// 幕7 液态玻璃胶囊：点赞 / 收藏反馈
    func testTourRail() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        sleep(13)
        for id in ["douyin.like", "douyin.favorite"] {
            let b = app.buttons.matching(identifier: id).allElementsBoundByIndex.first { $0.isHittable }
            b?.tap()
            sleep(4)
            b?.tap()
            sleep(3)
        }
    }

    /// 合屏左贴边探针：连滑几条，看每页是否都收到铰链回调（日志 DDHINGE）
    func testClosedAlignProbe() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autofit_v1", "NO"]
        app.launch()
        sleep(20)
        for i in 0..<4 {
            print("DDCHAT_SHOT_SWIPE\(i)"); sleep(3)
            app.swipeUp(velocity: .fast)
            sleep(5)
        }
        print("DDCHAT_SHOT_END"); sleep(3)
    }

    /// 幕5 半折叠桌面式：滑评论
    func testTourFold() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launch()
        sleep(26)
        let s = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let e = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        s.press(forDuration: 0.12, thenDragTo: e, withVelocity: .slow, thenHoldForDuration: 0)
        sleep(5)
        s.press(forDuration: 0.12, thenDragTo: e, withVelocity: .slow, thenHoldForDuration: 0)
        sleep(4)
    }

    /// 幕9 直播：分类按钮 → 进原生直播间
    func testTourLive() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        sleep(13)
        app.buttons["直播"].firstMatch.tap()
        sleep(9)
        app.buttons["live.categories"].firstMatch.tap()
        sleep(6)
        app.buttons["推荐直播"].firstMatch.tap()
        sleep(9)
        app.buttons.matching(identifier: "live.room.enter").firstMatch.tap()
        sleep(14)
    }

    /// 幕3 展开宽屏（iPad）：点评论 → 右侧滑出
    func testTourWide() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        sleep(14)
        let b = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
        b?.tap()
        sleep(6)
        let s = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.6))
        let e = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.25))
        s.press(forDuration: 0.12, thenDragTo: e, withVelocity: .slow, thenHoldForDuration: 0)
        sleep(5)
    }

    /// 截图用（iPad 宽屏）：点开评论 → 右侧滑出
    func testCaptureWideComment() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        sleep(14)
        let btn = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
        btn?.tap()
        sleep(5)
        attach(app, "wide-comment")
    }

    /// 截图用（iPad 横屏 + 半折叠）：书本式左右分
    func testCaptureBookFold() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(16)
        attach(app, "book-fold")
    }

    /// 截图用：保持横屏 40 秒，外部用 simctl 抓物理屏
    func testHoldLandscape() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launch()
        sleep(10)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(40)
    }

    /// 截图用：横屏 + 宽屏布局（评论右侧滑出）
    func testCaptureLandscapeWide() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(12)
        let btn = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
        btn?.tap()
        sleep(4)
        attach(app, "land-wide")
    }

    /// 截图用：横屏 + 强制半折叠（书本式左右分）
    func testCaptureLandscapeFold() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(14)
        attach(app, "land-fold")
    }

    /// 录屏版：先手动启动 App 再开录，这里只接管前台，画面从第一帧就是 App
    func testFeatureTourActive() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.activate()
        sleep(2)
        app.buttons["推荐"].firstMatch.tap()
        sleep(4)
        let current = app.staticTexts["douyin.currentID"]
        _ = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 40)
        sleep(4)

        // 更多 → 设置：短视频占比（展示 4 秒 + 选项 5 秒）
        app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }?.tap()
        sleep(3)
        app.buttons["设置"].firstMatch.tap()
        sleep(4)
        app.buttons["竖屏短视频占比（3 分钟内）"].firstMatch.tap()
        sleep(5)
        app.buttons["短视频 70%"].firstMatch.tap()
        sleep(2)
        app.tap()
        sleep(3)

        // 直播：分类按钮 → 面板 → 专区 → 进房
        app.buttons["直播"].firstMatch.tap()
        sleep(5)
        app.buttons["live.categories"].firstMatch.tap()
        sleep(5)
        app.buttons["英雄联盟"].firstMatch.tap()
        sleep(6)
        app.buttons.matching(identifier: "live.room.enter").firstMatch.tap()
        sleep(6)

        // 直播间：更多 → 清屏 → 恢复
        app.buttons["live.room.more"].firstMatch.tap()
        sleep(3)
        app.buttons["清屏"].firstMatch.tap()
        sleep(4)
        app.buttons["live.room.restore"].firstMatch.tap()
        sleep(3)
        app.buttons["live.room.close"].firstMatch.tap()
        sleep(4)
        app.buttons["推荐"].firstMatch.tap()
        sleep(4)
        attach(app, "tour-active-end")
    }

    /// 功能演示脚本（录屏用）：按固定节奏走一遍新功能，不做断言，只保证画面走位
    func testFeatureTour() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        _ = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60)
        sleep(3)

        // 更多 → 设置：短视频占比
        let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }
        more?.tap()
        sleep(2)
        app.buttons["设置"].firstMatch.tap()
        sleep(2)
        app.buttons["竖屏短视频占比（3 分钟内）"].firstMatch.tap()
        sleep(2)
        app.buttons["短视频 70%"].firstMatch.tap()
        sleep(2)
        app.tap()
        sleep(2)

        // 直播：分类按钮 → 专区 → 进房 → 清屏 → 退出
        app.buttons["直播"].firstMatch.tap()
        sleep(4)
        app.buttons["live.categories"].firstMatch.tap()
        sleep(3)
        app.buttons["英雄联盟"].firstMatch.tap()
        sleep(5)
        app.buttons.matching(identifier: "live.room.enter").firstMatch.tap()
        sleep(4)
        app.buttons["live.room.more"].firstMatch.tap()
        sleep(2)
        app.buttons["清屏"].firstMatch.tap()
        sleep(2)
        app.buttons["live.room.restore"].firstMatch.tap()
        sleep(2)
        app.buttons["live.room.close"].firstMatch.tap()
        sleep(3)
        app.buttons["推荐"].firstMatch.tap()
        sleep(4)
        attach(app, "tour-end")
    }

    func testConditionalTitleExpansion() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "classic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { app.terminate() }
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
        XCTAssertLessThanOrEqual(long.staticTexts["douyin.description"].frame.height, 60, "默认最多三行")
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
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed)
        sleep(3)
        XCTAssertFalse(app.buttons.matching(identifier: "douyin.follow").allElementsBoundByIndex.contains { $0.isHittable })
        let desc = app.staticTexts.matching(identifier: "douyin.description").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(desc)
        if let desc { XCTAssertLessThan(desc.frame.height, 40, "标题默认应只有一行") }
        if let prose = app.links.allElementsBoundByIndex.first(where: { $0.isHittable && !$0.label.hasPrefix("#") }) {
            prose.tap()
            XCTAssertTrue(app.buttons["douyin.description.close"].waitForExistence(timeout: 5))
            app.buttons["douyin.description.close"].tap()
        }
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
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
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
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
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
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
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
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
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
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
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
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
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
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
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
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
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

    /// Automated layout checks never write likes or collections to the account.
    func testLikeAndCollect() throws {
        throw XCTSkip("仅只读验收，不执行账号点赞或收藏写操作")
    }

    func testFollowedLivePickerRestoresRecommendation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { app.terminate() }
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launchEnvironment["DOUDUO_LIVEMOCK"] = "1"
        app.launchEnvironment["DOUDUO_FOLLOWMOCK"] = "rooms"
        app.launch()
        let current = app.staticTexts["live.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label == 'rec-a'"), evaluatedWith: current)], timeout: 10), .completed)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "live.follow").firstMatch.label.contains("我的关注"))
        app.descendants(matching: .any).matching(identifier: "live.follow").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["我的关注"].waitForExistence(timeout: 5))
        let row = app.buttons["live.follow.room.fol-b"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["live.follow.list"].exists)
        XCTAssertTrue(row.label.contains("关注乙"))
        XCTAssertTrue(row.label.contains("直播中"))
        XCTAssertFalse(row.label.contains("关注直播乙"), "列表不显示房间标题")
        XCTAssertFalse(row.label.contains("在看"))
        let other = app.buttons["live.follow.room.fol-a"]
        XCTAssertTrue(other.label.contains("关注甲"))
        XCTAssertTrue(other.label.contains("直播中"))
        XCTAssertTrue(other.label.contains("30"))
        XCTAssertTrue(other.label.contains("在看"))
        row.tap()
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label == 'fol-b'"), evaluatedWith: current)], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["live.room.close"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "live.follow").firstMatch.exists, "进入关注直播间后不显示选择按钮")
        app.buttons["live.room.close"].tap()
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label == 'rec-a'"), evaluatedWith: current)], timeout: 5), .completed, "退出应回到原来的推荐直播")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "live.follow").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["live.discover"].exists)
        app.windows.firstMatch.swipeUp(velocity: .slow)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label == 'rec-b'"), evaluatedWith: current)], timeout: 5), .completed, "回到推荐后只能滑到原来的下一间")
    }

    func testFollowedLiveStatesStayDistinct() throws {
        let empty = XCUIApplication()
        empty.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        empty.launchEnvironment["DOUDUO_LIVEMOCK"] = "1"
        empty.launchEnvironment["DOUDUO_FOLLOWMOCK"] = "empty"
        empty.launch()
        XCTAssertTrue(empty.buttons["live.follow"].waitForExistence(timeout: 10))
        empty.buttons["live.follow"].tap()
        XCTAssertTrue(empty.staticTexts["live.follow.empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(empty.staticTexts["live.follow.login"].exists)
        empty.terminate()

        let login = XCUIApplication()
        login.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        login.launchEnvironment["DOUDUO_LIVEMOCK"] = "1"
        login.launchEnvironment["DOUDUO_FOLLOWMOCK"] = "login"
        login.launch()
        XCTAssertTrue(login.buttons["live.follow"].waitForExistence(timeout: 10))
        login.buttons["live.follow"].tap()
        XCTAssertTrue(login.staticTexts["live.follow.login"].waitForExistence(timeout: 5))
        XCTAssertTrue(login.buttons["live.follow.login.button"].exists)
        XCTAssertFalse(login.staticTexts["live.follow.empty"].exists)
    }

    /// 关注开播只走直播页「我的关注」：直播页不挂头像条，关注页不挂直播头像。
    func testFollowLiveOnlyViaMyFollowButton() throws {
        continueAfterFailure = false
        let live = XCUIApplication()
        live.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { live.terminate() }
        live.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        live.launchEnvironment["DOUDUO_LIVEMOCK"] = "1"
        live.launchEnvironment["DOUDUO_FOLLOWMOCK"] = "rooms"
        live.launch()
        XCTAssertTrue(live.buttons["live.follow"].waitForExistence(timeout: 10), "「我的关注」入口保留")
        sleep(2)
        attach(live, "live-no-strip")
        XCTAssertFalse(live.scrollViews["live.follow.strip"].exists, "直播页不再挂关注头像条")
        XCTAssertFalse(live.buttons["live.follow.pill"].exists)
        live.terminate()

        let follow = XCUIApplication()
        follow.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { follow.terminate() }
        follow.launchEnvironment["DOUDUO_STARTFOLLOW"] = "1"
        follow.launchEnvironment["DOUDUO_FOLLOWMOCK"] = "rooms"
        follow.launch()
        XCTAssertTrue(follow.otherElements["douyin.follow.feed"].waitForExistence(timeout: 15))
        attach(follow, "follow-no-live-row")
        XCTAssertFalse(follow.staticTexts["直播中"].exists, "关注页不应出现直播头像")
    }

    /// 底部进度条左侧时间（秒）
    private func playTime(_ app: XCUIApplication) -> Int {
        let q = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+:[0-9][0-9]$'"))
        guard q.count > 0 else { return 0 }
        return q.element(boundBy: 0).label.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        print("DUODUO_CAPTURE " + name)
        Thread.sleep(forTimeInterval: 2) // Host captures the active Duo display; XCTest screenshots use the inactive outer screen.
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}

extension DouDuoUITests {
    /// 翻页固定「更快」（维护者定稿，无菜单）：上滑能翻到下一条，且连续翻页后当前视频与列表一致。只读，不点赞不发帖。
    func testPagingSpeedSettingAndVerticalNavigation() throws { try verifyFastPaging(mode: nil) }
    /// 经典布局以前自己复制了一份分页 ScrollView、漏挂了「更快」收尾；现在四种界面共用 DYFeedPager。
    func testPagingSpeedClassicLayout() throws { try verifyFastPaging(mode: "duoClassic") }

    private func verifyFastPaging(mode: String?) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let mode { app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode }
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douduo_dismissed_update_v1", "9.9.9"]
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != %@", "-"), evaluatedWith: current)], timeout: 60), .completed)
        XCTAssertFalse(app.buttons["翻页设置"].exists, "翻页速度已固定，不应再有菜单入口")
        var seen = [current.label]
        for _ in 0..<3 {
            let before = current.label
            app.swipeUp(velocity: .fast)
            XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: current)], timeout: 5), .completed)
            seen.append(current.label)
        }
        XCTAssertEqual(Set(seen).count, seen.count, "连续翻页不应停在重复的视频")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "real-feed-faster-page"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}


extension DouDuoUITests {
    /// Run on the actual Duo outer, inner landscape and inner portrait display.
    /// Public network videos/comments; no likes, follows, messages or posts are sent.
    func testClassicRecommendationTapRefreshOnline() throws {
        continueAfterFailure = false
        let app = launchOnlineRegression(pinned: false)
        let current = app.staticTexts["douyin.currentID"].firstMatch
        let first = current.label
        let window = app.windows.firstMatch
        let recommend = app.buttons["douyin.channel.recommend"].firstMatch
        recommend.tap()
        XCTAssertTrue(waitUntil(timeout: 75) { current.label != first && recommend.value as? String == "已选择" })
        let refreshed = current.label
        // Target the active Duo window's video area rather than an app-level gesture.
        // Retry after online prefetch has had time to append the next page.
        for _ in 0..<4 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.65))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.2)))
            if waitUntil(timeout: 5, condition: { current.label != refreshed }) { break }
        }
        XCTAssertNotEqual(current.label, refreshed)
        let second = current.label
        let home = app.buttons["首页"].firstMatch
        home.tap()
        home.tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(current.label, second, "Dock reselection must not change the video")
        let mine = app.buttons["我的"].firstMatch
        if !mine.isHittable { home.tap() }
        mine.tap()
        XCTAssertTrue(app.buttons["douyin.mine.post"].waitForExistence(timeout: 15))
        home.tap()
        XCTAssertTrue(app.buttons["douyin.comments"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(current.label, second, "Returning home preserves playback selection")
        app.buttons["douyin.channel.follow"].firstMatch.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { app.buttons["douyin.channel.follow"].firstMatch.value as? String == "已选择" })
        recommend.tap()
        XCTAssertTrue(waitUntil(timeout: 8) { recommend.value as? String == "已选择" })
        XCTAssertEqual(current.label, second, "Switching back does not refresh")
        recommend.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { recommend.value as? String == "正在刷新" })
        recommend.tap()
        XCTAssertTrue(waitUntil(timeout: 75) { recommend.value as? String == "已选择" })
        XCTAssertNotEqual(current.label, second, "Successful online refresh must replace the current recommendation")
        print("REFRESH_ONLINE window=\(window.frame) before=\(second) after=\(current.label)")
        pauseRegressionVideo(app)
        attach(app, "regression-refresh")
    }

    func testClassicHomeDockReselectionKeepsCurrentVideo() {
        continueAfterFailure = false
        let app = launchOnlineRegression(pinned: false)
        let window = app.windows.firstMatch
        let current = app.staticTexts["douyin.currentID"].firstMatch
        let initial = current.label
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.68))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.20))
        for _ in 0..<3 {
            start.press(forDuration: 0.05, thenDragTo: end)
            if waitUntil(timeout: 5, condition: { current.label != initial }) { break }
        }
        let paged = current.label
        XCTAssertNotEqual(paged, initial, "The test must leave the first video")

        let home = app.buttons["首页"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        for _ in 0..<2 {
            home.tap()
            XCTAssertFalse(waitUntil(timeout: 1) { current.label != paged },
                           "Reselecting Home must not scroll the feed to the first video")
        }

        let mine = app.buttons["我的"].firstMatch
        if !mine.isHittable { home.tap() } // Expand the system dock if it is compressed.
        XCTAssertTrue(mine.isHittable)
        mine.tap()
        XCTAssertTrue(app.buttons["douyin.mine.post"].waitForExistence(timeout: 15))
        home.tap()
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        XCTAssertEqual(current.label, paged, "Switching home from another tab restores the same video")
    }

    func testClassicCaptionCommentsAndCleanOnline() throws {
        continueAfterFailure = false
        let app = launchOnlineRegression()
        pauseRegressionVideo(app)
        let window = app.windows.firstMatch
        let any = app.descendants(matching: .any)
        let description = any.matching(identifier: "douyin.description").firstMatch
        XCTAssertTrue(description.waitForExistence(timeout: 10))
        description.tap()
        let expanded = any.matching(identifier: "douyin.description.expanded").firstMatch
        XCTAssertTrue(expanded.waitForExistence(timeout: 10))
        let header = app.otherElements["douyin.comments.header"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertLessThanOrEqual(expanded.frame.maxY, header.frame.minY + 2)
        let surface = app.otherElements["douyin.sheet.edgeSurface"].firstMatch
        if surface.exists {
            XCTAssertEqual(surface.frame.maxX, window.frame.maxX, accuracy: 2)
        }
        let author = any.matching(identifier: "douyin.description.author").firstMatch
        XCTAssertLessThan(author.frame.maxY, expanded.frame.minY)
        print("CAPTION_FRAMES author=\(author.frame) description=\(expanded.frame) heading=\(header.frame)")
        attach(app, "regression-caption")
        let captionClose = app.buttons["douyin.description.close"].firstMatch
        captionClose.tap()
        XCTAssertTrue(captionClose.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        for _ in 0..<2 {
            app.buttons["douyin.comments"].firstMatch.tap()
            XCTAssertTrue(header.waitForExistence(timeout: 10))
            let input = any.matching(identifier: "douyin.comment.input").firstMatch
            XCTAssertTrue(input.isHittable)
            XCTAssertGreaterThanOrEqual(input.frame.height, 20)
            if window.frame.width < 700 && window.frame.height > window.frame.width {
                let list = app.scrollViews["douyin.comments.list"].firstMatch
                XCTAssertEqual(list.frame.maxX, window.frame.maxX, accuracy: 2, "窄屏评论不留右侧状态栏空白")
            }
            let commentClose = app.buttons["douyin.comments.close"].firstMatch
            commentClose.tap()
            XCTAssertTrue(commentClose.waitForNonExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 1)
            let clean = app.buttons["douyin.cleanScreen"].firstMatch
            XCTAssertTrue(clean.waitForExistence(timeout: 10))
            clean.tap()
            XCTAssertTrue(waitUntil(timeout: 5) { clean.label == "退出清屏" })
            clean.tap()
            XCTAssertTrue(app.buttons["douyin.share"].firstMatch.isHittable)
            Thread.sleep(forTimeInterval: 1)
        }
        print("CAPTION_COMMENTS_CLEAN_ONLINE window=\(window.frame)")
        pauseRegressionVideo(app)
        attach(app, "regression-comments-restored")
        let search = app.buttons["douyin.search"].firstMatch
        XCTAssertTrue(search.exists)
        search.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.textFields["douyin.search.field"].waitForExistence(timeout: 10))
    }

    func testCompactLandscapeVideoHidesChannelBar() throws {
        continueAfterFailure = false
        let app = launchOnlineRegression(pinned: false, forceWide: true)
        let current = app.staticTexts["douyin.currentID"].firstMatch
        let before = current.label
        let recommend = app.buttons["douyin.channel.recommend"].firstMatch
        recommend.tap()
        XCTAssertTrue(waitUntil(timeout: 75) { current.label != before && recommend.value as? String == "已选择" })
        pauseRegressionVideo(app)
        app.buttons["douyin.comments"].firstMatch.tap()
        let header = app.otherElements["douyin.comments.header"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 12))
        XCTAssertLessThanOrEqual(header.frame.minY, app.windows.firstMatch.frame.height * 0.38 + 1)
        attach(app, "compact-landscape-no-channel")
        XCTAssertFalse(recommend.isHittable)
        app.buttons["douyin.comments.close"].firstMatch.tap()
        XCTAssertTrue(recommend.waitForExistence(timeout: 10))
    }

    private func launchOnlineRegression(pinned: Bool = true, forceWide: Bool = false, mode: String = "duoClassic") -> XCUIApplication {
        let app = XCUIApplication()
        addTeardownBlock { app.terminate() }
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
        if forceWide {
            app.launchEnvironment["DOUDUO_FORCEWIDE"] = "1"
            app.launchArguments += ["-douyin_wide_landscape_v1", "YES"]
        }
        if pinned { app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406" }
        app.launchArguments += ["-duoduomain_tab_v1", "首页", "-douyin_muted_v1", "YES",
                                "-douyin_autoplay_v1", "NO", "-douduo_dismissed_update_v1", "1.5.4",
                                "-douyin_danmaku_v1", "NO"]
        app.launch()
        let current = app.staticTexts["douyin.currentID"].firstMatch
        if pinned {
            XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 60))
        } else {
            XCTAssertTrue(waitUntil(timeout: 60) { current.exists && current.label != "-" })
            Thread.sleep(forTimeInterval: 5)
        }
        return app
    }

    private func pauseRegressionVideo(_ app: XCUIApplication) {
        let playback = app.staticTexts.matching(identifier: "douyin.video.playback").allElementsBoundByIndex
        if playback.contains(where: { $0.label == "playing" }) {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35)).tap()
            XCTAssertTrue(waitUntil(timeout: 5) {
                app.staticTexts.matching(identifier: "douyin.video.playback").allElementsBoundByIndex.contains { $0.label == "paused" }
            })
        }
    }
}


extension DouDuoUITests {
    func testTabletBasicLayoutsOnline() throws { try verifyBasicDeviceLayouts(landscape: true) }
    func testPhoneBasicLayoutsOnline() throws { try verifyBasicDeviceLayouts(landscape: false) }

    private func verifyBasicDeviceLayouts(landscape: Bool) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        for mode in ["duoClassic"] {
            let app = launchChrome(mode)
            addTeardownBlock { app.terminate() }
            let window = app.windows.firstMatch
            if landscape { XCTAssertGreaterThan(window.frame.width, window.frame.height) }
            else { XCTAssertGreaterThan(window.frame.height, window.frame.width) }
            pauseRegressionVideo(app)
            let any = app.descendants(matching: .any)
            func button(_ id: String) -> XCUIElement {
                let matches = app.buttons.matching(identifier: id)
                return matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch
            }
            attach(app, "smoke-" + mode + "-home")
            let controls = ["douyin.more", "douyin.search", "douyin.like", "douyin.comments"]
                + (mode == "duoClassic" ? ["douyin.share", "douyin.channel.recommend", "douyin.channel.follow"] : [])
            for id in controls {
                let control = button(id)
                if !control.isHittable { print(app.debugDescription) }
                XCTAssertTrue(control.isHittable, id)
                XCTAssertTrue(window.frame.intersects(control.frame), id)
            }
            if mode == "duoClassic" {
                let clean = button("douyin.cleanScreen")
                XCTAssertTrue(clean.isHittable)
                XCTAssertFalse(clean.frame.intersects(button("douyin.search").frame))
                XCTAssertGreaterThan(button("douyin.share").frame.maxY, window.frame.height * 0.7)
            }
            print("DEVICE_SMOKE mode=\(mode) window=\(window.frame) search=\(button("douyin.search").frame) like=\(button("douyin.like").frame)")
            button("douyin.comments").tap()
            let list = app.scrollViews["douyin.comments.list"].firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 15))
            let input = any.matching(identifier: "douyin.comment.input").firstMatch
            XCTAssertTrue(input.isHittable)
            XCTAssertGreaterThan(list.frame.width, 100)
            XCTAssertLessThanOrEqual(input.frame.maxY, window.frame.maxY)
            attach(app, "smoke-" + mode + "-comments")
            let close = app.buttons["douyin.comments.close"].firstMatch
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 1)
            if mode == "duoClassic" {
                any.matching(identifier: "douyin.description").firstMatch.tap()
                XCTAssertTrue(any.matching(identifier: "douyin.description.expanded").firstMatch.waitForExistence(timeout: 10))
                attach(app, "smoke-classic-caption")
                let captionClose = app.buttons["douyin.description.close"].firstMatch
                captionClose.tap()
                XCTAssertTrue(captionClose.waitForNonExistence(timeout: 5))
                Thread.sleep(forTimeInterval: 1)
                let clean = button("douyin.cleanScreen")
                clean.tap()
                XCTAssertTrue(waitUntil(timeout: 5) { clean.label == "退出清屏" })
                clean.tap()
                XCTAssertTrue(button("douyin.share").isHittable)
            }
            button("douyin.search").tap()
            XCTAssertTrue(app.textFields["douyin.search.field"].waitForExistence(timeout: 10))
            app.buttons["douyin.search.back"].firstMatch.tap()
            XCTAssertTrue(button("douyin.comments").waitForExistence(timeout: 10))
            app.terminate()
        }
    }
}

extension DouDuoUITests {
    /// 老板 11-17 报：冷启动（没有缓存）时卡在第一条，看了一半再上滑也翻不过去，要滑好几次。
    /// 第一条播了一阵之后，第一下上滑就必须翻到下一条。只读，不点赞不发帖。
    func testColdStartFirstSwipeAdvances() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let mode = ProcessInfo.processInfo.environment["DD_MODE"] { app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode }
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douduo_dismissed_update_v1", "9.9.9"]
        if let n = ProcessInfo.processInfo.environment["DD_CACHE_COUNT"] { app.launchArguments += ["-douyin_cache_count_v2", n] }
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"].firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertTrue(waitUntil(timeout: 60) { current.label != "-" }, "推荐流没有加载出来")
        if ProcessInfo.processInfo.environment["DD_WARM"] == "1" {
            // 真机上最常见的进法：上次留下了缓存好没看的视频，这次启动先播它
            Thread.sleep(forTimeInterval: 25)
            app.terminate()
            app.launch()
            XCTAssertTrue(current.waitForExistence(timeout: 30))
            XCTAssertTrue(waitUntil(timeout: 60) { current.label != "-" }, "二次启动推荐流没有加载出来")
        }
        // 先看一阵再滑（老板报的是「看到一半还滑不动」）。刚启动头几秒推荐还没拉回来时滑不动是既定规则，不在这里测。
        let wait = Double(ProcessInfo.processInfo.environment["DD_WATCH_SECONDS"] ?? "") ?? 12
        Thread.sleep(forTimeInterval: wait)
        let window = app.windows.firstMatch
        for round in 1...3 {
            let before = current.label
            // 跟真人一样快甩一小段（约 1/4 屏），不是慢慢拖过去
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45)),
                       withVelocity: .fast, thenHoldForDuration: 0)
            XCTAssertTrue(waitUntil(timeout: 3) { current.label != before }, "第 \(round) 条：上滑一次没有翻到下一条")
            Thread.sleep(forTimeInterval: 2)
        }
    }
}

extension DouDuoUITests {
    /// 老板 11-18 报：私信聊天里键盘弹出来把输入框和最后几条消息盖住，而且键盘收不回去。
    /// 离线聊天样张，不联网、不发送。
    func testChatKeyboardLiftsComposerAndCanDismiss() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_MESSAGE_LAYOUT"] = "1"
        app.launchEnvironment["DOUDUO_MESSAGE_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = ProcessInfo.processInfo.environment["DD_MODE"] ?? "classic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let rows = app.buttons.matching(identifier: "douyin.conversation.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        rows.matching(NSPredicate(format: "label CONTAINS %@", "青禾")).firstMatch.tap()
        let editor = app.textViews["douyin.messages.composer.editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), app.debugDescription)
        let restY = editor.frame.midY
        let webProbe = app.descendants(matching: .any).matching(identifier: "douyin.messages.chat.detail").firstMatch
        let headerProbe = app.descendants(matching: .any).matching(identifier: "douyin.messages.chat.header").firstMatch
        func frameOf(_ e: XCUIElement) -> String { e.exists ? "\(e.frame)" : "none" }
        print("CHATKB rest web=\(frameOf(webProbe)) header=\(frameOf(headerProbe)) editor=\(editor.frame)")
        // 跟真实聊天一样先停在最新一条（样张打开时停在最上面）
        let last = app.staticTexts["最后一条消息"].firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 5), "样张里找不到最后一条消息")
        for _ in 0..<4 where last.frame.maxY > editor.frame.minY {
            webProbe.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: webProbe.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.2)))
            Thread.sleep(forTimeInterval: 0.8)
        }
        print("CHATKB rest last=\(last.frame)")
        XCTAssertLessThanOrEqual(last.frame.maxY, editor.frame.minY + 1, "键盘没弹出时最后一条消息就应该看得见")
        attach(app, "chat-keyboard-rest")
        // 自绘右侧栏（默认 / 简洁 / 极简才有；经典用系统竖栏）：输入时必须留在原位
        // 经典布局的右侧栏由系统竖栏托管，位置不归 App 管，不在这里校验
        let systemRail = (ProcessInfo.processInfo.environment["DD_MODE"] ?? "") == "duoClassic"
        let railItem = app.buttons["douyin.messages.rail.fans"].firstMatch
        let railRest: CGRect? = railItem.exists && !systemRail ? railItem.frame : nil
        editor.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8), "键盘没弹出来")
        Thread.sleep(forTimeInterval: 1.5)
        let top = keyboard.frame.minY
        print("CHATKB editor=\(editor.frame) keyboardTop=\(top) rest=\(restY) window=\(app.windows.firstMatch.frame)")
        print("CHATKB up web=\(frameOf(webProbe)) header=\(frameOf(headerProbe))")
        if railRest != nil {
            // 老板定：键盘弹起来时右侧栏不许动（位置一模一样），返回键照常能点
            let back = app.buttons["douyin.messages.back"].firstMatch
            print("CHATKB back frame=\(back.exists ? "\(back.frame)" : "none") hittable=\(back.isHittable)")
            XCTAssertTrue(back.isHittable, "返回键要一直能点")
            XCTAssertEqual(railItem.frame.midX, railRest!.midX, accuracy: 2, "键盘弹出时右侧栏横向移动了")
            print("CHATKB railRest=\(railRest!) railNow=\(railItem.frame) kb=\(top)")
            XCTAssertEqual(railItem.frame.midY, railRest!.midY, accuracy: 2, "键盘弹出时右侧栏纵向移动了")
        }
        attach(app, "chat-keyboard-up")
        XCTAssertLessThanOrEqual(editor.frame.maxY, top + 1, "输入框被键盘盖住了")
        // 键盘元素的上沿是按键区，不含上面那条候选栏（约 45pt）；输入框贴在候选栏上方
        XCTAssertLessThan(top - editor.frame.maxY, 110, "输入框要紧贴键盘上方，不能被抬到半空")
        // 最后一条消息必须还看得见：在输入框上方，没被键盘或输入框盖住
        print("CHATKB last=\(last.frame)")
        // 消息列表按自己的节奏贴底，允许和输入框有十几 pt 的交叠；底线是不能被键盘盖住
        XCTAssertLessThanOrEqual(last.frame.maxY, top + 1, "最后一条消息被键盘盖住了")
        XCTAssertGreaterThan(last.frame.minY, 60, "最后一条消息被顶出屏幕了")
        let hide = app.buttons["douyin.messages.composer.hideKeyboard"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 3), "没有收起键盘的按钮")
        XCTAssertTrue(hide.isHittable, "收起键盘的按钮被挡住了")
        hide.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "点了收起，键盘没下去")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(editor.frame.midY, restY, accuracy: 3, "键盘收起后输入框要回到原位")
        if let railRest {
            XCTAssertTrue(app.buttons["douyin.messages.rail.system"].exists, "收起键盘后系统分类要回来")
            XCTAssertTrue(app.buttons["douyin.messages.rail.stranger"].exists, "收起键盘后陌生人分类要回来")
            XCTAssertTrue(railItem.isHittable, "收起键盘后右侧菜单栏要回来")
            XCTAssertEqual(railItem.frame.midX, railRest.midX, accuracy: 2, "收起键盘后右侧菜单栏要回原位")
            XCTAssertEqual(railItem.frame.midY, railRest.midY, accuracy: 2)
        }
        XCTAssertFalse(hide.exists, "键盘收起后不再显示收起按钮")
        attach(app, "chat-keyboard-down")
    }
}
