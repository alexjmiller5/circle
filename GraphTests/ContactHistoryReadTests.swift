import Foundation
import Testing
@testable import CircleGraph

private let historyBindings = CircleHistoryBindings(
    events: .init(table: "events", fields: Dictionary(uniqueKeysWithValues: CircleHistoryBindings.eventFields.map { ($0, $0) })),
    participants: .init(table: "participants", fields: Dictionary(uniqueKeysWithValues: CircleHistoryBindings.participantFields.map { ($0, $0) })),
    imports: .init(table: "imports", fields: Dictionary(uniqueKeysWithValues: CircleHistoryBindings.importFields.map { ($0, $0) })),
    coverage: .init(table: "coverage", fields: Dictionary(uniqueKeysWithValues: CircleHistoryBindings.coverageFields.map { ($0, $0) })))

private actor HistoryFixture: CircleHTTPClient {
    var requests: [[String: String]] = []
    var changeIdentityOnReread = false
    var denyCoverage = false
    var overflowingCoverage = false
    var scenario: String?
    private var candidatesRead = 0
    private let null = NSNull()
    func changeIdentity() { changeIdentityOnReread = true }
    func deny() { denyCoverage = true }
    func overflow() { overflowingCoverage = true }
    func setScenario(_ value: String) { scenario = value }
    func request(path: String, method: String, body: Data?, maxBytes: Int) async throws -> CircleHTTPReply {
        if scenario == "cancel" { throw CancellationError() }
        #expect(path == "/v1/rows/pull" && method == "POST")
        let request = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
        #expect(request["since"] == nil)
        let table = request["table"] as! String, columns = request["columns"] as! [String]
        let filters = request["where"] as? [String: String] ?? [:]
        requests.append(filters)
        var rows: [[String: Any]]
        switch table {
        case "events": rows = [["id":"event-1", "source":"apple_messages", "channel":"imessage", "event_kind":"message", "occurred_at":"2023-11-14T22:13:20Z", "direction":"outgoing", "message_state":"sent", "conversation_ref":"conversation-1", "conversation_kind":"direct", "duration_seconds":null, "call_outcome":null, "first_import_id":"import-1", "expected_participant_rows":2, "participant_coverage":"complete_for_event", "participant_coverage_reason":"verified_event_endpoints", "needs_review":0, "updated_at":"2023-11-15T00:00:00Z", "deleted_at":null, "body":"forbidden-content-canary"]]
        case "participants":
            if filters["person_id"] != nil { candidatesRead += 1 }
            let person = changeIdentityOnReread && candidatesRead >= 2 ? "person-2" : "person-1"
            rows = [
                ["id":"row-1", "event_id":"event-1", "role":"sender", "is_self":1, "person_id":null, "first_import_id":"import-1", "updated_at":"2023-11-15T00:00:00Z", "deleted_at":null],
                ["id":"row-2", "event_id":"event-1", "role":"recipient", "is_self":0, "person_id":person, "first_import_id":"import-1", "updated_at":"2023-11-15T00:00:00Z", "deleted_at":null]
            ]
        case "imports": rows = [["id":"import-1", "source":"apple_messages", "source_namespace":"account-1", "source_instance_ref":"replica-1", "policy_version":"metadata-v1", "captured_at":"2023-11-15T00:00:00Z", "window_start":null, "window_end":null, "coverage":"snapshot_complete", "reason_code":null, "observed_rows":1, "accepted_events":1, "existing_events":0, "excluded_rows":0, "duplicate_rows":0, "conflicted_events":0, "unresolved_participants":0, "completed_at":"2023-11-15T00:01:00Z", "updated_at":"2023-11-15T00:01:00Z", "deleted_at":null]]
        case "coverage":
            if denyCoverage { return CircleHTTPReply(status: 403, data: Data("{}".utf8)) }
            rows = [["id":"coverage-1", "import_id":"import-1", "channel":"imessage", "event_kind":"message", "disposition":"accepted", "reason_code":"none", "row_count":1, "available_event_start":"2023-11-14T22:13:20Z", "available_event_end":"2023-11-14T22:13:20Z", "updated_at":"2023-11-15T00:01:00Z", "deleted_at":null]]
        default: throw CircleConnectionError.invalidConfiguration
        }
        switch (scenario, table) {
        case ("incomplete_import", "imports"): rows[0]["completed_at"] = null
        case ("deleted_import", "imports"): rows[0]["deleted_at"] = "2023-11-16T00:00:00Z"
        case ("missing_coverage", "coverage"): rows = []
        case ("wrong_source", "imports"): rows[0]["source"] = "other_source"
        case ("wrong_participant_count", "events"): rows[0]["expected_participant_rows"] = 3
        case ("event_revision", "events") where candidatesRead >= 2: rows[0]["updated_at"] = "2023-11-16T00:00:00Z"
        case ("deleted_event", "events"): rows[0]["deleted_at"] = "2023-11-16T00:00:00Z"
        case ("deleted_participant", "participants"): rows[1]["deleted_at"] = "2023-11-16T00:00:00Z"
        default: break
        }
        if overflowingCoverage {
            if table == "imports" { rows[0]["observed_rows"] = 9_007_199_254_740_991; rows[0]["accepted_events"] = 9_007_199_254_740_991 }
            if table == "coverage" {
                let template = rows[0]
                rows = (0..<1025).map { index in
                    var row = template; row["id"] = String(format: "coverage-%04d", index)
                    row["row_count"] = 9_007_199_254_740_991; return row
                }
            }
        }
        rows = rows.filter { row in filters.allSatisfy { row[$0.key] as? String == $0.value } }
        if let after = request["after"] as? String { rows = rows.filter { ($0["id"] as! String) > after } }
        let next: Any = rows.count > 1 ? rows[0]["id"]! : null
        // Deliberately short pages exercise full enumeration without top-N assumptions.
        let page = rows.prefix(1).map { row in Dictionary(uniqueKeysWithValues: columns.map { ($0, row[$0]!) }) }
        return .init(status: 200, data: try JSONSerialization.data(withJSONObject: ["rows":page, "next_cursor":next]))
    }
}

@Test func contactHistoryReadFinishesPagesChecksPublicationAndKeepsRemindersProvisional() async throws {
    let fixture = HistoryFixture()
    #expect(historyBindings.scopes.count == 57)
    #expect(!historyBindings.scopes.contains { $0.contains("body") || $0.contains("provenance") })
    let result = try await CircleContactHistoryReader(client: fixture, bindings: historyBindings).read(personID: "person-1")
    #expect(result.readiness == .incomplete)
    #expect(result.interactions.map(\.personID) == ["person-1"])
    #expect(result.interactions.first?.kind == .outgoingMessage)
    let calls = await fixture.requests
    #expect(calls.filter { $0["event_id"] == "event-1" }.count == 4)
    var settings = ReachOutPreferences(); settings.remindersEnabled = true
    #expect(!ReachOutAssessment(personID: "person-1", interactions: result.interactions, history: result.readiness,
        settings: settings, now: Date(timeIntervalSince1970: 1_800_000_000)).notificationEligible)
}

@Test func contactHistoryReadRetractsFactsOnIdentityChangesAndDeniedDependencies() async throws {
    for changed in [true, false] {
        let fixture = HistoryFixture()
        if changed { await fixture.changeIdentity() } else { await fixture.deny() }
        let result = try await CircleContactHistoryReader(client: fixture, bindings: historyBindings).read(personID: "person-1")
        #expect(result.readiness == .dataPending)
        #expect(result.interactions.isEmpty)
    }
}

@Test func contactHistoryRejectsCoverageTotalsWithoutIntegerOverflow() async throws {
    let fixture = HistoryFixture(); await fixture.overflow()
    let result = try await CircleContactHistoryReader(client: fixture, bindings: historyBindings).read(personID: "person-1")
    #expect(result.readiness == .dataPending)
    #expect(result.interactions.isEmpty)
}

@Test func contactHistoryMissingPublicationAndObservedRevisionsStayPending() async throws {
    for scenario in ["incomplete_import", "deleted_import", "missing_coverage", "wrong_source", "wrong_participant_count", "event_revision"] {
        let fixture = HistoryFixture(); await fixture.setScenario(scenario)
        let result = try await CircleContactHistoryReader(client: fixture, bindings: historyBindings).read(personID: "person-1")
        #expect(result.readiness == .dataPending, "Failed case: \(scenario)")
        #expect(result.interactions.isEmpty)
    }
    for scenario in ["deleted_event", "deleted_participant"] {
        let fixture = HistoryFixture(); await fixture.setScenario(scenario)
        let result = try await CircleContactHistoryReader(client: fixture, bindings: historyBindings).read(personID: "person-1")
        #expect(result.readiness == .incomplete)
        #expect(result.interactions.isEmpty)
    }
    let fixture = HistoryFixture(); await fixture.setScenario("cancel")
    await #expect(throws: CancellationError.self) {
        try await CircleContactHistoryReader(client: fixture, bindings: historyBindings).read(personID: "person-1")
    }
}
