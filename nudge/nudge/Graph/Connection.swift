import CryptoKit
import Foundation
import Observation
import Security

struct CircleDeviceCandidate {
    let token: String
    var fingerprint: String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func generate() throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CircleConnectionError.unavailable
        }
        return Self(token: "lt_" + bytes.map { String(format: "%02x", $0) }.joined())
    }
}

struct StoredCircleConnection: Codable, Sendable {
    let endpoint: String
    let token: String
    let profile: CircleReaderProfile
    let revision: String
    let bindings: CirclePeopleBindings
    var preferenceKey: String {
        SHA256.hash(data: Data((endpoint + "/" + profile.id).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor protocol CircleCredentialStore {
    func load() throws -> StoredCircleConnection?
    func save(_ value: StoredCircleConnection) throws
    func clear() throws
}

@Observable @MainActor final class CircleConnectionModel {
    private(set) var graph: SocialGraph?
    private(set) var connection: StoredCircleConnection?
    private(set) var approvalURL: URL?
    private(set) var approvalCode: String?
    private(set) var busy = false
    private(set) var failure: String?
    private(set) var cleanupMessage: String?
    private(set) var refreshedAt: Date?
    private(set) var cacheMessage: String?
    /// Contact history from the maintained summaries; nil until the profile grants it and a read succeeds.
    private(set) var history: CommunicationHistory?
    private(set) var historyFailure: String?
    private let cache: CircleGraphCache?
    private let store: any CircleCredentialStore
    private let candidate: () throws -> CircleDeviceCandidate
    private let client: (String, String) throws -> any CircleHTTPClient
    private var generation = 0
    private var pending: (id: Int, client: any CircleHTTPClient)?

    init(store: any CircleCredentialStore, cache: CircleGraphCache? = nil,
         candidate: @escaping () throws -> CircleDeviceCandidate = CircleDeviceCandidate.generate,
         client: @escaping (String, String) throws -> any CircleHTTPClient = { try CircleHTTPTransport(endpoint: $0, token: $1) }) {
        self.cache = cache; self.store = store; self.candidate = candidate; self.client = client
    }

    func restore() async {
        guard connection == nil, !busy else { return }
        do { connection = try store.load() }
        catch { failure = error.localizedDescription; return }
        if let connection {
            do {
                if let saved = try cache?.load(profile: connection.preferenceKey) {
                    graph = saved.graph; refreshedAt = saved.refreshedAt; history = saved.history
                }
            } catch { cacheMessage = "The saved graph could not be read. Refresh to recover it." }
            await refresh()
        }
    }

    func connect(endpoint: String) async {
        guard !busy, connection == nil else { return }
        generation += 1
        let id = generation
        busy = true; failure = nil; cleanupMessage = nil
        do {
            let endpoint = try CircleHTTPTransport.canonicalEndpoint(endpoint).absoluteString
            let candidate = try candidate(), policy = try CircleEnrollmentPolicy()
            let client = try client(endpoint, candidate.token)
            let approval = try policy.approval(fingerprint: candidate.fingerprint, profile: CircleReaderProfile.circleID)
            let deadline = ProcessInfo.processInfo.systemUptime + Double(approval.policy.timeoutSeconds)
            pending = (id, client)
            approvalURL = URL(string: endpoint + approval.path); approvalCode = approval.approvalCode
            while generation == id && ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                let reply = try await client.request(path: "/v1/session", method: "GET", body: nil, maxBytes: approval.policy.maxResponseBytes)
                guard generation == id, !Task.isCancelled else {
                    _ = await revoke(client)
                    return
                }
                try requireCurrent(id, deadline: deadline)
                if reply.status == 200 {
                    let stored = try await validatedConnection(endpoint: endpoint, token: candidate.token, reply: reply, client: client, policy: policy)
                    guard generation == id, !Task.isCancelled else {
                        _ = await revoke(client)
                        return
                    }
                    try requireCurrent(id, deadline: deadline)
                    try store.save(stored)
                    connection = stored
                    pending = nil; approvalURL = nil; approvalCode = nil; busy = false
                    await refresh()
                    return
                }
                guard [401, 403, 429, 503].contains(reply.status) else { throw CircleConnectionError.unavailable }
                try await Task.sleep(for: .seconds(approval.policy.pollIntervalSeconds))
            }
            throw CancellationError()
        } catch {
            guard generation == id else { return }
            busy = false; approvalURL = nil; approvalCode = nil
            failure = error is CancellationError ? "Approval expired or stopped. Start again for a new link." : error.localizedDescription
            if let pending { self.pending = nil; cleanupMessage = await revoke(pending.client).message }
        }
    }

    private func requireCurrent(_ id: Int, deadline: Double? = nil) throws {
        guard generation == id, !Task.isCancelled,
              deadline == nil || ProcessInfo.processInfo.systemUptime < deadline! else { throw CancellationError() }
    }

    private func validatedConnection(endpoint: String, token: String, reply: CircleHTTPReply,
                                     client: any CircleHTTPClient, policy: CircleEnrollmentPolicy) async throws -> StoredCircleConnection {
        let fingerprint = CircleDeviceCandidate(token: token).fingerprint
        let identity = try policy.inspectCandidate(data: reply.data, fingerprint: fingerprint)
        guard identity.enrollmentProfile.id == CircleReaderProfile.circleID else { throw CircleConnectionError.reconnectRequired }
        let configReply = try await client.request(path: "/v1/consumer/config", method: "GET", body: nil, maxBytes: 65536)
        guard configReply.status == 200,
              let envelope = try JSONSerialization.jsonObject(with: configReply.data) as? [String: Any],
              let receipt = envelope["profile"] as? [String: String],
              receipt["id"] == identity.enrollmentProfile.id, receipt["revision"] == identity.enrollmentProfile.revision,
              let rawConfig = envelope["config"] else { throw CircleConnectionError.invalidConfiguration }
        let canonical = try policy.canonicalConfig(JSONSerialization.data(withJSONObject: rawConfig))
        guard let config = try JSONSerialization.jsonObject(with: canonical) as? [String: Any],
              config["namespace"] as? String == "circle.reader", let fields = config["bindings"] as? [String: Any],
              Set(fields.keys).subtracting(["photos", "summaries", "imports", "contacts", "hangouts", "hangoutLog"]) == ["people", "relations", "locations"] else {
            throw CircleConnectionError.invalidConfiguration
        }
        let bindings = try JSONDecoder().decode(CirclePeopleBindings.self, from: JSONSerialization.data(withJSONObject: fields))
        try bindings.validate()
        let profile = CircleReaderProfile(id: CircleReaderProfile.circleID, scopes: bindings.scopes)
        _ = try policy.validateSession(data: reply.data, fingerprint: fingerprint, profile: profile)
        return StoredCircleConnection(endpoint: endpoint, token: token, profile: profile,
                                      revision: identity.enrollmentProfile.revision, bindings: bindings)
    }

    func refresh() async {
        guard let connection, !busy else { return }
        let id = generation
        busy = true; failure = nil
        do {
            let client = try client(connection.endpoint, connection.token)
            let policy = try CircleEnrollmentPolicy()
            let reply = try await client.request(path: "/v1/session", method: "GET", body: nil, maxBytes: 65536)
            guard reply.status == 200 else {
                throw [401, 403].contains(reply.status) ? CircleConnectionError.reconnectRequired : CircleConnectionError.unavailable
            }
            let validated = try await validatedConnection(endpoint: connection.endpoint, token: connection.token,
                                                           reply: reply, client: client, policy: policy)
            guard validated.revision == connection.revision else { throw CircleConnectionError.reconnectRequired }
            try requireCurrent(id)
            let newGraph = try await CirclePeopleReader(client: client).graph(bindings: validated.bindings, selfID: graph?.selfID)
            try requireCurrent(id)
            // History is read after People and published on its own: a failed read keeps the last history.
            var newHistory = history
            if let summaries = validated.bindings.summaries, let imports = validated.bindings.imports {
                do {
                    newHistory = try await CommunicationHistoryReader(client: client)
                        .read(summaries: summaries, imports: imports, contacts: validated.bindings.contacts,
                              hangouts: validated.bindings.hangouts)
                    historyFailure = nil
                } catch is CancellationError { throw CancellationError() }
                catch { historyFailure = "Contact history could not be refreshed. \(error.localizedDescription)" }
                try requireCurrent(id)
            } else {
                newHistory = nil
                historyFailure = nil
            }
            graph = newGraph; history = newHistory; refreshedAt = Date(); busy = false
            do {
                try cache?.save(newGraph, history: newHistory, refreshedAt: refreshedAt!, profile: connection.preferenceKey)
                cacheMessage = nil
            } catch { cacheMessage = "People loaded, but the offline copy could not be saved." }
        } catch {
            guard id == generation else { return }
            failure = error.localizedDescription; busy = false
        }
    }

    func selectSelf(_ personID: String?) throws {
        guard let graph, let connection, let refreshedAt,
              personID == nil || graph.byID[personID!] != nil else { throw CircleConnectionError.invalidConfiguration }
        let selected = SocialGraph(people: graph.people, relations: graph.relations, selfID: personID)
        try cache?.save(selected, history: history, refreshedAt: refreshedAt, profile: connection.preferenceKey)
        self.graph = selected
    }

    func cancel() async {
        generation += 1
        let id = generation, previous = pending
        pending = nil; approvalURL = nil; approvalCode = nil; busy = false
        if let previous {
            let result = await revoke(previous.client)
            if generation == id { cleanupMessage = result.message }
        }
    }

    func disconnect() async {
        await cancel()
        guard let connection else { return }
        let id = generation
        busy = true
        defer { if generation == id { busy = false } }
        do {
            let result = await revoke(try client(connection.endpoint, connection.token), approved: true)
            guard generation == id else { return }
            cleanupMessage = result.message
            guard result.confirmed else { return }
            try cache?.remove(profile: connection.preferenceKey)
            try store.clear()
            cacheMessage = nil
            self.connection = nil; graph = nil; history = nil; historyFailure = nil; refreshedAt = nil; failure = nil
        } catch { failure = error.localizedDescription }
    }

    /// A pending candidate's 401 proves nothing (it may still be approved later); an approved,
    /// stored credential the service answers 401 for is already dead and safe to forget here.
    private func revoke(_ client: any CircleHTTPClient, approved: Bool = false) async -> (confirmed: Bool, message: String) {
        await Task { @MainActor in
            do {
                let reply = try await client.request(path: "/v1/session", method: "POST", body: nil, maxBytes: 65536)
                switch try CircleEnrollmentPolicy().revocation(reply) {
                case "revoked": return (true, "Device credential revoked.")
                case "unauthorized" where approved: return (true, "The service had already revoked this device.")
                default: break
                }
            } catch {}
            return (false, "Revocation is not confirmed. Check the service’s devices and revoke this candidate if it was approved.")
        }.value
    }
}
