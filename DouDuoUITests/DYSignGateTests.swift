import XCTest

/// 签名没完成前点发送：立刻提示「等待签名完成才可以发送评论」，不发、不出本地行、草稿还在；签名完成后提示消失
final class DYSignGateTests: XCTestCase {
    func testSendBlockedUntilSigningCompletes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "rail"
        app.launchEnvironment["DOUDUO_HASHTAG_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_SIGN_DELAY"] = "25"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                                "-douduo_dismissed_update_v1", "9.9.9", "-duoduomain_tab_v1", "首页"]
        app.launch()
        let cur = app.staticTexts["douyin.currentID"].firstMatch
        XCTAssertTrue(cur.waitForExistence(timeout: 20))
        let loaded = expectation(for: NSPredicate(format: "label == %@", "hashtag-cat"), evaluatedWith: cur)
        wait(for: [loaded], timeout: 20)
        let button = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(button, "找不到评论按钮")
        button?.tap()
        let input = app.descendants(matching: .any).matching(identifier: "douyin.comment.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("签名测试草稿")
        let send = app.descendants(matching: .any).matching(identifier: "douyin.comment.send").firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        let hint = app.descendants(matching: .any).matching(identifier: "douyin.comment.sendErr").firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 3), "点发送后应立刻提示")
        print("PROBE hint=\(hint.label)")
        XCTAssertTrue(hint.label.hasPrefix("等待签名完成才可以发送评论，约 "), hint.label)
        XCTAssertTrue(hint.label.hasSuffix(" 秒后再点发送"), hint.label)
        // 倒计时在走
        let n1 = Int(hint.label.components(separatedBy: "约 ").last!.components(separatedBy: " ").first!) ?? -1
        sleep(3)
        let n2 = Int(hint.label.components(separatedBy: "约 ").last!.components(separatedBy: " ").first!) ?? -1
        print("PROBE countdown \(n1) -> \(n2)")
        XCTAssertTrue(n1 > n2 && n2 > 0, "倒计时应减少: \(n1) -> \(n2)")
        let draftValue = (input.value as? String) ?? ""
        print("PROBE draft-after-blocked=\(draftValue.contains("签名测试草稿") ? "kept" : "lost:" + draftValue)")
        XCTAssertTrue(draftValue.contains("签名测试草稿"), "草稿应保留")
        XCTAssertFalse(app.staticTexts["签名测试草稿"].exists, "不应出现本地评论行")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "sign-gate-blocked"; shot.lifetime = .keepAlways; add(shot)
        // 签名完成后提示自动消失
        let done = NSPredicate(format: "label == %@", "签名完成，现在可以发送了")
        expectation(for: done, evaluatedWith: app.descendants(matching: .any).matching(identifier: "douyin.comment.sendErr").firstMatch)
        waitForExpectations(timeout: 40)
        print("PROBE done-hint shown")
        let shot2 = XCTAttachment(screenshot: app.screenshot()); shot2.name = "sign-gate-done"; shot2.lifetime = .keepAlways; add(shot2)
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.descendants(matching: .any).matching(identifier: "douyin.comment.sendErr").firstMatch)
        waitForExpectations(timeout: 8)
        print("PROBE hint-cleared-after-sign=1")
        app.terminate()
    }

    /// 侧栏模式模块菜单里有「信息」，点它进信息页（不是我的页）；「我的」进我的页
    func testModuleMenuMessagesEntry() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "rail"
        app.launchEnvironment["DOUDUO_HASHTAG_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_MESSAGE_FIXTURE"] = "1"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                                "-douduo_dismissed_update_v1", "9.9.9", "-duoduomain_tab_v1", "首页"]
        app.launch()
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 30)); menu.tap()
        let info = app.buttons["douyin.module.messages"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5), "模块菜单里没有「信息」")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "module-menu-info"; shot.lifetime = .keepAlways; add(shot)
        info.tap()
        // 进的是信息页（消息列表），不是我的页
        let title = app.staticTexts["douyin.messages.list.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "没进信息页")
        XCTAssertEqual(title.label, "消息")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "douyin.messages.interactive").firstMatch.exists, "信息页应有互动消息")
        print("PROBE info-page title=\(title.label)")
        let shot2 = XCTAttachment(screenshot: app.screenshot()); shot2.name = "info-page"; shot2.lifetime = .keepAlways; add(shot2)
        app.terminate()
    }
}
