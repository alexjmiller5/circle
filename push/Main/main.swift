import CircleGraph
import CirclePush
import CoreLocation
import Foundation
import Network

let usage = """
circle-push - Circle's nearby-alert push service.

    circle-push run      evaluate every --interval seconds, push confirmed arrivals,
                         and accept device registrations on 127.0.0.1:--listen-port
    circle-push test     push one clearly labeled test notification to every registered device

Required: --hub URL --hub-token-cmd CMD --apns-key-cmd CMD --team-id ID --key-id ID --topic BUNDLE_ID
          --checks-stream NAME --location-stream NAME --people-table TABLE --people-name-column COLUMN
Optional: --state-dir DIR (default ~/Library/Application Support/circle-push) --listen-port N (default 8787)
          --allowed-login LOGIN (repeatable; tailnet users who may register a phone) --interval SECONDS (default 120)
          --hide-names (lock-screen privacy: no names or places in alerts)
          --allow-tailnet-owner (also accept this machine's tailnet owner; --tailscale PATH, default tailscale)
Secrets arrive only through the commands' stdout (the APNs key as its .p8 text or base64 of it).
"""

func parseArguments() -> (mode: String, options: [String: [String]], flags: Set<String>) {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let mode = arguments.first, ["run", "test"].contains(mode) else { print(usage); exit(64) }
    arguments.removeFirst()
    var options: [String: [String]] = [:], flags = Set<String>()
    while let name = arguments.first {
        arguments.removeFirst()
        guard name.hasPrefix("--") else { print(usage); exit(64) }
        if ["--hide-names", "--allow-tailnet-owner"].contains(name) { flags.insert(name); continue }
        guard let value = arguments.first else { print(usage); exit(64) }
        arguments.removeFirst()
        options[name, default: []].append(value)
    }
    return (mode, options, flags)
}
let (mode, options, flags) = parseArguments()
func option(_ name: String) -> String {
    guard let value = options[name]?.last else { FileHandle.standardError.write(Data("missing \(name)\n\(usage)\n".utf8)); exit(64) }
    return value
}
/// Runs a secret command; its output never reaches the log.
func secret(_ command: String) -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardOutput = pipe
    do { try process.run() } catch { FileHandle.standardError.write(Data("secret command failed\n".utf8)); exit(65) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, !value.isEmpty else { FileHandle.standardError.write(Data("secret command failed\n".utf8)); exit(65) }
    return value
}
func log(_ fields: [String: Any]) {
    var line = fields
    line["at"] = ISO8601DateFormatter().string(from: Date())
    if let data = try? JSONSerialization.data(withJSONObject: line, options: .sortedKeys) {
        print(String(decoding: data, as: UTF8.self)); fflush(stdout)
    }
}

let stateDirectory = options["--state-dir"]?.last.map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/circle-push")
let registry = DeviceRegistry(file: stateDirectory.appendingPathComponent("devices.json"))
let keyText = secret(option("--apns-key-cmd"))
let pem = keyText.contains("BEGIN PRIVATE KEY") ? keyText : String(decoding: Data(base64Encoded: keyText) ?? Data(), as: UTF8.self)
let credentials: APNsCredentials
do { credentials = try APNsCredentials(teamID: option("--team-id"), keyID: option("--key-id"), pem: pem) }
catch { FileHandle.standardError.write(Data("the APNs key is not a P-256 .p8 key\n".utf8)); exit(65) }
let sender = APNsSender(credentials: credentials, topic: option("--topic"))
let settings: ReminderSettings = {
    var settings = ReminderSettings()
    settings.hideNames = flags.contains("--hide-names")
    return settings
}()

/// Pushes to every registered phone and forgets tokens APNs says are gone.
func push(title: String, body: String) async -> [String: Int] {
    var results: [String: Int] = [:]
    for device in registry.load() {
        let result = await sender.send(title: title, body: body, to: device, now: Date())
        switch result {
        case .sent: results["sent", default: 0] += 1
        case .unregistered: results["unregistered", default: 0] += 1; try? registry.remove(token: device.token)
        case .failed(let reason): results["failed:" + reason, default: 0] += 1
        }
    }
    return results
}

if mode == "test" {
    let results = await push(title: "Circle test", body: "Nearby alerts can reach this phone. This is a test, not a friend nearby.")
    log(["test": results, "devices": registry.load().count])
    exit(results["sent", default: 0] > 0 ? 0 : 1)
}

// Registrations from the phone arrive through `tailscale serve` on this loopback port.
/// This machine's tailnet owner, read once at startup.
func tailnetOwner() -> String? {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [options["--tailscale"]?.last ?? "tailscale", "status", "--json"]
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? TailnetOwner.login(status: data) : nil
}
let owner = flags.contains("--allow-tailnet-owner") ? tailnetOwner() : nil
if flags.contains("--allow-tailnet-owner") && owner == nil { log(["warning": "tailnet owner unknown; only --allowed-login users may register"]) }
let allowedLogins = Set((options["--allowed-login"] ?? []) + [owner].compactMap { $0 })
let port = NWEndpoint.Port(rawValue: UInt16(options["--listen-port"]?.last ?? "8787") ?? 8787)!
let parameters = NWParameters.tcp
parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
let listener: NWListener
do { listener = try NWListener(using: parameters) } catch { FileHandle.standardError.write(Data("cannot listen on \(port)\n".utf8)); exit(70) }
let reasons = [204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large"]
@Sendable func serve(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
        let received = buffer + (data ?? Data())
        var (status, device) = DeviceRegistration.handle(received, allowedLogins: allowedLogins)
        if status == 0 && (complete || error != nil) { status = 400 }
        if status == 0 { serve(connection, buffer: received); return }
        if let device {
            do { try registry.upsert(device); log(["registered": device.environment.rawValue]) } catch { status = 400 }
        }
        let response = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
listener.newConnectionHandler = { connection in
    connection.start(queue: .global())
    serve(connection, buffer: Data())
}
listener.start(queue: .global())

/// Apple's geocoder names places the way Find My does; one lookup per ~100 m of movement.
actor Geocoder {
    private var cache: (key: String, place: CurrentPlace?)?
    func place(_ lat: Double, _ lon: Double) async -> CurrentPlace? {
        let key = String(format: "%.3f,%.3f", lat, lon)
        if let cache, cache.key == key { return cache.place }
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)).first else { return nil }
        let place = CurrentPlace(city: mark.locality, district: mark.subLocality, region: mark.administrativeArea,
                                 country: mark.country, countryCode: mark.isoCountryCode)
        cache = (key, place)
        return place
    }
}
let geocoder = Geocoder()
let hub: CircleHTTPTransport
do { hub = try CircleHTTPTransport(endpoint: option("--hub"), token: secret(option("--hub-token-cmd"))) }
catch { FileHandle.standardError.write(Data("invalid hub URL or token\n".utf8)); exit(65) }
let evaluator = NearbyEvaluator(hub: hub, checksStream: option("--checks-stream"), locationStream: option("--location-stream"),
                                people: CircleProjectionTable(table: option("--people-table"),
                                                              fields: ["id": "id", "name": option("--people-name-column"), "deleted": "deleted_at"]),
                                geocode: { await geocoder.place($0, $1) })
let stateFile = stateDirectory.appendingPathComponent("state.json")
let interval = Double(options["--interval"]?.last ?? "120") ?? 120

func evaluateForever() async -> Never {
    var state = (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(PushState.self, from: $0) } ?? PushState()
    while true {
        do {
            let alerts = try await evaluator.step(&state, now: Date())
            var results: [String: Int] = [:]
            for (alert, name) in alerts {
                let text = NearbyAlerts.notification(alert, name: name, settings: settings)
                results.merge(await push(title: text.title, body: text.body), uniquingKeysWith: +)
            }
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
            log(["alerts": alerts.count, "push": results, "devices": registry.load().count])
        } catch {
            log(["error": "\(error)"])
        }
        try? await Task.sleep(for: .seconds(interval))
    }
}
await evaluateForever()
