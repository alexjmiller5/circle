import Foundation
import JavaScriptCore

struct CircleReaderProfile: Codable, Sendable {
    let id: String
    let scopes: [String]
    /// The service-owned profile Circle enrolls with: People reads, logged hangouts, cadence edits.
    static let circleID = "circle-editor-v1"
}

struct CircleEnrollmentApproval: Decodable {
    struct Policy: Decodable {
        let pollIntervalSeconds: Int
        let timeoutSeconds: Int
        let maxResponseBytes: Int
    }
    let path: String
    let approvalCode: String
    let policy: Policy
}

struct CircleSession: Decodable {
    struct ProfileReceipt: Codable {
        let id: String
        let revision: String
    }
    let name: String
    let scopes: [String]
    let enrollmentProfile: ProfileReceipt
}

enum CircleConnectionError: Error, LocalizedError {
    case invalidEndpoint, invalidPolicy, rejectedSession, reconnectRequired, invalidConfiguration, invalidResponse, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter an HTTPS service URL without a path, query, or password."
        case .invalidPolicy: "The bundled connection policy could not run."
        case .rejectedSession: "The service did not approve Circle's access."
        case .reconnectRequired: "Circle needs your approval again: disconnect, then reconnect."
        case .invalidConfiguration: "The service has no compatible Circle configuration."
        case .invalidResponse: "The service returned an incomplete or invalid response."
        case .unavailable: "The service is unavailable. Your saved data is unchanged."
        }
    }
}

/// Calls canonical pure policy. Transport, clocks and secure storage stay native.
@MainActor final class CircleEnrollmentPolicy {
    private let context: JSContext

    init() throws {
        guard let context = JSContext() else { throw CircleConnectionError.invalidPolicy }
        self.context = context
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let path = bundle.url(forResource: "life-core", withExtension: "js") else {
            throw CircleConnectionError.invalidPolicy
        }
        context.evaluateScript(try String(contentsOf: path, encoding: .utf8))
        guard context.exception == nil, context.objectForKeyedSubscript("CircleCore")?.isObject == true else {
            throw CircleConnectionError.invalidPolicy
        }
    }

    private func invoke(_ method: String, _ arguments: [Any]) throws -> Data {
        context.exception = nil
        guard let result = context.objectForKeyedSubscript("CircleCore")?.invokeMethod(method, withArguments: arguments),
              context.exception == nil, let object = result.toObject(), JSONSerialization.isValidJSONObject(object) else {
            // Never expose server-controlled payloads, JS exceptions or credentials in errors.
            throw CircleConnectionError.rejectedSession
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func approval(fingerprint: String, profile: String) throws -> CircleEnrollmentApproval {
        try JSONDecoder().decode(CircleEnrollmentApproval.self, from: invoke("enrollmentApproval", [[
            "fingerprint": fingerprint, "name": "Circle", "profile": profile
        ]]))
    }

    func validateSession(data: Data, fingerprint: String? = nil, profile: CircleReaderProfile) throws -> CircleSession {
        let object = try JSONSerialization.jsonObject(with: data)
        let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        if let fingerprint {
            struct Poll: Decodable { let session: CircleSession }
            return try JSONDecoder().decode(Poll.self, from: invoke("enrollmentPollResult", [
                ["status": 200, "data": object], fingerprint, expected
            ])).session
        }
        return try JSONDecoder().decode(CircleSession.self, from: invoke("validateDeviceSession", [object, expected]))
    }

    func inspectCandidate(data: Data, fingerprint: String) throws -> CircleSession {
        struct Poll: Decodable { let session: CircleSession }
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONDecoder().decode(Poll.self, from: invoke("enrollmentPollResult", [
            ["status": 200, "data": object], fingerprint
        ])).session
    }

    /// The canonical revocation outcome: "revoked" or "unauthorized"; anything else throws.
    func revocation(_ reply: CircleHTTPReply) throws -> String {
        struct Result: Decodable { let state: String }
        let data = try JSONSerialization.jsonObject(with: reply.data)
        return try JSONDecoder().decode(Result.self, from: invoke("sessionRevocationResult", [
            ["status": reply.status, "data": data]
        ])).state
    }

    func canonicalConfig(_ data: Data) throws -> Data {
        try invoke("canonicalConsumerConfig", [JSONSerialization.jsonObject(with: data)])
    }
}
