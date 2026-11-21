import Foundation
import Testing
@testable import CircleGraph

private func definitionBindings() throws -> CirclePeopleBindings {
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyDefinitionBindings())) as! [String: Any]
    json["circleDefinitions"] = ["table":"groups", "fields":Dictionary(uniqueKeysWithValues:
        ["id", "sourceLabel", "name", "kind", "periodLabel", "start", "end", "parent", "person", "deleted"].map { ($0, $0) })]
    return try JSONDecoder().decode(CirclePeopleBindings.self, from: JSONSerialization.data(withJSONObject: json))
}

@Test func optionalCircleDefinitionsAddOnlyTheirProjectedReads() throws {
    let legacy = legacyDefinitionBindings()
    let bindings = try definitionBindings()
    try bindings.validate()
    #expect(bindings.scopes.count == legacy.scopes.count + 10)
    #expect(bindings.scopes.contains("tables:read:groups:sourceLabel"))
    #expect(!bindings.scopes.contains("tables:read:groups"))
}

private func legacyDefinitionBindings() -> CirclePeopleBindings {
    .init(people:.init(table:"people",fields:["id":"id","name":"name","circles":"circles","deleted":"deleted_at"]),
          relations:.init(table:"relations",fields:["id":"id","person":"person_id","related":"related_id","kind":"relation_type","deleted":"deleted_at"]),
          locations:.init(table:"locations",fields:["id":"id","person":"person_id","city":"city","country":"country","start":"start","end":"end","deleted":"deleted_at"]))
}
private actor DefinitionHTTP: CircleHTTPClient {
    var pages: [CircleHTTPReply]
    init(_ pages: [CircleHTTPReply]) { self.pages = pages }
    func request(path: String, method: String, body: Data?, maxBytes: Int) async throws -> CircleHTTPReply {
        #expect(path == "/v1/rows/pull")
        #expect(maxBytes == 2 * 1024 * 1024)
        guard !pages.isEmpty else { throw CircleConnectionError.unavailable }
        return pages.removeFirst()
    }
}
private func page(_ rows: [[String: Any]], cursor: Any = NSNull(), status: Int = 200) throws -> CircleHTTPReply {
    .init(status: status, data: try JSONSerialization.data(withJSONObject: ["rows":rows,"next_cursor":cursor]))
}
private func definition(_ id: String = "g1", label: String = "Context 1", parent: Any = NSNull(), person: Any = NSNull()) -> [String: Any] {
    ["id":id,"sourceLabel":label,"name":label,"kind":NSNull(),"periodLabel":NSNull(),"start":NSNull(),"end":NSNull(),"parent":parent,"person":person,"deleted":NSNull()]
}
private func graphPages(_ definitions: [CircleHTTPReply]) throws -> [CircleHTTPReply] {
    [try page([["id":"p1","name":"Person 1","circles":"[\"Context 1\",\"Unmapped\",\"Context 1\"]","deleted_at":NSNull()]]), try page([]), try page([])] + definitions
}

@Test func circleRegistryReadsAllPagesWithoutChangingMembershipsAndKeepsOpaqueIdentity() async throws {
    let bindings = try definitionBindings()
    let fixture = DefinitionHTTP(try graphPages([page([definition()],cursor:"g1"),page([definition("g2",label:"Qualified context",parent:"g1",person:"p1")])]))
    let graph = try await CirclePeopleReader(client: fixture).graph(bindings: bindings, selfID: nil)
    #expect(graph.byID["p1"]?.circles == ["Context 1","Unmapped","Context 1"])
    #expect(graph.circleMetadata?.definitions.count == 2)
    #expect(graph.circleMetadata?.unavailable == false)
    #expect(graph.circleDefinition(for: "Context 1")?.id == "g1")
    #expect(graph.circleDefinition(for: "Unmapped") == nil)
    #expect(graph.circleDefinition(for: "Qualified context")?.kind == nil)
    #expect(graph.circleDefinition(for: "Qualified context")?.start == nil)
}

@Test func invalidOrPartialCircleRegistryNeverRejectsPeopleOrPublishesPartialDefinitions() async throws {
    let bindings = try definitionBindings()
    var badDate = definition(); badDate["start"] = "2026-02-30"
    var reverse = definition(); reverse["start"] = "2026-02-02"; reverse["end"] = "2026-01-01"
    for pages in [
        [try page([definition()],cursor:"g1"),try page([],status:503)],
        [try page([definition(),definition("g2")])],
        [try page([definition(parent:"missing")])],
        [try page([definition(person:"missing")])],
        [try page([definition(parent:"g2"),definition("g2",label:"Other",parent:"g1")])],
        [try page([badDate])], [try page([reverse])]
    ] {
        let graph = try await CirclePeopleReader(client: DefinitionHTTP(try graphPages(pages))).graph(bindings: bindings,selfID:nil)
        #expect(graph.people.count == 1)
        #expect(graph.circleMetadata?.unavailable == true)
        #expect(graph.circleMetadata?.definitions.isEmpty == true)
        #expect(graph.byID["p1"]?.circles == ["Context 1","Unmapped","Context 1"])
    }
}

@Test func failedOptionalRegistryKeepsPriorValidatedMetadataMarkedUnavailable() async throws {
    let bindings = try definitionBindings()
    let reader = CirclePeopleReader(client: DefinitionHTTP(try graphPages([page([definition()])])))
    let first = try await reader.graph(bindings:bindings,selfID:nil)
    let failed = try await CirclePeopleReader(client: DefinitionHTTP(try graphPages([page([],status:503)]))).graph(bindings:bindings,selfID:nil,previousMetadata:first.circleMetadata)
    #expect(failed.circleDefinition(for:"Context 1")?.id == "g1")
    #expect(failed.circleMetadata?.unavailable == true)
}

@Test func absentRegistryRetainsLegacyScopesAndOldCacheLoads() async throws {
    let bindings = legacyDefinitionBindings()
    let encoded = try JSONEncoder().encode(bindings)
    #expect(!(String(decoding:encoded,as:UTF8.self).contains("circleDefinitions")))
    let graph = try await CirclePeopleReader(client: DefinitionHTTP(try graphPages([]))).graph(bindings:bindings,selfID:nil)
    #expect(graph.circleMetadata == nil)
    let snapshot = CircleGraphCache.Snapshot(people:graph.people,relations:[],selfID:nil,refreshedAt:Date(timeIntervalSince1970:0))
    let data = try JSONEncoder().encode(snapshot)
    let restored = try JSONDecoder().decode(CircleGraphCache.Snapshot.self,from:data)
    #expect(restored.graph.circleMetadata == nil)
    #expect(restored.graph.people == graph.people)
}

@Test func circleGroupIdentityUsesRegistryIDButUnmappedLabelsKeepLegacyIdentity() async throws {
    let graph = try await CirclePeopleReader(client: DefinitionHTTP(try graphPages([page([definition()])]))).graph(bindings:definitionBindings(),selfID:nil)
    let groups = graph.groups(by:.circles,location:.base)
    #expect(groups.first { $0.name == "Context 1" }?.id == "circle:id:g1")
    #expect(groups.first { $0.name == "Unmapped" }?.id == "circle:value:Unmapped")
}

@Test func metadataCacheRoundtripPreservesStatusAndLegacyMemberships() async throws {
    let graph = try await CirclePeopleReader(client: DefinitionHTTP(try graphPages([page([definition()])]))).graph(bindings:definitionBindings(),selfID:nil)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let cache = CircleGraphCache(directory:directory), profile = String(repeating:"a",count:64)
    try cache.save(graph,refreshedAt:Date(timeIntervalSince1970:0),profile:profile)
    let loaded = try #require(try cache.load(profile:profile))
    #expect(loaded.graph.circleMetadata == graph.circleMetadata)
    #expect(loaded.graph.people == graph.people)
}

@Test func invalidCachedRegistryIsUnavailableWithoutRejectingCachedPeople() async throws {
    let graph = try await CirclePeopleReader(client: DefinitionHTTP(try graphPages([page([definition()])]))).graph(bindings:definitionBindings(),selfID:nil)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let cache = CircleGraphCache(directory:directory), profile = String(repeating:"a",count:64)
    try cache.save(graph,refreshedAt:Date(timeIntervalSince1970:0),profile:profile)
    let file = directory.appendingPathComponent(profile + ".json")
    var value = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
    var metadata = value["circleMetadata"] as! [String:Any]
    var definitions = metadata["definitions"] as! [[String:Any]]
    definitions[0]["parent"] = "missing"
    metadata["definitions"] = definitions; value["circleMetadata"] = metadata
    try JSONSerialization.data(withJSONObject:value).write(to:file)
    let loaded = try #require(try cache.load(profile:profile))
    #expect(loaded.graph.people == graph.people)
    #expect(loaded.graph.circleMetadata?.unavailable == true)
    #expect(loaded.graph.circleMetadata?.definitions.isEmpty == true)
}
