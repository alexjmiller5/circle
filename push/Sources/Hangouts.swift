import CircleGraph
import Foundation

public struct HangoutCandidate: Sendable {
    public let id: String
    public let name: String
    /// weekly, fortnightly, monthly or quarterly; nil = no hangout reminders.
    public let cadence: String?
    public let baseCity: String?
    public let baseCountry: String?

    public init(id: String, name: String, cadence: String?, baseCity: String?, baseCountry: String?) {
        self.id = id; self.name = name; self.cadence = cadence; self.baseCity = baseCity; self.baseCountry = baseCountry
    }
}

public struct HangoutNudge: Equatable, Sendable {
    public let personID: String
    public let name: String
    public let cadence: String
    public let city: String
    /// Newest logged hangout day (YYYY-MM-DD), nil when none is logged.
    public let lastDay: String?
}

/// Same-city hangout reminders: a person whose cadence has passed since the newest logged
/// hangout, based in the city this person is in now, at most once per cadence period, by day.
public enum HangoutNudges {
    public static func due(_ people: [HangoutCandidate], hangoutDays: [String: [String]], place: CurrentPlace?,
                           reminded: [String: Date], now: Date, calendar: Calendar) -> [HangoutNudge] {
        guard let place, let here = fold(place.city), (10..<20).contains(calendar.component(.hour, from: now)) else { return [] }
        return people.compactMap { person in
            guard let raw = person.cadence, let cadence = ContactCadence(rawValue: raw),
                  let city = person.baseCity, let base = fold(city.components(separatedBy: ",")[0]),
                  base == here || base == fold(place.district) else { return nil }
            if let country = fold(person.baseCountry), fold(place.country) != nil || fold(place.countryCode) != nil,
               country != fold(place.country) && country != fold(place.countryCode) { return nil }
            if let last = reminded[person.id], let again = cadence.next(after: last, calendar: calendar), again > now { return nil }
            let lastDay = (hangoutDays[person.id] ?? []).filter { day($0, calendar) ?? .distantFuture <= now }.max()
            if let lastDay, let last = day(lastDay, calendar), let due = cadence.next(after: last, calendar: calendar), due > now { return nil }
            return HangoutNudge(personID: person.id, name: person.name, cadence: raw, city: place.city ?? city, lastDay: lastDay)
        }
    }

    public static func notification(_ nudge: HangoutNudge, hideNames: Bool, now: Date, calendar: Calendar) -> (title: String, body: String) {
        if hideNames { return ("Time for a hangout", "Someone you want to see often is in your city.") }
        let cadence = ContactCadence(rawValue: nudge.cadence)?.label.lowercased() ?? nudge.cadence
        let since: String
        if let lastDay = nudge.lastDay, let last = day(lastDay, calendar) {
            let gap = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: now)).day ?? 0
            since = "Last hangout \(gap) days ago"
        } else {
            since = "No hangout logged yet"
        }
        return ("Hang out with \(nudge.name)?", "\(since) (\(cadence)). You're both in \(nudge.city).")
    }

    private static func fold(_ value: String?) -> String? {
        let folded = value?.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded?.isEmpty == false ? folded : nil
    }

    /// A logged day at local noon, as Circle counts it.
    private static func day(_ value: String, _ calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}
