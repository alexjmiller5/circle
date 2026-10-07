import Foundation
import Testing
@testable import CircleGraph

private actor ReadFixture: CircleHTTPClient {
    var replies: [CircleHTTPReply]
    var bodies: [Data?] = []
    init(_ replies: [CircleHTTPReply]) { self.replies = replies }
    func request(path: String, method: String, body: Data?, maxBytes: Int) async throws -> CircleHTTPReply {
        #expect(path == "/v1/rows/pull")
        #expect(method == "POST")
        bodies.append(body)
        guard !replies.isEmpty else { throw CircleConnectionError.unavailable }
        return replies.removeFirst()
    }
}

private func reply(_ json: String, status: Int = 200) -> CircleHTTPReply {
    .init(status: status, data: Data(json.utf8))
}

@Test func projectedReaderFinishesAllAuthorizedPagesAndFiltersNoTombstonesPrematurely() async throws {
    let fixture = ReadFixture([
        reply(#"{"rows":[{"id":"a","label":"One","deleted_at":null}],"next_cursor":"a"}"#),
        reply(#"{"rows":[{"id":"b","label":"Two","deleted_at":"2026-01-01"}],"next_cursor":null}"#)
    ])
    let reader = CirclePeopleReader(client: fixture)
    let table = CircleProjectionTable(table: "contacts", fields: ["id":"id", "name":"label", "deleted":"deleted_at"])
    let data = try await reader.read(table)
    let rows = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    #expect(rows.count == 2)
    let requests = await fixture.bodies
    let second = try JSONSerialization.jsonObject(with: requests[1]!) as! [String: Any]
    #expect(second["after"] as? String == "a")
    #expect(second["limit"] as? Int == 200)
    #expect(second["columns"] as? [String] == ["deleted_at", "id", "label"])
    #expect(second["since"] == nil)
}

@Test func projectedReaderRejectsChangingDuplicatesNonadvancingAndPartialPages() async throws {
    let table = CircleProjectionTable(table: "contacts", fields: ["id":"id", "name":"label"])
    for second in [
        reply(#"{"rows":[{"id":"a","label":"Changed"}],"next_cursor":null}"#),
        reply(#"{"rows":[{"id":"b","label":"Two"}],"next_cursor":"a"}"#),
        reply(#"{"rows":[],"next_cursor":null}"#, status: 503),
        reply(#"{"rows":[{"id":"b"}],"next_cursor":null}"#)
    ] {
        let reader = CirclePeopleReader(client: ReadFixture([
            reply(#"{"rows":[{"id":"a","label":"One"}],"next_cursor":"a"}"#), second
        ]))
        await #expect(throws: (any Error).self) { try await reader.read(table) }
    }
}

@Test func projectedEqualityReadUsesOnlyGrantedColumnsOnEveryPage() async throws {
    let fixture = ReadFixture([
        reply(#"{"rows":[{"id":"a","person_ref":"person-1"}],"next_cursor":"a"}"#),
        reply(#"{"rows":[{"id":"b","person_ref":"person-1"}],"next_cursor":null}"#)
    ])
    let table = CircleProjectionTable(table: "participants", fields: ["id":"id", "person":"person_ref"])
    let rows = try await CirclePeopleReader(client: fixture).read(table, where: ["person_ref":"person-1"])
    #expect(try table.rows(rows).count == 2)
    for data in await fixture.bodies {
        let request = try JSONSerialization.jsonObject(with: data!) as! [String: Any]
        #expect(request["where"] as? [String:String] == ["person_ref":"person-1"])
        #expect(request["since"] == nil)
    }
    let before = await fixture.bodies.count
    await #expect(throws: (any Error).self) {
        try await CirclePeopleReader(client: fixture).read(table, where: ["ungranted":"person-1"])
    }
    #expect(await fixture.bodies.count == before)
}

@Test func projectedEqualityReadRejectsRowsOutsideTheRequestedPerson() async throws {
    let fixture = ReadFixture([
        reply(#"{"rows":[{"id":"a","person_ref":"person-2"}],"next_cursor":null}"#)
    ])
    let table = CircleProjectionTable(table: "participants", fields: ["id":"id", "person":"person_ref"])
    await #expect(throws: (any Error).self) {
        try await CirclePeopleReader(client: fixture).read(table, where: ["person_ref":"person-1"])
    }
}
