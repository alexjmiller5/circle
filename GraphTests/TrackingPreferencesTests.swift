import Foundation
import Testing
@testable import CircleGraph

@Test func trackingPersistsPerProfileWithoutChangingCanonicalCircles() throws {
    let suite = "circle-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preview = TrackingPreferencesStore(defaults: defaults, profile: "preview")
    var tracked = preview.load()
    tracked.insert("person-1")
    preview.save(tracked)
    #expect(preview.load() == ["person-1"])
    let connected = TrackingPreferencesStore(defaults: defaults, profile: "connected")
    #expect(connected.load().isEmpty)
    tracked.remove("person-1")
    preview.save(tracked)
    #expect(preview.load().isEmpty)
}

@Test func trackingIgnoresMalformedEntriesWithoutLosingValidIDs() throws {
    let suite = "circle-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["person-1", "", "person-1", 42], forKey: "tracking-v1-preview")
    #expect(TrackingPreferencesStore(defaults: defaults, profile: "preview").load() == ["person-1"])
}
