import XCTest

final class NativeChromeUITests: XCTestCase {
  func testNativeTabSelectionAndBack() {
    let app = XCUIApplication()
    app.launch()

    let renderer = app.staticTexts["Tab renderer: native, bottom"]
    XCTAssertTrue(renderer.waitForExistence(timeout: 20))
    let tabBar = app.tabBars.firstMatch
    XCTAssertTrue(tabBar.exists)
    let browse = tabBar.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Browse")).firstMatch
    XCTAssertTrue(browse.exists)
    browse.tap()
    XCTAssertTrue(app.staticTexts["Selected: Browse"].waitForExistence(timeout: 5))

    app.buttons["Open detail"].tap()
    XCTAssertTrue(app.staticTexts["Detail page"].waitForExistence(timeout: 5))
    let back = app.buttons["Back"].firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
    XCTAssertTrue(renderer.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Selected: Browse"].exists)
    XCTAssertTrue(browse.exists)
  }
}
