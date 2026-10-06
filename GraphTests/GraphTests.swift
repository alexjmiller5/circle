import Foundation
import Testing
@testable import CircleGraph

private func fixture() -> SocialGraph {
    SocialGraph(people: [
        GraphPerson(id: "me", name: "You", circles: ["Group A"]),
        GraphPerson(id: "p1", name: "Person 1", circles: ["Group A", "Group B"], baseCity: "City A"),
        GraphPerson(id: "p2", name: "Person 2", circles: ["Group B"], currentCity: "City B"),
        GraphPerson(id: "p3", name: "Person 3")
    ], relations: [
        GraphRelation(personID: "p1", relatedID: "me", kind: "met_through"),
        GraphRelation(personID: "p2", relatedID: "p1", kind: "father"),
        GraphRelation(personID: "p1", relatedID: "p2", kind: "fathers_child"),
        GraphRelation(personID: "p1", relatedID: "missing", kind: "partner")
    ], selfID: "me")
}

@Test func relationshipsDoNotInventFriendshipOrReverseIntroductions() {
    let graph = fixture()
    #expect(graph.edges.count == 2)
    let introduction = graph.edges.first { $0.isIntroduction }
    #expect(introduction?.from == "me")
    #expect(introduction?.to == "p1")
    #expect(graph.neighbors(of: "p3").isEmpty)
    #expect(graph.depths(from: "me") == ["me": 0, "p1": 1, "p2": 2])
}

@Test func groupingPreservesOverlappingMembershipAndUnknownLocations() {
    let graph = fixture()
    #expect(graph.groups(by: .circles, location: .base).first { $0.name == "Group B" }?.members == ["p1", "p2"])
    #expect(graph.groups(by: .city, location: .base).first { $0.name == "Unknown" }?.members == ["me", "p2", "p3"])
    #expect(graph.groups(by: .city, location: .current).first { $0.name == "City B" }?.members == ["p2"])
    #expect(graph.groups(by: .city, location: .current).first { $0.name == "City A" } == nil)
}

@Test func backRestoresFocusAndModesWithoutReversingPaths() {
    let graph = fixture()
    var state = ExplorerState(selfID: graph.selfID)
    state.select(.person("p1"))
    state.layout = .pathways
    state.select(.group("Group B"))
    state.layout = .orbits
    #expect(state.focus == .group("Group B"))
    #expect(state.orbitAnchor == "p1")
    state.back()
    #expect(state.focus == .person("p1"))
    #expect(state.layout == .pathways)
    state.backToMe()
    #expect(state.focus == .person("me"))
    #expect(graph.edges.first { $0.isIntroduction }?.from == "me")
}

@Test func allLayoutsAreStableFiniteAndKeepDisconnectedPeople() {
    let graph = fixture()
    for layout in GraphLayout.allCases {
        var state = ExplorerState(selfID: graph.selfID)
        state.layout = layout
        let first = GraphPositions.make(graph: graph, state: state)
        #expect(first.count == 4)
        #expect(first == GraphPositions.make(graph: graph, state: state))
        #expect(first.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(first["p3"] != first["me"])
    }
}

@Test func pathwaysDoNotReparentWhenFocusChangesAndOrbitsKeepTheirAnchorForGroups() {
    let graph = fixture()
    var state = ExplorerState(selfID: graph.selfID)
    state.layout = .pathways
    let original = GraphPositions.make(graph: graph, state: state)
    state.select(.person("p2"))
    #expect(original == GraphPositions.make(graph: graph, state: state))
    state.layout = .orbits
    let orbit = GraphPositions.make(graph: graph, state: state)
    state.select(.group("Group A"))
    #expect(orbit == GraphPositions.make(graph: graph, state: state))
}

@Test func emptyDuplicateAndDanglingInputIsSafe() {
    let graph = SocialGraph(people: [GraphPerson(id: "a", name: "First"), GraphPerson(id: "a", name: "Duplicate")], relations: [GraphRelation(personID: "a", relatedID: "a", kind: "partner")], selfID: "absent")
    #expect(graph.people.count == 1)
    #expect(graph.selfID == nil)
    #expect(graph.edges.isEmpty)
    let empty = SocialGraph(people: [], relations: [], selfID: nil)
    for layout in GraphLayout.allCases {
        var state = ExplorerState(selfID: nil); state.layout = layout
        #expect(GraphPositions.make(graph: empty, state: state).isEmpty)
    }
}

@Test func largeGraphsRemainCompleteWithoutQuadraticSettling() {
    let people = (0..<1500).map { GraphPerson(id: "p\($0)", name: "Person \($0)", circles: ["Group \($0 % 20)"]) }
    let relations = (1..<1500).map { GraphRelation(personID: "p\($0)", relatedID: "p\(($0 - 1) / 2)", kind: "met_through") }
    let graph = SocialGraph(people: people, relations: relations, selfID: "p0")
    let start = Date()
    for layout in GraphLayout.allCases {
        var state = ExplorerState(selfID: graph.selfID); state.layout = layout
        #expect(GraphPositions.make(graph: graph, state: state).count == 1500)
    }
    #expect(Date().timeIntervalSince(start) < 2)
}

@Test func disconnectedComponentsWithMatchingNamesHaveSeparateIdentities() {
    let graph = SocialGraph(people: [GraphPerson(id: "a", name: "Same"), GraphPerson(id: "b", name: "Same")], relations: [], selfID: nil)
    let groups = graph.groups(by: .connections, location: .base)
    #expect(Set(groups.map(\.id)).count == 2)
    #expect(graph.members(of: .group(groups[1].id), grouping: .connections, location: .base) == ["b"])
}

@Test func cyclicIntroductionsAreVisibleWithoutInfiniteTraversal() {
    let graph = SocialGraph(people: [GraphPerson(id: "a", name: "A"), GraphPerson(id: "b", name: "B"), GraphPerson(id: "c", name: "C")], relations: [
        GraphRelation(personID: "a", relatedID: "b", kind: "met_through"),
        GraphRelation(personID: "b", relatedID: "a", kind: "met_through"),
        GraphRelation(personID: "c", relatedID: "b", kind: "met_through")
    ], selfID: "a")
    var state = ExplorerState(selfID: graph.selfID); state.layout = .pathways
    let points = GraphPositions.make(graph: graph, state: state)
    #expect(points.count == 3)
    #expect(Set(points.values.map { "\($0.x),\($0.y)" }).count == 3)
    #expect(graph.depths(from: "a").count == 3)
}

@Test func changingLocationDoesNotKeepAnInvalidGroupAndBackRestoresIt() {
    let graph = fixture()
    var state = ExplorerState(selfID: graph.selfID)
    state.setGrouping(.city, graph: graph)
    state.select(.group(graph.groups(by: .city, location: .base).first { $0.name == "City A" }!.id))
    state.setLocation(.current, graph: graph)
    #expect(state.focus == .person("me"))
    state.back()
    #expect(state.location == .base)
    #expect(state.focus == .group(graph.groups(by: .city, location: .base).first { $0.name == "City A" }!.id))
}

@Test func invalidGroupFallbackAlsoRestoresOrbitAnchor() {
    let graph = fixture()
    var state = ExplorerState(selfID: graph.selfID)
    state.select(.person("p2"))
    state.setGrouping(.city, graph: graph)
    let baseGroup = graph.groups(by: .city, location: .base).first { $0.name == "City A" }!
    state.select(.group(baseGroup.id))
    state.setLocation(.current, graph: graph)
    #expect(state.focus == .person("me"))
    #expect(state.orbitAnchor == "me")
}

@Test func groupIDsDoNotAliasOtherModesOrSyntheticUnknowns() {
    let graph = SocialGraph(people: [
        GraphPerson(id: "me", name: "You", circles: ["City A"], baseCity: "Unknown"),
        GraphPerson(id: "p1", name: "Person 1", circles: ["Unassigned"], baseCity: "City A"),
        GraphPerson(id: "p2", name: "Person 2")
    ], relations: [], selfID: "me")
    let circles = graph.groups(by: .circles, location: .base)
    let cities = graph.groups(by: .city, location: .base)
    #expect(Set(circles.map(\.id)).isDisjoint(with: Set(cities.map(\.id))))
    #expect(circles.count == 3)
    #expect(cities.count == 3)
    var state = ExplorerState(selfID: graph.selfID)
    state.select(.group(circles.first { $0.name == "City A" }!.id))
    state.setGrouping(.city, graph: graph)
    #expect(state.focus == .person("me"))
}
