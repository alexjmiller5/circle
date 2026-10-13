import Observation
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// Hands this phone's APNs token to the nearby-alert push service the user runs (a URL they enter).
/// The service decides when a friend is nearby; the phone only needs to be reachable.
@Observable @MainActor final class NearbyAlertsRegistration {
    static let shared = NearbyAlertsRegistration()
    private static let serverKey = "nearby-alerts-server-v1"

    var server: String = UserDefaults.standard.string(forKey: serverKey) ?? "" {
        didSet { UserDefaults.standard.set(server, forKey: Self.serverKey) }
    }
    private(set) var status: String?
    private(set) var busy = false

    /// Asks for notification permission, then for a device token; `deliver` finishes the job.
    func enable() async {
        guard endpoint != nil else { status = "Enter the alerts server's https:// address."; return }
        busy = true
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { busy = false; status = "Notifications are off for Circle. Allow them in Settings."; return }
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        busy = false; status = "Nearby alerts come to the iPhone app."
        #endif
    }

    func deliver(token: Data) async {
        defer { busy = false }
        guard let url = endpoint?.appendingPathComponent("devices") else { status = "Enter the alerts server's https:// address."; return }
        #if DEBUG
        let environment = "development"
        #else
        let environment = "production"
        #endif
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": token.map { String(format: "%02x", $0) }.joined(), "environment": environment])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 204: status = "This phone gets nearby alerts."
            case 403: status = "The alerts server did not accept this phone's tailnet user."
            case let code: status = "The alerts server answered \(code.map(String.init) ?? "nothing")."
            }
        } catch {
            status = "The alerts server could not be reached. Is Tailscale on?"
        }
    }

    func failed(_ error: Error) {
        busy = false
        status = "This build cannot receive push notifications."
    }

    private var endpoint: URL? {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

struct NearbyAlertsSettings: View {
    @State private var registration = NearbyAlertsRegistration.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nearby alerts").font(.headline)
            Text("When a friend arrives in your city, or you arrive in theirs, your alerts server pushes a notification here.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Alerts server (https://...)", text: $registration.server)
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never).keyboardType(.URL)
                #endif
                .accessibilityIdentifier("nearby-alerts-server")
            Button("Send nearby alerts to this phone") { Task { await registration.enable() } }
                .buttonStyle(.bordered).disabled(registration.busy)
            if let status = registration.status { Text(status).font(.caption) }
        }
    }
}

#if os(iOS)
final class CircleAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await NearbyAlertsRegistration.shared.deliver(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in NearbyAlertsRegistration.shared.failed(error) }
    }
}
#endif
