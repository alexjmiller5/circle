import CoreFoundation
import Foundation

/// Logical fields belong to Circle's metadata protocol. Actual table/column
/// names come from the service, never from customer-entered schema settings.
struct CircleHistoryBindings: Codable, Sendable {
    let events: CircleProjectionTable
    let participants: CircleProjectionTable
    let imports: CircleProjectionTable
    let coverage: CircleProjectionTable
    static let eventFields: Set<String> = ["id", "source", "channel", "event_kind", "occurred_at", "direction", "message_state", "conversation_ref", "conversation_kind", "duration_seconds", "call_outcome", "first_import_id", "expected_participant_rows", "participant_coverage", "participant_coverage_reason", "needs_review", "updated_at", "deleted_at"]
    static let participantFields: Set<String> = ["id", "event_id", "role", "is_self", "person_id", "first_import_id", "updated_at", "deleted_at"]
    static let importFields: Set<String> = ["id", "source", "source_namespace", "source_instance_ref", "policy_version", "captured_at", "window_start", "window_end", "coverage", "reason_code", "observed_rows", "accepted_events", "existing_events", "excluded_rows", "duplicate_rows", "conflicted_events", "unresolved_participants", "completed_at", "updated_at", "deleted_at"]
    static let coverageFields: Set<String> = ["id", "import_id", "channel", "event_kind", "disposition", "reason_code", "row_count", "available_event_start", "available_event_end", "updated_at", "deleted_at"]

    func validate() throws {
        try events.validate(keys: Self.eventFields)
        try participants.validate(keys: Self.participantFields)
        try imports.validate(keys: Self.importFields)
        try coverage.validate(keys: Self.coverageFields)
        guard Set([events, participants, imports, coverage].map(\.table)).count == 4 else {
            throw CircleConnectionError.invalidConfiguration
        }
    }
    var scopes: [String] {
        Set([events, participants, imports, coverage].flatMap { table in
            table.columns.map { "tables:read:\(table.table):\($0)" }
        }).sorted()
    }
}

struct CircleContactHistory: Sendable {
    let interactions: [ContactInteraction]
    let readiness: ContactHistoryReadiness
}

struct CircleContactHistoryReader: Sendable {
    let client: any CircleHTTPClient
    let bindings: CircleHistoryBindings

    /// Separate complete rescans and rereads detect observed changes, not ABA
    /// or atomic snapshots. Stable results remain provisional for reminders.
    func read(personID: String) async throws -> CircleContactHistory {
        do {
            try bindings.validate()
            guard !personID.isEmpty else { throw CircleConnectionError.invalidConfiguration }
            let first = try await capture(personID: personID)
            let second = try await capture(personID: personID)
            try Task.checkCancellation()
            guard first == second else { throw CircleConnectionError.invalidResponse }
            let candidates = try active(bindings.participants.rows(first["candidates"]!))
            let eventIDs = try Set(candidates.map { try string($0, "event_id")! })
            var interactions: [ContactInteraction] = []
            for id in eventIDs.sorted() {
                let row = try one(bindings.events, first["event:\(id)"]!)
                guard try active([row]).count == 1 else { continue }
                let participantRows = try bindings.participants.rows(first["participants:\(id)"]!)
                let participants = try participantRows.map { row in
                    ContactParticipantMetadata(id: try string(row, "id")!, eventID: try string(row, "event_id")!,
                        firstImportID: try string(row, "first_import_id")!, role: try string(row, "role")!,
                        isSelf: try boolean(row, "is_self"), personID: try string(row, "person_id", nullable: true),
                        deleted: try date(row, "deleted_at") != nil)
                }
                let activeParticipants = participants.filter { !$0.deleted }
                guard try integer(row, "expected_participant_rows") == activeParticipants.count else {
                    throw CircleConnectionError.invalidResponse
                }
                let references = Set([try string(row, "first_import_id")!] + activeParticipants.map(\.firstImportID))
                let source = try string(row, "source")!
                let imports = try references.map { reference in
                    let imported = try one(bindings.imports, first["import:\(reference)"]!)
                    guard try string(imported, "source") == source else { throw CircleConnectionError.invalidResponse }
                    return ContactImportMetadata(id: reference, sourceNamespace: try string(imported, "source_namespace")!,
                        completed: try date(imported, "completed_at") != nil, deleted: try date(imported, "deleted_at") != nil)
                }
                let event = ContactEventMetadata(id: id, firstImportID: try string(row, "first_import_id")!,
                    occurredAt: try date(row, "occurred_at"), kind: try string(row, "event_kind")!,
                    direction: try string(row, "direction")!, messageState: try string(row, "message_state", nullable: true),
                    conversationKind: try string(row, "conversation_kind")!, expectedParticipantRows: try integer(row, "expected_participant_rows"),
                    participantCoverage: try string(row, "participant_coverage")!, participantCoverageReason: try string(row, "participant_coverage_reason")!,
                    callOutcome: try string(row, "call_outcome", nullable: true), durationSeconds: try number(row, "duration_seconds"),
                    needsReview: try boolean(row, "needs_review"))
                interactions += try ContactMetadataProjection.interactions(event: event, participants: participants, imports: imports)
                    .filter { $0.personID == personID }
            }
            return CircleContactHistory(interactions: interactions, readiness: .incomplete)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // Replace prior facts with pending, never preserve a fresh recency maximum.
            return CircleContactHistory(interactions: [], readiness: .dataPending)
        }
    }

    private func capture(personID: String) async throws -> [String: Data] {
        let reader = CirclePeopleReader(client: client)
        var result = ["candidates": try await reader.read(bindings.participants,
            where: [bindings.participants.fields["person_id"]!: personID])]
        let candidates = try active(bindings.participants.rows(result["candidates"]!))
        let ids = try Set(candidates.map { try string($0, "event_id")! })
        for id in ids.sorted() {
            let eventData = try await reader.read(bindings.events, where: ["id": id])
            result["event:\(id)"] = eventData
            let event = try one(bindings.events, eventData)
            guard try active([event]).count == 1 else { continue }
            let participantData = try await reader.read(bindings.participants,
                where: [bindings.participants.fields["event_id"]!: id])
            result["participants:\(id)"] = participantData
            let participants = try active(bindings.participants.rows(participantData))
            let references = try Set([string(event, "first_import_id")!] + participants.map { try string($0, "first_import_id")! })
            for reference in references.sorted() where result["import:\(reference)"] == nil {
                let importData = try await reader.read(bindings.imports, where: ["id": reference])
                result["import:\(reference)"] = importData
                let imported = try one(bindings.imports, importData)
                guard try active([imported]).count == 1, try date(imported, "completed_at") != nil else {
                    throw CircleConnectionError.invalidResponse
                }
                let coverageData = try await reader.read(bindings.coverage,
                    where: [bindings.coverage.fields["import_id"]!: reference])
                result["coverage:\(reference)"] = coverageData
                try validateCoverage(imported, rows: active(bindings.coverage.rows(coverageData)))
            }
        }
        return result
    }

    private func validateCoverage(_ imported: [String: Any], rows: [[String: Any]]) throws {
        let counters = ["accepted":"accepted_events", "existing":"existing_events", "duplicate":"duplicate_rows", "excluded":"excluded_rows", "conflict":"conflicted_events"]
        let expectedObserved = try integer(imported, "observed_rows")
        var observed = 0, totals: [String: Int] = [:]
        for row in rows {
            let disposition = try string(row, "disposition")!, count = try integer(row, "row_count")
            guard counters[disposition] != nil || (disposition == "unavailable" && count == 0) else {
                throw CircleConnectionError.invalidResponse
            }
            guard count <= expectedObserved - observed else { throw CircleConnectionError.invalidResponse }
            totals[disposition, default: 0] += count
            observed += count
        }
        guard expectedObserved == observed else { throw CircleConnectionError.invalidResponse }
        for (disposition, column) in counters {
            guard try integer(imported, column) == totals[disposition, default: 0] else {
                throw CircleConnectionError.invalidResponse
            }
        }
    }

    private func one(_ table: CircleProjectionTable, _ data: Data) throws -> [String: Any] {
        let rows = try table.rows(data)
        guard rows.count == 1 else { throw CircleConnectionError.invalidResponse }
        return rows[0]
    }
    private func active(_ rows: [[String: Any]]) throws -> [[String: Any]] {
        try rows.filter { try date($0, "deleted_at") == nil }
    }
    private func string(_ row: [String: Any], _ key: String, nullable: Bool = false) throws -> String? {
        if nullable, row[key] is NSNull { return nil }
        guard let value = row[key] as? String, !value.isEmpty else { throw CircleConnectionError.invalidResponse }
        return value
    }
    private func date(_ row: [String: Any], _ key: String) throws -> Date? {
        guard let value = try string(row, key, nullable: true) else { return nil }
        if let date = try? Date(value, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        if let date = try? Date(value, strategy: Date.ISO8601FormatStyle()) { return date }
        throw CircleConnectionError.invalidResponse
    }
    private func number(_ row: [String: Any], _ key: String) throws -> Double? {
        if row[key] is NSNull { return nil }
        guard let value = row[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw CircleConnectionError.invalidResponse
        }
        return value.doubleValue
    }
    private func integer(_ row: [String: Any], _ key: String) throws -> Int {
        guard let value = try number(row, key), value >= 0, value <= 9_007_199_254_740_991, value.rounded() == value else {
            throw CircleConnectionError.invalidResponse
        }
        return Int(value)
    }
    private func boolean(_ row: [String: Any], _ key: String) throws -> Bool {
        guard let value = row[key] as? NSNumber, value.doubleValue == 0 || value.doubleValue == 1 else {
            throw CircleConnectionError.invalidResponse
        }
        return value.boolValue
    }
}
