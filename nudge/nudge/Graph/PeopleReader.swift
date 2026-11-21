import Foundation

public struct CircleHTTPReply: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}
public protocol CircleHTTPClient: Sendable {
    func request(path: String, method: String, body: Data?, maxBytes: Int) async throws -> CircleHTTPReply
}

public struct CirclePeopleReader: Sendable {
    let client: any CircleHTTPClient
    public init(client: any CircleHTTPClient) { self.client = client }

    /// Complete bounded scan, not a cross-page or cross-table snapshot.
    /// Nothing is published until every page has passed validation.
    public func read(_ table: CircleProjectionTable, where filters: [String: String] = [:], exactIDs: Bool = false) async throws -> Data {
        guard Set(filters.keys).isSubset(of: Set(table.columns)) else {
            throw CircleConnectionError.invalidConfiguration
        }
        var allRows: [[String: Any]] = []
        var identities = Set<String>(), cursors = Set<String>()
        var exactIdentities = Set<Data>(), exactCursors = Set<Data>()
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
                      !id.isEmpty, (exactIDs ? exactIdentities.insert(Data(id.utf8)).inserted : identities.insert(id).inserted),
                      filters.allSatisfy({ row[$0.key] as? String == $0.value }) else {
                    throw CircleConnectionError.invalidResponse
                }
            }
            allRows.append(contentsOf: rows)
            guard allRows.count <= 50_000 else { throw CircleConnectionError.invalidResponse }
            if rawCursor is NSNull { after = nil }
            else {
                guard let next = rawCursor as? String, !next.isEmpty,
                      let lastID = rows.last?["id"] as? String,
                      (exactIDs ? Data(next.utf8) == Data(lastID.utf8) : next == lastID),
                      (exactIDs ? exactCursors.insert(Data(next.utf8)).inserted : cursors.insert(next).inserted) else {
                    throw CircleConnectionError.invalidResponse
                }
                after = next
            }
        } while after != nil
        return try JSONSerialization.data(withJSONObject: allRows, options: [.sortedKeys])
    }

    func graph(bindings: CirclePeopleBindings, selfID: String?, previousMetadata: CircleMetadata? = nil) async throws -> SocialGraph {
        try bindings.validate()
        let people = try await read(bindings.people)
        let relations = try await read(bindings.relations)
        let locations = try await read(bindings.locations)
        var photos: Data?
        if let table = bindings.photos { photos = try await read(table) }
        var graph = try bindings.graph(people: people, relations: relations, locations: locations, photos: photos, selfID: selfID)
        if let table = bindings.circleDefinitions {
            do {
                let data = try await read(table, exactIDs: true)
                graph.circleMetadata = try CircleMetadata.read(data, table: table, people: graph.people.map(\.id))
            } catch is CancellationError { throw CancellationError() }
            catch {
                var retained = previousMetadata?.definitions ?? []
                do { try CircleMetadata.validate(retained, people: graph.people.map(\.id)) }
                catch { retained = [] }
                graph.circleMetadata = CircleMetadata(definitions: retained, unavailable: true)
            }
        }
        return graph
    }
}
