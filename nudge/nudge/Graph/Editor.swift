import CryptoKit
import Foundation

/// A service-owned create-only policy: the client computes the hub's target id from it.
struct CircleCreationBinding: Codable, Sendable {
    struct Policy: Codable, Sendable {
        let id: String
        let revision: String
    }
    let policy: Policy
    let namespace: String
    let sourceKind: String

    func validate() throws {
        guard policy.id.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) != nil,
              policy.revision.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              namespace.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil,
              !sourceKind.isEmpty else { throw CircleConnectionError.invalidConfiguration }
    }
}

enum CircleEditorError: Error, Equatable, LocalizedError {
    case changedElsewhere, refused
    var errorDescription: String? {
        switch self {
        case .changedElsewhere: "This person changed elsewhere. Refresh, then try again."
        case .refused: "The service did not accept the change. Nothing was saved."
        }
    }
}

/// Circle's only writes: a person's hangout cadence (revision-checked) and logged hangouts (create-only).
struct CircleEditor: Sendable {
    let client: any CircleHTTPClient
    let bindings: CirclePeopleBindings

    init?(client: any CircleHTTPClient, bindings: CirclePeopleBindings) {
        guard bindings.cadenceEditable || bindings.hangoutLog != nil else { return nil }
        self.client = client; self.bindings = bindings
    }

    var canEditCadence: Bool { bindings.cadenceEditable }
    var canLogHangouts: Bool { bindings.hangoutLog != nil }

    func setHangoutCadence(_ cadence: String?, personID: String, revision: GraphRowRevision) async throws -> GraphRowRevision {
        guard bindings.cadenceEditable, let column = bindings.people.fields["hangoutCadence"] else { throw CircleEditorError.refused }
        let body: [String: Any] = ["table": bindings.people.table, "id": personID, "values": [column: cadence as Any? ?? NSNull()],
                                   "expected_revision": ["updated_at": revision.updatedAt, "hub_at": revision.hubAt]]
        let reply = try await client.request(path: "/v1/rows/patch", method: "POST",
                                             body: JSONSerialization.data(withJSONObject: body), maxBytes: 65_536)
        if reply.status == 409 { throw CircleEditorError.changedElsewhere }
        guard reply.status == 200, let object = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
              object["id"] as? String == personID, let next = object["revision"] as? [String: String],
              let updated = next["updated_at"], let hub = next["hub_at"] else { throw CircleEditorError.refused }
        return GraphRowRevision(updatedAt: updated, hubAt: hub)
    }

    /// One tap is one source id, so a retry after a lost reply settles as the same row.
    func logHangout(day: String, people: [String], sourceID: UUID, now: Date) async throws -> String {
        guard let log = bindings.hangoutLog, let table = bindings.hangouts, !people.isEmpty,
              let dayColumn = table.fields["date"], let peopleColumn = table.fields["people"] else { throw CircleEditorError.refused }
        let source = sourceID.uuidString.lowercased()
        let target = Self.targetID(namespace: log.namespace, sourceKind: log.sourceKind, sourceID: source, occurrence: 0)
        let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(now)
        let body: [String: Any] = [
            "policy": ["id": log.policy.id, "revision": log.policy.revision], "sourceId": source, "occurrenceKey": 0,
            "target": ["kind": "generated", "id": target], "updatedAt": stamp,
            "values": [dayColumn: day, peopleColumn: String(decoding: try JSONSerialization.data(withJSONObject: people), as: UTF8.self)]
        ]
        let reply = try await client.request(path: "/v1/rows/create", method: "POST",
                                             body: JSONSerialization.data(withJSONObject: body), maxBytes: 65_536)
        guard reply.status == 200, let object = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any],
              ["created", "existing"].contains(object["kind"] as? String), object["id"] as? String == target,
              let policy = object["policy"] as? [String: String], policy == ["id": log.policy.id, "revision": log.policy.revision] else {
            throw CircleEditorError.refused
        }
        return target
    }

    /// UUIDv5(namespace, JSON ["v1", kind, source, occurrence]) as 32 lowercase hex, exactly as the hub computes it.
    static func targetID(namespace: String, sourceKind: String, sourceID: String, occurrence: Int) -> String {
        let hex = namespace.replacingOccurrences(of: "-", with: "")
        var bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        let name = (try? JSONSerialization.data(withJSONObject: ["v1", sourceKind, sourceID, occurrence], options: .withoutEscapingSlashes)) ?? Data()
        bytes += name
        var digest = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
        digest[6] = (digest[6] & 0x0f) | 0x50
        digest[8] = (digest[8] & 0x3f) | 0x80
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
