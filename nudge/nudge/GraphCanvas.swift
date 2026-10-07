import SwiftUI

// Stable colors derive from canonical group identity, never its current array position.
enum GraphTheme {
    static let accent = Color(red: 0.30, green: 0.43, blue: 0.82)
    static let surface = Color.primary.opacity(0.015)
    static let field = Color.primary.opacity(0.035)
    static func color(for id: String) -> Color {
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo]
        let hash = id.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

struct GraphCanvas: View {
    let graph: SocialGraph
    let state: ExplorerState
    let positions: [String: GraphPoint]
    let centerRequest: Int
    let select: (GraphFocus) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera = GraphCamera()
    @State private var moved: [String: GraphPoint] = [:]
    @GestureState private var pan = CGSize.zero
    @GestureState private var magnification = 1.0

    private var points: [String: GraphPoint] { positions.merging(moved) { _, moved in moved } }
    private var animation: Animation? { reduceMotion || !state.motion ? nil : .spring(response: 0.4, dampingFraction: 0.85) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let points = points
                let screen = screenPositions(points, size: geometry.size)
                ZStack {
                    GraphTheme.field
                    Canvas { context, size in
                        drawGrid(context: &context, size: size)
                        drawGuides(context: &context, screen: screen)
                        for edge in graph.edges {
                            guard let a = screen[edge.from], let b = screen[edge.to] else { continue }
                            if state.layout == .pathways && !edge.isIntroduction { continue }
                            draw(edge: edge, from: a, to: b, context: &context)
                        }
                    }.allowsHitTesting(false)
                    // Clipping alone leaves offscreen macOS AX buttons hittable over adjacent controls.
                    ForEach(graph.people) { person in
                        if let point = screen[person.id], point.x >= 38, point.y >= 33,
                           point.x <= geometry.size.width - 38, point.y <= geometry.size.height - 33 {
                            GraphNode(person: person, selected: state.focus == .person(person.id),
                                      showsName: camera.showsName(selected: state.focus == .person(person.id), magnification: magnification),
                                      color: personColor(person), select: { select(.person(person.id)) },
                                      move: { translation in
                                          guard var point = points[person.id] else { return }
                                          point.x += translation.width / camera.zoom
                                          point.y += translation.height / camera.zoom
                                          moved[person.id] = point
                                      })
                                .position(x: point.x, y: point.y)
                                .zIndex(state.focus == .person(person.id) ? 1 : 0)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped().contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 8)
                    .updating($pan) { value, offset, _ in offset = value.translation }
                    .onEnded { value in camera.pan(x: value.translation.width, y: value.translation.height) })
                .simultaneousGesture(MagnifyGesture()
                    .updating($magnification) { value, scale, _ in scale = value.magnification }
                    .onEnded { value in camera.setZoom(camera.zoom * value.magnification) })

            }
            HStack {
                Text("Tap to center · Drag to explore").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("−") { camera.setZoom(camera.zoom / 1.2) }.accessibilityLabel("Zoom out")
                Text(camera.zoom, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit()).frame(minWidth: 40).accessibilityIdentifier("graph-zoom")
                Button("+") { camera.setZoom(camera.zoom * 1.2) }.accessibilityLabel("Zoom in")
            }.buttonStyle(.bordered).padding(12)
        }
        .onAppear { center() }
        .onChange(of: centerRequest) { _, _ in withAnimation(animation) { center() } }
        .onChange(of: state.focus) { _, _ in withAnimation(animation) { center() } }
        .onChange(of: positions) { _, _ in
            moved = [:]
            withAnimation(animation) { center() }
        }
    }

    private func center() {
        let ids = graph.members(of: state.focus, grouping: state.grouping, location: state.location)
        camera.center(on: ids.compactMap { points[$0] })
    }

    private func screenPositions(_ points: [String: GraphPoint], size: CGSize) -> [String: CGPoint] {
        var transient = camera
        transient.setZoom(camera.zoom * magnification)
        transient.pan(x: pan.width, y: pan.height)
        return points.mapValues {
            let p = transient.screen($0, width: size.width, height: size.height)
            return CGPoint(x: p.x, y: p.y)
        }
    }

    private func personColor(_ person: GraphPerson) -> Color {
        if state.grouping == .city {
            let value = state.location == .base ? person.baseCity : person.currentCity
            return value.map { GraphTheme.color(for: "city:value:" + $0) } ?? .gray
        }
        return person.circles.sorted().first.map { GraphTheme.color(for: "circle:value:" + $0) } ?? .gray
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        for x in stride(from: 12.0, to: size.width, by: 24) {
            for y in stride(from: 12.0, to: size.height, by: 24) {
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.secondary.opacity(0.22)))
            }
        }
    }

    private func drawGuides(context: inout GraphicsContext, screen: [String: CGPoint]) {
        if state.layout == .constellation && state.boundaries {
            for group in graph.groups(by: state.grouping, location: state.location) {
                let points = group.members.compactMap { screen[$0] }
                guard let first = points.first else { continue }
                var rect = CGRect(origin: first, size: .zero)
                for point in points { rect = rect.union(CGRect(origin: point, size: .zero)) }
                rect = rect.insetBy(dx: -38, dy: -42)
                context.fill(Path(roundedRect: rect, cornerRadius: 24), with: .color(GraphTheme.color(for: group.id).opacity(0.08)))
            }
        }
        if state.layout == .orbits, let anchor = state.orbitAnchor, let origin = screen[anchor] {
            let depths = graph.depths(from: anchor)
            let rings = Dictionary(grouping: graph.people, by: { depths[$0.id] ?? -1 })
            for (depth, people) in rings where depth != 0 {
                guard let point = people.first.flatMap({ screen[$0.id] }) else { continue }
                let radius = hypot(point.x - origin.x, point.y - origin.y)
                let rect = CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2)
                context.stroke(Path(ellipseIn: rect), with: .color(.secondary.opacity(0.2)), style: StrokeStyle(lineWidth: 1, dash: depth < 0 ? [4, 5] : []))
            }
        }
    }

    private func draw(edge: GraphEdge, from: CGPoint, to: CGPoint, context: inout GraphicsContext) {
        let distance = max(1, hypot(to.x - from.x, to.y - from.y))
        let fromRadius = camera.showsName(selected: state.focus == .person(edge.from), magnification: magnification) ? 24.0 : 6.0
        let toRadius = camera.showsName(selected: state.focus == .person(edge.to), magnification: magnification) ? 28.0 : 8.0
        guard distance > fromRadius + toRadius else { return }
        let dx = (to.x - from.x) / distance, dy = (to.y - from.y) / distance
        let start = CGPoint(x: from.x + dx * fromRadius, y: from.y + dy * fromRadius)
        let end = CGPoint(x: to.x - dx * toRadius, y: to.y - dy * toRadius)
        var path = Path(); path.move(to: start); path.addLine(to: end)
        let active = state.focus == .person(edge.from) || state.focus == .person(edge.to)
        let color = active ? GraphTheme.accent.opacity(0.7) : Color.secondary.opacity(0.24)
        context.stroke(path, with: .color(color), lineWidth: active ? 1.6 : 1)
        if edge.isIntroduction {
            var arrow = Path()
            arrow.move(to: CGPoint(x: end.x - dx * 8 - dy * 4, y: end.y - dy * 8 + dx * 4))
            arrow.addLine(to: end)
            arrow.addLine(to: CGPoint(x: end.x - dx * 8 + dy * 4, y: end.y - dy * 8 - dx * 4))
            context.stroke(arrow, with: .color(color), lineWidth: 1.4)
        }
    }
}

private struct GraphNode: View {
    let person: GraphPerson
    let selected: Bool
    let showsName: Bool
    let color: Color
    let select: () -> Void
    let move: (CGSize) -> Void
    @GestureState private var translation = CGSize.zero

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                if showsName {
                    Text(person.name == "You" ? "You" : String(person.name.split(separator: " ").compactMap(\.first)))
                        .font(.caption.weight(.semibold)).foregroundStyle(.primary)
                        .frame(width: 42, height: 42)
                        .background(color.opacity(0.18), in: Circle())
                        .overlay(Circle().stroke(selected ? GraphTheme.accent : color.opacity(0.3), lineWidth: selected ? 2.5 : 1))
                    Text(person.name).font(.caption).lineLimit(1)
                } else {
                    Circle().fill(color.opacity(0.6)).frame(width: 12, height: 12)
                }
            }.frame(width: showsName ? 76 : 44, height: showsName ? 66 : 44).contentShape(Rectangle())
        }.buttonStyle(.plain).offset(translation)
            .accessibilityLabel(person.name).accessibilityIdentifier("person-\(person.id)")
            .accessibilityValue(selected ? "Selected" : "")
            .highPriorityGesture(DragGesture(minimumDistance: 8)
                .updating($translation) { value, offset, _ in offset = value.translation }
                .onEnded { value in move(value.translation) })
    }
}
