import XCTest

final class ExplorerUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testNormalLaunchNeverPretendsToHavePersonalData() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Your circle starts here"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Synthetic preview"].exists)
        XCTAssertFalse(app.buttons["person-person-01"].exists)
    }

    @MainActor
    func testExplorerFocusLayoutsSearchAndBack() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-graph", "--reset-explorer-preferences"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Synthetic preview"].waitForExistence(timeout: 10))
        let search = app.textFields["Find a person"]
        XCTAssertTrue(search.exists)
        search.clickOrTap()
        search.typeText("Person 1")
        app.buttons["search-person-01"].clickOrTap()
        XCTAssertTrue(app.staticTexts["Focus: Person 1"].waitForExistence(timeout: 3))
        app.buttons["layout-pathways"].clickOrTap()
        XCTAssertTrue(app.staticTexts["Focus: Person 1"].exists)
        app.buttons["layout-orbits"].clickOrTap()
        XCTAssertTrue(app.staticTexts["Focus: Person 1"].exists)
        app.buttons["Back"].clickOrTap()
        XCTAssertTrue(app.staticTexts["Focus: You"].exists)
        app.buttons["group-Circle 1"].clickOrTap()
        XCTAssertTrue(app.staticTexts["Focus: Circle 1"].exists)
        app.buttons["Back to me"].clickOrTap()
        XCTAssertTrue(app.staticTexts["Focus: You"].exists)
        app.buttons["Zoom in"].clickOrTap()
        app.buttons["Zoom out"].clickOrTap()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Native explorer"; shot.lifetime = .keepAlways; add(shot)
    }
}

private extension XCUIElement {
    func clickOrTap() {
        #if os(macOS)
        click()
        #else
        tap()
        #endif
    }
}
