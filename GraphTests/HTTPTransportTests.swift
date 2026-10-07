import Foundation
import Testing
@testable import CircleGraph

@Test func endpointsNeverAcceptCredentialsQueriesOrUnencryptedHosts() throws {
    #expect(try CircleHTTPTransport.canonicalEndpoint("https://example.invalid/").absoluteString == "https://example.invalid")
    for endpoint in ["http://example.invalid", "https://user:secret@example.invalid", "https://example.invalid/?token=x", "https://example.invalid/#fragment", "https://example.invalid/private", "file:///tmp/store"] {
        #expect(throws: (any Error).self) { try CircleHTTPTransport.canonicalEndpoint(endpoint) }
    }
}

private final class HTTPStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let valid = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" && request.httpMethod == "GET"
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 403, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 4096))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func nativeTransportBoundsRepliesAndCarriesOnlyItsDedicatedCredential() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HTTPStub.self]
    let transport = try CircleHTTPTransport(endpoint: "https://example.invalid", token: "fixture-token", configuration: configuration)
    let accepted = try await transport.request(path: "/v1/session", method: "GET", body: nil, maxBytes: 4096)
    #expect(accepted.status == 200)
    #expect(accepted.data.count == 4096)
    await #expect(throws: (any Error).self) { try await transport.request(path: "/v1/session", method: "GET", body: nil, maxBytes: 1024) }
    await #expect(throws: (any Error).self) { try await transport.request(path: "https://elsewhere.invalid", method: "GET", body: nil, maxBytes: 4096) }
}

@Test func nativeTransportAllowsOnlyBoundedStreamPageQueries() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HTTPStub.self]
    let transport = try CircleHTTPTransport(endpoint: "https://example.invalid", token: "fixture-token", configuration: configuration)
    let reply = try await transport.request(path: "/v1/streams/example_checks/records?limit=20&cursor=YWJj%2B%2F%3D", method: "GET", body: nil, maxBytes: 4096)
    #expect(reply.status == 200)
    for path in ["/v1/session?token=x", "/v1/streams/example_checks/append?limit=20", "/v1/streams/example_checks/records?limit=21", "/v1/streams/example_checks/records?limit=20&limit=1", "/v1/streams/example_checks/records?limit=20&token=x", "/v1/streams/example%2Fchecks/records?limit=20"] {
        await #expect(throws: (any Error).self) { try await transport.request(path: path, method: "GET", body: nil, maxBytes: 4096) }
    }
    await #expect(throws: (any Error).self) { try await transport.request(path: "/v1/streams/example_checks/records?limit=20", method: "POST", body: nil, maxBytes: 4096) }
}
