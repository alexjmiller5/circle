import Foundation

public struct PushDevice: Codable, Equatable, Sendable {
    public let token: String
    public let environment: APNsEnvironment
    public var registeredAt: Date

    public init(token: String, environment: APNsEnvironment, registeredAt: Date) {
        self.token = token; self.environment = environment; self.registeredAt = registeredAt
    }

    /// APNs device tokens are hex; anything else is refused before it is stored.
    static func validToken(_ value: String) -> Bool {
        (32...200).contains(value.count) && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// The phones to notify, one entry per token, in a private file the service owns.
public struct DeviceRegistry: Sendable {
    public let file: URL
    public init(file: URL) { self.file = file }

    public func load() -> [PushDevice] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([PushDevice].self, from: $0) } ?? []
    }

    public func upsert(_ device: PushDevice) throws {
        try save(load().filter { $0.token != device.token } + [device])
    }

    public func remove(token: String) throws {
        try save(load().filter { $0.token != token })
    }

    private func save(_ devices: [PushDevice]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(devices).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// `POST /devices {"token","environment"}` from the iPhone app, reached through `tailscale serve`,
/// which adds `Tailscale-User-Login` for the tailnet user who sent it.
public enum DeviceRegistration {
    static let maxBytes = 16_384

    /// Status 0 means the request is incomplete: read more bytes and call again.
    public static func handle(_ raw: Data, allowedLogins: Set<String>) -> (status: Int, device: PushDevice?) {
        guard raw.count <= maxBytes else { return (413, nil) }
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else {
            // Still arriving, unless what arrived cannot start an HTTP request line.
            let start = String(decoding: raw.prefix(8), as: UTF8.self)
            return start.range(of: #"^[A-Z]{1,7}( |$)"#, options: .regularExpression) != nil ? (0, nil) : (400, nil)
        }
        let lines = String(decoding: raw[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return (400, nil) }
        guard parts[1] == "/devices" else { return (404, nil) }
        guard parts[0] == "POST" else { return (405, nil) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return (400, nil) }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let length = headers["content-length"].flatMap(Int.init), length >= 0 else { return (400, nil) }
        let body = raw[split.upperBound...]
        guard body.count >= length else { return (0, nil) }
        guard let login = headers["tailscale-user-login"], allowedLogins.contains(login) else { return (403, nil) }
        guard let object = try? JSONSerialization.jsonObject(with: body.prefix(length)) as? [String: Any],
              Set(object.keys) == ["token", "environment"],
              let token = object["token"] as? String, PushDevice.validToken(token),
              let environment = (object["environment"] as? String).flatMap(APNsEnvironment.init(rawValue:)) else {
            return (400, nil)
        }
        return (204, PushDevice(token: token, environment: environment, registeredAt: Date()))
    }
}

/// Reads `tailscale status --json` for the login of the user who owns this machine. A tagged
/// machine has no owning user, so its tailnet's single human user stands in; with several
/// humans nobody is assumed (name them with --allowed-login).
public enum TailnetOwner {
    public static func login(status: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: status) as? [String: Any],
              let me = object["Self"] as? [String: Any], let id = me["UserID"] as? Int,
              let users = object["User"] as? [String: [String: Any]] else { return nil }
        if (me["Tags"] as? [String])?.isEmpty == false {
            let humans = users.values.compactMap { $0["LoginName"] as? String }.filter { $0.contains("@") }
            return humans.count == 1 ? humans[0] : nil
        }
        guard let login = users[String(id)]?["LoginName"] as? String, !login.isEmpty else { return nil }
        return login
    }
}
