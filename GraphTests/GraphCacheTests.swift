import Foundation
import Testing
@testable import CircleGraph

@Test func privateCacheRestoresCanonicalGraphButNeverReusesCurrentPresence() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CircleGraphCache(directory: directory)
    let key = String(repeating: "a", count: 64)
    let person = GraphPerson(id: "p", name: "Person 1", baseCity: "City 1", currentCity: "Stale city")
    let graph = SocialGraph(people: [person], relations: [], selfID: "p")
    let fetched = Date(timeIntervalSince1970: 1_700_000_000)
    try store.save(graph, refreshedAt: fetched, profile: key)
    let snapshot = try store.load(profile: key)
    let restored = try #require(snapshot)
    #expect(restored.graph.byID["p"]?.name == "Person 1")
    #expect(restored.graph.byID["p"]?.baseCity == "City 1")
    #expect(restored.graph.byID["p"]?.currentCity == nil)
    #expect(restored.refreshedAt == fetched)
    #expect(try store.load(profile: String(repeating: "b", count: 64)) == nil)
    #expect(throws: (any Error).self) { try store.load(profile: "../outside") }
    try store.remove(profile: key)
    #expect(try store.load(profile: key) == nil)
}
