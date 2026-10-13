import CircleGraph
import Foundation

/// Everything the service must remember between runs and restarts. Later fields are
/// optional so a state file written by an earlier version still loads.
public struct PushState: Codable, Sendable {
    /// Cursor of the last records page read; the next run re-reads that page, then continues.
    public var cursor: String?
    public var watch = NearbyWatch()
    public var hangoutCheckedAt: Date?
    var reminded: [String: Date]?
    public var hangoutReminded: [String: Date] { get { reminded ?? [:] } set { reminded = newValue } }
    public init() {}
}

/// The user's table and column names for what the service reads (a JSON file it is given).
public struct PushBindings: Codable, Sendable {
    public let people: CircleProjectionTable
    /// Current bases and logged hangouts; with a people cadence column they enable hangout reminders.
    public var locations: CircleProjectionTable?
    public var hangouts: CircleProjectionTable?

    public init(people: CircleProjectionTable, locations: CircleProjectionTable? = nil, hangouts: CircleProjectionTable? = nil) {
        self.people = people; self.locations = locations; self.hangouts = hangouts
    }

    var remindsHangouts: Bool { people.fields["hangoutCadence"] != nil && locations != nil && hangouts != nil }

    public func validate() throws {
        try people.validate(keys: ["id", "name", "deleted"], optional: ["hangoutCadence"])
        try locations?.validate(keys: ["id", "person", "city", "country", "end", "deleted"])
        try hangouts?.validate(keys: ["id", "date", "people", "deleted"])
        let parts = [people.fields["hangoutCadence"] != nil, locations != nil, hangouts != nil]
        guard parts.allSatisfy({ $0 }) || !parts.contains(true) else {
            throw PushBindingsError.incompleteHangouts
        }
    }

    /// The exact read grants the service's hub token needs besides its two streams.
    public var scopes: [String] {
        [people, locations, hangouts].compactMap { $0 }.flatMap { table in table.columns.map { "tables:read:\(table.table):\($0)" } }.sorted()
    }
}

enum PushBindingsError: Error { case incompleteHangouts }

public struct PushStep: Sendable {
    public let alerts: [(alert: NearbyAlert, name: String)]
    public let nudges: [HangoutNudge]
}

/// One evaluation: new friend checks from the stream, this person's latest fix as a city,
/// the approved visit rules, and the names for whoever was confirmed nearby.
public struct NearbyEvaluator: Sendable {
    let hub: any CircleHTTPClient
    let checksStream: String
    let locationStream: String
    let bindings: PushBindings
    /// City-level place for a coordinate, or nil when the geocoder has no answer.
    let geocode: @Sendable (Double, Double) async -> CurrentPlace?
    let calendar: Calendar
    /// Pages per run: the first run walks the whole stream; later runs read a page or two.
    var maxPages = 5_000

    public init(hub: any CircleHTTPClient, checksStream: String, locationStream: String, bindings: PushBindings,
                geocode: @escaping @Sendable (Double, Double) async -> CurrentPlace?, calendar: Calendar = .current) {
        self.hub = hub; self.checksStream = checksStream; self.locationStream = locationStream
        self.bindings = bindings; self.geocode = geocode; self.calendar = calendar
    }

    public func step(_ state: inout PushState, now: Date) async throws -> PushStep {
        let reader = CircleStreamReader(client: hub)
        var checks: [FriendCityCheck] = [], cursor = state.cursor
        for _ in 0..<maxPages {
            let page = try await reader.page(stream: checksStream, cursor: cursor)
            checks += page.entries.flatMap { Self.checks(in: $0.body) }
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        let here = await place()
        let alerts = state.watch.observe(checks, place: here, now: now)
        state.cursor = cursor
        let hangoutsDue = bindings.remindsHangouts && state.hangoutCheckedAt.map { now.timeIntervalSince($0) >= 1_800 } ?? true
        guard !alerts.isEmpty || hangoutsDue else { return PushStep(alerts: [], nudges: []) }
        let tables = CirclePeopleReader(client: hub)
        let people = try bindings.people.rows(try await tables.read(bindings.people)).filter { $0["deleted"] is NSNull }
        let names = Dictionary(people.compactMap { row -> (String, String)? in
            guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            return (id, name)
        }, uniquingKeysWith: { first, _ in first })
        var nudges: [HangoutNudge] = []
        if hangoutsDue, let locations = bindings.locations, let hangouts = bindings.hangouts {
            // One current base per person; several current claims are ambiguity, never a guess.
            var bases: [String: [(city: String, country: String?)]] = [:]
            for row in try locations.rows(try await tables.read(locations)) where row["deleted"] is NSNull && row["end"] is NSNull {
                if let person = row["person"] as? String, let city = row["city"] as? String {
                    bases[person, default: []].append((city, row["country"] as? String))
                }
            }
            var days: [String: [String]] = [:]
            for row in try hangouts.rows(try await tables.read(hangouts)) where row["deleted"] is NSNull {
                guard let day = row["date"] as? String, let ids = (row["people"] as? String).flatMap({
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }) else { continue }
                for id in ids { days[id, default: []].append(day) }
            }
            let candidates = people.compactMap { row -> HangoutCandidate? in
                guard let id = row["id"] as? String, let cadence = row["hangoutCadence"] as? String, bases[id]?.count == 1 else { return nil }
                return HangoutCandidate(id: id, name: names[id] ?? "Someone in Circle", cadence: cadence,
                                        baseCity: bases[id]![0].city, baseCountry: bases[id]![0].country)
            }
            nudges = HangoutNudges.due(candidates, hangoutDays: days, place: here, reminded: state.hangoutReminded, now: now, calendar: calendar)
            for nudge in nudges { state.hangoutReminded[nudge.personID] = now }
            state.hangoutCheckedAt = now
        }
        return PushStep(alerts: alerts.map { ($0, names[$0.personID] ?? "Someone in Circle") }, nudges: nudges)
    }

    /// One append is one record; historical batch bodies are arrays of records.
    static func checks(in body: String) -> [FriendCityCheck] {
        guard let array = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [Any] else {
            return FriendCityCheck.parse(body).map { [$0] } ?? []
        }
        return array.compactMap { element in
            (try? JSONSerialization.data(withJSONObject: element)).flatMap { FriendCityCheck.parse(String(decoding: $0, as: UTF8.self)) }
        }
    }

    /// The newest append on the location stream is the latest fix (OwnTracks `lat`/`lon`).
    private func place() async -> CurrentPlace? {
        guard let reply = try? await hub.request(path: "/v1/streams/\(locationStream)/tail", method: "GET", body: nil, maxBytes: 65_536),
              reply.status == 200,
              let fix = try? JSONSerialization.jsonObject(with: reply.data, options: .fragmentsAllowed) as? [String: Any],
              let lat = fix["lat"] as? Double, let lon = fix["lon"] as? Double,
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return await geocode(lat, lon)
    }
}
