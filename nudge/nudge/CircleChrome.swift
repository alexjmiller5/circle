import SwiftUI

/// Small decoded profile photos shared by the graph and the map. Bytes come through the
/// connection's photo loader (verified disk cache first); only thumbnails stay in memory.
@Observable @MainActor final class CircleAvatars {
    private(set) var images: [String: CGImage] = [:]
    @ObservationIgnored private var loading = Set<String>()
    @ObservationIgnored let loader: CirclePhotoLoader?

    init(loader: CirclePhotoLoader?) { self.loader = loader }

    func image(_ person: GraphPerson) -> CGImage? { person.photoChoices.first.flatMap { images[$0.key] } }

    func load(_ person: GraphPerson) async {
        guard let loader, let photo = person.photoChoices.first, images[photo.key] == nil,
              loading.insert(photo.key).inserted else { return }
        defer { loading.remove(photo.key) }
        guard case .image(let data) = await loader.load(photo), !Task.isCancelled,
              let image = await Task.detached(operation: { CirclePhotoLoader.thumbnail(data, maxPixels: 144) }).value else { return }
        // ponytail: crude bound on memory; an LRU if panning the whole graph ever thrashes it.
        if images.count >= 500 { images.removeAll() }
        images[photo.key] = image
    }
}

struct CircleAvatar: View {
    let person: GraphPerson
    let size: CGFloat
    let color: Color
    @Environment(CircleAvatars.self) private var avatars: CircleAvatars?

    var body: some View {
        ZStack {
            if let image = avatars?.image(person) {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Circle().fill(color.opacity(0.18))
                Text(initials).font(.system(size: size * 0.32, weight: .semibold)).foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .task(id: person.photoChoices.first?.key) { await avatars?.load(person) }
    }

    private var initials: String {
        person.name == "You" ? "You" : person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// App-wide actions the connected view offers from every tab's menu.
struct CircleAppActions {
    let updated: Date?
    let busy: Bool
    let refresh: () -> Void
    let showConnection: () -> Void
}

extension EnvironmentValues {
    @Entry var circleApp: CircleAppActions? = nil
}

/// The small bottom-right menu: the tab's own options, then the app's.
struct CircleMenuButton<Options: View>: View {
    /// Spoken state of the tab's options, e.g. the explorer's layout and grouping.
    var value = ""
    @ViewBuilder var options: Options
    @Environment(\.circleApp) private var app

    var body: some View {
        Menu {
            options
            if let app {
                Section {
                    Button("Refresh", systemImage: "arrow.clockwise", action: app.refresh).disabled(app.busy)
                    Button("Connection", systemImage: "link", action: app.showConnection)
                    if let updated = app.updated {
                        Text("Updated \(updated, format: .dateTime.month().day().hour().minute())")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.primary)
                .frame(width: 44, height: 44).background(.regularMaterial, in: Circle())
                .contentShape(Circle())
        }
        .menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
        .accessibilityLabel("Circle menu").accessibilityValue(value).accessibilityIdentifier("circle-menu")
    }
}
