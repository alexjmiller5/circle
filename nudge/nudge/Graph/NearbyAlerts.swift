import Foundation

/// One validated Find My city check (`findmy_ax`): region grade, never a coordinate or fix time.
/// `checkedAt` is collection time; `ageSeconds` is the displayed age, nil when not exact.
public struct FriendCityCheck: Equatable, Sendable {
    public let personID: String
    public let city: String
    public let region: String?
    public let country: String?
    public let locationText: String
    public let ageSeconds: Double?
    public let paused: Bool
    public let checkID: String
    public let checkedAt: Date

    private struct Record: Decodable {
        let personId, city, locationText, sourceCheckId, source: String
        let region, country: String?
        let ageSeconds: Double?
        let paused: Bool
        let checkedAt: Double
    }

    /// nil for anything that is not exactly one collector record.
    public static func parse(_ body: String) -> FriendCityCheck? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let record = try? decoder.decode(Record.self, from: Data(body.utf8)), record.source == "findmy_ax",
              !record.personId.isEmpty, !record.sourceCheckId.isEmpty,
              record.checkedAt.isFinite, record.checkedAt > 0 else { return nil }
        func optional(_ value: String?) -> String? { value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil }
        return FriendCityCheck(personID: record.personId, city: record.city, region: optional(record.region),
                               country: optional(record.country), locationText: record.locationText,
                               ageSeconds: record.ageSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                               paused: record.paused, checkID: record.sourceCheckId,
                               checkedAt: Date(timeIntervalSince1970: record.checkedAt))
    }
}

/// Where this device is, city-level, as the system geocoder names it.
public struct CurrentPlace: Codable, Equatable, Sendable {
    public let city: String?
    /// A named part of the city, such as a borough.
    public let district: String?
    public let region: String?
    public let country: String?
    public let countryCode: String?

    public init(city: String?, district: String?, region: String?, country: String?, countryCode: String?) {
        self.city = city; self.district = district; self.region = region; self.country = country; self.countryCode = countryCode
    }
}

enum NearbyArea {
    /// City-only rule (approved 2026-10-07): the same city (or the device's district), with region and
    /// country agreeing whenever both sides show one. Metro areas and distance are never inferred.
    static func relation(_ check: FriendCityCheck, to place: CurrentPlace?) -> NearbyRelation {
        func key(_ value: String?) -> String? {
            let folded = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return folded?.isEmpty == false ? folded : nil
        }
        guard let place, let city = key(check.city), key(place.city) != nil else { return .unknown }
        guard city == key(place.city) || city == key(place.district) else { return .away }
        if let region = key(check.region), let mine = key(place.region), region != mine { return .away }
        if let country = key(check.country), key(place.country) != nil || key(place.countryCode) != nil,
           country != key(place.country) && country != key(place.countryCode) { return .away }
        return .nearby
    }
}

public struct NearbyAlert: Equatable, Sendable {
    public let personID: String
    public let checkID: String
    public let locationText: String
    public let ageSeconds: Double
    public let checkedAt: Date
}

/// Per-profile visit state for everyone with a fresh location (no opt-in or circle gate).
public struct NearbyWatch: Codable, Sendable {
    private var visits: [String: NearbyVisit] = [:]

    public init() {}

    /// Measured 2026-10-09 (p99 displayed age 6 min): fresh = not paused, displayed age at most
    /// 10 min and the check itself at most 15 min old. Returns arrivals confirmed by these checks.
    public mutating func observe(_ checks: [FriendCityCheck], place: CurrentPlace?, now: Date,
                          maxAgeSeconds: Double = 600, maxCheckAgeSeconds: Double = 900) -> [NearbyAlert] {
        checks.sorted { ($0.checkedAt, $0.checkID) < ($1.checkedAt, $1.checkID) }.compactMap { check in
            let age = check.ageSeconds
            let fresh = !check.paused && age.map { $0 <= maxAgeSeconds } == true
                && now.timeIntervalSince(check.checkedAt) <= maxCheckAgeSeconds
            let evidence = NearbyCheck(id: check.checkID, checkedAt: check.checkedAt, relation: NearbyArea.relation(check, to: place),
                                       sourceAgeSeconds: age, available: fresh)
            guard visits[check.personID, default: NearbyVisit()].observe(evidence, now: now,
                                                                         freshnessSeconds: maxAgeSeconds + maxCheckAgeSeconds),
                  let age else { return nil }
            return NearbyAlert(personID: check.personID, checkID: check.checkID, locationText: check.locationText,
                               ageSeconds: age, checkedAt: check.checkedAt)
        }
    }
}

public enum NearbyAlerts {
    static let prefix = "circle.nearby."

    /// Shows the observed place and says nearby, never the same town or a distance it cannot know.
    public static func notification(_ alert: NearbyAlert, name: String, settings: ReminderSettings) -> (id: String, title: String, body: String) {
        let minutes = Int(alert.ageSeconds / 60)
        let updated = minutes < 1 ? "just before the check" : "\(minutes) min before the check"
        return ("\(prefix)\(alert.personID).\(alert.checkID)",
                settings.hideNames ? "Someone is nearby" : "\(name) is nearby",
                settings.hideNames ? "A friend in Circle is in your area." : "Find My showed \(alert.locationText), updated \(updated). Distance unknown.")
    }
}
