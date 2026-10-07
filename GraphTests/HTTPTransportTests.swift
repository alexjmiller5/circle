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
