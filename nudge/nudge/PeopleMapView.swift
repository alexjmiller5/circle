import MapKit
import SwiftUI

struct PeopleMapView: View {
    let graph: SocialGraph
    let locator: CirclePlaceLocator
    let photos: CirclePhotoLoader?
    let isPreview: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var coordinates: [String: CircleCoordinate] = [:]
    @State private var locating = 0
    @State private var unlocated = 0
    @State private var circle: String?
    @State private var selected: GraphPerson?
    @State private var camera: MapCameraPosition = .automatic

    private var pins: [CircleMapPin] { CirclePeopleMap.pins(graph: graph, coordinates: coordinates, circle: circle) }
    private var animation: Animation? {
        reduceMotion || ProcessInfo.processInfo.arguments.contains("--reduce-motion") ? nil : .easeInOut(duration: 0.4)
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 760 {
                HStack(spacing: 0) {
                    map
                    Divider()
                    ScrollView { panel }.frame(width: 320)
                }
            } else {
                VStack(spacing: 0) {
                    map.frame(height: max(280, geometry.size.height * 0.5))
                    Divider()
                    ScrollView { panel }
                }
            }
        }
        .sheet(item: $selected) { person in PersonMapSheet(person: person, photos: photos, isPreview: isPreview) }
        .task { await locate() }
    }

    private var map: some View {
        Map(position: $camera) {
            ForEach(pins) { pin in
                Annotation(pin.name, coordinate: CLLocationCoordinate2D(latitude: pin.coordinate.latitude, longitude: pin.coordinate.longitude)) {
                    Button { selected = graph.byID[pin.id] } label: {
                        Text(initials(pin.name)).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(GraphTheme.color(for: graph.byID[pin.id]?.circles.first ?? pin.id), in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(pin.name), based in \(pin.place.query)")
                    .accessibilityIdentifier("pin-\(pin.id)")
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass(); MapScaleView() }
        .accessibilityLabel("Map of current bases")
    }

    private var panel: some View {
        let mapped = Set(CirclePeopleMap.pins(graph: graph, coordinates: coordinates, circle: nil).map(\.id))
        let circles = CirclePeopleMap.circles(graph: graph)
        let conflicting = graph.people.filter { $0.basePlace == nil && $0.baseHistory.contains { $0.end == nil } }.count
        let unknown = graph.people.filter { $0.basePlace == nil }.count - conflicting
        let unplaced = locating > 0 ? 0 : graph.people.filter { $0.basePlace.map { coordinates[$0.key] == nil } ?? false }.count
        return VStack(alignment: .leading, spacing: 14) {
            Text("People map").font(.system(.title2, design: .rounded).weight(.semibold))
            Text("\(pins.count) \(pins.count == 1 ? "person" : "people") pinned at a current base")
                .font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                if locating > 0 {
                    Label("Locating \(locating) \(locating == 1 ? "base" : "bases")…", systemImage: "location.magnifyingglass")
                } else if unlocated > 0 {
                    Label("\(unlocated) \(unlocated == 1 ? "base" : "bases") could not be located now. Circle tries again next time.",
                          systemImage: "exclamationmark.triangle")
                }
                if unplaced > 0 { Text("\(unplaced) with a base the map could not place") }
                Text("\(unknown) with no recorded current base")
                if conflicting > 0 { Text("\(conflicting) with conflicting current bases, left unpinned") }
                Text("Pins are city-level and spread apart so each stays tappable. Presence is not shown.")
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Circle").foregroundStyle(.secondary)
                Picker("Circle", selection: Binding(get: { circle }, set: { value in
                    circle = value; fit()
                })) {
                    Text("All circles").tag(String?.none)
                    ForEach(circles, id: \.name) { item in Text("\(item.name) · \(item.count)").tag(Optional(item.name)) }
                }
                .pickerStyle(.menu).labelsHidden().accessibilityIdentifier("map-circle-filter")
            }
            if let circle {
                Text("People in \(circle)").font(.headline)
                ForEach(graph.people.filter { $0.circles.contains(circle) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { person in
                    row(person.name, detail: person.basePlace?.query ?? "No known base") { selected = person }
                        .accessibilityIdentifier("map-person-\(person.id)")
                }
            } else {
                Text("Met where").font(.headline)
                Text("Circles record how and where you met people. A place-named circle means you met there, not that they live there.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(circles, id: \.name) { item in
                    let count = graph.people.filter { mapped.contains($0.id) && $0.circles.contains(item.name) }.count
                    row(item.name, detail: "\(count) of \(item.count) pinned") {
                        circle = item.name; fit()
                    }
                    .accessibilityIdentifier("map-circle-\(item.name)")
                }
            }
            Text(isPreview ? "Synthetic people at public city locations" : "Residence from People · presence not connected")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }.font(.subheadline).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// Frames every visible pin; a lone city still shows its surroundings.
    private func fit() {
        let latitudes = pins.map(\.coordinate.latitude), longitudes = pins.map(\.coordinate.longitude)
        guard let south = latitudes.min(), let north = latitudes.max(),
              let west = longitudes.min(), let east = longitudes.max() else { return }
        // A camera distance, unlike a region, can zoom out to the globe when people span continents.
        let middle = (south + north) / 2
        let widthKm = (east - west) * 111 * max(cos(middle * .pi / 180), 0.2), heightKm = (north - south) * 111
        let camera = MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: middle, longitude: (west + east) / 2),
                               distance: min(max(max(widthKm, heightKm) * 2_000, 60_000), 40_000_000))
        withAnimation(animation) { self.camera = .camera(camera) }
    }

    /// Cached bases appear at once; the rest are geocoded one at a time to respect the system rate limit.
    private func locate() async {
        let (found, missing) = locator.cached(graph.people.compactMap(\.basePlace), now: Date())
        coordinates = found
        fit()
        locating = missing.count
        var failures = 0
        for place in missing {
            guard !Task.isCancelled, failures < 3 else { break }
            do {
                if let coordinate = try await locator.lookup(place, now: Date()) { coordinates[place.key] = coordinate }
                failures = 0
            } catch {
                failures += 1; unlocated += 1
            }
            locating -= 1
            try? await Task.sleep(for: .milliseconds(1300))
        }
        unlocated += locating
        locating = 0
        if !missing.isEmpty { fit() }
    }
}

struct PersonMapSheet: View {
    let person: GraphPerson
    let photos: CirclePhotoLoader?
    let isPreview: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(ReachOutModel.self) private var reachOut: ReachOutModel?
    @State private var platform: String?
    @State private var result: CirclePhotoResult?

    private var photo: GraphPhoto? {
        person.photoChoices.first { $0.platform == platform } ?? person.photoChoices.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") { photoSection }
                Section("Met where") {
                    Text(person.circles.isEmpty ? "No circles recorded" : person.circles.joined(separator: " · "))
                    Text("Circles say how and where you met, never where someone lives.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Based in") {
                    if let place = person.basePlace { Text(place.query) }
                    else if person.baseHistory.contains(where: { $0.end == nil }) { Text("Unknown: conflicting current bases") }
                    else { Text("Unknown") }
                }
                Section("Base history") {
                    if person.baseHistory.isEmpty { Text("No residence recorded").foregroundStyle(.secondary) }
                    ForEach(Array(person.baseHistory.enumerated()), id: \.offset) { _, residence in
                        LabeledContent(CirclePlace(city: residence.city ?? "", country: residence.country).query.nonEmpty ?? "Unknown place",
                                       value: period(residence))
                    }
                }
                Section("Hometown") {
                    Text("Unknown")
                    Text("Hometown is not shared with Circle.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Currently in") {
                    Text(person.presence)
                    Text(isPreview ? "Synthetic preview presence." : "Presence is not connected. A base is not a current location.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if reachOut != nil { ReachOutSections(person: person) }
            }
            .formStyle(.grouped)
            .navigationTitle(person.name)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 560)
        #endif
        .task(id: photo?.key) {
            result = nil
            guard let photo, let photos else { return }
            result = await photos.load(photo)
        }
    }

    @ViewBuilder private var photoSection: some View {
        let choices = person.photoChoices
        if let photo {
            HStack(spacing: 16) {
                photoImage.frame(width: 96, height: 96).clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(platformName(photo.platform)).font(.headline)
                    if let fetched = photo.fetchedAt { Text("Fetched \(String(fetched.prefix(10)))").font(.caption).foregroundStyle(.secondary) }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if choices.count > 1 {
                Picker("Photo from", selection: Binding(get: { photo.platform }, set: { platform = $0 })) {
                    ForEach(choices, id: \.platform) { Text(platformName($0.platform)).tag($0.platform) }
                }.accessibilityIdentifier("photo-platform")
            }
        } else {
            Text("No profile photo recorded").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var photoImage: some View {
        if case .image(let data) = result, let image = platformImage(data) {
            image.resizable().scaledToFill()
                .accessibilityLabel("Profile photo from \(platformName(photo?.platform ?? ""))")
        } else {
            ZStack {
                Circle().fill(GraphTheme.color(for: person.circles.first ?? person.id).opacity(0.25))
                if result == nil && photos != nil { ProgressView() }
                else { Image(systemName: "person.fill").font(.title).foregroundStyle(.secondary) }
            }.accessibilityHidden(true)
        }
    }

    private var message: String? {
        switch result {
        case .notShared: "Stored outside the photos Circle may read."
        case .unavailable: "Unavailable right now."
        case .image, nil: photos == nil ? (isPreview ? "Preview has no photos." : "Connect to load photos.") : nil
        }
    }

    private func platformImage(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }

    private func platformName(_ value: String) -> String { CirclePeopleMap.platformName(value) }

    private func period(_ residence: GraphResidence) -> String {
        switch (residence.start, residence.end) {
        case (nil, nil): "Current"
        case (let start?, nil): "\(start) to now"
        case (nil, let end?): "until \(end)"
        case (let start?, let end?): "\(start) to \(end)"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

#Preview("Map") {
    PeopleMapView(graph: PreviewGraph.graph, locator: CirclePlaceLocator(cache: nil, geocoder: CircleSystemGeocoder()),
                  photos: nil, isPreview: true)
}
#Preview("Person") { PersonMapSheet(person: PreviewGraph.graph.people[1], photos: nil, isPreview: true) }
