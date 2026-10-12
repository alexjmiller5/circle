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
    state.select(.group("circle:value:Group B"))
    state.layout = .orbits
    #expect(state.focus == .group("circle:value:Group B"))
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
    state.select(.group("circle:value:Group A"))
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

/// Real circles are skewed: one huge circle and hundreds of tiny ones. Sizing every
/// cell by the largest circle made the world ~40,000 pt wide and slow to cross.
@Test func constellationPacksSkewedCirclesCompactlyWithoutOverlap() {
    let sizes = [429, 245, 170, 137, 94, 93, 87, 81] + Array(repeating: 2, count: 250)
    var people: [GraphPerson] = []
    for (group, size) in sizes.enumerated() {
        for slot in 0..<size { people.append(GraphPerson(id: "g\(group)-\(slot)", name: "P", circles: ["Circle \(group)"])) }
    }
    // Overlapping membership: everyone in the second circle also belongs to the first.
    people = people.map { var p = $0; if p.circles == ["Circle 1"] { p.circles.append("Circle 0") }; return p }
    let graph = SocialGraph(people: people, relations: [], selfID: nil)
    let points = GraphPositions.make(graph: graph, state: ExplorerState(selfID: nil))
    #expect(points.count == people.count)
    let xs = points.values.map(\.x), ys = points.values.map(\.y)
    #expect(xs.max()! - xs.min()! < 9_000)
    #expect(ys.max()! - ys.min()! < 9_000)
    // No two people closer than a tap target, checked through a coarse grid.
    var cells: [Int: [GraphPoint]] = [:]
    func key(_ x: Int, _ y: Int) -> Int { x &* 73_856_093 ^ y &* 19_349_663 }
    var closest = Double.infinity
    for point in points.values {
        let cx = Int((point.x / 60).rounded(.down)), cy = Int((point.y / 60).rounded(.down))
        for dx in -1...1 { for dy in -1...1 {
            for other in cells[key(cx + dx, cy + dy)] ?? [] { closest = min(closest, hypot(other.x - point.x, other.y - point.y)) }
        } }
        cells[key(cx, cy), default: []].append(point)
    }
    #expect(closest >= 44)
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

/// Edges record how people met: introductions (who introduced two people, possibly you)
/// and independent friendships are undirected; met_through stays your directed arrow.
@Test func introducedAndKnowsAreUndirectedAndOnePerPair() {
    let people = ["me", "a", "b", "c", "intro"].map { GraphPerson(id: $0, name: $0) }
    let graph = SocialGraph(people: people, relations: [
        GraphRelation(personID: "a", relatedID: "b", kind: "knows"),
        GraphRelation(personID: "b", relatedID: "a", kind: "introduced", introducerID: "intro"),
        GraphRelation(personID: "b", relatedID: "c", kind: "introduced", introducerID: "me"),
        GraphRelation(personID: "a", relatedID: "me", kind: "met_through")
    ], selfID: "me")
    let pair = graph.edges.filter { Set([$0.from, $0.to]) == ["a", "b"] }
    #expect(pair.count == 1)
    #expect(pair.first?.kind == .knows)
    #expect(graph.edges.first { Set([$0.from, $0.to]) == ["b", "c"] }?.kind == .introduced)
    #expect(graph.edges.first { $0.isIntroduction }.map { [$0.from, $0.to] } == ["me", "a"])
    #expect(graph.neighbors(of: "c") == ["b"])
    // The introducer is a fact about the pair, not an edge to the introducer.
    #expect(graph.neighbors(of: "intro").isEmpty)
    #expect(graph.introducer(of: "b", and: "c") == "me")
    #expect(graph.introducer(of: "a", and: "b") == "intro")
}
