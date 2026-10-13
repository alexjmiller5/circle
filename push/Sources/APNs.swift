import CryptoKit
import Foundation

/// The team's APNs auth key. Provider tokens are ES256 JWTs over the team and key ids.
public struct APNsCredentials: Sendable {
    public let teamID: String
    public let keyID: String
    private let key: P256.Signing.PrivateKey

    /// `pem` is the .p8 file Apple issues (PKCS#8, P-256).
    public init(teamID: String, keyID: String, pem: String) throws {
        self.teamID = teamID
        self.keyID = keyID
        key = try P256.Signing.PrivateKey(pemRepresentation: pem)
    }

    public func token(at date: Date) throws -> String {
        func encode(_ object: [String: Any]) throws -> String {
            base64url(try JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
        }
        let unsigned = "\(try encode(["alg": "ES256", "kid": keyID])).\(try encode(["iss": teamID, "iat": Int(date.timeIntervalSince1970)]))"
        let signature = try key.signature(for: Data(unsigned.utf8))
        return unsigned + "." + base64url(signature.rawRepresentation)
    }
}

private func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Ad Hoc and App Store builds receive production pushes; Xcode debug builds use the sandbox.
public enum APNsEnvironment: String, Codable, Sendable {
    case production, development
    var host: String { self == .production ? "api.push.apple.com" : "api.sandbox.push.apple.com" }
}

public enum APNsResult: Equatable, Sendable {
    case sent
    /// The token no longer reaches an install of the app: forget it.
    case unregistered
    case failed(String)
}

public protocol APNsTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Int, Data)
}

/// URLSession negotiates the HTTP/2 APNs requires.
public struct URLSessionAPNsTransport: APNsTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Int, Data) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Sends alert pushes for one app topic, reusing a provider token for 50 minutes (Apple allows 60).
public actor APNsSender {
    private let credentials: APNsCredentials
    private let topic: String
    private let transport: any APNsTransport
    private var cached: (token: String, at: Date)?

    public init(credentials: APNsCredentials, topic: String, transport: any APNsTransport = URLSessionAPNsTransport()) {
        self.credentials = credentials; self.topic = topic; self.transport = transport
    }

    public func send(title: String, body: String, to device: PushDevice, now: Date) async -> APNsResult {
        do {
            if cached == nil || now.timeIntervalSince(cached!.at) > 3000 { cached = (try credentials.token(at: now), now) }
            var request = URLRequest(url: URL(string: "https://\(device.environment.host)/3/device/\(device.token)")!)
            request.httpMethod = "POST"
            request.setValue("bearer " + cached!.token, forHTTPHeaderField: "authorization")
            request.setValue(topic, forHTTPHeaderField: "apns-topic")
            request.setValue("alert", forHTTPHeaderField: "apns-push-type")
            request.setValue("10", forHTTPHeaderField: "apns-priority")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "aps": ["alert": ["title": title, "body": body], "sound": "default"]
            ])
            let (status, data) = try await transport.send(request)
            if status == 200 { return .sent }
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String ?? "HTTP \(status)"
            if status == 410 || (status == 400 && ["BadDeviceToken", "DeviceTokenNotForTopic"].contains(reason)) { return .unregistered }
            return .failed(reason)
        } catch {
            return .failed("\(error)")
        }
    }
}
