import Foundation

/// Optional presentation metadata. Exact legacy labels remain the membership authority.
struct CircleDefinition: Codable, Equatable, Sendable {
    let id: String
    let sourceLabel: String
    let name: String
    let kind: String?
    let periodLabel: String?
    let start: String?
    let end: String?
    let parent: String?
    let person: String?
    static let keys: Set<String> = ["id", "sourceLabel", "name", "kind", "periodLabel", "start", "end", "parent", "person", "deleted"]
}

struct CircleMetadata: Codable, Equatable, Sendable {
    let definitions: [CircleDefinition]
    let unavailable: Bool

    static func read(_ data: Data, table: CircleProjectionTable, people: [String]) throws -> Self {
        let definitions = try table.rows(data, exactIDs: true).compactMap { row -> CircleDefinition? in
            func text(_ key: String, required: Bool = false) throws -> String? {
                if row[key] is NSNull, !required { return nil }
                guard let value = row[key] as? String, !value.isEmpty else { throw CircleConnectionError.invalidResponse }
                return value
            }
            if try text("deleted") != nil { return nil }
            return try CircleDefinition(id: text("id", required: true)!, sourceLabel: text("sourceLabel", required: true)!,
                name: text("name", required: true)!, kind: text("kind"), periodLabel: text("periodLabel"),
                start: text("start"), end: text("end"), parent: text("parent"), person: text("person"))
        }
        try validate(definitions, people: people)
        return Self(definitions: definitions, unavailable: false)
    }

    static func validate(_ definitions: [CircleDefinition], people: [String]) throws {
        guard definitions.count <= 50_000, Set(definitions.map { Data($0.id.utf8) }).count == definitions.count,
              Set(definitions.map { Data($0.sourceLabel.utf8) }).count == definitions.count else { throw CircleConnectionError.invalidResponse }
        let byID = Dictionary(uniqueKeysWithValues: definitions.map { (Data($0.id.utf8), $0) })
        let personIDs = Set(people.map { Data($0.utf8) })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        for definition in definitions {
            guard !definition.id.isEmpty, !definition.sourceLabel.isEmpty, !definition.name.isEmpty,
                  definition.person.map { personIDs.contains(Data($0.utf8)) } ?? true,
                  definition.parent.map({ byID[Data($0.utf8)] != nil }) ?? true else { throw CircleConnectionError.invalidResponse }
            for value in [definition.start, definition.end].compactMap({ $0 }) {
                guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
                      let date = formatter.date(from: value), formatter.string(from: date) == value else {
                    throw CircleConnectionError.invalidResponse
                }
            }
            if let start = definition.start, let end = definition.end, start > end { throw CircleConnectionError.invalidResponse }
        }
        // Iterative traversal bounds work and avoids recursion on hostile deep parent chains.
        var finished = Set<Data>()
        for definition in definitions {
            var visiting = Set<Data>(), cursor: Data? = Data(definition.id.utf8)
            while let id = cursor, !finished.contains(id) {
                guard visiting.insert(id).inserted else { throw CircleConnectionError.invalidResponse }
                cursor = byID[id]?.parent.map { Data($0.utf8) }
            }
            finished.formUnion(visiting)
        }
    }
}
