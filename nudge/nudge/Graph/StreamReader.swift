import Foundation

public struct CircleStreamPage: Sendable {
    public struct Entry: Sendable {
        public let id: String
        public let body: String
    }
    public let entries: [Entry]
    public let nextCursor: String?
}

/// One bounded page of original append bodies, not a snapshot, source fix,
/// latest-per-person result or proof of complete source coverage.
public struct CircleStreamReader: Sendable {
    let client: any CircleHTTPClient
    public init(client: any CircleHTTPClient) { self.client = client }

    static func validCursor(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 8192 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [43, 47, 61].contains($0)
        }
    }

    public func page(stream: String, cursor: String? = nil) async throws -> CircleStreamPage {
        guard (1...64).contains(stream.utf8.count), stream.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 95].contains($0)
        }), cursor.map(Self.validCursor) ?? true else { throw CircleConnectionError.invalidConfiguration }
        var path = "/v1/streams/\(stream)/records?limit=20"
        if let cursor {
            let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            path += "&cursor=" + encoded
        }
        try Task.checkCancellation()
        let reply = try await client.request(path: path, method: "GET", body: nil, maxBytes: 2_000_000)
        guard reply.status == 200 else { throw CircleConnectionError.unavailable }
        guard reply.data.count <= 2_000_000,
              let raw = try JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
              Set(raw.keys) == ["entries", "next_cursor"],
              let rows = raw["entries"] as? [[String: Any]], rows.count <= 20,
              let next = raw["next_cursor"] else { throw CircleConnectionError.invalidResponse }
        var ids = Set<String>()
        let entries = try rows.map { row -> CircleStreamPage.Entry in
            guard Set(row.keys) == ["id", "body"], let id = row["id"] as? String,
                  id.utf8.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  ids.insert(id).inserted, let body = row["body"] as? String else {
                throw CircleConnectionError.invalidResponse
            }
            return CircleStreamPage.Entry(id: id, body: body)
        }
        let nextCursor: String?
        if next is NSNull { nextCursor = nil }
        else {
            guard let value = next as? String, Self.validCursor(value), value != cursor else {
                throw CircleConnectionError.invalidResponse
            }
            nextCursor = value
        }
        try Task.checkCancellation()
        return CircleStreamPage(entries: entries, nextCursor: nextCursor)
    }
}
