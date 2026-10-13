import Foundation

/// Device-wide reminder delivery choices; whether a person is reminded is per-person and off by default.
public struct ReminderSettings: Codable, Equatable, Sendable {
    var quietStartHour = 21
    var quietEndHour = 9
    /// Lock-screen privacy: notifications never carry the person's name.
    public var hideNames = false

    public init() {}

    /// Moves a moment inside the quiet window to the window's end. Equal hours mean no quiet window.
    func outsideQuietHours(_ date: Date, calendar: Calendar) -> Date {
        guard quietStartHour != quietEndHour else { return date }
        let hour = calendar.component(.hour, from: date)
        let quiet = quietStartHour < quietEndHour
            ? (quietStartHour..<quietEndHour).contains(hour)
            : hour >= quietStartHour || hour < quietEndHour
        guard quiet else { return date }
        return calendar.nextDate(after: date, matching: DateComponents(hour: quietEndHour, minute: 0, second: 0),
                                 matchingPolicy: .nextTime) ?? date
    }
}

struct ReachOutReminder: Equatable, Sendable {
    let id: String
    let personID: String
    let fireAt: Date
    let title: String
    let body: String
}

enum ReachOutReminders {
    static let prefix = "circle.reachout."
    /// iOS keeps at most 64 pending requests per app.
    static let limit = 60

    /// Local reminders from the reach-out model. The id names the person and the moment that
    /// anchors it, so a fresh qualifying contact or a snooze produces a new request.
    static func plan(_ people: [(id: String, name: String)], preferences: [String: ReachOutPreferences],
                     history: CommunicationHistory?, settings: ReminderSettings, now: Date,
                     calendar: Calendar = .current) -> [ReachOutReminder] {
        people.compactMap { person -> ReachOutReminder? in
            guard let preference = preferences[person.id], preference.remindersEnabled else { return nil }
            let assessment = ReachOutAssessment(personID: person.id, history: history, settings: preference, now: now, calendar: calendar)
            guard let anchor = assessment.reminderAt, let elapsed = assessment.elapsedDays else { return nil }
            let detail = "Last contact \(ReachOutAssessment.days(elapsed)) ago; \(preference.cadence.label.lowercased()) cadence."
            return ReachOutReminder(id: "\(prefix)\(person.id).\(Int(anchor.timeIntervalSince1970))", personID: person.id,
                                    fireAt: settings.outsideQuietHours(max(anchor, now), calendar: calendar),
                                    title: settings.hideNames ? "Time to reach out" : "Reach out to \(person.name)",
                                    body: settings.hideNames ? "Someone in Circle is due for a reach-out." : detail)
        }
        .sorted { ($0.fireAt, $0.id) < ($1.fireAt, $1.id) }
        .prefix(limit).map { $0 }
    }

    /// Adds what is new, withdraws Circle requests no longer wanted, and never re-adds a request
    /// the system already received (delivered or dismissed) for the same anchor.
    static func reconcile(desired: [ReachOutReminder], pending: Set<String>,
                          ledger: Set<String>) -> (add: [ReachOutReminder], remove: [String], ledger: Set<String>) {
        let wanted = Set(desired.map(\.id))
        let add = desired.filter { !pending.contains($0.id) && !ledger.contains($0.id) }
        let remove = pending.filter { $0.hasPrefix(prefix) && !wanted.contains($0) }.sorted()
        return (add, remove, ledger.union(add.map(\.id)).intersection(wanted))
    }
}
