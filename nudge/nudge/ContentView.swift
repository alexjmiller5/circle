import SwiftUI

struct ContentView: View {
    var preview = false

    var body: some View {
        if preview { PreviewCircleView() } else { ConnectedCircleView() }
    }
}

/// Explicit synthetic development entry point; never presented as live data.
struct PreviewCircleView: View {
    @State private var tab = "explorer"
    @State private var reachOut = ReachOutModel(profile: "preview", history: PreviewGraph.history)
    @State private var avatars = CircleAvatars(loader: PreviewGraph.photos)

    var body: some View {
        CircleTabs(explorer: ExplorerView(graph: PreviewGraph.graph),
                   map: PeopleMapView(graph: PreviewGraph.graph, locator: CirclePlaceLocator(cache: nil, geocoder: CircleSystemGeocoder()),
                                      photos: PreviewGraph.photos, isPreview: true),
                   reachOut: ReachOutTab(graph: PreviewGraph.graph),
                   tab: $tab)
            .environment(reachOut)
            .environment(avatars)
            .modifier(ReachOutReminderScheduling(model: reachOut, people: PreviewGraph.graph.people))
    }
}

struct CircleTabs<Explorer: View, PeopleMap: View, ReachOut: View>: View {
    let explorer: Explorer
    let map: PeopleMap
    let reachOut: ReachOut
    /// Owned above any view whose identity resets on refresh.
    @Binding var tab: String
    @Environment(\.circleApp) private var app

    var body: some View {
        TabView(selection: $tab) {
            explorer.tabItem { Label("Explorer", systemImage: "circle.hexagongrid") }.tag("explorer")
            map.overlay(alignment: .bottomTrailing) { appMenu }.tabItem { Label("Map", systemImage: "map") }.tag("map")
            reachOut.overlay(alignment: .bottomTrailing) { appMenu }.tabItem { Label("Reach out", systemImage: "bubble.left.and.bubble.right") }.tag("reachout")
        }
    }

    /// The explorer adds its graph options to the same menu; other tabs carry only the app's.
    @ViewBuilder private var appMenu: some View {
        if app != nil { CircleMenuButton {}.padding(12) }
    }
}

struct ExplorerView: View {
    let graph: SocialGraph
    @State private var state: ExplorerState
    @State private var query = ""
    @State private var trackedIDs: Set<String>
    private let tracking: TrackingPreferencesStore
    @FocusState private var searchFocused: Bool
    @State private var centerRequest = 0
    @State private var showDetails = false
    @State private var positions: [String: GraphPoint]
    private let preferences: UserDefaults
    private let preferenceKey: String
    private let isPreview: Bool

    init(graph: SocialGraph, profile: String = "preview") {
        self.preferenceKey = "explorer-" + profile + "-v1"
        self.isPreview = profile == "preview"
        self.graph = graph
        let preferences = UserDefaults.standard
        self.preferences = preferences
        let tracking = TrackingPreferencesStore(defaults: preferences, profile: profile)
        self.tracking = tracking
        if isPreview && ProcessInfo.processInfo.arguments.contains("--reset-explorer-preferences") {
            preferences.removeObject(forKey: preferenceKey)
            tracking.save([])
        }
        _trackedIDs = State(initialValue: tracking.load())
        var initial = ExplorerState(selfID: graph.selfID)
        ExplorerPreferences(values: preferences.dictionary(forKey: preferenceKey) ?? [:]).apply(to: &initial)
        if ProcessInfo.processInfo.arguments.contains("--reduce-motion") { initial.motion = false }
        _state = State(initialValue: initial)
        _positions = State(initialValue: GraphPositions.make(graph: graph, state: initial))
    }

    private var groups: [GraphGroup] { graph.groups(by: state.grouping, location: state.location) }
    private var focusName: String {
        switch state.focus {
        case .person(let id): return graph.byID[id]?.name ?? "Unknown"
        case .group(let id): return groups.first { $0.id == id }?.name ?? "Unknown"
        case nil: return "Your people"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760
            HStack(spacing: 0) {
                GraphCanvas(graph: graph, state: state, positions: positions, centerRequest: centerRequest, select: select) {
                    CircleMenuButton(value: optionsSummary) { graphOptions }
                }
                .overlay(alignment: .top) { topBar }
                .overlay(alignment: .bottomLeading) { if !wide { focusCard } }
                // Keep the focus centered above the half-height details sheet.
                .padding(.bottom, showDetails && !wide ? geometry.size.height * 0.45 : 0)
                if wide {
                    Divider()
                    ScrollView { details }.frame(width: 280)
                }
            }
        }
        .background(GraphTheme.surface)
        .tint(GraphTheme.accent)
        .sheet(isPresented: $showDetails) {
            NavigationStack {
                ScrollView { details }
                    .navigationTitle(focusName)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showDetails = false } } }
            }
            .presentationDetents([.medium, .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .onChange(of: trackedIDs) { _, ids in tracking.save(ids) }
        .onChange(of: state) { old, new in
            preferences.set(ExplorerPreferences(state: new).values, forKey: preferenceKey)
            if old.layout != new.layout || old.grouping != new.grouping || old.location != new.location ||
                (new.layout == .orbits && old.orbitAnchor != new.orbitAnchor) {
                positions = GraphPositions.make(graph: graph, state: new)
            }
        }
    }

    /// Search, focus history and tracked people float over the full-bleed graph.
    private var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Find a person", text: $query)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("Find a person")
                    .focused($searchFocused).onSubmit { searchFocused = false }
                if isPreview { Text("Synthetic preview").font(.caption).foregroundStyle(.secondary) }
            }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let matches = graph.people.filter { $0.name.localizedStandardContains(trimmed) }
                if matches.isEmpty { Text("No matching people").font(.caption).foregroundStyle(.secondary) }
                chips(matches, id: "search") { select(.person($0.id)); query = "" }
            } else if !trackedIDs.isEmpty {
                chips(graph.people.filter { trackedIDs.contains($0.id) }, id: "tracked") { select(.person($0.id)) }
            }
            HStack(spacing: 8) {
                Button { state.back() } label: { Label("Back", systemImage: "chevron.backward") }.disabled(!state.canGoBack)
                Text("Focus: \(focusName)").font(.caption).lineLimit(1)
                Spacer(minLength: 0)
                Button { if let id = graph.selfID { select(.person(id)) } } label: { Label("Back to me", systemImage: "person.crop.circle") }
                    .disabled(graph.selfID == nil)
            }
            .labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.small)
        }
        .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).padding(10)
    }

    private func chips(_ people: [GraphPerson], id: String, action: @escaping (GraphPerson) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(people) { person in
                    Button { action(person) } label: {
                        HStack(spacing: 6) {
                            CircleAvatar(person: person, size: 22, color: GraphTheme.color(for: person.circles.first ?? person.id))
                            Text(person.name)
                        }
                    }.accessibilityIdentifier("\(id)-\(person.id)")
                }
            }.buttonStyle(.bordered)
        }
    }

    /// Compact layouts keep details one tap away instead of under the graph.
    private var focusCard: some View {
        Button { showDetails = true } label: {
            HStack(spacing: 10) {
                if case .person(let id) = state.focus, let person = graph.byID[id] {
                    CircleAvatar(person: person, size: 40, color: GraphTheme.color(for: person.circles.first ?? person.id))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name).font(.headline).lineLimit(1)
                        Text(person.circles.isEmpty ? "No circles recorded" : person.circles.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(focusName).font(.headline).lineLimit(1)
                        Text("\(graph.members(of: state.focus, grouping: state.grouping, location: state.location).count) people")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up").foregroundStyle(.secondary)
            }
            .padding(12).frame(maxWidth: 360).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain).accessibilityIdentifier("focus-details")
        .padding(.leading, 12).padding(.trailing, 68).padding(.bottom, 12)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            GraphDetails(graph: graph, state: state, trackedIDs: $trackedIDs, select: select)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(state.grouping == .city ? "Cities" : state.grouping == .connections ? "Connected groups" : "Circles")
                    .font(.subheadline.weight(.medium))
                Text("\(graph.people.count) people · \(graph.groups(by: .circles, location: .base).count) circles")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(groups) { group in
                    Button { select(.group(group.id)) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(GraphTheme.color(for: group.id)).frame(width: 7, height: 7)
                            Text(group.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(group.members.count)").foregroundStyle(.secondary)
                        }.padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("group-\(group.id)")
                }
                Text(isPreview ? "Synthetic people and locations" : "Recorded connections · presence not connected")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.subheadline).padding(20)
        }
    }

    private var optionsSummary: String {
        var parts = [state.layout.rawValue.capitalized, "grouped by " + state.grouping.rawValue]
        if state.grouping == .city { parts.append(state.location == .base ? "based in" : "currently in") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var graphOptions: some View {
        Picker("Layout", selection: $state.layout) {
            ForEach(GraphLayout.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }.pickerStyle(.inline)
        Picker("Group by", selection: Binding(get: { state.grouping }, set: { state.setGrouping($0, graph: graph) })) {
            ForEach(GraphGrouping.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }.pickerStyle(.inline).disabled(state.layout != .constellation)
        if state.grouping == .city {
            Picker("Location", selection: Binding(get: { state.location }, set: { state.setLocation($0, graph: graph) })) {
                Text("Based in").tag(LocationMode.base)
                Text("Currently in").tag(LocationMode.current)
            }.pickerStyle(.inline).disabled(state.layout != .constellation)
        }
        Section {
            Toggle("Show group boundaries", isOn: $state.boundaries).disabled(state.layout != .constellation)
            Toggle("Spring motion", isOn: $state.motion)
        }
    }

    private func select(_ focus: GraphFocus) {
        searchFocused = false
        state.select(focus)
        centerRequest &+= 1
    }
}

#Preview("Explorer") { ExplorerView(graph: PreviewGraph.graph) }
#Preview("Unconnected") { ContentView() }
