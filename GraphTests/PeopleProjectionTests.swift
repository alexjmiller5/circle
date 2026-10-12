import Foundation
import Testing
@testable import CircleGraph

@Test func peopleProjectionPreservesIdentityDirectionAndSeparatesResidenceFromPresence() throws {
    let config = CirclePeopleBindings(
        people: .init(table: "contacts", fields: ["id":"id", "name":"label", "circles":"groups", "deleted":"deleted_at"]),
        relations: .init(table: "links", fields: ["id":"id", "person":"subject", "related":"object", "kind":"kind", "deleted":"deleted_at"]),
        locations: .init(table: "bases", fields: ["id":"id", "person":"person", "city":"city", "country":"country", "start":"start", "end":"end", "deleted":"deleted_at"]))
    let people = Data(#"[{"id":"p1","label":"Person 1","groups":"[\"Circle 1\"]","deleted_at":null},{"id":"p2","label":"Person 2","groups":null,"deleted_at":null},{"id":"removed","label":"Removed","groups":null,"deleted_at":"2026-01-01"}]"#.utf8)
    let relations = Data(#"[{"id":"r1","subject":"p1","object":"p2","kind":"met_through","deleted_at":null}]"#.utf8)
    let locations = Data(#"[{"id":"b1","person":"p1","city":"City 1","country":"Country 1","start":"2020","end":null,"deleted_at":null},{"id":"b2","person":"p2","city":"City 2","country":"Country 1","start":"2010","end":"2020","deleted_at":null}]"#.utf8)
    let graph = try config.graph(people: people, relations: relations, locations: locations, selfID: "p2")
    #expect(graph.people.count == 2)
    #expect(graph.byID["p1"]?.circles == ["Circle 1"])
    #expect(graph.byID["p1"]?.baseCity == "City 1")
    #expect(graph.byID["p1"]?.baseCountry == "Country 1")
    #expect(graph.byID["p1"]?.currentCity == nil)
    #expect(graph.byID["p2"]?.baseCity == nil)
    #expect(graph.edges.first?.from == "p2")
    #expect(graph.edges.first?.to == "p1")
    #expect(config.scopes.count == 16)
    #expect(config.scopes.contains("tables:read:contacts:label"))
}

@Test func peopleProjectionRejectsMissingDeletionAndMalformedCirclesRatherThanPublishingPartialGraph() throws {
    let config = CirclePeopleBindings.standardFixture
    let missing = Data(#"[{"id":"p1","name":"Person 1","circles":null}]"#.utf8)
    #expect(throws: (any Error).self) { try config.graph(people: missing, relations: Data("[]".utf8), locations: Data("[]".utf8), selfID: nil) }
    let malformed = Data(#"[{"id":"p1","name":"Person 1","circles":"not json","deleted_at":null}]"#.utf8)
    #expect(throws: (any Error).self) { try config.graph(people: malformed, relations: Data("[]".utf8), locations: Data("[]".utf8), selfID: nil) }
}

@Test func conflictingCurrentBasesStayUnknownInsteadOfPickingAnArbitraryResidence() throws {
    let config = CirclePeopleBindings.standardFixture
    let people = Data(#"[{"id":"p1","name":"Person 1","circles":null,"deleted_at":null}]"#.utf8)
    let bases = Data(#"[{"id":"b1","person_id":"p1","city":"City 1","country":null,"start":null,"end":null,"deleted_at":null},{"id":"b2","person_id":"p1","city":"City 2","country":null,"start":null,"end":null,"deleted_at":null}]"#.utf8)
    #expect(try config.graph(people: people, relations: Data("[]".utf8), locations: bases, selfID: nil).byID["p1"]?.baseCity == nil)
}

private extension CirclePeopleBindings {
    static var standardFixture: Self {
        .init(people: .init(table: "people", fields: ["id":"id", "name":"name", "circles":"circles", "deleted":"deleted_at"]),
              relations: .init(table: "relations", fields: ["id":"id", "person":"person_id", "related":"related_id", "kind":"relation_type", "deleted":"deleted_at"]),
              locations: .init(table: "locations", fields: ["id":"id", "person":"person_id", "city":"city", "country":"country", "start":"start", "end":"end", "deleted":"deleted_at"]))
    }
}

@Test func cityGroupsKeepSameNamedCitiesInDifferentCountriesSeparate() {
    let graph = SocialGraph(people: [
        GraphPerson(id: "p1", name: "Person 1", baseCity: "City 1", baseCountry: "Country 1"),
        GraphPerson(id: "p2", name: "Person 2", baseCity: "City 1", baseCountry: "Country 2"),
        GraphPerson(id: "p3", name: "Person 3", baseCity: "City 1")
    ], relations: [], selfID: nil)
    #expect(graph.groups(by: .city, location: .base).count == 3)
    #expect(graph.city(of: graph.byID["p1"]!, mode: .base) == "City 1, Country 1")
    #expect(graph.groups(by: .city, location: .current).count == 1)
}

@Test func relationsBindingMayCarryTheIntroducer() throws {
    let base = ["id":"id", "person":"subject", "related":"object", "kind":"kind", "deleted":"deleted_at"]
    var fields = base; fields["introducer"] = "via"
    let config = CirclePeopleBindings(
        people: .init(table: "contacts", fields: ["id":"id", "name":"label", "circles":"groups", "deleted":"deleted_at"]),
        relations: .init(table: "links", fields: fields),
        locations: .init(table: "bases", fields: ["id":"id", "person":"person", "city":"city", "country":"country", "start":"start", "end":"end", "deleted":"deleted_at"]))
    try config.validate()
    #expect(config.scopes.contains("tables:read:links:via"))
    let people = Data(#"[{"id":"p1","label":"Person 1","groups":null,"deleted_at":null},{"id":"p2","label":"Person 2","groups":null,"deleted_at":null},{"id":"p3","label":"Person 3","groups":null,"deleted_at":null}]"#.utf8)
    let relations = Data(#"[{"id":"r1","subject":"p1","object":"p2","kind":"introduced","via":"p3","deleted_at":null},{"id":"r2","subject":"p1","object":"p3","kind":"knows","via":null,"deleted_at":null}]"#.utf8)
    let graph = try config.graph(people: people, relations: relations, locations: Data("[]".utf8), selfID: nil)
    #expect(graph.introducer(of: "p1", and: "p2") == "p3")
    #expect(graph.edges.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.introduced, .knows])
    // Unknown relation fields are still refused.
    var extra = base; extra["note"] = "note"
    let bad = CirclePeopleBindings(people: config.people, relations: .init(table: "links", fields: extra), locations: config.locations)
    #expect(throws: (any Error).self) { try bad.validate() }
}
