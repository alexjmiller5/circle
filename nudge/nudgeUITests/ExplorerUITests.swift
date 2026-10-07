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
        #if os(iOS)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Selecting a search result should dismiss the keyboard")
        #endif
        XCTAssertTrue(app.staticTexts["Focus: Person 1"].waitForExistence(timeout: 3))
        app.buttons["layout-pathways"].clickOrTap()
        XCTAssertTrue(app.staticTexts["Focus: Person 1"].exists)
        app.buttons["layout-orbits"].clickOrTap()
        XCTAssertTrue(app.staticTexts["Focus: Person 1"].exists)
        app.buttons["Back"].clickOrTap()
        XCTAssertTrue(app.staticTexts["Focus: You"].exists)
        app.buttons["group-circle:value:Circle 1"].clickOrTap()
        XCTAssertTrue(app.staticTexts["Focus: Circle 1"].exists)
        app.buttons["Back to me"].clickOrTap()
        XCTAssertTrue(app.staticTexts["Focus: You"].exists)
        app.buttons["Zoom in"].clickOrTap()
        app.buttons["Zoom out"].clickOrTap()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Native explorer"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor
    func testTrackingSurvivesRelaunchAndCanBeRemoved() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-graph", "--reset-explorer-preferences"]
        app.launch()
        let search = app.textFields["Find a person"]
        search.clickOrTap()
        search.typeText("Person 1")
        app.buttons["search-person-01"].clickOrTap()
        let track = app.buttons["tracking-person-01"]
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        track.clickOrTap()
        XCTAssertEqual(track.value as? String, "Tracked")
        app.terminate()
        app.launchArguments = ["--preview-graph"]
        app.launch()
        let tracked = app.buttons["tracked-person-01"]
        XCTAssertTrue(tracked.waitForExistence(timeout: 5))
        tracked.clickOrTap()
        XCTAssertEqual(app.buttons["tracking-person-01"].value as? String, "Tracked")
        app.buttons["tracking-person-01"].clickOrTap()
        XCTAssertFalse(app.buttons["tracked-person-01"].exists)
    }

    @MainActor
    func testReachOutHistoryUnknownAndSettingsPersist() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-graph", "--reset-explorer-preferences"]
        app.launch()
        app.textFields["Find a person"].clickOrTap()
        app.textFields["Find a person"].typeText("Person 1")
        app.buttons["search-person-01"].clickOrTap()
        app.buttons["tracking-person-01"].clickOrTap()
        app.buttons["Reach out"].clickOrTap()
        XCTAssertTrue(app.staticTexts["History incomplete"].waitForExistence(timeout: 5))
        app.buttons["reachout-person-01"].clickOrTap()
        XCTAssertTrue(app.staticTexts["No verified contact history is connected."].exists)
        app.buttons["cadence-quarterly"].clickOrTap()
        app.buttons["priority-high"].clickOrTap()
        app.terminate()
        app.launchArguments = ["--preview-graph"]
        app.launch()
        app.buttons["Reach out"].clickOrTap()
        app.buttons["reachout-person-01"].clickOrTap()
        XCTAssertEqual(app.buttons["cadence-quarterly"].value as? String, "Selected")
        XCTAssertEqual(app.buttons["priority-high"].value as? String, "Selected")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Reach-out settings"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor
    func testNodeDragPanAndZoom() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-graph", "--reset-explorer-preferences", "--reduce-motion"]
        app.launch()
        let node = app.buttons["person-person-00"]
        XCTAssertTrue(node.waitForExistence(timeout: 5))
        let neighbor = app.buttons["person-person-01"]
        let start = node.frame
        let otherStart = neighbor.frame
        let from = node.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 55, dy: 0)))
        XCTAssertGreaterThan(node.frame.midX, start.midX + 35)
        XCTAssertEqual(neighbor.frame.midX, otherStart.midX, accuracy: 3)
        let moved = node.frame
        let background = node.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -145))
        background.press(forDuration: 0.1, thenDragTo: background.withOffset(CGVector(dx: -45, dy: 0)))
        XCTAssertLessThan(node.frame.midX, moved.midX - 25)
        app.buttons["Back to me"].clickOrTap()
        XCTAssertEqual(node.frame.midX, start.midX, accuracy: 3)
        XCTAssertEqual(node.frame.midY, start.midY, accuracy: 3)
        app.buttons["Zoom in"].clickOrTap()
        XCTAssertEqual(app.staticTexts["graph-zoom"].displayedText, "120%")
        app.buttons["Zoom out"].clickOrTap()
        XCTAssertEqual(app.staticTexts["graph-zoom"].displayedText, "100%")
        #if os(iOS)
        node.pinch(withScale: 1.4, velocity: 1)
        XCTAssertNotEqual(app.staticTexts["graph-zoom"].displayedText, "100%")
        #endif
    }

    @MainActor
    func testLocationAndPreferencesSurviveRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-graph", "--reset-explorer-preferences"]
        app.launch()
        app.buttons["grouping-city"].clickOrTap()
        app.buttons["location-current"].clickOrTap()
        app.buttons["group-city:unknown"].clickOrTap()
        XCTAssertTrue(app.staticTexts["Focus: Unknown"].exists)
        app.buttons["layout-orbits"].clickOrTap()
        app.terminate()
        app.launchArguments = ["--preview-graph"]
        app.launch()
        XCTAssertEqual(app.buttons["layout-orbits"].value as? String, "Selected")
        app.buttons["layout-constellation"].clickOrTap()
        XCTAssertEqual(app.buttons["location-current"].value as? String, "Selected")
        XCTAssertTrue(app.buttons["group-city:unknown"].exists)
    }

}

private extension XCUIElement {
    var displayedText: String { label.isEmpty ? (value as? String ?? "") : label }
    func clickOrTap() {
        #if os(macOS)
        if !isHittable {
            let scroll = XCUIApplication().scrollViews.firstMatch
            let window = XCUIApplication().windows.firstMatch.frame
            for _ in 0..<5 where !isHittable {
                scroll.scroll(byDeltaX: 0, deltaY: frame.midY > window.midY ? -180 : 180)
            }
        }
        XCTAssertTrue(isHittable)
        click()
        #else
        tap()
        #endif
    }
}
