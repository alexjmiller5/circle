import Foundation
import Testing
@testable import CircleGraph

private func record(person: String = "p1", city: String = "City A", region: String? = "AA", country: String? = nil,
                    age: Double? = 60, paused: Bool = false, check: String, at: Double) -> String {
    var fields: [String: Any] = [
        "person_id": person, "city": city, "location_text": [city, region ?? country ?? ""].filter { !$0.isEmpty }.joined(separator: ", "),
        "age_text": age.map { "\(Int($0 / 60)) min. ago" } ?? "Last week", "paused": paused, "source_check_id": check,
        "checked_at": at, "run_rows": 1, "run_unresolved": 0, "run_complete": true, "source": "findmy_ax",
        "region": region ?? NSNull(), "country": country ?? NSNull(), "age_seconds": age ?? NSNull()
    ]
    if fields["region"] is NSNull { fields["region"] = NSNull() }
    return String(data: try! JSONSerialization.data(withJSONObject: fields, options: .sortedKeys), encoding: .utf8)!
}

private let home = CurrentPlace(city: "City A", district: "District A", region: "AA", country: "Country A", countryCode: "CA")

@Test func cityChecksParseOnlyExactCollectorRecords() throws {
    let check = try #require(FriendCityCheck.parse(record(check: "c1", at: 1_000)))
    #expect(check.personID == "p1" && check.city == "City A" && check.region == "AA" && check.country == nil)
    #expect(check.ageSeconds == 60 && !check.paused && check.checkID == "c1")
    #expect(check.checkedAt == Date(timeIntervalSince1970: 1_000))
    #expect(FriendCityCheck.parse(record(age: nil, check: "c2", at: 1_000))?.ageSeconds == nil)
    for bad in ["", "[]", "{}", "not json",
                record(check: "c1", at: 1_000).replacingOccurrences(of: "findmy_ax", with: "other"),
                record(person: "", check: "c1", at: 1_000), record(check: "", at: 1_000),
                record(check: "c1", at: 1_000).replacingOccurrences(of: "\"paused\":false", with: "\"paused\":\"no\"")] {
        #expect(FriendCityCheck.parse(bad) == nil)
    }
}

@Test func areaMatchesTheSameCityOnlyAndUnknownStaysUnknown() throws {
    func relation(_ city: String, region: String? = "AA", country: String? = nil, place: CurrentPlace? = home) -> NearbyRelation {
        NearbyArea.relation(FriendCityCheck.parse(record(city: city, region: region, country: country, check: "c", at: 1))!, to: place)
    }
    #expect(relation("City A") == .nearby)
    #expect(relation(" city a ") == .nearby)
    // A district the device reports (a borough) is the same place.
    #expect(relation("District A") == .nearby)
    #expect(relation("City B") == .away)
    #expect(relation("City A", region: "BB") == .away)
    #expect(relation("City A", region: nil, country: "Country A") == .nearby)
    #expect(relation("City A", region: nil, country: "Country B") == .away)
    // No metro or distance inference, and no claim without both places.
    #expect(relation("City A", place: nil) == .unknown)
    #expect(relation("City A", place: CurrentPlace(city: nil, district: nil, region: "AA", country: nil, countryCode: nil)) == .unknown)
    #expect(relation("") == .unknown)
}

@Test func watchAlertsOnceAfterTwoFreshChecksFiveMinutesApart() throws {
    var watch = NearbyWatch()
    let t0 = 1_000_000.0
    func checks(_ items: [(String, Double, String)]) -> [FriendCityCheck] {
        items.map { FriendCityCheck.parse(record(city: $0.2, check: $0.0, at: $0.1))! }
    }
    #expect(watch.observe(checks([("a1", t0, "City A")]), place: home, now: Date(timeIntervalSince1970: t0 + 30)).isEmpty)
    // Under five minutes later: still only a candidate.
    #expect(watch.observe(checks([("a2", t0 + 200, "City A")]), place: home, now: Date(timeIntervalSince1970: t0 + 230)).isEmpty)
    let alerts = watch.observe(checks([("a3", t0 + 600, "City A")]), place: home, now: Date(timeIntervalSince1970: t0 + 630))
    #expect(alerts.map(\.personID) == ["p1"])
    #expect(alerts.first?.locationText == "City A, AA")
    // Once per visit: staying nearby never repeats.
    #expect(watch.observe(checks([("a4", t0 + 1_200, "City A")]), place: home, now: Date(timeIntervalSince1970: t0 + 1_230)).isEmpty)
    // Confirmed departure, then re-entry alerts again.
    _ = watch.observe(checks([("b1", t0 + 1_800, "City B")]), place: home, now: Date(timeIntervalSince1970: t0 + 1_830))
    _ = watch.observe(checks([("b2", t0 + 2_400, "City B")]), place: home, now: Date(timeIntervalSince1970: t0 + 2_430))
    _ = watch.observe(checks([("c1", t0 + 3_000, "City A")]), place: home, now: Date(timeIntervalSince1970: t0 + 3_030))
    #expect(watch.observe(checks([("c2", t0 + 3_600, "City A")]), place: home, now: Date(timeIntervalSince1970: t0 + 3_630)).count == 1)
    // The state survives a relaunch.
    let restored = try JSONDecoder().decode(NearbyWatch.self, from: JSONEncoder().encode(watch))
    var copy = restored
    #expect(copy.observe(checks([("c3", t0 + 4_200, "City A")]), place: home, now: Date(timeIntervalSince1970: t0 + 4_230)).isEmpty)
}

@Test func staleOrPausedChecksNeverConfirmAnArrival() {
    let t0 = 2_000_000.0
    func run(age: Double?, paused: Bool = false, lag: Double = 30) -> Int {
        var watch = NearbyWatch()
        var count = 0
        for (index, at) in [t0, t0 + 600].enumerated() {
            let check = FriendCityCheck.parse(record(age: age, paused: paused, check: "s\(index)", at: at))!
            count += watch.observe([check], place: home, now: Date(timeIntervalSince1970: at + lag)).count
        }
        return count
    }
    #expect(run(age: 60) == 1)
    // Measured cutoff (2026-10-09): displayed age at most 10 min, check at most 15 min old.
    #expect(run(age: 601) == 0)
    #expect(run(age: nil) == 0)
    #expect(run(age: 60, paused: true) == 0)
    #expect(run(age: 60, lag: 901) == 0)
}

@Test func nearbyNotificationsShowTheObservedCityAndRespectPrivacy() {
    let alert = NearbyAlert(personID: "p1", checkID: "c9", locationText: "City A, AA", ageSeconds: 180,
                            checkedAt: Date(timeIntervalSince1970: 0))
    let shown = NearbyAlerts.notification(alert, name: "Person 1", settings: ReminderSettings())
    #expect(shown.id == "circle.nearby.p1.c9")
    #expect(shown.title == "Person 1 is nearby")
    #expect(shown.body == "Find My showed City A, AA, updated 3 min before the check. Distance unknown.")
    var hidden = ReminderSettings(); hidden.hideNames = true
    let quiet = NearbyAlerts.notification(alert, name: "Person 1", settings: hidden)
    #expect(!quiet.title.contains("Person 1") && !quiet.body.contains("Person 1") && !quiet.body.contains("City A"))
}
