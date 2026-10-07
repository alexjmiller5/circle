import Foundation

/// App-owned selection keyed by canonical person IDs. Never modifies People circles.
struct TrackingPreferencesStore {
    let defaults: UserDefaults
    let profile: String
    private var key: String { "tracking-v1-\(profile)" }

    func load() -> Set<String> {
        Set((defaults.array(forKey: key) ?? []).compactMap { value in
            guard let id = value as? String, !id.isEmpty else { return nil }
            return id
        })
    }

    func save(_ ids: Set<String>) {
        defaults.set(ids.filter { !$0.isEmpty }.sorted(), forKey: key)
    }
}
