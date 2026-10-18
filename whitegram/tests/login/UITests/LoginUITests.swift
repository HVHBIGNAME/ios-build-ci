import XCTest

final class LoginUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "whitegram.telegra.Telegraph")

    override func setUp() {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["WHITEGRAM_LOGIN_PROBE"] = "__PROBE_TOKEN__"
        app.launch()
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func element(_ identifier: String) -> XCUIElement {
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func replaceText(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        let value = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count) + text)
    }

    func testProductionLoginRequest() {
        let start = element("Auth.Welcome.StartButton")
        if start.waitForExistence(timeout: 20) { start.tap() }
        capture("01-login-screen")
        replaceText(app.textFields["Auth.PhoneEntry.CountryCodeField"], with: "1")
        // NANPA reserves 555-0100...0199 for fictional use; do not call a random subscriber.
        replaceText(app.textFields["Auth.PhoneEntry.PhoneNumberField"], with: "2025550147")
        capture("02-number-entered")
        let next = element("Auth.PhoneEntry.ContinueButton")
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(next.isEnabled)
        next.tap()
        let confirm = element("Auth.PhoneConfirm.ContinueButton")
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        capture("03-request-submitted")
        // The Python runner evaluates the real MTProto completion, not this wait or UI survival.
        Thread.sleep(forTimeInterval: 40)
        capture("04-login-result")
    }

    override func tearDown() {
        capture("05-final-state")
    }
}
