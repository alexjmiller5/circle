import SwiftUI

@main
struct CircleApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(CircleAppDelegate.self) private var delegate
    #endif
    init() { ReachOutNotifications.shared.register() }

    var body: some Scene {
        WindowGroup {
            ContentView(preview: ProcessInfo.processInfo.arguments.contains("--preview-graph"))
        }
        .defaultSize(width: 1100, height: 840)
    }
}
