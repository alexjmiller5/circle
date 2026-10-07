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

    var body: some View {
        VStack(spacing: 0) {
            if let graph = model.graph, let connection = model.connection {
                HStack {
                    if let refreshed = model.refreshedAt {
                        Text("Updated \(refreshed, format: .dateTime.month().day().hour().minute())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connection") { showConnection.toggle() }
                    Button("Refresh") { Task { await model.refresh() } }.disabled(model.busy)
                }.padding(12)
                if model.failure != nil || model.cacheMessage != nil || model.graph?.selfID == nil || showConnection { connectionPanel }
                ExplorerView(graph: graph, profile: connection.preferenceKey)
                    .id("\(model.refreshedAt?.timeIntervalSince1970 ?? 0):\(graph.selfID ?? "")")
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
        .task { await model.restore() }
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let connection = model.connection {
                Text(connection.endpoint).font(.callout).textSelection(.enabled)
                Text("Read-only People connection").foregroundStyle(.secondary)
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
                Button("Disconnect and remove cached people", role: .destructive) {
                    Task { await model.disconnect() }
                }.disabled(model.busy)
            } else {
                TextField("Service URL", text: $endpoint)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("Service URL")
                    .disabled(model.busy)
                Text("Circle requests names, circles, recorded relationships and residence history. Approval happens in your service; Circle never asks for an operator token.")
                    .font(.caption).foregroundStyle(.secondary)
                if let url = model.approvalURL {
                    Link("Approve read-only access", destination: url)
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
