#if os(iOS)
import Contacts
import XCTest

/// Opt-in simulator smoke for what unit tests cannot prove: the Contacts chooser, each deep link
/// opening its app (or falling back), and a delivered local reminder. It creates and removes one
/// synthetic contact card. Run with TEST_RUNNER_CIRCLE_SMOKE=1 after granting Contacts access to
/// the app and the test runner (`xcrun simctl privacy <udid> grant contacts <bundle id>`).
final class ReachOutSmokeUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    @MainActor
    func testDeepLinksContactsChooserAndReminder() throws {
        guard ProcessInfo.processInfo.environment["CIRCLE_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in simulator smoke")
        }
        let store = CNContactStore()
        try removeSyntheticCards(store)
        let card = CNMutableContact()
        card.givenName = "Person"; card.familyName = "5"
        card.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "(555) 010-0155"))]
        card.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "person5@example.com" as NSString)]
        let save = CNSaveRequest(); save.add(card, toContainerWithIdentifier: nil)
        try store.execute(save)
        // A failed UI step ends the test without running defers; teardown blocks always run.
        addTeardownBlock { try? self.removeSyntheticCards(store) }

        let app = XCUIApplication()
        app.launchArguments = ["--preview-graph", "--reset-explorer-preferences", "--reduce-motion"]
        app.launch()
        app.tabBars.buttons["Reach out"].tap()
        XCTAssertTrue(app.buttons["reachout-person-05"].waitForExistence(timeout: 10))
        snap("1 Reach out list")

        // Matched by name: the chooser always asks, and opening Messages is not contact.
        app.buttons["contact-message-person-05"].tap()
        choose(app, containing: "010-0155")
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.MobileSMS").wait(for: .runningForeground, timeout: 10))
        snap("2 sms opens Messages")
        returnTo(app)

        app.buttons["contact-call-person-05"].tap()
        choose(app, containing: "010-0155")
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS 'No app on this device opens Call'")).firstMatch.waitForExistence(timeout: 10))
        snap("3 tel has no handler on the simulator")
        app.alerts.buttons["OK"].tap()

        app.buttons["contact-whatsapp-person-05"].tap()
        choose(app, containing: "010-0155")
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        snap("4 whatsapp falls back to wa.me in Safari")
        returnTo(app)

        app.buttons["contact-facetime-person-05"].tap()
        choose(app, containing: "person5@example.com")
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS 'No app on this device opens FaceTime'")).firstMatch.waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()

        // Reminders: person 5 is overdue, so an enabled reminder is delivered within seconds.
        app.buttons["reachout-person-05"].tap()
        XCTAssertTrue(app.staticTexts["reachout-status"].waitForExistence(timeout: 5))
        snap("5 Person sheet top")
        let toggle = app.switches["reminders-toggle"]
        for _ in 0..<10 where !(toggle.exists && toggle.isHittable) { app.swipeUp() }
        snap("5 Person sheet")
        // A Form toggle only flips on its switch, not on its label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Notifications are off'")).firstMatch.exists)
        // XCUITest cannot query system banners; the screen capture includes them. The reminder
        // fires five seconds after scheduling and shows for about five more.
        for frame in 1...5 {
            Thread.sleep(forTimeInterval: 1.5)
            snap("6 Reminder frame \(frame)")
        }
    }

    private func returnTo(_ app: XCUIApplication) {
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.buttons["reachout-person-05"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func choose(_ app: XCUIApplication, containing text: String) {
        let option = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        snap("chooser \(text)")
        option.tap()
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func removeSyntheticCards(_ store: CNContactStore) throws {
        let found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: "Person 5"),
                                              keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor])
        let delete = CNSaveRequest()
        for contact in found where contact.givenName == "Person" && contact.familyName == "5" {
            delete.delete(contact.mutableCopy() as! CNMutableContact)
        }
        try store.execute(delete)
    }
}
#endif
