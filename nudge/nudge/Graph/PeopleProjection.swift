import Foundation

/// Service-owned table and column bindings. Customers supply no schema internals.
struct CircleProjectionTable: Codable, Sendable {
    let table: String
    let fields: [String: String]
    var columns: [String] { Array(Set(fields.values)).sorted() }

    func validate(keys: Set<String>) throws {
        let valid: (String) -> Bool = { $0.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil }
        guard valid(table), !["history", "provenance", "purges"].contains(table.lowercased()),
              !table.lowercased().hasPrefix("catalog_"), !table.lowercased().hasPrefix("sqlite_"),
              Set(fields.keys) == keys, fields["id"] == "id", fields.values.allSatisfy(valid),
              columns.count == fields.count else { throw CircleConnectionError.invalidConfiguration }
    }

    func rows(_ data: Data) throws -> [[String: Any]] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CircleConnectionError.invalidResponse
        }
        var ids = Set<String>()
        return try rows.map { row in
            guard Set(row.keys) == Set(columns), let id = row["id"] as? String, !id.isEmpty,
                  ids.insert(id).inserted else { throw CircleConnectionError.invalidResponse }
            return Dictionary(uniqueKeysWithValues: fields.map { ($0.key, row[$0.value]!) })
        }
    }
}

struct CirclePeopleBindings: Codable, Sendable {
    let people: CircleProjectionTable
    let relations: CircleProjectionTable
    let locations: CircleProjectionTable

    func validate() throws {
        try people.validate(keys: ["id", "name", "circles", "deleted"])
        try relations.validate(keys: ["id", "person", "related", "kind", "deleted"])
        try locations.validate(keys: ["id", "person", "city", "country", "start", "end", "deleted"])
    }

    var scopes: [String] {
        Set([people, relations, locations].flatMap { table in
            table.columns.map { "tables:read:\(table.table):\($0)" }
        }).sorted()
    }

    func graph(people peopleData: Data, relations relationData: Data, locations locationData: Data, selfID: String?) throws -> SocialGraph {
        try validate()
        func string(_ row: [String: Any], _ key: String, required: Bool = false) throws -> String? {
            guard let value = row[key] else { throw CircleConnectionError.invalidResponse }
            if value is NSNull, !required { return nil }
            guard let text = value as? String, !required || !text.isEmpty else { throw CircleConnectionError.invalidResponse }
            return text
        }
        func active(_ rows: [[String: Any]]) throws -> [[String: Any]] {
            try rows.filter { try string($0, "deleted") == nil }
        }
        var bases: [String: Set<BaseLocation>] = [:]
        for row in try active(locations.rows(locationData)) {
            let personID = try string(row, "person", required: true)!
            let end = try string(row, "end")
            _ = try string(row, "start")
            let city = try string(row, "city"), country = try string(row, "country")
            if end == nil, let city, !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bases[personID, default: []].insert(BaseLocation(city: city, country: country))
            }
        }
        let people = try active(people.rows(peopleData)).map { row in
            let id = try string(row, "id", required: true)!
            let name = try string(row, "name", required: true)!
            let circles: [String]
            if row["circles"] is NSNull { circles = [] }
            else if let encoded = row["circles"] as? String, let data = encoded.data(using: .utf8) {
                circles = try JSONDecoder().decode([String].self, from: data)
            } else { throw CircleConnectionError.invalidResponse }
            // Multiple distinct current claims are ambiguity, never an arbitrary winner.
            let base = bases[id]?.count == 1 ? bases[id]?.first : nil
            return GraphPerson(id: id, name: name, circles: circles, baseCity: base?.city, baseCountry: base?.country)
        }
        let edges = try active(relations.rows(relationData)).map { row in
            GraphRelation(personID: try string(row, "person", required: true)!,
                          relatedID: try string(row, "related", required: true)!,
                          kind: try string(row, "kind", required: true)!)
        }
        return SocialGraph(people: people, relations: edges, selfID: selfID)
    }
}

private struct BaseLocation: Hashable { let city: String; let country: String? }
