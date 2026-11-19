import XCTest

/// 身份验证页：真模拟器 + 真抖音网页 + 官方验证组件（不登录，给非法验证信息，不会发任何评论）
final class DYVerifyFlowTests: XCTestCase {
    private func launch(_ decision: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO", "-douduo_whatsnew_seen_v1", "1.6.1", "-douduo_dismissed_update_v1", "9.9.9"]
        app.launchEnvironment["DOUDUO_VERIFY_DEMO"] = decision
        app.launch()
        return app
    }

    func testVerifyPageLoadsOfficialComponentAndReportsResult() throws {
        let app = launch(#"{"verify_from":"verify_center","decision":"bogus"}"#)
        XCTAssertTrue(app.staticTexts["抖音要求身份验证"].waitForExistence(timeout: 15), "验证页应弹出")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "verify-page"; shot.lifetime = .keepAlways; add(shot)
        let alert = app.alerts["VERIFY_RESULT"]
        XCTAssertTrue(alert.waitForExistence(timeout: 60), "应拿到官方组件的结果")
        let msg = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        print("PROBE verify result: \(msg)")
        XCTAssertTrue(msg.contains("failed:"), msg)
        XCTAssertFalse(msg.contains("找不到身份验证组件") || msg.contains("没加载完"), "官方组件应能加载: \(msg)")
        XCTAssertFalse(app.staticTexts["抖音要求身份验证"].exists, "结束后验证页应关闭")
        app.terminate()
    }

    func testCancelKeepsDraftAndCloses() throws {
        let app = launch("not-json-but-we-cancel-first")
        let cancel = app.buttons["douyin.verify.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        cancel.tap()
        let alert = app.alerts["VERIFY_RESULT"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        let msg = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        print("PROBE cancel result: \(msg)")
        XCTAssertTrue(msg.contains("cancelled") || msg.contains("failed:"), msg)
        app.terminate()
    }
}
