import XCTest
final class TypingTest: XCTestCase {
    func testTyping() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "org.svarovsky.thimble")
        app.launch()
        let field = app.textFields["Handle"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        sleep(1)
        var seen: [String] = []
        for ch in "oogboog" {
            app.typeText(String(ch))
            usleep(400000)
            XCTAssertEqual(app.state, .runningForeground, "app died after \(seen)")
            seen.append((field.value as? String) ?? "nil")
            print("LABELS typed:", seen.last!, "focus:", (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false)
        }
        XCTAssertEqual(seen.last, "oogboog", "typed text")
    }
    func testTypingAfterSignOut() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication(bundleIdentifier: "org.svarovsky.thimble")
        app.launch()
        let field = app.textFields["Handle"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap(); app.typeText(env["A_HANDLE"]!)
        let pw = app.secureTextFields["App password"]
        pw.tap(); app.typeText(env["A_APP_PASSWORD"]!)
        app.buttons["Sign in"].firstMatch.tap()
        let you = app.tabBars.buttons["You"]
        XCTAssertTrue(you.waitForExistence(timeout: 30), "signed in")
        sleep(3)
        you.tap()
        sleep(3)
        let bar = app.navigationBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        bar.buttons.element(boundBy: bar.buttons.count - 1).tap()
        let f2 = app.textFields["Handle"]
        XCTAssertTrue(f2.waitForExistence(timeout: 20), "login screen after sign-out")
        f2.tap()
        sleep(1)
        var seen: [String] = []
        for ch in "oogboog" {
            app.typeText(String(ch))
            sleep(1)
            XCTAssertEqual(app.state, .runningForeground, "app died after \(seen)")
            seen.append((f2.value as? String) ?? "nil")
            print("LABELS after-signout typed:", seen.last!)
        }
        XCTAssertEqual(seen.last, "oogboog", "typed text after sign-out")
    }
}
