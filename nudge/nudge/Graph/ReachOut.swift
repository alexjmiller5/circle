import Foundation

/// What may reset a person's reach-out clock.
enum ContactInteractionKind: String, Codable, CaseIterable, Sendable {
    case outgoingMessage, incomingMessage, answeredCall, hangout

    var label: String {
        switch self {
        case .outgoingMessage: "sent message"
        case .incomingMessage: "received message"
        case .answeredCall: "answered call"
        case .hangout: "logged hangout"
        }
    }
}

enum ContactCadence: String, CaseIterable, Codable, Sendable {
    case weekly, fortnightly, monthly, quarterly

    var label: String {
        switch self {
        case .weekly: "Weekly"
        case .fortnightly: "Every two weeks"
        case .monthly: "Monthly"
        case .quarterly: "Every three months"
        }
    }

    func next(after date: Date, calendar: Calendar) -> Date? {
        switch self {
        case .weekly: calendar.date(byAdding: .day, value: 7, to: date)
        case .fortnightly: calendar.date(byAdding: .day, value: 14, to: date)
        case .monthly: calendar.date(byAdding: .month, value: 1, to: date)
        case .quarterly: calendar.date(byAdding: .month, value: 3, to: date)
        }
    }
}

enum ContactPriority: Int, CaseIterable, Codable, Sendable {
    case low = 1, normal = 2, high = 3
    var label: String { switch self { case .low: "Low"; case .normal: "Normal"; case .high: "High" } }
}

struct ReachOutPreferences: Codable, Equatable, Sendable {
    var cadence: ContactCadence = .monthly
    var hangoutCadence: ContactCadence = .monthly
    var priority: ContactPriority = .normal
    var remindersEnabled = false
    var hangoutRemindersEnabled = false
    var snoozedUntil: Date?
    var resetKinds: Set<ContactInteractionKind> = [.outgoingMessage, .answeredCall, .hangout]
}

struct ContactMoment: Equatable, Sendable {
    let date: Date
    let channel: CommunicationChannel
}

/// Best-of across a person's channels. Events dated after `now` are data to review, never contact.
struct PersonContactHistory: Sendable {
    let channels: [ChannelSummary]
    let lastSent: ContactMoment?
    let lastReceived: ContactMoment?
    let lastAnsweredCall: ContactMoment?
    let lastHangout: ContactMoment?

    init(_ channels: [ChannelSummary], hangouts: [Date] = [], now: Date) {
        self.channels = channels
        func newest(_ date: (ChannelSummary) -> Date?) -> ContactMoment? {
            channels.compactMap { summary in date(summary).flatMap { $0 <= now ? ContactMoment(date: $0, channel: summary.channel) : nil } }
                .max { $0.date < $1.date }
        }
        lastSent = newest(\.lastSent)
        lastReceived = newest(\.lastReceived)
        lastAnsweredCall = newest(\.lastAnsweredCall)
        lastHangout = hangouts.filter { $0 <= now }.max().map { ContactMoment(date: $0, channel: .inPerson) }
    }

    func latest(_ kind: ContactInteractionKind) -> ContactMoment? {
        switch kind {
        case .outgoingMessage: lastSent
        case .incomingMessage: lastReceived
        case .answeredCall: lastAnsweredCall
        case .hangout: lastHangout
        }
    }
}

enum ReachOutBucket: String, CaseIterable, Sendable {
    case due = "Due now", month = "Not contacted in 1 month", threeWeeks = "Not contacted in 3 weeks"
    case unknown = "History unknown", snoozed = "Snoozed", recent = "In touch"
}

struct ReachOutAssessment: Sendable {
    struct Evidence: Equatable, Sendable {
        let kind: ContactInteractionKind
        let moment: ContactMoment
    }
    let lastContact: Evidence?
    /// Shown even when it does not reset the clock.
    let lastIncoming: ContactMoment?
    let dueAt: Date?
    let elapsedDays: Int?
    let bucket: ReachOutBucket
    let score: Double
    let reason: String
    /// When a reminder is wanted: the due moment, or the end of a snooze.
    let reminderAt: Date?

    init(personID: String, history: CommunicationHistory?, settings: ReachOutPreferences, now: Date,
         calendar: Calendar = .current) {
        let person = PersonContactHistory(history?.channels[personID] ?? [],
                                          hangouts: history?.hangoutDays(for: personID, calendar: calendar) ?? [], now: now)
        lastContact = settings.resetKinds.compactMap { kind in person.latest(kind).map { Evidence(kind: kind, moment: $0) } }
            .max { $0.moment.date < $1.moment.date }
        lastIncoming = person.lastReceived
        let last = lastContact?.moment.date
        dueAt = last.flatMap { settings.cadence.next(after: $0, calendar: calendar) }
        elapsedDays = last.flatMap { calendar.dateComponents([.day], from: $0, to: now).day }
        let snoozed = settings.snoozedUntil.flatMap { $0 > now ? $0 : nil }
        if history == nil || last == nil || dueAt == nil { bucket = snoozed == nil ? .unknown : .snoozed }
        else if snoozed != nil { bucket = .snoozed }
        else if dueAt! <= now { bucket = .due }
        else if calendar.date(byAdding: .month, value: 1, to: last!)! <= now { bucket = .month }
        else if calendar.date(byAdding: .day, value: 21, to: last!)! <= now { bucket = .threeWeeks }
        else { bucket = .recent }
        if let last, let dueAt, dueAt > last, bucket != .snoozed {
            score = now.timeIntervalSince(last) / dueAt.timeIntervalSince(last) * Double(settings.priority.rawValue)
        } else { score = 0 }
        reminderAt = settings.remindersEnabled ? dueAt.map { max($0, snoozed ?? $0) } : nil

        var parts: [String] = []
        let format = Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: calendar, timeZone: calendar.timeZone)
        if let snoozed { parts.append("Snoozed until \(snoozed.formatted(format)).") }
        if history == nil {
            parts.append("Contact history is not connected, so no due date is claimed.")
        } else if let lastContact, let dueAt, let elapsedDays {
            parts.append("\(Self.days(elapsedDays)) since your last \(lastContact.kind.label) (\(lastContact.moment.channel.label)).")
            parts.append("\(settings.cadence.label) cadence, due \(dueAt.formatted(format)).")
        } else {
            let kinds = settings.resetKinds.subtracting([.hangout]).sorted { $0.rawValue < $1.rawValue }.map(\.label)
            let sources = history!.sources
            var unknown = "Unknown: no \(kinds.isEmpty ? "tracked contact" : kinds.joined(separator: " or ")) in the connected history"
            if let start = sources.compactMap(\.firstEvent).min() { unknown += " since \(start.formatted(format))" }
            if sources.isEmpty || sources.contains(where: { $0.state != .complete }) { unknown += ", which is partial" }
            parts.append(unknown + ".")
        }
        if settings.priority != .normal { parts.append("\(settings.priority.label) priority.") }
        if !settings.resetKinds.contains(.incomingMessage), let incoming = lastIncoming,
           lastContact.map({ incoming.date > $0.moment.date }) ?? true {
            let ago = calendar.dateComponents([.day], from: incoming.date, to: now).day ?? 0
            parts.append("They messaged \(Self.days(ago)) ago (\(incoming.channel.label)); that does not reset the clock.")
        }
        reason = parts.joined(separator: " ")
    }

    static func days(_ count: Int) -> String { count == 1 ? "1 day" : "\(count) days" }
}

struct ReachOutPreferencesStore {
    let defaults: UserDefaults
    let profile: String
    private var key: String { "reach-out-v1-\(profile)" }

    func load() throws -> [String: ReachOutPreferences] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return try JSONDecoder().decode([String: ReachOutPreferences].self, from: data)
    }

    func save(_ preferences: [String: ReachOutPreferences]) throws {
        defaults.set(try JSONEncoder().encode(preferences), forKey: key)
    }

    /// Unreadable reminder settings fall back to the private defaults (reminders stay per-person opt-in).
    func loadReminders() -> ReminderSettings {
        defaults.data(forKey: "reach-out-reminders-v1-\(profile)").flatMap { try? JSONDecoder().decode(ReminderSettings.self, from: $0) }
            ?? ReminderSettings()
    }

    func saveReminders(_ settings: ReminderSettings) {
        defaults.set(try? JSONEncoder().encode(settings), forKey: "reach-out-reminders-v1-\(profile)")
    }

    /// Reminder requests already handed to the system, so a delivered one is never repeated.
    func loadLedger() -> Set<String> { Set(defaults.stringArray(forKey: "reach-out-ledger-v1-\(profile)") ?? []) }
    func saveLedger(_ ids: Set<String>) { defaults.set(ids.sorted(), forKey: "reach-out-ledger-v1-\(profile)") }
}
