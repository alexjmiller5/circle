import Foundation
import Testing
@testable import CircleGraph

private actor StreamStub: CircleHTTPClient {
    let payload: Data
    var requestedPath: String?
    init(_ page: [String: Any]) throws { payload = try JSONSerialization.data(withJSONObject: page) }
    func request(path: String, method: String, body: Data?, maxBytes: Int) async throws -> CircleHTTPReply {
        requestedPath = path
        #expect(method == "GET" && body == nil && maxBytes == 2_000_000)
        return CircleHTTPReply(status: 200, data: payload)
    }
}

@Test func boundedStreamPagesPreserveBodiesAndEncodeOpaqueCursors() async throws {
    let raw = #"[{"source_age":"Now"}]"#
    let client = try StreamStub(["entries":[["id":String(repeating:"a",count:64),"body":raw]],"next_cursor":"ZGVm+/="])
    let page = try await CircleStreamReader(client: client).page(stream: "example_checks", cursor: "YWJj+/=")
    #expect(page.entries.count == 1)
    #expect(page.entries[0].body == raw)
    #expect(page.nextCursor == "ZGVm+/=")
    #expect(await client.requestedPath == "/v1/streams/example_checks/records?limit=20&cursor=YWJj%2B%2F%3D")
}

@Test func streamPageRejectsDuplicatesInvalidIDsAndMoreThanTwentyBodies() async throws {
    let entry = ["id":String(repeating:"a",count:64),"body":"{}"]
    for entries in [[entry,entry], [["id":"bad","body":"{}"]], Array(repeating:entry,count:21)] {
        let client = try StreamStub(["entries":entries,"next_cursor":NSNull()])
        await #expect(throws: (any Error).self) { try await CircleStreamReader(client: client).page(stream: "example_checks") }
    }
    let repeated = try StreamStub(["entries":[entry],"next_cursor":"YWJj+/="])
    await #expect(throws: (any Error).self) { try await CircleStreamReader(client: repeated).page(stream: "example_checks", cursor:"YWJj+/=") }
    let empty = try StreamStub(["entries":[],"next_cursor":NSNull()])
    let page = try await CircleStreamReader(client: empty).page(stream: "example_checks")
    #expect(page.entries.isEmpty && page.nextCursor == nil)
    for name in ["", "../private", "a/b", String(repeating:"a",count:65)] {
        await #expect(throws: (any Error).self) { try await CircleStreamReader(client: empty).page(stream:name) }
    }
}
