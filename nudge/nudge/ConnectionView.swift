import SwiftUI

struct ConnectedCircleView: View {
    @State private var model = ConnectedCircleView.makeModel()

    private static func makeModel() -> CircleConnectionModel {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CIRCLE_UI_TEST_EMPTY_CONNECTION"] == "1" {
            return CircleConnectionModel(store: EmptyUITestConnectionStore())
        }
        #endif
        return CircleConnectionModel(store: CircleKeychainStore(), cache: .application)
    }
    @State private var endpoint = ""
    @State private var connecting: Task<Void, Never>?
    @State private var showConnection = false
    @State private var identityError: String?
    @State private var tab = "explorer"
    @State private var reachOut: ReachOutModel?
    /// One photo loader and thumbnail cache per connection, kept across refreshes.
    @State private var avatars: CircleAvatars?
    @State private var editor: CircleEditor?

    var body: some View {
        VStack(spacing: 0) {
            if let graph = model.graph, let connection = model.connection {
                if model.failure != nil || model.cacheMessage != nil || graph.selfID == nil { connectionNotice }
                if let reachOut, reachOut.profile == connection.preferenceKey, let avatars {
                    CircleTabs(explorer: ExplorerView(graph: graph, profile: connection.preferenceKey),
                               map: PeopleMapView(graph: graph, locator: Self.locator(connection), photos: avatars.loader, isPreview: false),
                               reachOut: ReachOutTab(graph: graph),
                               tab: $tab)
                        .id("\(model.refreshedAt?.timeIntervalSince1970 ?? 0):\(graph.selfID ?? "")")
                        .environment(reachOut)
                        .environment(avatars)
                        .environment(\.circleEditor, editor)
                        .environment(\.circleApp, CircleAppActions(updated: model.refreshedAt, busy: model.busy,
                                                                    refresh: { Task { await model.refresh() } },
                                                                    showConnection: { showConnection = true }))
                        .modifier(ReachOutReminderScheduling(model: reachOut, people: graph.people))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        Text("Circle").font(.system(.largeTitle, design: .rounded).weight(.semibold))
                        Text("Your circle starts here").font(.title2)
                        Text("Connect your People service to explore your recorded connections.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        connectionPanel
                    }.padding(32).frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $showConnection) {
            NavigationStack {
                ScrollView { connectionPanel }
                    .navigationTitle("Connection")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showConnection = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 360)
            #endif
        }
        .task { await model.restore() }
        .task(id: model.connection?.preferenceKey) {
            reachOut = model.connection.map { ReachOutModel(profile: $0.preferenceKey, history: model.history) }
            avatars = model.connection.map { CircleAvatars(loader: Self.photos($0)) }
            editor = model.connection.flatMap { connection in
                (try? CircleHTTPTransport(endpoint: connection.endpoint, token: connection.token))
                    .flatMap { CircleEditor(client: $0, bindings: connection.bindings) }
            }
            reachOut?.historyFailure = model.historyFailure
        }
        .onChange(of: model.history) { _, value in reachOut?.history = value }
        .onChange(of: model.historyFailure) { _, value in reachOut?.historyFailure = value }
    }

    private static func locator(_ connection: StoredCircleConnection) -> CirclePlaceLocator {
        CirclePlaceLocator(cache: (try? CircleGraphCache.application.placesFile(profile: connection.preferenceKey)).map(CircleGeocodeCache.init(file:)),
                           geocoder: CircleSystemGeocoder())
    }

    /// Photos read through the connection's own credential, only under its granted prefixes.
    private static func photos(_ connection: StoredCircleConnection) -> CirclePhotoLoader? {
        guard let prefixes = connection.bindings.photos?.files,
              let client = try? CircleHTTPTransport(endpoint: connection.endpoint, token: connection.token) else { return nil }
        return CirclePhotoLoader(client: client, prefixes: prefixes,
                                 cache: (try? CircleGraphCache.application.photosDirectory(profile: connection.preferenceKey)).map(CirclePhotoCache.init(directory:)))
    }

    /// One line above the tabs; the full panel stays in the Connection sheet.
    private var connectionNotice: some View {
        let problem = model.failure ?? model.cacheMessage
        return Button { showConnection = true } label: {
            HStack(spacing: 10) {
                Image(systemName: problem == nil ? "person.crop.circle.badge.questionmark" : "exclamationmark.triangle")
                Text(problem ?? "Choose yourself in Connection to anchor Back to me and Orbits.")
                    .font(.callout).lineLimit(3).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(model.failure == nil ? Color.primary : Color.red)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .accessibilityIdentifier("connection-notice")
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let connection = model.connection {
                Text(connection.endpoint).font(.callout).textSelection(.enabled)
                Text(editor == nil ? "Read-only People connection" : "People connection: reads, plus hangout cadence and logged hangouts")
                    .foregroundStyle(.secondary)
                if let graph = model.graph {
                    Picker("My person record", selection: Binding(get: { graph.selfID ?? "" }, set: { value in
                        do { try model.selectSelf(value.isEmpty ? nil : value); identityError = nil }
                        catch { identityError = "The selection could not be saved. Your previous selection is unchanged." }
                    })) {
                        Text("Not selected").tag("")
                        ForEach(graph.people.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { person in
                            Text(person.name).tag(person.id)
                        }
                    }.disabled(model.busy)
                    Text("Choose yourself to anchor Back to me and Orbits. This stays in Circle.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let identityError { Text(identityError).foregroundStyle(.red) }
                }
                if model.graph == nil {
                    Button("Retry loading People") { Task { await model.refresh() } }.disabled(model.busy)
                }
                Divider()
                NearbyAlertsSettings()
                Divider()
                Button("Disconnect and remove cached people", role: .destructive) {
                    Task { await model.disconnect() }
                }.disabled(model.busy)
            } else {
                TextField("Service URL", text: $endpoint)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("Service URL")
                    .disabled(model.busy)
                Text("Circle requests names, circles, recorded relationships, residence history, profile photos, per-channel contact summaries and logged hangouts, plus permission to set a person's hangout cadence and log hangouts. Approval happens in your service; Circle never asks for an operator token.")
                    .font(.caption).foregroundStyle(.secondary)
                if let url = model.approvalURL {
                    Link("Approve access", destination: url).accessibilityValue(url.absoluteString)
                    if let code = model.approvalCode { Text("Approval code: \(code)").textSelection(.enabled) }
                    Text("Waiting for your approval…").font(.caption)
                    Button("Cancel connection") {
                        connecting?.cancel()
                        Task { await model.cancel() }
                    }
                } else {
                    Button("Connect to People") {
                        connecting = Task { await model.connect(endpoint: endpoint) }
                    }.buttonStyle(.borderedProminent).disabled(model.busy || endpoint.isEmpty)
                }
            }
            if model.busy { ProgressView().controlSize(.small) }
            if let failure = model.failure {
                Text(failure).foregroundStyle(.red).accessibilityIdentifier("connection-error")
            }
            if let warning = model.cacheMessage { Text(warning).font(.caption).foregroundStyle(.secondary) }
            if let message = model.cleanupMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.padding(16)
    }
}

#if DEBUG
/// Explicit UI-test entry point never reads or changes the installed session.
@MainActor private final class EmptyUITestConnectionStore: CircleCredentialStore {
    private var value: StoredCircleConnection?
    func load() throws -> StoredCircleConnection? { value }
    func save(_ value: StoredCircleConnection) throws { self.value = value }
    func clear() throws { value = nil }
}
#endif
