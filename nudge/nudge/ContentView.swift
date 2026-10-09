import SwiftUI

struct ContentView: View {
    var preview = false
    @State private var tab = "explorer"

    var body: some View {
        if preview {
            CircleTabs(explorer: ExplorerView(graph: PreviewGraph.graph),
                       map: PeopleMapView(graph: PreviewGraph.graph, locator: CirclePlaceLocator(cache: nil, geocoder: CircleSystemGeocoder()),
                                          photos: nil, isPreview: true),
                       tab: $tab)
        } else {
            ConnectedCircleView()
        }
    }
}

struct CircleTabs<Explorer: View, PeopleMap: View>: View {
    let explorer: Explorer
    let map: PeopleMap
    /// Owned above any view whose identity resets on refresh.
    @Binding var tab: String

    var body: some View {
        TabView(selection: $tab) {
            explorer.tabItem { Label("Explorer", systemImage: "circle.hexagongrid") }.tag("explorer")
            map.tabItem { Label("Map", systemImage: "map") }.tag("map")
        }
    }
}

struct ExplorerView: View {
    let graph: SocialGraph
    @State private var state: ExplorerState
    @State private var query = ""
    @State private var trackedIDs: Set<String>
    private let tracking: TrackingPreferencesStore
    @State private var reachOutPreferences: [String: ReachOutPreferences]
    @State private var settingsError: String?
    @State private var showReachOut = false
    private let reachOutStore: ReachOutPreferencesStore
    @FocusState private var searchFocused: Bool
    @State private var centerRequest = 0
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
        let reachOutStore = ReachOutPreferencesStore(defaults: preferences, profile: profile)
        self.reachOutStore = reachOutStore
        if isPreview && ProcessInfo.processInfo.arguments.contains("--reset-explorer-preferences") {
            preferences.removeObject(forKey: preferenceKey)
            tracking.save([])
            try? reachOutStore.save([:])
        }
        _trackedIDs = State(initialValue: tracking.load())
        do { _reachOutPreferences = State(initialValue: try reachOutStore.load()) }
        catch {
            _reachOutPreferences = State(initialValue: [:])
            _settingsError = State(initialValue: "Saved preferences could not be read. Editing is paused to preserve them.")
        }
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
            ScrollView {
                VStack(spacing: 0) {
                    header
                    controls
                    if geometry.size.width >= 760 {
                        HStack(alignment: .top, spacing: 0) {
                            graphColumn.frame(maxWidth: .infinity)
                            Divider()
                            GraphDetails(graph: graph, state: state, trackedIDs: $trackedIDs, select: select).frame(width: 248)
                        }
                    } else {
                        graphColumn
                        Divider()
                        GraphDetails(graph: graph, state: state, trackedIDs: $trackedIDs, select: select)
                    }
                    HStack {
                        Toggle("Spring motion", isOn: $state.motion).fixedSize()
                        Spacer()
                        Text(isPreview ? "Synthetic people and locations" : "Recorded connections · presence not connected").foregroundStyle(.secondary)
                    }.font(.caption).padding(16)
                }
                .frame(maxWidth: 1400)
                .frame(maxWidth: .infinity)
            }
        }
        .background(GraphTheme.surface)
        .tint(GraphTheme.accent)
        .sheet(isPresented: $showReachOut) {
            ReachOutView(graph: graph, trackedIDs: trackedIDs, preferences: $reachOutPreferences, settingsError: settingsError)
        }
        .onChange(of: reachOutPreferences) { _, values in
            guard settingsError == nil else { return }
            do { try reachOutStore.save(values) }
            catch { settingsError = "Preferences could not be saved." }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Circle").font(.system(.title3, design: .rounded).weight(.semibold))
                Spacer()
                Button("Reach out") { showReachOut = true }.buttonStyle(.bordered)
                Text(isPreview ? "Synthetic preview" : "People").font(.caption).foregroundStyle(.secondary)
            }
            Text("Your people").font(.system(.largeTitle, design: .rounded).weight(.semibold))
            Text("\(graph.people.count) people · \(graph.groups(by: .circles, location: .base).count) circles")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("Find a person", text: $query)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("Find a person")
                .focused($searchFocused).onSubmit { searchFocused = false }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let matches = graph.people.filter { $0.name.localizedStandardContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if matches.isEmpty { Text("No matching people").foregroundStyle(.secondary) }
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(matches) { person in
                            Button(person.name) { select(.person(person.id)); query = "" }
                                .accessibilityIdentifier("search-\(person.id)")
                        }
                    }.buttonStyle(.bordered)
                }
            }
            if !trackedIDs.isEmpty {
                Text("Tracked people").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(graph.people.filter { trackedIDs.contains($0.id) }) { person in
                            Button(person.name) { select(.person(person.id)) }
                                .accessibilityIdentifier("tracked-\(person.id)")
                        }
                    }.buttonStyle(.bordered)
                }
            }
            HStack(spacing: 4) {
                ForEach(GraphLayout.allCases, id: \.self) { layout in
                    choice(layout.rawValue.capitalized, selected: state.layout == layout, id: "layout-\(layout.rawValue)") {
                        state.layout = layout
                    }
                }
            }
        }.padding(20)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Group by").font(.caption).foregroundStyle(.secondary)
                ForEach(GraphGrouping.allCases, id: \.self) { group in
                    Button(group.rawValue.capitalized) { state.setGrouping(group, graph: graph) }
                        .buttonStyle(.bordered)
                        .tint(state.grouping == group ? GraphTheme.accent : .secondary)
                        .accessibilityIdentifier("grouping-\(group.rawValue)")
                        .accessibilityValue(state.grouping == group ? "Selected" : "")
                }
            }.disabled(state.layout != .constellation)
            if state.grouping == .city {
                HStack {
                    choice("Based in", selected: state.location == .base, id: "location-base") { state.setLocation(.base, graph: graph) }
                    choice("Currently in", selected: state.location == .current, id: "location-current") { state.setLocation(.current, graph: graph) }
                }.disabled(state.layout != .constellation)
            }
            Toggle("Show group boundaries", isOn: $state.boundaries)
                .font(.caption).fixedSize().disabled(state.layout != .constellation)
            if state.layout == .orbits {
                Text("Distance from \(state.orbitAnchor.flatMap { graph.byID[$0]?.name } ?? "Unknown") · unconnected people on the outer ring")
                    .font(.caption).foregroundStyle(.secondary)
            } else if state.layout == .pathways {
                Text("Arrows follow recorded introductions").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(GraphTheme.field)
    }

    private var graphColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Back") { state.back() }.disabled(!state.canGoBack)
                Text("Focus: \(focusName)").font(.caption).lineLimit(1)
                Spacer(minLength: 0)
                Button("Back to me") { if let id = graph.selfID { select(.person(id)) } }.disabled(graph.selfID == nil)
            }.buttonStyle(.bordered).padding(12)
            GraphCanvas(graph: graph, state: state, positions: positions, centerRequest: centerRequest, select: select)
                .frame(height: 440)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(groups) { group in
                        Button { select(.group(group.id)) } label: {
                            HStack(spacing: 5) {
                                Circle().fill(GraphTheme.color(for: group.id)).frame(width: 7, height: 7)
                                Text(group.name)
                                Text("\(group.members.count)").foregroundStyle(.secondary)
                            }.padding(.vertical, 10)
                        }.buttonStyle(.plain).accessibilityIdentifier("group-\(group.id)")
                    }
                }.font(.caption).padding(.horizontal, 16)
            }
        }
    }

    private func select(_ focus: GraphFocus) {
        searchFocused = false
        state.select(focus)
        centerRequest &+= 1
    }

    private func choice(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline).padding(.vertical, 12).frame(maxWidth: .infinity)
                .background(selected ? GraphTheme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).foregroundStyle(selected ? GraphTheme.accent : .primary)
            .accessibilityIdentifier(id).accessibilityValue(selected ? "Selected" : "")
    }
}

#Preview("Explorer") { ExplorerView(graph: PreviewGraph.graph) }
#Preview("Unconnected") { ContentView() }
