import XCTest

final class ExplorerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    @MainActor
    private func testApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CIRCLE_UI_TEST_EMPTY_CONNECTION"] = "1"
        return app
    }

    @MainActor
    func testNormalLaunchNeverPretendsToHavePersonalData() {
        let app = testApp()
        app.launch()
        XCTAssertTrue(app.staticTexts["Your circle starts here"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Synthetic preview"].exists)
        XCTAssertFalse(app.buttons["person-person-01"].exists)
    }

    @MainActor
    func testConnectionFormRejectsUnsafeURLBeforeEnrollment() {
        let app = testApp()
        app.launch()
        let endpoint = app.textFields["Service URL"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        endpoint.clickOrTap()
        endpoint.typeText("http://example.invalid")
        app.buttons["Connect to People"].clickOrTap()
        XCTAssertTrue(app.staticTexts["connection-error"].waitForExistence(timeout: 3))
        #if os(macOS)
        XCTAssertEqual(app.staticTexts["connection-error"].value as? String, "Enter an HTTPS service URL without a path, query, or password.")
        #else
        XCTAssertEqual(app.staticTexts["connection-error"].label, "Enter an HTTPS service URL without a path, query, or password.")
        #endif
        XCTAssertFalse(app.links["Approve read-only access"].exists)
        XCTAssertTrue(app.staticTexts["Your circle starts here"].exists)
    }

    @MainActor
    func testOptInLiveEnrollmentAndRecovery() throws {
        guard let endpoint = ProcessInfo.processInfo.environment["CIRCLE_LIVE_ENDPOINT"] else {
            throw XCTSkip("Live enrollment requires an explicit service endpoint")
        }
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["Service URL"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.clickOrTap()
        field.typeText(endpoint)
        app.buttons["Connect to People"].clickOrTap()
        let approval = app.links["Approve read-only access"]
        XCTAssertTrue(approval.waitForExistence(timeout: 10))
        print("CIRCLE_APPROVAL_URL=\(approval.value as? String ?? "missing")")
        XCTAssertTrue(menu(app).waitForExistence(timeout: 270))
        XCTAssertTrue(app.textFields["Find a person"].exists)
        XCTAssertFalse(app.staticTexts["connection-error"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(menu(app).waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields["Find a person"].exists)
        XCTAssertFalse(app.staticTexts["Synthetic preview"].exists)
    }

    @MainActor
    func testExplorerFocusLayoutsSearchAndBack() {
        let app = testApp()
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
        choose("Pathways", in: app)
        XCTAssertTrue(app.staticTexts["Focus: Person 1"].exists)
        choose("Orbits", in: app)
        XCTAssertTrue(app.staticTexts["Focus: Person 1"].exists)
        app.buttons["Back"].clickOrTap()
        XCTAssertTrue(app.staticTexts["Focus: You"].exists)
        openDetails(app)
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
        let app = testApp()
        app.launchArguments = ["--preview-graph", "--reset-explorer-preferences"]
        app.launch()
        let search = app.textFields["Find a person"]
        search.clickOrTap()
        search.typeText("Person 1")
        app.buttons["search-person-01"].clickOrTap()
        openDetails(app)
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
        openDetails(app)
        XCTAssertEqual(app.buttons["tracking-person-01"].value as? String, "Tracked")
        app.buttons["tracking-person-01"].clickOrTap()
        XCTAssertFalse(app.buttons["tracked-person-01"].exists)
    }

    @MainActor
    private func openReachOutTab(_ app: XCUIApplication) {
        #if os(macOS)
        let tab = app.radioButtons["Reach out"].exists ? app.radioButtons["Reach out"] : app.buttons["Reach out"]
        #else
        let tab = app.tabBars.buttons["Reach out"].exists ? app.tabBars.buttons["Reach out"] : app.buttons["Reach out"]
        #endif
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.clickOrTap()
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        // Lists load rows lazily, so a row above the viewport does not exist yet: search both ways.
        for down in [true, false] {
            for _ in 0..<10 where !(element.exists && element.isHittable) {
                #if os(macOS)
                app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: down ? -200 : 200)
                #else
                if down { app.swipeUp() } else { app.swipeDown() }
                #endif
            }
        }
    }

    @MainActor
    func testReachOutGroupsExplainReasonsAndSettingsPersist() {
        let app = testApp()
        app.launchArguments = ["--preview-graph", "--reset-explorer-preferences", "--reduce-motion"]
        app.launch()
        openReachOutTab(app)
        XCTAssertTrue(app.staticTexts["reachout-group-due"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'History refreshed'")).firstMatch.exists)
        let person = app.buttons["reachout-person-01"]
        XCTAssertTrue(person.waitForExistence(timeout: 5))
        XCTAssertTrue(person.label.contains("since your last sent message"), person.label)
        XCTAssertTrue(person.label.contains("does not reset"), person.label)
        // Incoming-only history is unknown, never "never contacted".
        let unknown = app.buttons["reachout-person-08"]
        scrollTo(unknown, in: app)
        XCTAssertTrue(unknown.label.contains("Unknown"), unknown.label)
        XCTAssertFalse(unknown.label.lowercased().contains("never contacted"))
        scrollTo(person, in: app)
        person.clickOrTap()
        XCTAssertTrue(app.staticTexts["reachout-status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["history-imessage"].exists || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'iMessage'")).firstMatch.exists)
        let quarterly = app.buttons["cadence-quarterly"]
        scrollTo(quarterly, in: app)
        quarterly.clickOrTap()
        let high = app.buttons["priority-high"]
        scrollTo(high, in: app)
        high.clickOrTap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Reach-out person"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate()
        app.launchArguments = ["--preview-graph", "--reduce-motion"]
        app.launch()
        openReachOutTab(app)
        XCTAssertTrue(app.staticTexts["reachout-group-due"].waitForExistence(timeout: 10))
        let again = app.buttons["reachout-person-01"]
        scrollTo(again, in: app)
        XCTAssertTrue(app.staticTexts["reachout-group-month"].exists)
        // A quarterly cadence moves 40 days of silence out of Due into the one-month group.
        XCTAssertTrue(again.label.contains("Every three months cadence"), again.label)
        XCTAssertTrue(again.label.contains("High priority"), again.label)
        again.clickOrTap()
        let saved = app.buttons["cadence-quarterly"]
        scrollTo(saved, in: app)
        XCTAssertEqual(saved.value as? String, "Selected")
    }

    @MainActor
    func testZoomedOutOverviewKeepsNamesAccessibleAndFocusReadable() {
        let app = testApp()
        app.launchArguments = ["--preview-graph", "--reset-explorer-preferences", "--reduce-motion"]
        app.launch()
        XCTAssertTrue(app.buttons["person-person-00"].waitForExistence(timeout: 5))
        for _ in 0..<8 { app.buttons["Zoom out"].clickOrTap() }
        let focused = app.buttons["person-person-00"]
        let others = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "person-", "person-person-00")).allElementsBoundByIndex
        XCTAssertFalse(others.isEmpty)
        for node in others {
            XCTAssertFalse(node.label.isEmpty, "Overview dots retain their full accessible names")
            XCTAssertLessThan(node.frame.height, focused.frame.height - 10)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Readable overview"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testNodeDragPanAndZoom() {
        let app = testApp()
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
        #if os(macOS)
        // A pointer drag on a person moves only that person.
        XCTAssertEqual(neighbor.frame.midX, otherStart.midX, accuracy: 3)
        #else
        // A touch swipe that starts on a person pans the whole graph with the finger.
        XCTAssertEqual(neighbor.frame.midX - otherStart.midX, node.frame.midX - start.midX, accuracy: 3)
        #endif
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

    #if os(iOS)
    /// A quick flick keeps the graph moving past the finger, so crossing a large graph takes few swipes.
    @MainActor
    func testFlickCarriesTheGraphFurtherThanTheFinger() {
        let app = testApp()
        app.launchArguments = ["--preview-graph", "--reset-explorer-preferences"]
        app.launch()
        let node = app.buttons["person-person-00"]
        XCTAssertTrue(node.waitForExistence(timeout: 5))
        let start = node.frame
        let from = node.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: -80, dy: 0)),
                   withVelocity: XCUIGestureVelocity(2500), thenHoldForDuration: 0)
        let moved = expectation(for: NSPredicate { _, _ in node.exists && node.frame.midX < start.midX - 110 || !node.exists },
                                evaluatedWith: nil)
        wait(for: [moved], timeout: 3)
    }
    #endif

    @MainActor
    func testLocationAndPreferencesSurviveRelaunch() {
        let app = testApp()
        app.launchArguments = ["--preview-graph", "--reset-explorer-preferences"]
        app.launch()
        choose("City", in: app)
        choose("Currently in", in: app)
        openDetails(app)
        app.buttons["group-city:unknown"].clickOrTap()
        XCTAssertTrue(app.staticTexts["Focus: Unknown"].exists)
        closeDetails(app)
        choose("Orbits", in: app)
        app.terminate()
        app.launchArguments = ["--preview-graph"]
        app.launch()
        XCTAssertTrue(menu(app).waitForExistence(timeout: 5))
        XCTAssertEqual(menu(app).value as? String, "Orbits · grouped by city · currently in")
        choose("Constellation", in: app)
        XCTAssertEqual(menu(app).value as? String, "Constellation · grouped by city · currently in")
        openDetails(app)
        XCTAssertTrue(app.buttons["group-city:unknown"].exists)
    }

    @MainActor
    func testMapGroupsByCircleAndOpensPersonFacts() {
        let app = testApp()
        app.launchArguments = ["--preview-graph", "--reduce-motion"]
        app.launch()
        #if os(macOS)
        let mapTab = app.radioButtons["Map"]
        #else
        let mapTab = app.tabBars.buttons["Map"]
        #endif
        XCTAssertTrue(mapTab.waitForExistence(timeout: 10))
        mapTab.clickOrTap()
        XCTAssertTrue(app.staticTexts["Met where"].waitForExistence(timeout: 5))
        app.buttons["map-circle-Circle 1"].clickOrTap()
        XCTAssertTrue(app.staticTexts["People in Circle 1"].waitForExistence(timeout: 5))
        app.buttons["map-person-person-01"].clickOrTap()
        XCTAssertTrue(app.staticTexts["Base history"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["Profile photo from Instagram"].waitForExistence(timeout: 5))
        app.buttons["Done"].clickOrTap()
        XCTAssertTrue(app.staticTexts["People in Circle 1"].waitForExistence(timeout: 5))
    }

    /// Everyone based in one city shares a pin; tapping it lists them with photos to choose from.
    @MainActor
    func testMapClusterOpensAChooserWithEveryoneThere() {
        let app = testApp()
        app.launchArguments = ["--preview-graph", "--reduce-motion"]
        app.launch()
        #if os(macOS)
        let mapTab = app.radioButtons["Map"]
        #else
        let mapTab = app.tabBars.buttons["Map"]
        #endif
        XCTAssertTrue(mapTab.waitForExistence(timeout: 10))
        mapTab.clickOrTap()
        // Synthetic people live in three public cities; geocoding needs the system service.
        let cluster = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'cluster-'")).firstMatch
        XCTAssertTrue(cluster.waitForExistence(timeout: 30))
        cluster.clickOrTap()
        let person = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'cluster-person-'")).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Map cluster chooser"; shot.lifetime = .keepAlways; add(shot)
        person.clickOrTap()
        XCTAssertTrue(app.staticTexts["Base history"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func menu(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "circle-menu").firstMatch
    }

    /// Picks one entry from the explorer's bottom-right menu.
    @MainActor
    private func choose(_ item: String, in app: XCUIApplication) {
        let button = menu(app)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.clickOrTap()
        #if os(macOS)
        let entry = app.menuItems[item]
        #else
        let entry = app.buttons[item]
        #endif
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.clickOrTap()
    }

    /// Compact layouts show details in a sheet; wide ones keep them beside the graph.
    @MainActor
    private func openDetails(_ app: XCUIApplication) {
        let card = app.buttons["focus-details"]
        if card.exists { card.clickOrTap() }
    }

    @MainActor
    private func closeDetails(_ app: XCUIApplication) {
        if !app.buttons["focus-details"].exists { return }
        let done = app.buttons["Done"]
        if done.exists { done.clickOrTap() }
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
