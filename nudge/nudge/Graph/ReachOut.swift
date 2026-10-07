import Foundation

enum ContactInteractionKind: String, Codable, CaseIterable, Sendable {
    case outgoingMessage, incomingMessage, answeredCall, callAttempt, hangout
}

/// Normalized evidence, after source/participant/publication reconciliation.
/// `verified` is false until the adapter has proven the required source state.
struct ContactInteraction: Equatable, Sendable {
    var id: String
    var personID: String
    var occurredAt: Date
    var kind: ContactInteractionKind
    var verified = false
    var direct = false
    var participantsComplete = false
    var identityResolved = false
    var deleted = false

    func qualifies(settings: ReachOutPreferences, now: Date) -> Bool {
        verified && direct && participantsComplete && identityResolved && !deleted &&
        occurredAt <= now && kind != .callAttempt && settings.resetKinds.contains(kind)
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

enum ContactHistoryReadiness: Sendable { case ready, incomplete, dataPending }
enum ReachOutBucket: String, CaseIterable, Sendable {
    case overdue = "Overdue", dueSoon = "Due soon", historyIncomplete = "History incomplete"
    case snoozed = "Snoozed", upToDate = "Up to date"
}

struct ReachOutAssessment: Sendable {
    let lastContact: Date?
    let dueAt: Date?
    let bucket: ReachOutBucket
    let notificationEligible: Bool
    let score: Double

    init(personID: String, interactions: [ContactInteraction], history: ContactHistoryReadiness,
         settings: ReachOutPreferences, now: Date, calendar: Calendar = utcCalendar) {
        lastContact = interactions.filter {
            $0.personID == personID && $0.qualifies(settings: settings, now: now)
        }.map(\.occurredAt).max()
        dueAt = lastContact.flatMap { settings.cadence.next(after: $0, calendar: calendar) }
        if history != .ready || dueAt == nil {
            bucket = .historyIncomplete
        } else if let snooze = settings.snoozedUntil, snooze > now {
            bucket = .snoozed
        } else if let dueAt, dueAt <= now {
            bucket = .overdue
        } else if let dueAt, dueAt <= calendar.date(byAdding: .day, value: 7, to: now)! {
            bucket = .dueSoon
        } else {
            bucket = .upToDate
        }
        notificationEligible = settings.remindersEnabled && bucket == .overdue
        if history == .ready, let lastContact, let dueAt, dueAt > lastContact {
            score = now.timeIntervalSince(lastContact) / dueAt.timeIntervalSince(lastContact) * Double(settings.priority.rawValue)
        } else { score = 0 }
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
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
}
