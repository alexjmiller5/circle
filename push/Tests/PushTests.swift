import CryptoKit
import Foundation
import Testing
@testable import CircleGraph
@testable import CirclePush

private let key = P256.Signing.PrivateKey()
private func credentials() throws -> APNsCredentials {
    try APNsCredentials(teamID: "TEAM123456", keyID: "KEY1234567", pem: key.pemRepresentation)
}
private func base64url(_ text: Substring) -> Data {
    var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while value.count % 4 != 0 { value += "=" }
    return Data(base64Encoded: value)!
}

@Test func providerTokenIsAnES256JWTSignedByTheKey() throws {
    let token = try credentials().token(at: Date(timeIntervalSince1970: 1_800_000_000))
    let parts = token.split(separator: ".")
    #expect(parts.count == 3)
    let header = try JSONSerialization.jsonObject(with: base64url(parts[0])) as! [String: Any]
    let claims = try JSONSerialization.jsonObject(with: base64url(parts[1])) as! [String: Any]
    #expect(header["alg"] as? String == "ES256" && header["kid"] as? String == "KEY1234567")
    #expect(claims["iss"] as? String == "TEAM123456" && claims["iat"] as? Int == 1_800_000_000)
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: base64url(parts[2]))
    #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
}

private actor Recorder: APNsTransport {
    var requests: [URLRequest] = []
    let reply: (Int, Data)
    init(_ status: Int, _ body: String = "") { reply = (status, Data(body.utf8)) }
    func send(_ request: URLRequest) async throws -> (Int, Data) { requests.append(request); return reply }
}

@Test func alertsGoToTheDeviceEnvironmentWithTopicAndToken() async throws {
    let recorder = Recorder(200)
    let sender = APNsSender(credentials: try credentials(), topic: "com.example.app", transport: recorder)
    let device = PushDevice(token: String(repeating: "ab", count: 32), environment: .production, registeredAt: Date())
    #expect(await sender.send(title: "Person 1 is nearby", body: "Find My showed City A", to: device, now: Date()) == .sent)
    let request = try #require(await recorder.requests.first)
    #expect(request.url?.absoluteString == "https://api.push.apple.com/3/device/" + device.token)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "apns-topic") == "com.example.app")
    #expect(request.value(forHTTPHeaderField: "apns-push-type") == "alert")
    #expect(request.value(forHTTPHeaderField: "authorization")?.hasPrefix("bearer ") == true)
    let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    let alert = (payload["aps"] as! [String: Any])["alert"] as! [String: String]
    #expect(alert == ["title": "Person 1 is nearby", "body": "Find My showed City A"])
    let sandbox = PushDevice(token: device.token, environment: .development, registeredAt: Date())
    _ = await sender.send(title: "t", body: "b", to: sandbox, now: Date())
    #expect(await recorder.requests.last?.url?.host == "api.sandbox.push.apple.com")
    // One provider token serves many sends.
    let tokens = Set(await recorder.requests.map { $0.value(forHTTPHeaderField: "authorization") })
    #expect(tokens.count == 1)
}

@Test func deadTokensAreReportedSoTheyCanBeDropped() async throws {
    let device = PushDevice(token: String(repeating: "cd", count: 32), environment: .production, registeredAt: Date())
    for (status, body, expected) in [(410, #"{"reason":"Unregistered"}"#, APNsResult.unregistered),
                                     (400, #"{"reason":"BadDeviceToken"}"#, .unregistered),
                                     (400, #"{"reason":"BadTopic"}"#, .failed("BadTopic")),
                                     (429, #"{"reason":"TooManyRequests"}"#, .failed("TooManyRequests"))] {
        let sender = APNsSender(credentials: try credentials(), topic: "com.example.app", transport: Recorder(status, body))
        #expect(await sender.send(title: "t", body: "b", to: device, now: Date()) == expected)
    }
}

@Test func registryKeepsOneEntryPerTokenInAPrivateFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = DeviceRegistry(file: directory.appendingPathComponent("devices.json"))
    let token = String(repeating: "ef", count: 32)
    try registry.upsert(PushDevice(token: token, environment: .development, registeredAt: Date(timeIntervalSince1970: 1)))
    try registry.upsert(PushDevice(token: token, environment: .production, registeredAt: Date(timeIntervalSince1970: 2)))
    #expect(registry.load().map(\.environment) == [.production])
    let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("devices.json").path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    try registry.remove(token: token)
    #expect(registry.load().isEmpty)
}

@Test func registrationAcceptsOnlyTheAllowedTailnetUser() {
    let token = String(repeating: "0a", count: 32)
    func request(_ method: String = "POST", path: String = "/devices", login: String? = "owner@example.com",
                 body: String? = nil) -> Data {
        let content = body ?? #"{"token":"\#(token)","environment":"production"}"#
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(content.utf8.count)\r\n"
        if let login { head += "Tailscale-User-Login: \(login)\r\n" }
        return Data((head + "\r\n" + content).utf8)
    }
    let allowed: Set<String> = ["owner@example.com"]
    let ok = DeviceRegistration.handle(request(), allowedLogins: allowed)
    #expect(ok.status == 204 && ok.device?.token == token && ok.device?.environment == .production)
    #expect(DeviceRegistration.handle(request(login: nil), allowedLogins: allowed).status == 403)
    #expect(DeviceRegistration.handle(request(login: "someone@example.com"), allowedLogins: allowed).status == 403)
    #expect(DeviceRegistration.handle(request(body: #"{"token":"nothex","environment":"production"}"#), allowedLogins: allowed).status == 400)
    #expect(DeviceRegistration.handle(request(body: #"{"token":"\#(token)","environment":"staging"}"#), allowedLogins: allowed).status == 400)
    #expect(DeviceRegistration.handle(request(body: #"{"token":"\#(token)","environment":"production","name":"x"}"#), allowedLogins: allowed).status == 400)
    #expect(DeviceRegistration.handle(request("GET"), allowedLogins: allowed).status == 405)
    #expect(DeviceRegistration.handle(request(path: "/other"), allowedLogins: allowed).status == 404)
    #expect(DeviceRegistration.handle(Data("garbage".utf8), allowedLogins: allowed).status == 400)
    // An incomplete request (headers or body still arriving) asks for more bytes.
    #expect(DeviceRegistration.handle(request().prefix(40), allowedLogins: allowed).status == 0)
}

/// Synthetic hub: a friend check stream in pages, a location tail and a names table.
private actor Hub: CircleHTTPClient {
    var pages: [String?: (entries: [String], next: String?)] = [:]
    var location: String = "null"
    var reads: [String] = []
    func request(path: String, method: String, body: Data?, maxBytes: Int) async throws -> CircleHTTPReply {
        reads.append(path)
        if path.hasPrefix("/v1/streams/checks/records") {
            let cursor = URLComponents(string: path)?.queryItems?.first { $0.name == "cursor" }?.value
            let page = pages[cursor] ?? ([], nil)
            let entries = page.entries.enumerated().map { ["id": String(repeating: "\($0.offset % 10)", count: 64), "body": $0.element] }
            return CircleHTTPReply(status: 200, data: try JSONSerialization.data(withJSONObject: [
                "entries": entries, "next_cursor": page.next as Any? ?? NSNull()]))
        }
        if path == "/v1/streams/fixes/tail" { return CircleHTTPReply(status: 200, data: Data(location.utf8)) }
        if path == "/v1/rows/pull" {
            let request = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
            let table = request["table"] as! String, columns = request["columns"] as! [String]
            let all: [[String: Any]] = switch table {
            case "contacts": [["id": "p1", "label": "Person 1", "every": "monthly", "deleted_at": NSNull()]]
            case "bases": [["id": "b1", "who": "p1", "city": "City A, State A", "country": NSNull(), "until": NSNull(), "deleted_at": NSNull()]]
            default: [["id": "h1", "day": "2026-08-01", "who": "[\"p1\"]", "deleted_at": NSNull()]]
            }
            let rows = all.map { row in row.filter { columns.contains($0.key) } }
            return CircleHTTPReply(status: 200, data: try JSONSerialization.data(withJSONObject: ["rows": rows, "next_cursor": NSNull()]))
        }
        return CircleHTTPReply(status: 404, data: Data())
    }
    func set(page cursor: String?, entries: [String], next: String?) { pages[cursor] = (entries, next) }
    func set(location: String) { self.location = location }
}

private func check(_ id: String, at: Double, city: String = "City A") -> String {
    #"{"age_seconds":60,"age_text":"1 min. ago","checked_at":\#(at),"city":"\#(city)","country":null,"location_text":"\#(city), AA","paused":false,"person_id":"p1","region":"AA","run_complete":true,"run_rows":1,"run_unresolved":0,"source":"findmy_ax","source_check_id":"\#(id)"}"#
}

@Test func evaluatorAlertsOnceFromStreamPagesAndResumesFromTheLastPage() async throws {
    let hub = Hub()
    let t0 = 1_800_000_000.0
    await hub.set(page: nil, entries: [check("a1", at: t0)], next: "Y3Vyc29yMQ==")
    await hub.set(page: "Y3Vyc29yMQ==", entries: [], next: nil)
    await hub.set(location: #"{"_type":"location","lat":40.7,"lon":-74.0,"tst":1800000000}"#)
    let evaluator = NearbyEvaluator(hub: hub, checksStream: "checks", locationStream: "fixes",
                                    bindings: PushBindings(people: CircleProjectionTable(table: "contacts", fields: ["id": "id", "name": "label", "deleted": "deleted_at"])),
                                    geocode: { lat, lon in
                                        #expect(lat == 40.7 && lon == -74.0)
                                        return CurrentPlace(city: "City A", district: nil, region: "AA", country: "Country", countryCode: "CC")
                                    })
    var state = PushState()
    #expect(try await evaluator.step(&state, now: Date(timeIntervalSince1970: t0 + 30)).alerts.isEmpty)
    #expect(state.cursor == "Y3Vyc29yMQ==")
    // The next run re-reads the last page, which now holds a second check six minutes later.
    await hub.set(page: "Y3Vyc29yMQ==", entries: [check("a2", at: t0 + 360)], next: nil)
    let alerts = try await evaluator.step(&state, now: Date(timeIntervalSince1970: t0 + 390)).alerts
    #expect(alerts.map(\.name) == ["Person 1"])
    #expect(alerts.first?.alert.locationText == "City A, AA")
    // Re-reading the same page never repeats the alert, and state survives a restart.
    let restored = try JSONDecoder().decode(PushState.self, from: JSONEncoder().encode(state))
    state = restored
    #expect(try await evaluator.step(&state, now: Date(timeIntervalSince1970: t0 + 420)).alerts.isEmpty)
    // Without a location there is no place, so nothing is claimed nearby.
    await hub.set(location: "null")
    var fresh = PushState()
    _ = try await evaluator.step(&fresh, now: Date(timeIntervalSince1970: t0 + 30))
    #expect(try await evaluator.step(&fresh, now: Date(timeIntervalSince1970: t0 + 390)).alerts.isEmpty)
}

/// The machine's own tailnet owner may register without naming them in config.
@Test func tailnetOwnerComesFromThisMachinesStatus() {
    let status = Data(#"{"Self":{"UserID":42,"HostName":"mini"},"User":{"42":{"ID":42,"LoginName":"owner@example.com"},"7":{"ID":7,"LoginName":"tagged-devices"}}}"#.utf8)
    #expect(TailnetOwner.login(status: status) == "owner@example.com")
    #expect(TailnetOwner.login(status: Data(#"{"Self":{"UserID":9},"User":{}}"#.utf8)) == nil)
    #expect(TailnetOwner.login(status: Data("not json".utf8)) == nil)
    // A tagged machine belongs to the tailnet, not a user: its one human user owns it.
    let tagged = Data(#"{"Self":{"UserID":5,"Tags":["tag:server"]},"User":{"5":{"ID":5,"LoginName":"mini.example.ts.net"},"42":{"ID":42,"LoginName":"owner@example.com"}}}"#.utf8)
    #expect(TailnetOwner.login(status: tagged) == "owner@example.com")
    let shared = Data(#"{"Self":{"UserID":5,"Tags":["tag:server"]},"User":{"5":{"ID":5,"LoginName":"mini.example.ts.net"},"42":{"ID":42,"LoginName":"owner@example.com"},"43":{"ID":43,"LoginName":"other@example.com"}}}"#.utf8)
    #expect(TailnetOwner.login(status: shared) == nil)
}

@Test func evaluatorNudgesDueHangoutsInYourCityAtMostEveryHalfHourAndOncePerPeriod() async throws {
    let hub = Hub()
    await hub.set(location: #"{"lat":40.7,"lon":-74.0}"#)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let bindings = PushBindings(
        people: CircleProjectionTable(table: "contacts", fields: ["id": "id", "name": "label", "hangoutCadence": "every", "deleted": "deleted_at"]),
        locations: CircleProjectionTable(table: "bases", fields: ["id": "id", "person": "who", "city": "city", "country": "country", "end": "until", "deleted": "deleted_at"]),
        hangouts: CircleProjectionTable(table: "meetups", fields: ["id": "id", "date": "day", "people": "who", "deleted": "deleted_at"]))
    try bindings.validate()
    #expect(bindings.scopes.contains("tables:read:contacts:every") && bindings.scopes.contains("tables:read:meetups:day"))
    let evaluator = NearbyEvaluator(hub: hub, checksStream: "checks", locationStream: "fixes", bindings: bindings,
                                    geocode: { _, _ in CurrentPlace(city: "City A", district: nil, region: "AA", country: nil, countryCode: nil) },
                                    calendar: calendar)
    let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!
    var state = PushState()
    let first = try await evaluator.step(&state, now: noon)
    #expect(first.nudges.map(\.personID) == ["p1"] && first.nudges.first?.lastDay == "2026-08-01")
    // Within the half hour nothing is re-read; within the cadence nobody is nudged twice.
    #expect(try await evaluator.step(&state, now: noon.addingTimeInterval(600)).nudges.isEmpty)
    #expect(try await evaluator.step(&state, now: noon.addingTimeInterval(3_600)).nudges.isEmpty)
    let restored = try JSONDecoder().decode(PushState.self, from: JSONEncoder().encode(state))
    #expect(restored.hangoutReminded["p1"] == noon)
}
