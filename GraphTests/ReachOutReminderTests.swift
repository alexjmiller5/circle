import Foundation
import Testing
@testable import CircleGraph

private func instant(_ value: String) -> Date { try! Date(value, strategy: .iso8601) }
private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()

private func history(sentAt: [String: String]) -> CommunicationHistory {
    var value = CommunicationHistory()
    for (person, date) in sentAt {
        value.channels[person] = [ChannelSummary(channel: .imessage, lastSent: instant(date), refreshedAt: instant(date))]
    }
    return value
}

private let people = [(id: "p1", name: "Person 1"), (id: "p2", name: "Person 2"), (id: "p3", name: "Person 3")]
private func enabled(_ edit: (inout ReachOutPreferences) -> Void = { _ in }) -> ReachOutPreferences {
    var value = ReachOutPreferences(); value.remindersEnabled = true; edit(&value); return value
}

@Test func remindersAreOffByDefaultAndOnlyForEnabledPeopleWithEvidence() {
    let clock = instant("2026-03-10T12:00:00Z")
    let sent = history(sentAt: ["p1": "2026-01-01T12:00:00Z", "p2": "2026-03-01T12:00:00Z"])
    #expect(ReachOutReminders.plan(people, preferences: [:], history: sent, settings: ReminderSettings(), now: clock, calendar: utc).isEmpty)
    let plan = ReachOutReminders.plan(people, preferences: ["p1": enabled(), "p2": enabled(), "p3": enabled()],
                                      history: sent, settings: ReminderSettings(), now: clock, calendar: utc)
    // p3 has no history: unknown never becomes a reminder.
    #expect(plan.map(\.personID) == ["p1", "p2"])
    // Overdue fires now; upcoming fires at its due moment.
    #expect(plan[0].fireAt == clock)
    #expect(plan[1].fireAt == instant("2026-04-01T12:00:00Z"))
    #expect(plan[0].title == "Reach out to Person 1")
    #expect(plan[0].id == "circle.reachout.p1.\(Int(instant("2026-02-01T12:00:00Z").timeIntervalSince1970))")
}

@Test func quietHoursMoveRemindersToTheirEnd() {
    var settings = ReminderSettings()
    settings.quietStartHour = 21; settings.quietEndHour = 9
    #expect(settings.outsideQuietHours(instant("2026-03-10T22:30:00Z"), calendar: utc) == instant("2026-03-11T09:00:00Z"))
    #expect(settings.outsideQuietHours(instant("2026-03-10T03:00:00Z"), calendar: utc) == instant("2026-03-10T09:00:00Z"))
    #expect(settings.outsideQuietHours(instant("2026-03-10T09:00:00Z"), calendar: utc) == instant("2026-03-10T09:00:00Z"))
    #expect(settings.outsideQuietHours(instant("2026-03-10T20:59:00Z"), calendar: utc) == instant("2026-03-10T20:59:00Z"))
    settings.quietStartHour = 13; settings.quietEndHour = 15
    #expect(settings.outsideQuietHours(instant("2026-03-10T14:10:00Z"), calendar: utc) == instant("2026-03-10T15:00:00Z"))
    settings.quietEndHour = 13
    #expect(settings.outsideQuietHours(instant("2026-03-10T13:30:00Z"), calendar: utc) == instant("2026-03-10T13:30:00Z"))
    let clock = instant("2026-03-10T23:00:00Z")
    let plan = ReachOutReminders.plan(people, preferences: ["p1": enabled()], history: history(sentAt: ["p1": "2026-01-01T12:00:00Z"]),
                                      settings: ReminderSettings(), now: clock, calendar: utc)
    #expect(plan.first?.fireAt == instant("2026-03-11T09:00:00Z"))
}

@Test func lockScreenPrivacyHidesNames() {
    var settings = ReminderSettings(); settings.hideNames = true
    let plan = ReachOutReminders.plan(people, preferences: ["p1": enabled()], history: history(sentAt: ["p1": "2026-01-01T12:00:00Z"]),
                                      settings: settings, now: instant("2026-03-10T12:00:00Z"), calendar: utc)
    #expect(plan.count == 1)
    #expect(!plan[0].title.contains("Person 1") && !plan[0].body.contains("Person 1"))
}

@Test func snoozeMovesTheReminderAndAFreshContactReplacesIt() {
    let clock = instant("2026-03-10T12:00:00Z")
    let before = ReachOutReminders.plan(people, preferences: ["p1": enabled()], history: history(sentAt: ["p1": "2026-01-01T12:00:00Z"]),
                                        settings: ReminderSettings(), now: clock, calendar: utc)
    let snoozed = ReachOutReminders.plan(people, preferences: ["p1": enabled { $0.snoozedUntil = instant("2026-03-17T12:00:00Z") }],
                                         history: history(sentAt: ["p1": "2026-01-01T12:00:00Z"]), settings: ReminderSettings(), now: clock, calendar: utc)
    #expect(snoozed[0].fireAt == instant("2026-03-17T12:00:00Z"))
    #expect(snoozed[0].id != before[0].id)
    let fresh = ReachOutReminders.plan(people, preferences: ["p1": enabled()], history: history(sentAt: ["p1": "2026-03-09T12:00:00Z"]),
                                       settings: ReminderSettings(), now: clock, calendar: utc)
    #expect(fresh[0].fireAt == instant("2026-04-09T12:00:00Z"))
    #expect(fresh[0].id != before[0].id)
}

@Test func reconcileNeverRepeatsADeliveredReminderAndDropsStaleOnes() {
    let first = ReachOutReminder(id: "circle.reachout.p1.1", personID: "p1", fireAt: Date(), title: "", body: "")
    let second = ReachOutReminder(id: "circle.reachout.p2.1", personID: "p2", fireAt: Date(), title: "", body: "")
    var step = ReachOutReminders.reconcile(desired: [first, second], pending: ["other.app.request"], ledger: [])
    #expect(step.add.map(\.id) == [first.id, second.id])
    #expect(step.remove.isEmpty)
    // first was delivered (no longer pending); second is still pending.
    step = ReachOutReminders.reconcile(desired: [first, second], pending: [second.id], ledger: step.ledger)
    #expect(step.add.isEmpty)
    // A fresh contact replaces second's request; the stale one is withdrawn and forgotten.
    let replaced = ReachOutReminder(id: "circle.reachout.p2.2", personID: "p2", fireAt: Date(), title: "", body: "")
    step = ReachOutReminders.reconcile(desired: [first, replaced], pending: [second.id], ledger: step.ledger)
    #expect(step.add.map(\.id) == [replaced.id])
    #expect(step.remove == [second.id])
    #expect(step.ledger == [first.id, replaced.id])
}

@Test func planStaysWithinThePendingRequestLimit() {
    let crowd = (0..<80).map { (id: "p\($0)", name: "Person \($0)") }
    var sent = CommunicationHistory(), preferences: [String: ReachOutPreferences] = [:]
    for (index, person) in crowd.enumerated() {
        sent.channels[person.id] = [ChannelSummary(channel: .sms, lastSent: instant("2026-01-01T12:00:00Z").addingTimeInterval(Double(index) * 86_400),
                                                   refreshedAt: instant("2026-03-01T00:00:00Z"))]
        preferences[person.id] = enabled()
    }
    let plan = ReachOutReminders.plan(crowd, preferences: preferences, history: sent, settings: ReminderSettings(),
                                      now: instant("2026-03-10T12:00:00Z"), calendar: utc)
    #expect(plan.count == ReachOutReminders.limit)
    #expect(plan.map(\.fireAt) == plan.map(\.fireAt).sorted())
}
