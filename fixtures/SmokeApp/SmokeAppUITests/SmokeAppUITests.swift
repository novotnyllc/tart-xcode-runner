import XCTest

final class SmokeAppUITests: XCTestCase {
    func testLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["ready"].waitForExistence(timeout: 10))
    }
}
