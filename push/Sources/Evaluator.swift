import CircleGraph
import Foundation

/// Everything the service must remember between runs and restarts.
public struct PushState: Codable, Sendable {
    /// Cursor of the last records page read; the next run re-reads that page, then continues.
    public var cursor: String?
    public var watch = NearbyWatch()
    public init() {}
}

/// One evaluation: new friend checks from the stream, this person's latest fix as a city,
/// the approved visit rules, and the names for whoever was confirmed nearby.
public struct NearbyEvaluator: Sendable {
    let hub: any CircleHTTPClient
    let checksStream: String
    let locationStream: String
    let people: CircleProjectionTable
    /// City-level place for a coordinate, or nil when the geocoder has no answer.
    let geocode: @Sendable (Double, Double) async -> CurrentPlace?
    /// Pages per run: the first run walks the whole stream; later runs read a page or two.
    var maxPages = 5_000

    public init(hub: any CircleHTTPClient, checksStream: String, locationStream: String, people: CircleProjectionTable,
                geocode: @escaping @Sendable (Double, Double) async -> CurrentPlace?) {
        self.hub = hub; self.checksStream = checksStream; self.locationStream = locationStream
        self.people = people; self.geocode = geocode
    }

    public func step(_ state: inout PushState, now: Date) async throws -> [(alert: NearbyAlert, name: String)] {
        let reader = CircleStreamReader(client: hub)
        var checks: [FriendCityCheck] = [], cursor = state.cursor
        for _ in 0..<maxPages {
            let page = try await reader.page(stream: checksStream, cursor: cursor)
            checks += page.entries.flatMap { Self.checks(in: $0.body) }
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        let alerts = state.watch.observe(checks, place: await place(), now: now)
        state.cursor = cursor
        guard !alerts.isEmpty else { return [] }
        let rows = try people.rows(try await CirclePeopleReader(client: hub).read(people))
        let names = Dictionary(rows.compactMap { row -> (String, String)? in
            guard row["deleted"] is NSNull, let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            return (id, name)
        }, uniquingKeysWith: { first, _ in first })
        return alerts.map { ($0, names[$0.personID] ?? "Someone in Circle") }
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
