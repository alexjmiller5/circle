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

struct GraphCanvas<Accessory: View>: View {
    let graph: SocialGraph
    let state: ExplorerState
    let positions: [String: GraphPoint]
    let centerRequest: Int
    let select: (GraphFocus) -> Void
    @ViewBuilder var accessory: Accessory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera = GraphCamera()
    @State private var moved: [String: GraphPoint] = [:]
    // A gesture moves and scales the layer already rendered for `camera` (no per-frame
    // layout of every person) and commits to the camera in steps the layer's margin covers.
    @State private var drag = CGSize.zero
    @State private var dragApplied = CGSize.zero
    @State private var dragging = false
    @State private var flings = 0
    @State private var scale = 1.0
    @State private var scaleApplied = 1.0

    private var points: [String: GraphPoint] { positions.merging(moved) { _, moved in moved } }
    private var animation: Animation? { reduceMotion || !state.motion ? nil : .spring(response: 0.4, dampingFraction: 0.85) }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            GraphLayer(graph: graph, state: state, points: points, camera: camera, size: size, select: select, move: move)
                .equatable()
                .frame(width: size.width * 2, height: size.height * 2)
                .offset(drag)
                .scaleEffect(scale)
                .frame(width: size.width, height: size.height)
                .clipped().contentShape(Rectangle())
                .gesture(pan(size))
                .simultaneousGesture(magnify)
        }
        .background(GraphTheme.field)
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 10) {
                VStack(spacing: 0) {
                    Button { zoom(1.2) } label: { Image(systemName: "plus").frame(width: 44, height: 38).contentShape(Rectangle()) }
                        .accessibilityLabel("Zoom in")
                    Text(camera.zoom, format: .percent.precision(.fractionLength(0)))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).accessibilityIdentifier("graph-zoom")
                    Button { zoom(1 / 1.2) } label: { Image(systemName: "minus").frame(width: 44, height: 38).contentShape(Rectangle()) }
                        .accessibilityLabel("Zoom out")
                }
                .buttonStyle(.plain).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                accessory
            }.padding(12)
        }
        .onAppear { center() }
        .onChange(of: centerRequest) { _, _ in settle(); withAnimation(animation) { center() } }
        .onChange(of: state.focus) { _, _ in settle(); withAnimation(animation) { center() } }
        .onChange(of: positions) { _, _ in
            settle(); moved = [:]
            withAnimation(animation) { center() }
        }
    }

    /// Finger-tracking pan with momentum. The layer renders half a viewport past every edge.
    private func pan(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !dragging { dragging = true; settle(); dragApplied = .zero }
                var live = CGSize(width: value.translation.width - dragApplied.width, height: value.translation.height - dragApplied.height)
                if abs(live.width) > size.width / 4 || abs(live.height) > size.height / 4 {
                    camera.pan(x: live.width, y: live.height)
                    dragApplied = value.translation
                    live = .zero
                }
                drag = live
            }
            .onEnded { value in
                dragging = false
                let fling = CGSize(width: value.predictedEndTranslation.width - value.translation.width,
                                   height: value.predictedEndTranslation.height - value.translation.height)
                let target = CGSize(width: min(max(drag.width + fling.width, -size.width / 2), size.width / 2),
                                    height: min(max(drag.height + fling.height, -size.height / 2), size.height / 2))
                guard animation != nil else { settle(); return }
                flings += 1
                let id = flings
                withAnimation(.easeOut(duration: 0.45), completionCriteria: .logicallyComplete) { drag = target } completion: {
                    if id == flings && !dragging { settle() }
                }
            }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                var live = value.magnification / scaleApplied
                if live < 0.6 || live > 1.6 {
                    camera.setZoom(camera.zoom * live)
                    scaleApplied = value.magnification
                    live = 1
                }
                scale = live
            }
            .onEnded { value in
                camera.setZoom(camera.zoom * value.magnification / scaleApplied)
                scaleApplied = 1; scale = 1
            }
    }

    /// Moves any pending layer offset into the camera.
    private func settle() {
        flings += 1
        guard drag != .zero else { return }
        camera.pan(x: drag.width, y: drag.height)
        drag = .zero
    }

    private func zoom(_ factor: Double) {
        settle()
        camera.setZoom(camera.zoom * factor)
    }

    private func move(_ id: String, _ translation: CGSize) {
        guard var point = points[id] else { return }
        point.x += translation.width / camera.zoom
        point.y += translation.height / camera.zoom
        moved[id] = point
    }

    private func center() {
        let ids = graph.members(of: state.focus, grouping: state.grouping, location: state.location)
        camera.center(on: ids.compactMap { points[$0] })
    }

}

/// Everything drawn for one committed camera, twice the viewport in each dimension. Equatable so a
/// live gesture (an offset or scale on this layer) never re-lays out the people.
private struct GraphLayer: View, Equatable {
    let graph: SocialGraph
    let state: ExplorerState
    let points: [String: GraphPoint]
    let camera: GraphCamera
    let size: CGSize
    let select: (GraphFocus) -> Void
    let move: (String, CGSize) -> Void

    // The graph is fixed for a canvas's lifetime (the explorer is rebuilt on refresh);
    // the closures write through view state, so a stale copy still acts on the current view.
    static func == (a: Self, b: Self) -> Bool {
        a.state == b.state && a.camera == b.camera && a.size == b.size && a.points == b.points
    }

    var body: some View {
        let width = size.width * 2, height = size.height * 2
        let screen = points.mapValues { point in
            let p = camera.screen(point, width: width, height: height)
            return CGPoint(x: p.x, y: p.y)
        }
        let viewport = CGRect(x: size.width / 2, y: size.height / 2, width: size.width, height: size.height)
        ZStack {
            Canvas { context, size in
                drawGrid(context: &context, size: size)
                drawGuides(context: &context, screen: screen)
                for edge in graph.edges {
                    guard let a = screen[edge.from], let b = screen[edge.to] else { continue }
                    if state.layout == .pathways && !edge.isIntroduction { continue }
                    draw(edge: edge, from: a, to: b, context: &context)
                }
            }.allowsHitTesting(false)
            ForEach(graph.people) { person in
                if let point = screen[person.id], point.x >= 38, point.y >= 33, point.x <= width - 38, point.y <= height - 33 {
                    let selected = state.focus == .person(person.id)
                    GraphNode(person: person, selected: selected, showsName: camera.showsName(selected: selected),
                              color: personColor(person), select: { select(.person(person.id)) },
                              move: { move(person.id, $0) })
                        .position(x: point.x, y: point.y)
                        .zIndex(selected ? 1 : 0)
                        // Offscreen margin nodes must not be hittable accessibility elements over adjacent controls.
                        .accessibilityHidden(!viewport.contains(point))
                }
            }
        }.frame(width: width, height: height)
    }

    private func personColor(_ person: GraphPerson) -> Color {
        if state.grouping == .city {
            let value = state.location == .base ? person.baseCity : person.currentCity
            return value.map { GraphTheme.color(for: "city:value:" + $0) } ?? .gray
        }
        return person.circles.sorted().first.map { GraphTheme.color(for: "circle:value:" + $0) } ?? .gray
    }

    /// Dots anchored to the world, so committing a pan never makes the grid jump.
    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let origin = camera.screen(.zero, width: size.width, height: size.height)
        let phaseX = origin.x.truncatingRemainder(dividingBy: 24) + 24, phaseY = origin.y.truncatingRemainder(dividingBy: 24) + 24
        for x in stride(from: phaseX.truncatingRemainder(dividingBy: 24), to: size.width, by: 24) {
            for y in stride(from: phaseY.truncatingRemainder(dividingBy: 24), to: size.height, by: 24) {
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
        let fromRadius = camera.showsName(selected: state.focus == .person(edge.from)) ? 24.0 : 6.0
        let toRadius = camera.showsName(selected: state.focus == .person(edge.to)) ? 28.0 : 8.0
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
        VStack(spacing: 4) {
            if showsName {
                CircleAvatar(person: person, size: 42, color: color)
                    .overlay(Circle().stroke(selected ? GraphTheme.accent : color.opacity(0.45), lineWidth: selected ? 2.5 : 1.5))
                Text(person.name).font(.caption).lineLimit(1)
            } else {
                Circle().fill(color.opacity(0.6)).frame(width: 12, height: 12)
            }
        }
        .frame(width: showsName ? 76 : 44, height: showsName ? 66 : 44).contentShape(Rectangle())
        // A tap, not a Button: a button still fires on release after a short swipe, recentering mid-pan.
        .onTapGesture(perform: select)
        .offset(translation)
        .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
        .accessibilityLabel(person.name).accessibilityIdentifier("person-\(person.id)")
        .accessibilityValue(selected ? "Selected" : "").accessibilityAction { select() }
        #if os(macOS)
            // Pointer only: on touch a swipe that starts on a person must pan the graph.
            .highPriorityGesture(DragGesture(minimumDistance: 8)
                .updating($translation) { value, offset, _ in offset = value.translation }
                .onEnded { value in move(value.translation) })
        #endif
    }
}
