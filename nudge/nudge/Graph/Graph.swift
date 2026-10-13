import Foundation

struct GraphPerson: Identifiable, Equatable, Codable, Sendable {
    let id: String
    var name: String
    var circles: [String] = []
    var baseCity: String? = nil
    var baseCountry: String? = nil
    // A future adapter must supply only presence accepted by the explicit freshness policy.
    var currentCity: String? = nil
    // Optional so offline copies saved before these fields existed still load.
    var residences: [GraphResidence]? = nil
    var photos: [GraphPhoto]? = nil
    /// How often Alex wants in-person time (weekly, fortnightly, monthly, quarterly); nil = no reminders.
    var hangoutCadence: String? = nil
    /// The row revision a cadence edit must name; nil until the hub has stamped the row.
    var revision: GraphRowRevision? = nil
}

struct GraphRowRevision: Equatable, Codable, Sendable {
    let updatedAt: String
    let hubAt: String
}

/// One residence claim; null `end` means a current base.
struct GraphResidence: Equatable, Codable, Sendable {
    let city: String?
    let country: String?
    let start: String?
    let end: String?
}

/// One retained profile photo; the key is read through the authorized file service.
struct GraphPhoto: Equatable, Codable, Sendable {
    let platform: String
    let key: String
    let sha256: String?
    let fetchedAt: String?
    let updatedAt: String?
}

struct GraphRelation: Equatable, Codable, Sendable {
    let personID: String
    let relatedID: String
    let kind: String
    /// Who introduced the pair, for `introduced` relations only.
    var introducerID: String? = nil
}

/// met_through is your directed arrow; the rest are undirected, one per pair, strongest kind kept.
enum GraphEdgeKind: Int, Comparable, Sendable {
    case introduced, knows, tie, metThrough
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct GraphEdge: Identifiable, Equatable, Sendable {
    let from: String
    let to: String
    let kind: GraphEdgeKind
    var isIntroduction: Bool { kind == .metThrough }
    var id: String { "\(isIntroduction):\(from):\(to)" }
}

struct GraphGroup: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let members: [String]

    init(name: String, members: [String], id: String? = nil) {
        self.id = id ?? name; self.name = name; self.members = members
    }
}

enum GraphLayout: String, CaseIterable, Sendable { case constellation, pathways, orbits }
enum GraphGrouping: String, CaseIterable, Sendable { case connections, circles, city }
enum LocationMode: String, CaseIterable, Sendable { case base, current }
enum GraphFocus: Equatable, Sendable { case person(String), group(String) }

struct SocialGraph: Sendable {
    let people: [GraphPerson]
    let byID: [String: GraphPerson]
    let relations: [GraphRelation]
    let edges: [GraphEdge]
    let selfID: String?
    private let adjacency: [String: Set<String>]

    init(people: [GraphPerson], relations: [GraphRelation], selfID: String?) {
        var unique: [String: GraphPerson] = [:]
        for person in people where unique[person.id] == nil { unique[person.id] = person }
        self.people = unique.values.sorted { $0.id < $1.id }
        self.byID = unique
        self.selfID = selfID.flatMap { unique[$0] == nil ? nil : $0 }
        self.relations = relations.filter {
            $0.personID != $0.relatedID && unique[$0.personID] != nil && unique[$0.relatedID] != nil
        }
        var edgeMap: [String: GraphEdge] = [:]
        var adjacency: [String: Set<String>] = [:]
        for relation in self.relations {
            let kind: GraphEdgeKind = switch relation.kind {
            case "met_through": .metThrough
            case "introduced": .introduced
            case "knows": .knows
            default: .tie
            }
            let pair = [relation.personID, relation.relatedID].sorted()
            let edge = GraphEdge(from: kind == .metThrough ? relation.relatedID : pair[0],
                                 to: kind == .metThrough ? relation.personID : pair[1], kind: kind)
            if let existing = edgeMap[edge.id], existing.kind >= kind { continue }
            edgeMap[edge.id] = edge
            adjacency[edge.from, default: []].insert(edge.to)
            adjacency[edge.to, default: []].insert(edge.from)
        }
        self.edges = edgeMap.values.sorted { $0.id < $1.id }
        self.adjacency = adjacency
    }

    func neighbors(of id: String) -> Set<String> { adjacency[id] ?? [] }

    /// Who introduced two people, when an `introduced` relation records it.
    func introducer(of a: String, and b: String) -> String? {
        relations.first { $0.kind == "introduced" && Set([$0.personID, $0.relatedID]) == [a, b] }?.introducerID
    }

    func depths(from id: String) -> [String: Int] {
        guard byID[id] != nil else { return [:] }
        var depths = [id: 0], queue = [id], index = 0
        while index < queue.count {
            let current = queue[index]; index += 1
            for neighbor in neighbors(of: current).sorted() where depths[neighbor] == nil {
                depths[neighbor] = depths[current, default: 0] + 1
                queue.append(neighbor)
            }
        }
        return depths
    }

    func city(of person: GraphPerson, mode: LocationMode) -> String {
        let value = mode == .base ? person.baseCity : person.currentCity
        guard let city = value?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty else { return "Unknown" }
        if mode == .base, let country = person.baseCountry?.trimmingCharacters(in: .whitespacesAndNewlines), !country.isEmpty {
            return city + ", " + country
        }
        return city
    }

    func groups(by grouping: GraphGrouping, location: LocationMode) -> [GraphGroup] {
        if grouping == .connections {
            var remaining = Set(byID.keys), result: [GraphGroup] = []
            for person in people where remaining.contains(person.id) {
                let ids = depths(from: person.id).keys.sorted()
                remaining.subtract(ids)
                result.append(GraphGroup(name: person.name, members: ids, id: "component:\(person.id)"))
            }
            return result
        }
        var members: [String: [String]] = [:], labels: [String: String] = [:]
        for person in people {
            let entries: [(String, String)]
            if grouping == .city {
                let value = (location == .base ? person.baseCity : person.currentCity)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let value, !value.isEmpty {
                    if location == .base, let country = person.baseCountry?.trimmingCharacters(in: .whitespacesAndNewlines), !country.isEmpty {
                        let key = String(data: try! JSONEncoder().encode([value, country]), encoding: .utf8)!
                        entries = [("city:country:" + key, city(of: person, mode: location))]
                    } else {
                        entries = [("city:value:" + value, value)]
                    }
                } else {
                    entries = [("city:unknown", "Unknown")]
                }
            } else if person.circles.isEmpty {
                entries = [("circle:unassigned", "Unassigned")]
            } else {
                entries = Set(person.circles).sorted().map { ("circle:value:" + $0, $0) }
            }
            for (id, label) in entries {
                members[id, default: []].append(person.id)
                labels[id] = label
            }
        }
        return members.keys.sorted().map { GraphGroup(name: labels[$0]!, members: members[$0]!, id: $0) }
    }

    func members(of focus: GraphFocus?, grouping: GraphGrouping, location: LocationMode) -> [String] {
        switch focus {
        case .person(let id): return byID[id] == nil ? [] : [id]
        case .group(let id): return groups(by: grouping, location: location).first { $0.id == id }?.members ?? []
        case nil: return []
        }
    }
}

struct ExplorerState: Equatable, Sendable {
    var layout: GraphLayout = .constellation
    var grouping: GraphGrouping = .circles
    var location: LocationMode = .base
    var boundaries = false
    var motion = true
    private(set) var focus: GraphFocus?
    private(set) var orbitAnchor: String?
    let selfID: String?
    private var history: [Selection] = []
    var canGoBack: Bool { !history.isEmpty }

    private struct Selection: Equatable, Sendable {
        let focus: GraphFocus?
        let layout: GraphLayout
        let grouping: GraphGrouping
        let location: LocationMode
        let orbitAnchor: String?
    }

    init(selfID: String?) {
        self.selfID = selfID
        self.focus = selfID.map(GraphFocus.person)
        self.orbitAnchor = selfID
    }

    mutating func select(_ focus: GraphFocus) {
        guard self.focus != focus else { return }
        remember()
        self.focus = focus
        if case .person(let id) = focus { orbitAnchor = id }
    }

    mutating func setGrouping(_ grouping: GraphGrouping, graph: SocialGraph) {
        guard self.grouping != grouping else { return }
        remember(); self.grouping = grouping
        validateFocus(graph: graph)
    }

    mutating func setLocation(_ location: LocationMode, graph: SocialGraph) {
        guard self.location != location else { return }
        remember(); self.location = location
        validateFocus(graph: graph)
    }

    private mutating func validateFocus(graph: SocialGraph) {
        if case .group = focus, graph.members(of: focus, grouping: grouping, location: location).isEmpty {
            focus = selfID.map(GraphFocus.person)
            orbitAnchor = selfID
        }
    }

    private mutating func remember() {
        history.append(Selection(focus: focus, layout: layout, grouping: grouping, location: location, orbitAnchor: orbitAnchor))
        if history.count > 40 { history.removeFirst() }
    }

    mutating func back() {
        guard let previous = history.popLast() else { return }
        focus = previous.focus; layout = previous.layout; grouping = previous.grouping
        location = previous.location; orbitAnchor = previous.orbitAnchor
    }

    mutating func backToMe() {
        if let selfID { select(.person(selfID)) }
    }
}

struct GraphPoint: Equatable, Sendable {
    var x: Double
    var y: Double
    static let zero = GraphPoint(x: 0, y: 0)
}

enum GraphPositions {
    static func make(graph: SocialGraph, state: ExplorerState) -> [String: GraphPoint] {
        guard !graph.people.isEmpty else { return [:] }
        switch state.layout {
        case .constellation: return constellation(graph: graph, state: state)
        case .pathways: return pathways(graph: graph)
        case .orbits: return orbits(graph: graph, anchor: state.orbitAnchor)
        }
    }

    private static func constellation(graph: SocialGraph, state: ExplorerState) -> [String: GraphPoint] {
        // One position per person, even if several circle regions contain them: largest
        // groups first, so a person sits in their biggest group.
        let groups = graph.groups(by: state.grouping, location: state.location).sorted {
            $0.members.count != $1.members.count ? $0.members.count > $1.members.count : $0.id < $1.id
        }
        var placed = Set<String>()
        let clusters = groups.map { $0.members.filter { placed.insert($0).inserted } }.filter { !$0.isEmpty }
        // Each cluster is a sunflower disk sized by its own members, shelf-packed in rows.
        // Sizing by the largest group made the world ~40,000 pt wide; no all-pairs settling.
        let spacing = 65.0, padding = 50.0
        let radii = clusters.map { sqrt(Double($0.count - 1)) * spacing + padding }
        let rowWidth = max(2 * (radii.max() ?? 0), sqrt(radii.reduce(0) { $0 + 4 * $1 * $1 }) * 1.2)
        var points: [String: GraphPoint] = [:], x = 0.0, y = 0.0, rowHeight = 0.0
        for (cluster, radius) in zip(clusters, radii) {
            if x > 0 && x + 2 * radius > rowWidth { x = 0; y += rowHeight; rowHeight = 0 }
            let center = GraphPoint(x: x + radius, y: y + radius)
            for (slot, id) in cluster.enumerated() {
                let r = sqrt(Double(slot)) * spacing, angle = Double(slot) * 2.3999632297
                points[id] = GraphPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            }
            x += 2 * radius; rowHeight = max(rowHeight, 2 * radius)
        }
        return points
    }

    private static func pathways(graph: SocialGraph) -> [String: GraphPoint] {
        let edges = graph.edges.filter(\.isIntroduction)
        var incoming: [String: Int] = [:], children: [String: [String]] = [:]
        for edge in edges {
            incoming[edge.to, default: 0] += 1
            children[edge.from, default: []].append(edge.to)
        }
        var queue = graph.people.filter { incoming[$0.id, default: 0] == 0 }.map(\.id)
        var level = Dictionary(uniqueKeysWithValues: queue.map { ($0, 0) }), index = 0
        while index < queue.count {
            let id = queue[index]; index += 1
            for child in children[id, default: []].sorted() {
                level[child] = max(level[child, default: 0], level[id, default: 0] + 1)
                incoming[child, default: 0] -= 1
                if incoming[child] == 0 { queue.append(child) }
            }
        }
        let cyclicLevel = (level.values.max() ?? 0) + 1
        let resolved = Set(queue)
        for person in graph.people where !resolved.contains(person.id) { level[person.id] = cyclicLevel }
        let bands = Dictionary(grouping: graph.people.map(\.id), by: { level[$0, default: 0] })
        var points: [String: GraphPoint] = [:]
        for (depth, ids) in bands {
            for (slot, id) in ids.sorted().enumerated() {
                points[id] = GraphPoint(x: (Double(slot) - Double(ids.count - 1) / 2) * 112, y: Double(depth) * 155)
            }
        }
        return points
    }

    private static func orbits(graph: SocialGraph, anchor: String?) -> [String: GraphPoint] {
        let anchor = anchor.flatMap { graph.byID[$0] == nil ? nil : $0 } ?? graph.people[0].id
        let depths = graph.depths(from: anchor)
        let disconnected = (depths.values.max() ?? 0) + 1
        let rings = Dictionary(grouping: graph.people.map(\.id), by: { depths[$0] ?? disconnected })
        var points: [String: GraphPoint] = [anchor: .zero], radius = 0.0
        for depth in rings.keys.sorted() where depth > 0 {
            let ids = rings[depth]!.sorted()
            radius = max(radius + 145, Double(ids.count) * 80 / (2 * .pi))
            for (slot, id) in ids.enumerated() {
                let angle = Double(slot) / Double(ids.count) * 2 * .pi - .pi / 2
                points[id] = GraphPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            }
        }
        return points
    }
}
