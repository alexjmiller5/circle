import CoreFoundation
import Foundation

/// Channels the service summarizes. Raw values are the service's vocabulary.
enum CommunicationChannel: String, Codable, CaseIterable, Sendable {
    case imessage, sms, rcs, phone, facetimeAudio = "facetime_audio", facetimeVideo = "facetime_video", whatsapp
    /// A logged hangout; never a summary channel.
    case inPerson = "in_person"

    var label: String {
        switch self {
        case .imessage: "iMessage"
        case .sms: "SMS"
        case .rcs: "RCS"
        case .phone: "Phone"
        case .facetimeAudio: "FaceTime audio"
        case .facetimeVideo: "FaceTime video"
        case .whatsapp: "WhatsApp"
        case .inPerson: "In person"
        }
    }

    /// Import sources feeding this channel's summary.
    var sources: [String] {
        switch self {
        case .imessage, .sms, .rcs: ["apple_messages"]
        case .phone, .facetimeAudio, .facetimeVideo: ["apple_calls"]
        case .whatsapp: ["whatsapp_messages", "whatsapp_calls"]
        case .inPerson: []
        }
    }
}

/// One maintained (person, channel) summary. A nil date means nothing within
/// coverageStart...coverageEnd, never "never".
struct ChannelSummary: Codable, Equatable, Sendable {
    var channel: CommunicationChannel
    var lastSent: Date? = nil
    var lastReceived: Date? = nil
    var lastAnsweredCall: Date? = nil
    var answeredSeconds: Double? = nil
    var lastCall: Date? = nil
    var sent = 0
    var received = 0
    var callsAnswered = 0
    var callsMissed = 0
    var coverageStart: Date? = nil
    var coverageEnd: Date? = nil
    var refreshedAt: Date
    var needsReview: String? = nil
}

/// How completely the newest run of one import source captured its store.
struct SourceCoverage: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case complete, partial, unavailable }
    var source: String
    var state: State
    var reason: String?
    var completedAt: Date
    var firstEvent: Date?

    var label: String {
        switch source {
        case "apple_messages": "Messages"
        case "apple_calls": "Calls"
        case "whatsapp_messages": "WhatsApp messages"
        case "whatsapp_calls": "WhatsApp calls"
        default: source
        }
    }
}

struct CommunicationHistory: Codable, Equatable, Sendable {
    var channels: [String: [ChannelSummary]] = [:]
    var sources: [SourceCoverage] = []
    /// Address-book identifiers from confirmed links. Handles are resolved on device and never stored.
    var contactIDs: [String: [String]] = [:]
    /// Logged hangout days (YYYY-MM-DD, local) per person, oldest first. Optional so older caches still load.
    var hangouts: [String: [String]]? = nil

    /// Each logged day at local noon, so a day never shifts across a time-zone boundary.
    func hangoutDays(for person: String, calendar: Calendar) -> [Date] {
        (hangouts?[person] ?? []).compactMap { day in
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        }
    }

    var refreshedAt: Date? { channels.values.joined().map(\.refreshedAt).max() }
    func coverage(of channel: CommunicationChannel) -> [SourceCoverage] {
        sources.filter { channel.sources.contains($0.source) }
    }
}

/// Reads the maintained summaries, never streams or source apps. Separate
/// table reads are not a snapshot; each is complete and validated on its own.
struct CommunicationHistoryReader: Sendable {
    static let summaryKeys: Set<String> = ["id", "person", "channel", "lastSent", "lastReceived", "lastAnsweredCall",
        "lastAnsweredSeconds", "lastCall", "sent", "received", "callsAnswered", "callsMissed", "coverageStart",
        "coverageEnd", "refreshed", "review", "updated", "deleted"]
    static let importKeys: Set<String> = ["id", "source", "instance", "coverage", "reason", "firstEvent", "completed", "updated", "deleted"]
    static let contactKeys: Set<String> = ["id", "person", "platform", "source", "deleted"]
    static let hangoutKeys: Set<String> = ["id", "date", "people", "deleted"]
    static let sources = ["apple_messages", "apple_calls", "whatsapp_messages", "whatsapp_calls"]

    let client: any CircleHTTPClient

    func read(summaries: CircleProjectionTable, imports: CircleProjectionTable,
              contacts: CircleProjectionTable?, hangouts: CircleProjectionTable? = nil) async throws -> CommunicationHistory {
        let reader = CirclePeopleReader(client: client)
        var history = CommunicationHistory()
        for values in try summaries.rows(await reader.read(summaries)) {
            let row = Row(values)
            guard try row.date("deleted") == nil else { continue }
            let person = try row.text("person"), name = try row.text("channel")
            guard try row.text("id") == "\(person):\(name)" else { throw CircleConnectionError.invalidResponse }
            // A channel newer than this app is skipped until the app learns it.
            guard let channel = CommunicationChannel(rawValue: name) else { continue }
            history.channels[person, default: []].append(ChannelSummary(
                channel: channel, lastSent: try row.date("lastSent"), lastReceived: try row.date("lastReceived"),
                lastAnsweredCall: try row.date("lastAnsweredCall"), answeredSeconds: try row.number("lastAnsweredSeconds"),
                lastCall: try row.date("lastCall"), sent: try row.count("sent"), received: try row.count("received"),
                callsAnswered: try row.count("callsAnswered"), callsMissed: try row.count("callsMissed"),
                coverageStart: try row.date("coverageStart"), coverageEnd: try row.date("coverageEnd"),
                refreshedAt: try row.required("refreshed"), needsReview: try row.optionalText("review")))
        }
        for source in Self.sources {
            let runs = try imports.rows(await reader.read(imports, where: [imports.fields["source"]!: source]))
                .map(Row.init).filter { try $0.date("deleted") == nil }
            guard !runs.isEmpty else { continue }
            // Retained backups are one-time snapshots; the live store's newest run says how current it is.
            let live = try runs.filter { try $0.text("instance") == "live" }
            var newest: (row: Row, at: Date)?
            for run in live.isEmpty ? runs : live {
                let at = try run.required("completed")
                if newest == nil || at > newest!.at { newest = (run, at) }
            }
            guard let newest, let state = SourceCoverage.State(rawValue: try newest.row.text("coverage")) else {
                throw CircleConnectionError.invalidResponse
            }
            history.sources.append(SourceCoverage(source: source, state: state, reason: try newest.row.optionalText("reason"),
                                                  completedAt: newest.at, firstEvent: try runs.compactMap { try $0.date("firstEvent") }.min()))
        }
        if let contacts {
            for values in try contacts.rows(await reader.read(contacts, where: [contacts.fields["platform"]!: "apple_contacts"])) {
                let row = Row(values)
                guard try row.date("deleted") == nil else { continue }
                history.contactIDs[try row.text("person"), default: []].append(try row.text("source"))
            }
        }
        if let hangouts {
            var days: [String: Set<String>] = [:]
            for values in try hangouts.rows(await reader.read(hangouts)) {
                let row = Row(values)
                guard try row.optionalText("deleted") == nil else { continue }
                let day = try row.text("date")
                guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                      let people = try JSONSerialization.jsonObject(with: Data(try row.text("people").utf8)) as? [String] else {
                    throw CircleConnectionError.invalidResponse
                }
                for person in people { days[person, default: []].insert(day) }
            }
            history.hangouts = days.mapValues { $0.sorted() }
        }
        return history
    }
}

private struct Row {
    let values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }

    func optionalText(_ key: String) throws -> String? {
        if values[key] is NSNull { return nil }
        guard let value = values[key] as? String, !value.isEmpty else { throw CircleConnectionError.invalidResponse }
        return value
    }
    func text(_ key: String) throws -> String {
        guard let value = try optionalText(key) else { throw CircleConnectionError.invalidResponse }
        return value
    }
    func date(_ key: String) throws -> Date? {
        guard let value = try optionalText(key) else { return nil }
        if let date = try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        if let date = try? Date(value, strategy: Date.ISO8601FormatStyle()) { return date }
        throw CircleConnectionError.invalidResponse
    }
    func required(_ key: String) throws -> Date {
        guard let value = try date(key) else { throw CircleConnectionError.invalidResponse }
        return value
    }
    func number(_ key: String) throws -> Double? {
        if values[key] is NSNull { return nil }
        guard let value = values[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
              value.doubleValue >= 0 else { throw CircleConnectionError.invalidResponse }
        return value.doubleValue
    }
    /// Null counts are zero: the summary leaves message columns empty on call-only channels.
    func count(_ key: String) throws -> Int {
        guard let value = try number(key) else { return 0 }
        guard value <= 9_007_199_254_740_991, value.rounded() == value else { throw CircleConnectionError.invalidResponse }
        return Int(value)
    }
}
