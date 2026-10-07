import Foundation

// Synthetic identities only. This fixture is reachable only from explicit development entry points.
enum PreviewGraph {
    static let graph: SocialGraph = {
        let people = (0...16).map { i in
            GraphPerson(id: String(format: "person-%02d", i), name: i == 0 ? "You" : "Person \(i)",
                        circles: ["Circle \(i == 0 ? 1 : (i - 1) / 4 + 1)"],
                        baseCity: i == 16 ? nil : "City \(i % 3 + 1)",
                        currentCity: i % 3 == 0 ? nil : "City \(i % 2 + 1)")
        }
        let relations = (1...15).map { i in
            GraphRelation(personID: people[i].id, relatedID: people[(i - 1) / 3].id, kind: "met_through")
        }
        return SocialGraph(people: people, relations: relations, selfID: people[0].id)
    }()
}
