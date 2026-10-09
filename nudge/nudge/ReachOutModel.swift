import Foundation
import Observation
import UserNotifications

extension Notification.Name {
    /// Posted when reach-out settings change outside the open views (a notification's Snooze action).
    static let circleReachOutChanged = Notification.Name("circle.reachout.changed")
}

/// Per-profile reach-out state shared by the Reach out tab and person sheets.
@Observable @MainActor final class ReachOutModel {
    let profile: String
    let isPreview: Bool
    var history: CommunicationHistory?
    var historyFailure: String?
    var preferences: [String: ReachOutPreferences] = [:] {
        didSet { guard settingsError == nil else { return }; persist() }
    }
    var reminders = ReminderSettings() {
        didSet { store.saveReminders(reminders); revision += 1 }
    }
    private(set) var trackedIDs: Set<String> = []
    private(set) var settingsError: String?
    private(set) var reminderMessage: String?
    /// Changes whenever reminders need recomputing.
    private(set) var revision = 0
    private let store: ReachOutPreferencesStore
    private let tracking: TrackingPreferencesStore
    /// Synthetic settings are reset once per launch, not every time a view rebuilds.
    private static var didResetPreview = false

    init(profile: String, history: CommunicationHistory? = nil, defaults: UserDefaults = .standard) {
        self.profile = profile
        self.isPreview = profile == "preview"
        self.history = history
        store = ReachOutPreferencesStore(defaults: defaults, profile: profile)
        tracking = TrackingPreferencesStore(defaults: defaults, profile: profile)
        if isPreview && !Self.didResetPreview && ProcessInfo.processInfo.arguments.contains("--reset-explorer-preferences") {
            Self.didResetPreview = true
            try? store.save([:])
            store.saveReminders(ReminderSettings())
            store.saveLedger([])
        }
        reload()
    }

    func reload() {
        do { preferences = try store.load(); settingsError = nil }
        catch { settingsError = "Saved reach-out settings could not be read. Editing is paused to preserve them." }
        reminders = store.loadReminders()
        trackedIDs = tracking.load()
    }

    func settings(_ id: String) -> ReachOutPreferences { preferences[id] ?? ReachOutPreferences() }

    func assessment(_ id: String, now: Date = Date()) -> ReachOutAssessment {
        ReachOutAssessment(personID: id, history: history, settings: settings(id), now: now)
    }

    private func persist() {
        do { try store.save(preferences); revision += 1 }
        catch { settingsError = "Settings could not be saved." }
    }

    /// Asks for notification permission the first time a reminder is switched on.
    func enableReminders(_ on: Bool, for id: String) async {
        if on {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            reminderMessage = granted ? nil : "Notifications are off for Circle. Allow them in Settings to receive reminders."
        }
        preferences[id, default: ReachOutPreferences()].remindersEnabled = on
    }

    /// Recomputes local reminders from the current history and settings. No push server.
    func schedule(people: [GraphPerson], now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let desired = ReachOutReminders.plan(people.map { ($0.id, $0.name) }, preferences: preferences,
                                             history: history, settings: reminders, now: now)
        let pending = Set(await center.pendingNotificationRequests().map(\.identifier))
        let step = ReachOutReminders.reconcile(desired: desired, pending: pending, ledger: store.loadLedger())
        center.removePendingNotificationRequests(withIdentifiers: step.remove)
        var failed = 0
        for reminder in step.add {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.categoryIdentifier = ReachOutNotifications.category
            content.userInfo = ["profile": profile, "person": reminder.personID]
            let delay = reminder.fireAt.timeIntervalSince(now)
            let trigger: UNNotificationTrigger = delay < 60
                ? UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 5), repeats: false)
                : UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: reminder.fireAt), repeats: false)
            do { try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)) }
            catch { failed += 1 }
        }
        store.saveLedger(step.ledger)
        if failed > 0 { reminderMessage = "\(failed) reminder\(failed == 1 ? "" : "s") could not be scheduled." }
    }
}

/// Handles reminder actions while Circle is running or launched from a notification.
final class ReachOutNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let category = "circle.reachout"
    static let snoozeAction = "circle.reachout.snooze"
    static let shared = ReachOutNotifications()

    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Snooze for a week")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [snooze],
                                                                 intentIdentifiers: [], options: [])])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard response.actionIdentifier == Self.snoozeAction,
              let profile = info["profile"] as? String, let person = info["person"] as? String else { return }
        await MainActor.run {
            let store = ReachOutPreferencesStore(defaults: .standard, profile: profile)
            guard var all = try? store.load() else { return }
            all[person, default: ReachOutPreferences()].snoozedUntil = Calendar.current.date(byAdding: .day, value: 7, to: Date())
            try? store.save(all)
            NotificationCenter.default.post(name: .circleReachOutChanged, object: profile)
        }
    }
}
