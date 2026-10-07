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
    var requestedPaths: [String] = []
    var revocations = 0
    var firstRevocationUnauthorized = false
    func denyFirstRevocation() { firstRevocationUnauthorized = true }
    init(fingerprint: String, bindings: CirclePeopleBindings) { self.fingerprint = fingerprint; self.bindings = bindings }
    func failNextRows() { failRows = true }
    func request(path: String, method: String, body: Data?, maxBytes: Int) async throws -> CircleHTTPReply {
        requestedPaths.append(path)
        let revision = String(repeating: "b", count: 64)
        let profile = ["id":"circle-reader", "revision":revision]
        var value: [String: Any]
        switch path {
        case "/v1/session":
            if method == "POST" {
                revocations += 1
                if firstRevocationUnauthorized && revocations == 1 {
                    return CircleHTTPReply(status: 401, data: Data("{}".utf8))
                }
                value = ["logged_out":true]
            }
            else { value = ["name":"device:\(fingerprint)", "scopes":bindings.scopes, "enrollmentProfile":profile,
                           "capabilities":["row_api":"v1", "schema":"none", "replica_sync":false]] }
        case "/v1/consumer/config":
            value = ["profile":profile, "config":["version":1,"namespace":"circle.reader","bindings":try JSONSerialization.jsonObject(with: JSONEncoder().encode(bindings))]]
        case "/v1/rows/pull":
            if failRows { throw CircleConnectionError.unavailable }
            let table = try JSONSerialization.jsonObject(with: body!) as! [String:Any]
            value = ["rows":table["table"] as? String == "contacts" ? [["id":"p1","label":"Person 1","groups":NSNull(),"deleted_at":NSNull()]] : [], "next_cursor":NSNull()]
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
    await fixture.denyFirstRevocation()
    await model.disconnect()
    #expect(store.value != nil)
    await model.disconnect()
    #expect(store.value == nil)
    #expect(model.graph == nil)
    #expect(try cache.load(profile: profile) == nil)
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
    await paused.resume()
    await connecting.value
    #expect(await source.revocations == 2)
    #expect(store.value == nil)
    #expect(model.graph == nil)
    #expect(model.approvalURL == nil)
}
