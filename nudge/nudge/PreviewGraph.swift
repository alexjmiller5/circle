import Foundation

// Synthetic identities only. This fixture is reachable only from explicit development entry points.
enum PreviewGraph {
    static let graph: SocialGraph = {
        // Public city names so the map can place synthetic people.
        let cities = [("Lisbon", "Portugal"), ("Chicago", "United States"), ("Osaka", "Japan")]
        let people = (0...16).map { i in
            let base = cities[i % 3], past = cities[(i + 1) % 3]
            return GraphPerson(id: String(format: "person-%02d", i), name: i == 0 ? "You" : "Person \(i)",
                               circles: ["Circle \(i == 0 ? 1 : (i - 1) / 4 + 1)"],
                               baseCity: i == 16 ? nil : base.0, baseCountry: i == 16 ? nil : base.1,
                               currentCity: i % 3 == 0 ? nil : cities[i % 2].0,
                               residences: i == 16 ? nil : [GraphResidence(city: base.0, country: base.1, start: "2021", end: nil),
                                                            GraphResidence(city: past.0, country: past.1, start: "2015", end: "2021")])
        }
        let relations = (1...15).map { i in
            GraphRelation(personID: people[i].id, relatedID: people[(i - 1) / 3].id, kind: "met_through")
        }
        return SocialGraph(people: people, relations: relations, selfID: people[0].id)
    }()
}
