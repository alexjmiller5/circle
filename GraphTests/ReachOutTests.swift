import Foundation
import Testing
@testable import CircleGraph

private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

@Test func onlyProvenDirectContactResetsTheDefaultClock() {
    let now = instant("2026-03-10T12:00:00Z")
    let sent = ContactInteraction(id: "sent", personID: "p", occurredAt: now, kind: .outgoingMessage, verified: true, direct: true, participantsComplete: true, identityResolved: true)
    let received = ContactInteraction(id: "received", personID: "p", occurredAt: now, kind: .incomingMessage, verified: true, direct: true, participantsComplete: true, identityResolved: true)
    let attempt = ContactInteraction(id: "attempt", personID: "p", occurredAt: now, kind: .callAttempt, verified: true, direct: true, participantsComplete: true, identityResolved: true)
    let pending = ContactInteraction(id: "pending", personID: "p", occurredAt: now, kind: .outgoingMessage, verified: false)
    var group = sent; group.id = "group"; group.direct = false
    var partial = sent; partial.id = "partial"; partial.participantsComplete = false
    var unknownPerson = sent; unknownPerson.id = "unresolved"; unknownPerson.identityResolved = false
    let settings = ReachOutPreferences()
    #expect([sent, received, attempt, pending, group, partial, unknownPerson].filter { $0.qualifies(settings: settings, now: now) }.map(\.id) == ["sent"])
    var enabled = settings
    enabled.resetKinds.insert(.incomingMessage)
    #expect(received.qualifies(settings: enabled, now: now))
    #expect(!ContactInteraction(id: "future", personID: "p", occurredAt: now.addingTimeInterval(1), kind: .hangout, verified: true, direct: true, participantsComplete: true, identityResolved: true).qualifies(settings: settings, now: now))
}

@Test func monthlyCadenceUsesCalendarAndSnoozeDoesNotChangeEvidence() {
    let last = instant("2026-01-31T12:00:00Z")
    let now = instant("2026-03-01T12:00:00Z")
    let event = ContactInteraction(id: "call", personID: "p", occurredAt: last, kind: .answeredCall, verified: true, direct: true, participantsComplete: true, identityResolved: true)
    var settings = ReachOutPreferences()
    let due = ReachOutAssessment(personID: "p", interactions: [event], history: .ready, settings: settings, now: now)
    #expect(due.lastContact == last)
    #expect(due.dueAt == instant("2026-02-28T12:00:00Z"))
    #expect(due.bucket == .overdue)
    #expect(!due.notificationEligible)
    settings.remindersEnabled = true
    settings.snoozedUntil = instant("2026-03-05T12:00:00Z")
    let snoozed = ReachOutAssessment(personID: "p", interactions: [event], history: .ready, settings: settings, now: now)
    #expect(snoozed.bucket == .snoozed)
    #expect(snoozed.lastContact == last)
    #expect(!snoozed.notificationEligible)
}

@Test func partialHistoryAndRetractionsNeverCreateNeverContactedClaims() {
    let now = instant("2026-03-10T12:00:00Z")
    let old = ContactInteraction(id: "old", personID: "p", occurredAt: instant("2026-01-01T12:00:00Z"), kind: .outgoingMessage, verified: true, direct: true, participantsComplete: true, identityResolved: true)
    var settings = ReachOutPreferences(); settings.remindersEnabled = true
    let partial = ReachOutAssessment(personID: "p", interactions: [old], history: .incomplete, settings: settings, now: now)
    #expect(partial.lastContact == old.occurredAt)
    #expect(partial.bucket == .historyIncomplete)
    #expect(!partial.notificationEligible)
    var corrected = old; corrected.personID = "other"
    let afterCorrection = ReachOutAssessment(personID: "p", interactions: [corrected], history: .dataPending, settings: settings, now: now)
    #expect(afterCorrection.lastContact == nil)
    #expect(afterCorrection.bucket == .historyIncomplete)
    var deleted = old; deleted.deleted = true
    #expect(ReachOutAssessment(personID: "p", interactions: [deleted], history: .ready, settings: settings, now: now).bucket == .historyIncomplete)
}

@Test func dueSoonAndHangoutCadencesRemainIndependent() {
    let now = instant("2026-03-27T12:00:00Z")
    let call = ContactInteraction(id: "call", personID: "p", occurredAt: instant("2026-03-01T12:00:00Z"), kind: .answeredCall, verified: true, direct: true, participantsComplete: true, identityResolved: true)
    var settings = ReachOutPreferences()
    let contact = ReachOutAssessment(personID: "p", interactions: [call], history: .ready, settings: settings, now: now)
    #expect(contact.bucket == .dueSoon)
    settings.resetKinds = [.hangout]
    #expect(ReachOutAssessment(personID: "p", interactions: [call], history: .ready, settings: settings, now: now).lastContact == nil)
}

@Test func reachOutSettingsPersistWithoutLeakingBetweenPeopleOrProfiles() throws {
    let suite = "circle-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ReachOutPreferencesStore(defaults: defaults, profile: "preview")
    var settings = ReachOutPreferences()
    settings.cadence = .quarterly
    settings.hangoutCadence = .weekly
    settings.priority = .high
    settings.resetKinds.insert(.incomingMessage)
    try store.save(["person-1": settings])
    let loaded = try store.load()
    #expect(loaded["person-1"] == settings)
    #expect(loaded["person-2"] == nil)
    #expect(try ReachOutPreferencesStore(defaults: defaults, profile: "connected").load().isEmpty)
    defaults.set(Data("invalid".utf8), forKey: "reach-out-v1-preview")
    #expect(throws: (any Error).self) { try store.load() }
}
