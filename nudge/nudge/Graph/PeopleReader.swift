import Foundation

struct CircleHTTPReply: Sendable { let status: Int; let data: Data }
protocol CircleHTTPClient: Sendable {
    func request(path: String, method: String, body: Data?, maxBytes: Int) async throws -> CircleHTTPReply
}

struct CirclePeopleReader: Sendable {
    let client: any CircleHTTPClient

    /// Complete bounded scan, not a cross-page or cross-table snapshot.
    /// Nothing is published until every page has passed validation.
    func read(_ table: CircleProjectionTable, where filters: [String: String] = [:]) async throws -> Data {
        guard Set(filters.keys).isSubset(of: Set(table.columns)) else {
            throw CircleConnectionError.invalidConfiguration
        }
        var allRows: [[String: Any]] = []
        var identities = Set<String>(), cursors = Set<String>()
        var after: String?
        repeat {
            try Task.checkCancellation()
            var request: [String: Any] = ["table": table.table, "columns": table.columns, "limit": 200]
            if !filters.isEmpty { request["where"] = filters }
            if let after { request["after"] = after }
            let reply = try await client.request(path: "/v1/rows/pull", method: "POST",
                body: JSONSerialization.data(withJSONObject: request), maxBytes: 2 * 1024 * 1024)
            guard reply.status == 200 else { throw CircleConnectionError.unavailable }
            guard let page = try JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
                  let rows = page["rows"] as? [[String: Any]], rows.count <= 200,
                  let rawCursor = page["next_cursor"] else { throw CircleConnectionError.invalidResponse }
            for row in rows {
                guard Set(row.keys) == Set(table.columns), let id = row["id"] as? String,
                      !id.isEmpty, identities.insert(id).inserted,
                      filters.allSatisfy({ row[$0.key] as? String == $0.value }) else {
                    throw CircleConnectionError.invalidResponse
                }
            }
            allRows.append(contentsOf: rows)
            guard allRows.count <= 50_000 else { throw CircleConnectionError.invalidResponse }
            if rawCursor is NSNull { after = nil }
            else {
                guard let next = rawCursor as? String, !next.isEmpty,
                      next == rows.last?["id"] as? String, cursors.insert(next).inserted else {
                    throw CircleConnectionError.invalidResponse
                }
                after = next
            }
        } while after != nil
        return try JSONSerialization.data(withJSONObject: allRows, options: [.sortedKeys])
    }

    func graph(bindings: CirclePeopleBindings, selfID: String?) async throws -> SocialGraph {
        try bindings.validate()
        let people = try await read(bindings.people)
        let relations = try await read(bindings.relations)
        let locations = try await read(bindings.locations)
        var photos: Data?
        if let table = bindings.photos { photos = try await read(table) }
        return try bindings.graph(people: people, relations: relations, locations: locations, photos: photos, selfID: selfID)
    }
}
