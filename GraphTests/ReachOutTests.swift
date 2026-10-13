import Foundation
import Testing
@testable import CircleGraph

private func instant(_ value: String) -> Date { try! Date(value, strategy: .iso8601) }
private let now = instant("2026-03-10T12:00:00Z")
private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()

private func days(_ count: Double) -> Date { now.addingTimeInterval(-count * 86_400) }

private func history(_ channels: [ChannelSummary], person: String = "p", sources: [SourceCoverage]? = nil) -> CommunicationHistory {
    var value = CommunicationHistory()
    value.channels[person] = channels
    value.sources = sources ?? [
        SourceCoverage(source: "apple_messages", state: .complete, reason: nil, completedAt: days(0.5), firstEvent: instant("2017-08-11T00:00:00Z")),
        SourceCoverage(source: "apple_calls", state: .partial, reason: "outbox", completedAt: days(0.5), firstEvent: instant("2025-07-16T00:00:00Z"))
    ]
    return value
}

private func assess(_ value: CommunicationHistory?, _ settings: ReachOutPreferences = ReachOutPreferences(), person: String = "p") -> ReachOutAssessment {
    ReachOutAssessment(personID: person, history: value, settings: settings, now: now, calendar: utc)
}

@Test func defaultClockResetsOnSentMessagesAndAnsweredCallsOnly() {
    let channels = [
        ChannelSummary(channel: .imessage, lastSent: days(40), lastReceived: days(2), refreshedAt: now),
        ChannelSummary(channel: .phone, lastAnsweredCall: days(35), lastCall: days(1), refreshedAt: now)
    ]
    let value = assess(history(channels))
    // Incoming messages and unanswered calls are shown, never a reset.
    #expect(value.lastContact?.kind == .answeredCall)
    #expect(value.lastContact?.moment == ContactMoment(date: days(35), channel: .phone))
    #expect(value.lastIncoming?.date == days(2))
    #expect(value.bucket == .due)
    #expect(value.elapsedDays == 35)
    #expect(value.reason.contains("35 days since your last answered call (Phone)"))
    #expect(value.reason.contains("does not reset"))
    var incoming = ReachOutPreferences()
    incoming.resetKinds.insert(.incomingMessage)
    let configured = assess(history(channels), incoming)
    #expect(configured.lastContact?.kind == .incomingMessage)
    #expect(configured.bucket == .recent)
    #expect(!configured.reason.contains("does not reset"))
}

@Test func bestOfAcrossChannelsPicksTheNewestQualifyingEvent() {
    let value = assess(history([
        ChannelSummary(channel: .sms, lastSent: days(50), refreshedAt: now),
        ChannelSummary(channel: .whatsapp, lastSent: days(10), refreshedAt: now),
        ChannelSummary(channel: .imessage, lastSent: days(25), refreshedAt: now)
    ]))
    #expect(value.lastContact?.moment.channel == .whatsapp)
    #expect(value.bucket == .recent)
}

@Test func missingOrPartialCoverageIsUnknownNeverNeverContacted() {
    let notConnected = assess(nil)
    #expect(notConnected.bucket == .unknown)
    #expect(notConnected.lastContact == nil && notConnected.dueAt == nil && notConnected.reminderAt == nil)
    #expect(notConnected.reason.contains("not connected"))
    let incomingOnly = assess(history([ChannelSummary(channel: .imessage, lastReceived: days(3), refreshedAt: now)]))
    #expect(incomingOnly.bucket == .unknown)
    #expect(incomingOnly.reason.hasPrefix("Unknown"))
    #expect(incomingOnly.reason.contains("partial"))
    #expect(!incomingOnly.reason.lowercased().contains("never"))
    #expect(incomingOnly.reason.contains("3 days ago"))
    var reminders = ReachOutPreferences(); reminders.remindersEnabled = true
    #expect(assess(history([]), reminders).reminderAt == nil)
}

@Test func futureDatedEventsNeverResetTheClock() {
    let value = assess(history([ChannelSummary(channel: .imessage, lastSent: now.addingTimeInterval(3600), refreshedAt: now)]))
    #expect(value.lastContact == nil)
    #expect(value.bucket == .unknown)
}

@Test func groupsSeparateCadenceFromElapsedTime() {
    var quarterly = ReachOutPreferences(); quarterly.cadence = .quarterly
    #expect(assess(history([ChannelSummary(channel: .sms, lastSent: days(33), refreshedAt: now)]), quarterly).bucket == .month)
    #expect(assess(history([ChannelSummary(channel: .sms, lastSent: days(22), refreshedAt: now)]), quarterly).bucket == .threeWeeks)
    #expect(assess(history([ChannelSummary(channel: .sms, lastSent: days(20), refreshedAt: now)]), quarterly).bucket == .recent)
    var weekly = ReachOutPreferences(); weekly.cadence = .weekly
    #expect(assess(history([ChannelSummary(channel: .sms, lastSent: days(8), refreshedAt: now)]), weekly).bucket == .due)
}

@Test func monthlyCadenceUsesTheCalendarAndSnoozeKeepsTheEvidence() {
    let last = instant("2026-01-31T12:00:00Z")
    let at = instant("2026-03-01T12:00:00Z")
    let summary = history([ChannelSummary(channel: .phone, lastAnsweredCall: last, refreshedAt: at)])
    var settings = ReachOutPreferences()
    let due = ReachOutAssessment(personID: "p", history: summary, settings: settings, now: at, calendar: utc)
    #expect(due.dueAt == instant("2026-02-28T12:00:00Z"))
    #expect(due.bucket == .due)
    #expect(due.reminderAt == nil)
    settings.remindersEnabled = true
    #expect(ReachOutAssessment(personID: "p", history: summary, settings: settings, now: at, calendar: utc).reminderAt == due.dueAt)
    settings.snoozedUntil = instant("2026-03-05T12:00:00Z")
    let snoozed = ReachOutAssessment(personID: "p", history: summary, settings: settings, now: at, calendar: utc)
    #expect(snoozed.bucket == .snoozed)
    #expect(snoozed.lastContact?.moment.date == last)
    #expect(snoozed.reminderAt == settings.snoozedUntil)
    #expect(snoozed.reason.contains("Snoozed until"))
}

@Test func priorityRaisesTheScoreAndIsExplained() {
    let channels = [ChannelSummary(channel: .sms, lastSent: days(45), refreshedAt: now)]
    var high = ReachOutPreferences(); high.priority = .high
    let normal = assess(history(channels)), raised = assess(history(channels), high)
    #expect(raised.score > normal.score)
    #expect(raised.reason.contains("High priority"))
    #expect(!normal.reason.contains("priority"))
}

@Test func hangoutsHaveNoSourceYet() {
    var settings = ReachOutPreferences(); settings.resetKinds = [.hangout]
    let value = assess(history([ChannelSummary(channel: .sms, lastSent: days(1), refreshedAt: now)]), settings)
    #expect(value.lastContact == nil)
    #expect(value.bucket == .unknown)
}

@Test func reachOutSettingsPersistWithoutLeakingBetweenPeopleOrProfiles() throws {
    let suite = "circle-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ReachOutPreferencesStore(defaults: defaults, profile: "preview")
    var settings = ReachOutPreferences()
    settings.cadence = .quarterly
    settings.priority = .high
    settings.resetKinds.insert(.incomingMessage)
    try store.save(["person-1": settings])
    let loaded = try store.load()
    #expect(loaded["person-1"] == settings)
    #expect(loaded["person-2"] == nil)
    #expect(try ReachOutPreferencesStore(defaults: defaults, profile: "connected").load().isEmpty)
    var reminders = ReminderSettings(); reminders.hideNames = true; reminders.quietStartHour = 22
    store.saveReminders(reminders)
    #expect(store.loadReminders() == reminders)
    #expect(ReachOutPreferencesStore(defaults: defaults, profile: "connected").loadReminders() == ReminderSettings())
    store.saveLedger(["a", "b"])
    #expect(store.loadLedger() == ["a", "b"])
    defaults.set(Data("invalid".utf8), forKey: "reach-out-v1-preview")
    #expect(throws: (any Error).self) { try store.load() }
}

@Test func earlierSavedPreferencesStillDecode() throws {
    let saved = #"{"p":{"cadence":"monthly","hangoutCadence":"weekly","priority":3,"remindersEnabled":false,"hangoutRemindersEnabled":false,"resetKinds":["outgoingMessage","answeredCall","hangout"]}}"#
    let decoded = try JSONDecoder().decode([String: ReachOutPreferences].self, from: Data(saved.utf8))
    #expect(decoded["p"]?.priority == .high)
    #expect(decoded["p"]?.resetKinds == [.outgoingMessage, .answeredCall, .hangout])
}
