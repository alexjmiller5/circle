import Foundation
import Testing
@testable import CircleGraph

@MainActor private final class MemoryCredentialStore: CircleCredentialStore {
    var value: StoredCircleConnection?
    func load() throws -> StoredCircleConnection? { value }
    func save(_ value: StoredCircleConnection) throws { self.value = value }
    func clear() throws { value = nil }
}

private actor ConnectionFixture: CircleHTTPClient {
    let fingerprint: String
    let bindings: CirclePeopleBindings
    var failRows = false
    var failHistory = false
    func failHistoryReads() { failHistory = true }
    var requestedPaths: [String] = []
    var revocations = 0
    /// Statuses for the next revocations, in order; then revocations succeed.
    var revocationStatuses: [Int] = []
    func denyFirstRevocation() { revocationStatuses = [401] }
    func answerRevocations(_ statuses: [Int]) { revocationStatuses = statuses }
    init(fingerprint: String, bindings: CirclePeopleBindings) { self.fingerprint = fingerprint; self.bindings = bindings }
    func failNextRows() { failRows = true }
    var profileID = CircleReaderProfile.circleID
    var revision = String(repeating: "b", count: 64)
    func approve(profile id: String, revision: String) { profileID = id; self.revision = revision }
    var sessionStatus = 200
    func answerSession(_ status: Int) { sessionStatus = status }
    func request(path: String, method: String, body: Data?, maxBytes: Int) async throws -> CircleHTTPReply {
        requestedPaths.append(path)
        let profile = ["id":profileID, "revision":revision]
        var value: [String: Any]
        switch path {
        case "/v1/session":
            if method == "POST" {
                revocations += 1
                if !revocationStatuses.isEmpty {
                    return CircleHTTPReply(status: revocationStatuses.removeFirst(), data: Data("{}".utf8))
                }
                value = ["logged_out":true]
            }
            else if sessionStatus != 200 { return CircleHTTPReply(status: sessionStatus, data: Data("{}".utf8)) }
            else { value = ["name":"device:\(fingerprint)", "scopes":bindings.scopes, "enrollmentProfile":profile,
                           "capabilities":["row_api":"v1", "schema":"none", "replica_sync":false]] }
        case "/v1/consumer/config":
            value = ["profile":profile, "config":["version":1,"namespace":"circle.reader","bindings":try JSONSerialization.jsonObject(with: JSONEncoder().encode(bindings))]]
        case "/v1/rows/pull":
            if failRows { throw CircleConnectionError.unavailable }
            let table = try JSONSerialization.jsonObject(with: body!) as! [String:Any]
            if failHistory && table["table"] as? String == "talk_summary" { return CircleHTTPReply(status: 503, data: Data("{}".utf8)) }
            value = ["rows":table["table"] as? String == "talk_summary" ? [[
                "id":"p1:sms", "who":"p1", "via":"sms", "sent_at":"2026-09-01T10:00:00.000Z", "got_at":NSNull(), "answered_at":NSNull(),
                "answered_secs":NSNull(), "call_at":NSNull(), "sent_n":1, "got_n":0, "answered_n":0, "missed_n":0, "from_at":NSNull(),
                "to_at":NSNull(), "refreshed_at":"2026-10-09T00:00:00.000Z", "review":NSNull(), "updated_at":"2026-10-09T00:00:00.000Z",
                "deleted_at":NSNull()]] : table["table"] as? String == "contacts" ? [["id":"p1","label":"Person 1","groups":NSNull(),"deleted_at":NSNull()]] : [], "next_cursor":NSNull()]
        default: throw CircleConnectionError.invalidResponse
        }
        return CircleHTTPReply(status: 200, data: try JSONSerialization.data(withJSONObject: value))
    }
}

@Test @MainActor func connectionStoresOnlyValidatedProfileAndRefreshFailurePreservesGraph() async throws {
    let bindings = CirclePeopleBindings(
        people: .init(table:"contacts", fields:["id":"id","name":"label","circles":"groups","deleted":"deleted_at"]),
        relations: .init(table:"links", fields:["id":"id","person":"subject","related":"object","kind":"kind","deleted":"deleted_at"]),
        locations: .init(table:"bases", fields:["id":"id","person":"person","city":"city","country":"country","start":"start","end":"end","deleted":"deleted_at"]))
    let candidate = CircleDeviceCandidate(token: "fixture-candidate")
    let fixture = ConnectionFixture(fingerprint: candidate.fingerprint, bindings: bindings)
    let store = MemoryCredentialStore()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = CircleGraphCache(directory: directory)
    let model = CircleConnectionModel(store: store, cache: cache, candidate: { candidate }, client: { _,_ in fixture })
    await model.connect(endpoint: "https://example.invalid")
    #expect(model.graph?.byID["p1"]?.name == "Person 1")
    #expect(store.value?.profile.scopes == bindings.scopes)
    #expect(model.approvalURL == nil)
    try model.selectSelf("p1")
    #expect(model.graph?.selfID == "p1")
    #expect(throws: (any Error).self) { try model.selectSelf("missing") }
    #expect(model.graph?.selfID == "p1")
    let profile = try #require(store.value?.preferenceKey)
    #expect(try cache.load(profile: profile)?.graph.byID["p1"]?.name == "Person 1")
    await fixture.failNextRows()
    let restored = CircleConnectionModel(store: store, cache: cache, client: { _,_ in fixture })
    await restored.restore()
    #expect(restored.graph?.byID["p1"]?.name == "Person 1")
    #expect(restored.failure != nil)
    #expect(restored.graph?.selfID == "p1")
    await model.refresh()
    #expect(model.graph?.byID["p1"]?.name == "Person 1")
    #expect(model.failure != nil)
    // An outage is no proof of revocation: the connection stays until the service confirms.
    await fixture.answerRevocations([503])
    await model.disconnect()
    #expect(store.value != nil)
    await model.disconnect()
    #expect(store.value == nil)
    #expect(model.graph == nil)
    #expect(try cache.load(profile: profile) == nil)
}

/// A Circle update can need wider access than the saved device credential was approved for.
@Test @MainActor func aConnectionApprovedForAnOlderProfileAsksToReconnectAndKeepsPeople() async throws {
    let bindings = CirclePeopleBindings(
        people: .init(table:"contacts", fields:["id":"id","name":"label","circles":"groups","deleted":"deleted_at"]),
        relations: .init(table:"links", fields:["id":"id","person":"subject","related":"object","kind":"kind","deleted":"deleted_at"]),
        locations: .init(table:"bases", fields:["id":"id","person":"person","city":"city","country":"country","start":"start","end":"end","deleted":"deleted_at"]))
    let candidate = CircleDeviceCandidate(token: "fixture-candidate")
    let fixture = ConnectionFixture(fingerprint: candidate.fingerprint, bindings: bindings)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MemoryCredentialStore()
    let model = CircleConnectionModel(store: store, cache: CircleGraphCache(directory: directory),
                                      candidate: { candidate }, client: { _,_ in fixture })
    await model.connect(endpoint: "https://example.invalid")
    #expect(model.failure == nil && model.graph?.byID["p1"] != nil)
    for (id, revision) in [("circle-older-v0", String(repeating: "b", count: 64)), (CircleReaderProfile.circleID, String(repeating: "c", count: 64))] {
        await fixture.approve(profile: id, revision: revision)
        await model.refresh()
        #expect(model.failure == CircleConnectionError.reconnectRequired.localizedDescription)
        #expect(model.graph?.byID["p1"]?.name == "Person 1")
    }
    // A revoked credential needs the same new approval; an outage only needs a later retry.
    for (status, error) in [(401, CircleConnectionError.reconnectRequired), (403, .reconnectRequired), (503, .unavailable), (429, .unavailable)] {
        await fixture.answerSession(status)
        await model.refresh()
        #expect(model.failure == error.localizedDescription)
    }
    // An approved credential the service no longer accepts is already dead: forget it here
    // instead of trapping the user (a pending candidate's 401 still proves nothing).
    await fixture.answerRevocations([401])
    await model.disconnect()
    #expect(store.value == nil && model.connection == nil)
    #expect(model.cleanupMessage == "The service had already revoked this device.")
}

private actor PausedSession: CircleHTTPClient {
    let base: ConnectionFixture
    private var started = false
    private var observer: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    init(_ base: ConnectionFixture) { self.base = base }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() { release?.resume(); release = nil }
    func request(path: String, method: String, body: Data?, maxBytes: Int) async throws -> CircleHTTPReply {
        if path == "/v1/session" && method == "GET" && !started {
            await withCheckedContinuation { continuation in
                release = continuation; started = true; observer?.resume(); observer = nil
            }
        }
        return try await base.request(path: path, method: method, body: body, maxBytes: maxBytes)
    }
}

@Test @MainActor func cancelledEnrollmentCannotInstallALateApprovedReply() async throws {
    let bindings = CirclePeopleBindings(
        people: .init(table:"contacts", fields:["id":"id","name":"label","circles":"groups","deleted":"deleted_at"]),
        relations: .init(table:"links", fields:["id":"id","person":"subject","related":"object","kind":"kind","deleted":"deleted_at"]),
        locations: .init(table:"bases", fields:["id":"id","person":"person","city":"city","country":"country","start":"start","end":"end","deleted":"deleted_at"]))
    let candidate = CircleDeviceCandidate(token: "fixture-candidate")
    let source = ConnectionFixture(fingerprint: candidate.fingerprint, bindings: bindings)
    await source.denyFirstRevocation()
    let paused = PausedSession(source)
    let store = MemoryCredentialStore()
    let model = CircleConnectionModel(store: store, candidate: { candidate }, client: { _,_ in paused })
    let connecting = Task { await model.connect(endpoint: "https://example.invalid") }
    await paused.waitUntilStarted()
    await model.cancel()
    // A pending candidate's 401 is no proof: it might still be approved later.
    #expect(model.cleanupMessage?.hasPrefix("Revocation is not confirmed") == true)
    await paused.resume()
    await connecting.value
    #expect(await source.revocations == 2)
    #expect(store.value == nil)
    #expect(model.graph == nil)
    #expect(model.approvalURL == nil)
}

@Test @MainActor func photoProfileWithFileGrantEnrollsAndStoresItsPrefixes() async throws {
    let base = CirclePeopleBindings(
        people: .init(table:"contacts", fields:["id":"id","name":"label","circles":"groups","deleted":"deleted_at"]),
        relations: .init(table:"links", fields:["id":"id","person":"subject","related":"object","kind":"kind","deleted":"deleted_at"]),
        locations: .init(table:"bases", fields:["id":"id","person":"person","city":"city","country":"country","start":"start","end":"end","deleted":"deleted_at"]))
    let bindings = CirclePeopleBindings(people: base.people, relations: base.relations, locations: base.locations,
        photos: .init(table: "pictures", fields: ["id":"id","person":"person","platform":"source","key":"object_key","sha256":"digest",
                                                  "fetched":"fetched_at","updated":"updated_at","deleted":"deleted_at"],
                      files: ["pictures/people/"]))
    let candidate = CircleDeviceCandidate(token: "fixture-candidate")
    let fixture = ConnectionFixture(fingerprint: candidate.fingerprint, bindings: bindings)
    let store = MemoryCredentialStore()
    let model = CircleConnectionModel(store: store, candidate: { candidate }, client: { _,_ in fixture })
    await model.connect(endpoint: "https://example.invalid")
    #expect(model.failure == nil)
    #expect(store.value?.profile.scopes.contains("files:read:pictures/people/") == true)
    #expect(store.value?.bindings.photos?.files == ["pictures/people/"])
    #expect(model.graph?.byID["p1"]?.photoChoices.isEmpty == true)
    #expect(await fixture.requestedPaths.filter { $0 == "/v1/rows/pull" }.count == 4)
}

@Test @MainActor func historyProfileReadsSummariesAndAFailedHistoryReadKeepsTheLastOne() async throws {
    var bindings = CirclePeopleBindings(
        people: .init(table:"contacts", fields:["id":"id","name":"label","circles":"groups","deleted":"deleted_at"]),
        relations: .init(table:"links", fields:["id":"id","person":"subject","related":"object","kind":"kind","deleted":"deleted_at"]),
        locations: .init(table:"bases", fields:["id":"id","person":"person","city":"city","country":"country","start":"start","end":"end","deleted":"deleted_at"]))
    bindings.summaries = summaryTable; bindings.imports = importTable; bindings.contacts = contactTable
    let candidate = CircleDeviceCandidate(token: "fixture-candidate")
    let fixture = ConnectionFixture(fingerprint: candidate.fingerprint, bindings: bindings)
    let store = MemoryCredentialStore()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = CircleGraphCache(directory: directory)
    let model = CircleConnectionModel(store: store, cache: cache, candidate: { candidate }, client: { _,_ in fixture })
    await model.connect(endpoint: "https://example.invalid")
    #expect(model.failure == nil)
    #expect(store.value?.profile.scopes.contains("tables:read:talk_runs:why") == true)
    let first = try #require(model.history)
    #expect(first.channels["p1"]?.first?.sent == 1)
    #expect(try cache.load(profile: try #require(store.value?.preferenceKey))?.history == first)
    await fixture.failHistoryReads()
    await model.refresh()
    #expect(model.failure == nil)
    #expect(model.graph?.byID["p1"] != nil)
    #expect(model.history == first)
    #expect(model.historyFailure != nil)
}
