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

/// Metadata from a completed, reconciled read. Import completion describes
/// publication, never historical endpoint coverage or account-wide history.
struct ContactImportMetadata: Equatable, Sendable {
    var id: String
    var sourceNamespace: String
    var completed: Bool
    var deleted = false
}

struct ContactParticipantMetadata: Equatable, Sendable {
    var id: String
    var eventID: String
    var firstImportID: String
    var role: String
    var isSelf: Bool
    var personID: String?
    var deleted = false
}

struct ContactEventMetadata: Equatable, Sendable {
    var id: String
    var firstImportID: String
    var occurredAt: Date?
    var kind: String
    var direction: String
    var messageState: String?
    var conversationKind: String
    var expectedParticipantRows: Int
    var participantCoverage: String
    var participantCoverageReason: String
    var callOutcome: String?
    var durationSeconds: Double?
    var needsReview = false
    var deleted = false
}

enum ContactMetadataProjection {
    /// The caller must supply ALL participant rows, including self, unresolved
    /// and tombstoned rows. Matching separate rereads are best-known evidence,
    /// not an atomic snapshot; automatic reminders remain gated independently.
    static func interactions(event: ContactEventMetadata, participants: [ContactParticipantMetadata],
                             imports: [ContactImportMetadata]) throws -> [ContactInteraction] {
        var unique: [String: ContactParticipantMetadata] = [:]
        for row in participants {
            guard !row.id.isEmpty, row.eventID == event.id else { throw CircleConnectionError.invalidResponse }
            if let previous = unique[row.id], previous != row { throw CircleConnectionError.invalidResponse }
            unique[row.id] = row
        }
        var receipts: [String: ContactImportMetadata] = [:]
        for row in imports {
            guard !row.id.isEmpty, !row.sourceNamespace.isEmpty else { throw CircleConnectionError.invalidResponse }
            if let previous = receipts[row.id], previous != row { throw CircleConnectionError.invalidResponse }
            receipts[row.id] = row
        }
        let active = unique.values.filter { !$0.deleted }
        let referenced = [event.firstImportID] + active.map(\.firstImportID)
        guard !event.id.isEmpty, !event.deleted, !event.needsReview,
              let occurredAt = event.occurredAt, occurredAt.timeIntervalSince1970.isFinite,
              event.conversationKind == "direct", event.participantCoverage == "complete_for_event",
              event.participantCoverageReason == "verified_event_endpoints",
              event.expectedParticipantRows == active.count, active.count == 2,
              referenced.allSatisfy({ receipts[$0]?.completed == true && receipts[$0]?.deleted == false }),
              Set(referenced.compactMap { receipts[$0]?.sourceNamespace }).count == 1,
              let own = active.first(where: \.isSelf), let other = active.first(where: { !$0.isSelf }),
              let personID = other.personID, !personID.isEmpty, own.personID != personID else { return [] }
        let ownRole: String, otherRole: String, kind: ContactInteractionKind
        switch (event.kind, event.direction) {
        case ("message", "outgoing") where event.messageState == "sent" && event.callOutcome == nil && event.durationSeconds == nil:
            (ownRole, otherRole, kind) = ("sender", "recipient", .outgoingMessage)
        case ("message", "incoming") where event.messageState == "received" && event.callOutcome == nil && event.durationSeconds == nil:
            (ownRole, otherRole, kind) = ("recipient", "sender", .incomingMessage)
        case ("call", "outgoing") where event.callOutcome == "answered" && event.messageState == nil:
            (ownRole, otherRole, kind) = ("caller", "callee", .answeredCall)
        case ("call", "incoming") where event.callOutcome == "answered" && event.messageState == nil:
            (ownRole, otherRole, kind) = ("callee", "caller", .answeredCall)
        default: return []
        }
        guard own.role == ownRole, other.role == otherRole,
              event.durationSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true else { return [] }
        return [ContactInteraction(id: event.id, personID: personID, occurredAt: occurredAt, kind: kind,
                                   verified: true, direct: true, participantsComplete: true, identityResolved: true)]
    }
}
