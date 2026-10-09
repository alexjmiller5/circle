import Foundation

/// Service-owned table and column bindings. Customers supply no schema internals.
struct CircleProjectionTable: Codable, Sendable {
    let table: String
    let fields: [String: String]
    /// Retained-file prefixes readable for this table's keys (photos only).
    var files: [String]? = nil
    var columns: [String] { Array(Set(fields.values)).sorted() }

    func validate(keys: Set<String>, files expectsFiles: Bool = false) throws {
        let valid: (String) -> Bool = { $0.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil }
        if expectsFiles {
            guard let files, !files.isEmpty, Set(files).count == files.count,
                  files.allSatisfy(CirclePhotoLoader.validPrefix) else { throw CircleConnectionError.invalidConfiguration }
        } else if files != nil { throw CircleConnectionError.invalidConfiguration }
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
    /// Optional so a profile without photo access stays valid.
    var photos: CircleProjectionTable? = nil

    func validate() throws {
        try people.validate(keys: ["id", "name", "circles", "deleted"])
        try relations.validate(keys: ["id", "person", "related", "kind", "deleted"])
        try locations.validate(keys: ["id", "person", "city", "country", "start", "end", "deleted"])
        try photos?.validate(keys: ["id", "person", "platform", "key", "sha256", "fetched", "updated", "deleted"], files: true)
    }

    var scopes: [String] {
        Set(([people, relations, locations] + [photos].compactMap { $0 }).flatMap { table in
            table.columns.map { "tables:read:\(table.table):\($0)" }
        } + (photos?.files ?? []).map { "files:read:" + $0 }).sorted()
    }

    func graph(people peopleData: Data, relations relationData: Data, locations locationData: Data,
               photos photoData: Data? = nil, selfID: String?) throws -> SocialGraph {
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
        var bases: [String: Set<BaseLocation>] = [:], histories: [String: [GraphResidence]] = [:]
        for row in try active(locations.rows(locationData)) {
            let personID = try string(row, "person", required: true)!
            let end = try string(row, "end")
            let start = try string(row, "start")
            let city = try string(row, "city"), country = try string(row, "country")
            histories[personID, default: []].append(GraphResidence(city: city, country: country, start: start, end: end))
            if end == nil, let city, !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bases[personID, default: []].insert(BaseLocation(city: city, country: country))
            }
        }
        var pictures: [String: [GraphPhoto]] = [:]
        if let photos {
            guard let photoData else { throw CircleConnectionError.invalidResponse }
            for row in try active(photos.rows(photoData)) {
                pictures[try string(row, "person", required: true)!, default: []].append(GraphPhoto(
                    platform: try string(row, "platform", required: true)!, key: try string(row, "key", required: true)!,
                    sha256: try string(row, "sha256"), fetchedAt: try string(row, "fetched"), updatedAt: try string(row, "updated")))
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
            return GraphPerson(id: id, name: name, circles: circles, baseCity: base?.city, baseCountry: base?.country,
                               residences: histories[id], photos: pictures[id])
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
