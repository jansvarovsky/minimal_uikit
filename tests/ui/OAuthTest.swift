import XCTest
final class OAuthTest: XCTestCase {
    func shot(_ n: String) { let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = n; a.lifetime = .keepAlways; add(a) }
    func testOAuth() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let handle = env["A_HANDLE"]!, password = env["A_PASSWORD"]!
        let app = XCUIApplication(bundleIdentifier: "org.svarovsky.thimble")
        app.launchEnvironment["THIMBLE_OAUTH_DEV"] = "1"
        app.launch()
        let field = app.textFields["Handle"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap(); field.typeText(handle)
        app.buttons["Sign in with browser"].tap()
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(sb.buttons["Continue"].waitForExistence(timeout: 20), "consent alert")
        sb.buttons["Continue"].tap()
        let web = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let pw = web.secureTextFields.firstMatch
        XCTAssertTrue(pw.waitForExistence(timeout: 40), "password field: " + web.debugDescription.prefix(3000))
        shot("signin")
        pw.tap(); pw.typeText(password + "\n")
        let accept = web.buttons.matching(NSPredicate(format: "label IN {'Accept','Authorize','Allow','Continue'}")).firstMatch
        var tapped = false
        for _ in 0..<40 {
            if app.tabBars.buttons["You"].exists { break }
            if !tapped && accept.exists && accept.isHittable { shot("consent"); print("LABELS tapping consent:", accept.label); accept.tap(); tapped = true }
            sleep(1)
        }
        if !app.tabBars.buttons["You"].exists { shot("stuck"); print("LABELS stuck") }
        XCTAssertTrue(app.tabBars.buttons["You"].waitForExistence(timeout: 40), "app after sign-in: " + app.debugDescription.prefix(2000))
        shot("signedin")
        app.tabBars.buttons["You"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'followers'")).firstMatch.waitForExistence(timeout: 30), "signed API call: " + app.debugDescription.prefix(2000))
        app.tabBars.buttons["Chats"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Thimble test DM'")).firstMatch.waitForExistence(timeout: 30), "chat over OAuth")
        shot("chats")
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["You"].waitForExistence(timeout: 20), "session survives relaunch")
        app.tabBars.buttons["You"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'followers'")).firstMatch.waitForExistence(timeout: 30), "DPoP key restored after relaunch")
    }
}
