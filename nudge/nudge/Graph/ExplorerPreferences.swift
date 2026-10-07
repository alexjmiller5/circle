import Foundation

struct ExplorerPreferences: Equatable {
    var layout: GraphLayout = .constellation
    var grouping: GraphGrouping = .circles
    var location: LocationMode = .base
    var boundaries = false
    var motion = true

    init(values: [String: Any]) {
        layout = (values["layout"] as? String).flatMap(GraphLayout.init) ?? .constellation
        grouping = (values["grouping"] as? String).flatMap(GraphGrouping.init) ?? .circles
        location = (values["location"] as? String).flatMap(LocationMode.init) ?? .base
        boundaries = values["boundaries"] as? Bool ?? false
        motion = values["motion"] as? Bool ?? true
    }

    init(state: ExplorerState) {
        layout = state.layout; grouping = state.grouping; location = state.location
        boundaries = state.boundaries; motion = state.motion
    }

    var values: [String: Any] {
        ["layout": layout.rawValue, "grouping": grouping.rawValue, "location": location.rawValue,
         "boundaries": boundaries, "motion": motion]
    }

    func apply(to state: inout ExplorerState) {
        state.layout = layout; state.grouping = grouping; state.location = location
        state.boundaries = boundaries; state.motion = motion
    }
}

struct GraphCamera: Equatable {
    var center = GraphPoint.zero
    private(set) var zoom = 1.0

    mutating func center(on points: [GraphPoint]) {
        guard let first = points.first else { return }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        center = GraphPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    mutating func setZoom(_ value: Double) { zoom = min(3, max(0.25, value)) }
    mutating func pan(x: Double, y: Double) {
        center.x -= x / zoom; center.y -= y / zoom
    }
    func screen(_ point: GraphPoint, width: Double, height: Double) -> GraphPoint {
        GraphPoint(x: (point.x - center.x) * zoom + width / 2,
                   y: (point.y - center.y) * zoom + height / 2)
    }
}
