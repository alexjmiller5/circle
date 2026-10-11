import Foundation
import Testing
@testable import CircleGraph

private let photoBindings = CirclePeopleBindings(
    people: .init(table: "contacts", fields: ["id":"id", "name":"label", "circles":"groups", "deleted":"deleted_at"]),
    relations: .init(table: "links", fields: ["id":"id", "person":"subject", "related":"object", "kind":"kind", "deleted":"deleted_at"]),
    locations: .init(table: "bases", fields: ["id":"id", "person":"person", "city":"city", "country":"country", "start":"start", "end":"end", "deleted":"deleted_at"]),
    photos: .init(table: "pictures", fields: ["id":"id", "person":"person", "platform":"source", "key":"object_key", "sha256":"digest",
                                              "fetched":"fetched_at", "updated":"updated_at", "deleted":"deleted_at"],
                  files: ["pictures/people/"]))

private let fixturePeople = Data(#"[{"id":"p1","label":"Person 1","groups":"[\"Place 1\",\"Era 1\"]","deleted_at":null},{"id":"p2","label":"Person 2","groups":null,"deleted_at":null}]"#.utf8)
private let fixtureBases = Data(#"""
[{"id":"b1","person":"p1","city":"City 1","country":"Country 1","start":"2020","end":null,"deleted_at":null},
 {"id":"b2","person":"p1","city":"City 2","country":"Country 1","start":"2012","end":"2020","deleted_at":null},
 {"id":"b3","person":"p1","city":"City 3","country":null,"start":"2001","end":"2005","deleted_at":"2026-01-01T00:00:00.000Z"}]
"""#.utf8)
private let fixturePhotos = Data(#"""
[{"id":"f1","person":"p1","source":"platform_a","object_key":"pictures/people/a/old.jpg","digest":"aa","fetched_at":"2026-01-01T00:00:00.000Z","updated_at":"2026-01-01T00:00:00.000Z","deleted_at":null},
 {"id":"f2","person":"p1","source":"platform_a","object_key":"pictures/people/a/new.jpg","digest":"bb","fetched_at":"2026-03-01T00:00:00.000Z","updated_at":"2026-03-01T00:00:00.000Z","deleted_at":null},
 {"id":"f3","person":"p1","source":"platform_b","object_key":"pictures/people/b/one.jpg","digest":"cc","fetched_at":"2026-02-01T00:00:00.000Z","updated_at":"2026-02-01T00:00:00.000Z","deleted_at":null},
 {"id":"f4","person":"p1","source":"platform_c","object_key":"pictures/people/c/gone.jpg","digest":"dd","fetched_at":"2026-09-01T00:00:00.000Z","updated_at":"2026-09-01T00:00:00.000Z","deleted_at":"2026-09-02T00:00:00.000Z"}]
"""#.utf8)

@Test func platformNamesKeepBrandCapitalization() {
    #expect(CirclePeopleMap.platformName("linkedin") == "LinkedIn")
    #expect(CirclePeopleMap.platformName("whatsapp") == "WhatsApp")
    #expect(CirclePeopleMap.platformName("instagram") == "Instagram")
    #expect(CirclePeopleMap.platformName("platform_a") == "Platform A")
}

@Test func photoBindingAddsExactColumnAndFileGrants() throws {
    try photoBindings.validate()
    #expect(photoBindings.scopes.count == 25)
    #expect(photoBindings.scopes.contains("tables:read:pictures:object_key"))
    #expect(photoBindings.scopes.contains("files:read:pictures/people/"))
    // The three-table profile stays valid: photos are optional upstream configuration.
    let legacy = CirclePeopleBindings(people: photoBindings.people, relations: photoBindings.relations, locations: photoBindings.locations)
    try legacy.validate()
    #expect(legacy.scopes.count == 16)
    for prefixes in [[String](), ["pictures"], ["../people/"], ["pictures//"], ["pictures/%2e/"]] {
        let bad = CirclePeopleBindings(people: photoBindings.people, relations: photoBindings.relations, locations: photoBindings.locations,
                                       photos: .init(table: "pictures", fields: photoBindings.photos!.fields, files: prefixes))
        #expect(throws: (any Error).self) { try bad.validate() }
    }
    let tableFiles = CirclePeopleBindings(people: .init(table: "contacts", fields: photoBindings.people.fields, files: ["x/"]),
                                          relations: photoBindings.relations, locations: photoBindings.locations)
    #expect(throws: (any Error).self) { try tableFiles.validate() }
}

@Test func projectionKeepsBaseHistoryAndNewestPhotoPerPlatform() throws {
    let graph = try photoBindings.graph(people: fixturePeople, relations: Data("[]".utf8), locations: fixtureBases,
                                        photos: fixturePhotos, selfID: nil)
    let person = try #require(graph.byID["p1"])
    #expect(person.baseHistory.map(\.city) == ["City 1", "City 2"])
    #expect(person.baseHistory.first?.end == nil)
    #expect(person.basePlace?.query == "City 1, Country 1")
    #expect(person.photoChoices.map(\.key) == ["pictures/people/a/new.jpg", "pictures/people/b/one.jpg"])
    #expect(graph.byID["p2"]?.photoChoices.isEmpty == true)
    #expect(graph.byID["p2"]?.basePlace == nil)
}

@Test func presenceStaysUnknownWithResidenceCacheOrConflicts() throws {
    let graph = try photoBindings.graph(people: fixturePeople, relations: Data("[]".utf8), locations: fixtureBases,
                                        photos: fixturePhotos, selfID: nil)
    let person = try #require(graph.byID["p1"])
    #expect(person.basePlace != nil)
    #expect(person.presence == "Unknown")
    // A cached graph that somehow carried presence never revives it.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = CircleGraphCache(directory: directory), key = String(repeating: "c", count: 64)
    var stale = person; stale.currentCity = "City 9"
    try cache.save(SocialGraph(people: [stale], relations: [], selfID: nil), refreshedAt: Date(), profile: key)
    let restored = try #require(try cache.load(profile: key)).graph
    #expect(restored.byID["p1"]?.presence == "Unknown")
    #expect(restored.byID["p1"]?.baseHistory.count == 2)
    #expect(restored.byID["p1"]?.photoChoices.count == 2)
    // Pins come from residence only; presence alone never places a person.
    let travelling = GraphPerson(id: "p3", name: "Person 3", currentCity: "City 1")
    let pins = CirclePeopleMap.pins(graph: SocialGraph(people: [person, travelling], relations: [], selfID: nil),
                                    coordinates: [person.basePlace!.key: CircleCoordinate(latitude: 10, longitude: 20)], circle: nil)
    #expect(pins.map(\.id) == ["p1"])
}

@Test func pinsFilterByCircleAndSpreadSharedBasesDeterministically() {
    let place = CirclePlace(city: "City 1", country: "Country 1")
    let people = (1...4).map { GraphPerson(id: "p\($0)", name: "Person \($0)", circles: $0 % 2 == 0 ? ["Place 1"] : ["Era 1"],
                                           baseCity: "City 1", baseCountry: "Country 1") }
    let graph = SocialGraph(people: people, relations: [], selfID: nil)
    let center = CircleCoordinate(latitude: 40, longitude: -70)
    let all = CirclePeopleMap.pins(graph: graph, coordinates: [place.key: center], circle: nil)
    #expect(all.count == 4)
    #expect(Set(all.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" }).count == 4)
    #expect(all.allSatisfy { abs($0.coordinate.latitude - 40) < 0.05 && abs($0.coordinate.longitude + 70) < 0.05 })
    #expect(all == CirclePeopleMap.pins(graph: graph, coordinates: [place.key: center], circle: nil))
    #expect(CirclePeopleMap.pins(graph: graph, coordinates: [place.key: center], circle: "Place 1").map(\.id) == ["p2", "p4"])
    #expect(CirclePeopleMap.circles(graph: graph).map(\.name) == ["Era 1", "Place 1"])
    // Same-named cities in different countries are different places.
    #expect(CirclePlace(city: "City 1", country: "Country 2").key != place.key)
    #expect(CirclePlace(city: " city 1 ", country: "COUNTRY 1").key == place.key)
}
