import Foundation
import Testing
@testable import CircleGraph

// Synthetic table and column names; the service owns the real bindings.
let summaryTable = CircleProjectionTable(table: "talk_summary", fields: [
    "id":"id", "person":"who", "channel":"via", "lastSent":"sent_at", "lastReceived":"got_at",
    "lastAnsweredCall":"answered_at", "lastAnsweredSeconds":"answered_secs", "lastCall":"call_at",
    "sent":"sent_n", "received":"got_n", "callsAnswered":"answered_n", "callsMissed":"missed_n",
    "coverageStart":"from_at", "coverageEnd":"to_at", "refreshed":"refreshed_at", "review":"review",
    "updated":"updated_at", "deleted":"deleted_at"])
let importTable = CircleProjectionTable(table: "talk_runs", fields: [
    "id":"id", "source":"store", "instance":"copy", "coverage":"state", "reason":"why",
    "firstEvent":"first_at", "completed":"done_at", "updated":"updated_at", "deleted":"deleted_at"])
let contactTable = CircleProjectionTable(table: "handles", fields: [
    "id":"id", "person":"who", "platform":"kind", "source":"native_id", "deleted":"deleted_at"])

private func summaryRow(_ person: String, _ channel: String, id: String? = nil, sent: Any = NSNull(), received: Any = NSNull(),
                        answered: Any = NSNull(), deleted: Any = NSNull()) -> [String: Any] {
    ["id": id ?? "\(person):\(channel)", "who": person, "via": channel, "sent_at": sent, "got_at": received,
     "answered_at": answered, "answered_secs": NSNull(), "call_at": answered, "sent_n": 3, "got_n": 2, "answered_n": 0,
     "missed_n": 0, "from_at": "2017-08-11T15:02:25.000Z", "to_at": "2026-10-09T21:43:44.113Z",
     "refreshed_at": "2026-10-09T22:25:39.814Z", "review": NSNull(), "updated_at": "2026-10-09T22:25:39.814Z", "deleted_at": deleted]
}

private func importRow(_ id: String, _ source: String, instance: String = "live", state: String = "partial",
                       first: Any = NSNull(), done: String, deleted: Any = NSNull()) -> [String: Any] {
    ["id": id, "store": source, "copy": instance, "state": state, "why": state == "complete" ? NSNull() : "a partial mirror",
     "first_at": first, "done_at": done, "updated_at": done, "deleted_at": deleted]
}

actor HistoryFixture: CircleHTTPClient {
    var summaries: [[String: Any]]
    var imports: [[String: Any]]
    var contacts: [[String: Any]]
    private(set) var filters: [String: [[String: String]]] = [:]
    init(summaries: [[String: Any]], imports: [[String: Any]], contacts: [[String: Any]] = []) {
        self.summaries = summaries; self.imports = imports; self.contacts = contacts
    }
    func request(path: String, method: String, body: Data?, maxBytes: Int) async throws -> CircleHTTPReply {
        #expect(path == "/v1/rows/pull" && method == "POST")
        let request = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
        let table = request["table"] as! String, filter = request["where"] as? [String: String] ?? [:]
        filters[table, default: []].append(filter)
        let all: [[String: Any]] = switch table {
        case "talk_summary": summaries
        case "talk_runs": imports
        case "handles": contacts
        default: throw CircleConnectionError.invalidConfiguration
        }
        let rows = all.filter { row in filter.allSatisfy { row[$0.key] as? String == $0.value } }
        return CircleHTTPReply(status: 200, data: try JSONSerialization.data(withJSONObject: ["rows": rows, "next_cursor": NSNull()]))
    }
}

private func instant(_ value: String) -> Date { try! Date(value, strategy: .iso8601) }

@Test func summaryReaderGroupsLiveRowsPerPersonAndDropsTombstones() async throws {
    let fixture = HistoryFixture(summaries: [
        summaryRow("p1", "imessage", sent: "2026-09-01T10:00:00.000Z", received: "2026-10-01T10:00:00.000Z"),
        summaryRow("p1", "phone", answered: "2026-09-20T18:30:00Z"),
        summaryRow("p2", "sms", sent: "2026-01-01T00:00:00.000Z", deleted: "2026-10-09T00:00:00.000Z"),
        summaryRow("p3", "signal", sent: "2026-01-01T00:00:00.000Z")
    ], imports: [importRow("r1", "apple_messages", state: "complete", first: "2017-08-11T15:02:25.000Z", done: "2026-10-09T21:43:47.267Z")])
    let history = try await CommunicationHistoryReader(client: fixture).read(summaries: summaryTable, imports: importTable, contacts: nil)
    let p1 = try #require(history.channels["p1"])
    #expect(p1.map(\.channel).sorted { $0.rawValue < $1.rawValue } == [.imessage, .phone])
    let imessage = try #require(p1.first { $0.channel == .imessage })
    #expect(imessage.lastSent == instant("2026-09-01T10:00:00Z"))
    #expect(imessage.lastReceived == instant("2026-10-01T10:00:00Z"))
    #expect(imessage.sent == 3 && imessage.received == 2)
    #expect(imessage.coverageStart == instant("2017-08-11T15:02:25Z"))
    #expect(p1.first { $0.channel == .phone }?.lastAnsweredCall == instant("2026-09-20T18:30:00Z"))
    // A tombstoned pair is no evidence; an unknown future channel waits for an app update.
    #expect(history.channels["p2"] == nil)
    #expect(history.channels["p3"] == nil)
    #expect(history.refreshedAt == instant("2026-10-09T22:25:39.814Z"))
}

@Test func summaryReaderRejectsRowsWhoseIdentityDisagrees() async throws {
    let fixture = HistoryFixture(summaries: [summaryRow("p1", "imessage", id: "p2:imessage")], imports: [])
    await #expect(throws: CircleConnectionError.self) {
        try await CommunicationHistoryReader(client: fixture).read(summaries: summaryTable, imports: importTable, contacts: nil)
    }
    let badDate = HistoryFixture(summaries: [summaryRow("p1", "imessage", sent: "last tuesday")], imports: [])
    await #expect(throws: CircleConnectionError.self) {
        try await CommunicationHistoryReader(client: badDate).read(summaries: summaryTable, imports: importTable, contacts: nil)
    }
}

@Test func coverageUsesEachSourcesNewestLiveRunWithEarliestEvent() async throws {
    let fixture = HistoryFixture(summaries: [], imports: [
        // A retained backup read after the live store must not hide the live store's state.
        importRow("a", "apple_calls", instance: "backup:week/calls.db.gz", first: "2025-07-16T20:42:27.641Z", done: "2026-10-09T22:30:00.000Z"),
        importRow("b", "apple_calls", first: "2026-06-02T22:36:17.375Z", done: "2026-10-09T19:24:21.081Z"),
        importRow("c", "apple_calls", state: "complete", done: "2026-10-09T21:43:50.795Z"),
        importRow("d", "apple_calls", state: "unavailable", done: "2026-10-09T23:00:00.000Z", deleted: "2026-10-09T23:01:00.000Z"),
        importRow("e", "whatsapp_messages", first: "2018-08-11T22:40:54.000Z", done: "2026-10-09T21:43:56.209Z")
    ])
    let history = try await CommunicationHistoryReader(client: fixture).read(summaries: summaryTable, imports: importTable, contacts: nil)
    let calls = try #require(history.sources.first { $0.source == "apple_calls" })
    #expect(calls.state == .complete)
    #expect(calls.completedAt == instant("2026-10-09T21:43:50.795Z"))
    #expect(calls.firstEvent == instant("2025-07-16T20:42:27.641Z"))
    #expect(history.sources.first { $0.source == "whatsapp_messages" }?.state == .partial)
    #expect(history.sources.first { $0.source == "apple_messages" } == nil)
    // Imports are equality reads per source, never an unbounded scan.
    #expect(await fixture.filters["talk_runs"]?.map { $0["store"] ?? "" } == CommunicationHistoryReader.sources)
}

@Test func unknownImportCoverageStateIsAnInvalidResponse() async throws {
    let fixture = HistoryFixture(summaries: [], imports: [importRow("a", "apple_calls", state: "mostly", done: "2026-10-09T21:43:50.795Z")])
    await #expect(throws: CircleConnectionError.self) {
        try await CommunicationHistoryReader(client: fixture).read(summaries: summaryTable, imports: importTable, contacts: nil)
    }
}

@Test func addressBookLinksAreReadByPlatformEqualityAndSkipTombstones() async throws {
    let fixture = HistoryFixture(summaries: [], imports: [], contacts: [
        ["id":"l1", "who":"p1", "kind":"apple_contacts", "native_id":"AAAA:ABPerson", "deleted_at":NSNull()],
        ["id":"l2", "who":"p1", "kind":"apple_contacts", "native_id":"BBBB:ABPerson", "deleted_at":"2026-01-01T00:00:00Z"],
        ["id":"l3", "who":"p2", "kind":"instagram", "native_id":"123", "deleted_at":NSNull()]
    ])
    let history = try await CommunicationHistoryReader(client: fixture).read(summaries: summaryTable, imports: importTable, contacts: contactTable)
    #expect(history.contactIDs == ["p1": ["AAAA:ABPerson"]])
    #expect(await fixture.filters["handles"] == [["kind": "apple_contacts"]])
}

@Test func historyBindingsAreOptionalButMustArriveTogether() throws {
    let base = CirclePeopleBindings(
        people: .init(table:"contacts", fields:["id":"id","name":"label","circles":"groups","deleted":"deleted_at"]),
        relations: .init(table:"links", fields:["id":"id","person":"subject","related":"object","kind":"kind","deleted":"deleted_at"]),
        locations: .init(table:"bases", fields:["id":"id","person":"person","city":"city","country":"country","start":"start","end":"end","deleted":"deleted_at"]))
    try base.validate()
    var full = base
    full.summaries = summaryTable; full.imports = importTable; full.contacts = contactTable
    try full.validate()
    #expect(full.scopes.count == base.scopes.count + 18 + 9 + 5)
    #expect(full.scopes.contains("tables:read:talk_summary:sent_at"))
    #expect(full.scopes.contains("tables:read:handles:native_id"))
    var lonely = base
    lonely.summaries = summaryTable
    #expect(throws: CircleConnectionError.self) { try lonely.validate() }
    var linksOnly = base
    linksOnly.contacts = contactTable
    #expect(throws: CircleConnectionError.self) { try linksOnly.validate() }
    var missingColumn = full
    missingColumn.imports = .init(table: "talk_runs", fields: importTable.fields.filter { $0.key != "reason" })
    #expect(throws: CircleConnectionError.self) { try missingColumn.validate() }
    let decoded = try JSONDecoder().decode(CirclePeopleBindings.self, from: JSONEncoder().encode(full))
    #expect(decoded.scopes == full.scopes)
}

@Test func cachedSnapshotKeepsHistoryAndOlderSnapshotsStillLoad() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = CircleGraphCache(directory: directory), profile = String(repeating: "c", count: 64)
    let graph = SocialGraph(people: [GraphPerson(id: "p1", name: "Person 1", circles: [])], relations: [], selfID: nil)
    var history = CommunicationHistory()
    history.channels["p1"] = [ChannelSummary(channel: .sms, lastSent: instant("2026-09-01T10:00:00Z"), refreshedAt: instant("2026-10-09T00:00:00Z"))]
    try cache.save(graph, history: history, refreshedAt: Date(), profile: profile)
    #expect(try cache.load(profile: profile)?.history == history)
    try cache.save(graph, refreshedAt: Date(), profile: profile)
    #expect(try cache.load(profile: profile)?.history == nil)
}
