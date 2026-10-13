import Foundation
import Testing
@testable import CircleGraph

@Test @MainActor func nativeEnrollmentUsesCoreAndRejectsBroaderOrWrongDeviceSessions() throws {
    let policy = try CircleEnrollmentPolicy()
    let fingerprint = String(repeating: "a", count: 64)
    let scopes = ["tables:read:contacts:id", "tables:read:contacts:label"]
    let profile = CircleReaderProfile(id: CircleReaderProfile.circleID, scopes: scopes)
    let approval = try policy.approval(fingerprint: fingerprint, profile: profile.id)
    #expect(approval.path == "/login?key=\(fingerprint)&name=Circle&profile=circle-editor-v1")
    #expect(approval.policy.pollIntervalSeconds == 5)
    let data: [String: Any] = [
        "name": "device:\(fingerprint)", "scopes": scopes,
        "enrollmentProfile": ["id": CircleReaderProfile.circleID, "revision": String(repeating: "b", count: 64)],
        "capabilities": ["row_api": "v1", "schema": "none", "replica_sync": false]
    ]
    let accepted = try policy.validateSession(data: JSONSerialization.data(withJSONObject: data), fingerprint: fingerprint, profile: profile)
    #expect(accepted.enrollmentProfile.id == CircleReaderProfile.circleID)
    var broad = data; broad["scopes"] = scopes + ["full"]
    #expect(throws: (any Error).self) { try policy.validateSession(data: JSONSerialization.data(withJSONObject: broad), fingerprint: fingerprint, profile: profile) }
    #expect(throws: (any Error).self) { try policy.validateSession(data: JSONSerialization.data(withJSONObject: data), fingerprint: String(repeating: "c", count: 64), profile: profile) }
    var authority = data
    authority["capabilities"] = ["row_api": "v1", "schema": "none", "replica_sync": false, "governance": [:]]
    #expect(throws: (any Error).self) { try policy.validateSession(data: JSONSerialization.data(withJSONObject: authority), fingerprint: fingerprint, profile: profile) }
}

@Test @MainActor func nativeConfigUsesCanonicalNamespaceAndSizeBoundary() throws {
    let policy = try CircleEnrollmentPolicy()
    let valid = Data(#"{"version":1,"namespace":"circle.reader","bindings":{}}"#.utf8)
    #expect((try JSONSerialization.jsonObject(with: policy.canonicalConfig(valid)) as? [String: Any])?["namespace"] as? String == "circle.reader")
    let invalid = Data(#"{"version":1,"namespace":"circle.reader","bindings":{},"token":"forbidden"}"#.utf8)
    #expect(throws: (any Error).self) { try policy.canonicalConfig(invalid) }
}

@Test @MainActor func exactStreamEnrollmentRejectsAppendOtherStreamsAndEstateScopes() throws {
    let policy = try CircleEnrollmentPolicy()
    let fingerprint = String(repeating: "a", count: 64)
    let profile = CircleReaderProfile(id: "circle-presence", scopes: ["streams:read:example_checks"])
    var data: [String: Any] = ["name":"device:\(fingerprint)", "scopes":profile.scopes,
        "enrollmentProfile":["id":profile.id,"revision":String(repeating:"b",count:64)],
        "capabilities":["row_api":"v1","schema":"none","replica_sync":false]]
    #expect(try policy.validateSession(data: JSONSerialization.data(withJSONObject: data), fingerprint: fingerprint, profile: profile).scopes == profile.scopes)
    for scope in ["streams:append:example_checks", "streams:read:other_checks", "streams:read", "full"] {
        data["scopes"] = [scope]
        #expect(throws: (any Error).self) { try policy.validateSession(data: JSONSerialization.data(withJSONObject: data), fingerprint: fingerprint, profile: profile) }
    }
}
