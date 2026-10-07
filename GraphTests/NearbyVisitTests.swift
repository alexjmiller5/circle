import Foundation
import Testing
@testable import CircleGraph

private let checkTime = Date(timeIntervalSince1970: 1_800_000_000)
private func nearbyCheck(_ id: String, _ seconds: Double, _ relation: NearbyRelation = .nearby,
                         age: Double? = 0, available: Bool = true) -> NearbyCheck {
    NearbyCheck(id: id, checkedAt: checkTime.addingTimeInterval(seconds), relation: relation,
                sourceAgeSeconds: age, available: available)
}

@Test func cityVisitRequiresTwoFreshChecksFiveMinutesApartAndNotifiesOnce() throws {
    var visit = NearbyVisit()
    #expect(visit.observe(nearbyCheck("first", 0), now: checkTime, freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("early", 299), now: checkTime.addingTimeInterval(299), freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("confirm", 300), now: checkTime.addingTimeInterval(300), freshnessSeconds: 900) == true)
    for seconds in [301.0, 600, 900] {
        #expect(visit.observe(nearbyCheck("next-\(seconds)", seconds), now: checkTime.addingTimeInterval(seconds), freshnessSeconds: 900) == false)
    }
    var restored = try JSONDecoder().decode(NearbyVisit.self, from: JSONEncoder().encode(visit))
    #expect(restored.observe(nearbyCheck("restart", 1200), now: checkTime.addingTimeInterval(1200), freshnessSeconds: 900) == false)
}

@Test func stalePausedUnknownAndRepeatedChecksCannotConfirmOrProveDeparture() {
    for bad in [nearbyCheck("bad", 300, age: nil), nearbyCheck("bad", 300, age: 901),
                nearbyCheck("bad", 300, available: false), nearbyCheck("bad", 300, .unknown)] {
        var visit = NearbyVisit()
        #expect(visit.observe(nearbyCheck("first", 0), now: checkTime, freshnessSeconds: 900) == false)
        #expect(visit.observe(bad, now: checkTime.addingTimeInterval(300), freshnessSeconds: 900) == false)
        #expect(visit.observe(nearbyCheck("fresh", 600), now: checkTime.addingTimeInterval(600), freshnessSeconds: 900) == false)
    }
    var visit = NearbyVisit()
    #expect(visit.observe(nearbyCheck("first", 0), now: checkTime, freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("first", 300), now: checkTime.addingTimeInterval(300), freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("confirm", 301), now: checkTime.addingTimeInterval(301), freshnessSeconds: 900) == true)
    #expect(visit.observe(nearbyCheck("missing", 600, .unknown), now: checkTime.addingTimeInterval(600), freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("back", 900), now: checkTime.addingTimeInterval(900), freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("still-back", 1200), now: checkTime.addingTimeInterval(1200), freshnessSeconds: 900) == false)
}

@Test func departureAndReentryBothRequireConfirmationAndOldChecksNeverRewind() {
    var visit = NearbyVisit()
    #expect(visit.observe(nearbyCheck("first", 0), now: checkTime, freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("confirm", 300), now: checkTime.addingTimeInterval(300), freshnessSeconds: 900) == true)
    #expect(visit.observe(nearbyCheck("leave", 600, .away), now: checkTime.addingTimeInterval(600), freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("old", 450), now: checkTime.addingTimeInterval(600), freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("left", 900, .away), now: checkTime.addingTimeInterval(900), freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("return", 1200), now: checkTime.addingTimeInterval(1200), freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("returned", 1500), now: checkTime.addingTimeInterval(1500), freshnessSeconds: 900) == true)
    #expect(visit.observe(nearbyCheck("future", 2400), now: checkTime.addingTimeInterval(1800), freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("invalid-age", 1800, age: -1), now: checkTime.addingTimeInterval(1800), freshnessSeconds: 900) == false)
}

@Test func collectionAgeAndInvalidFreshnessCannotRenewArrivalEvidence() {
    for freshness in [0.0, -1, .infinity, .nan] {
        var visit = NearbyVisit()
        #expect(visit.observe(nearbyCheck("first", 0), now: checkTime, freshnessSeconds: 900) == false)
        #expect(visit.observe(nearbyCheck("invalid", 300), now: checkTime.addingTimeInterval(300), freshnessSeconds: freshness) == false)
        #expect(visit.observe(nearbyCheck("fresh", 600), now: checkTime.addingTimeInterval(600), freshnessSeconds: 900) == false)
    }
    var visit = NearbyVisit()
    #expect(visit.observe(nearbyCheck("first", 0), now: checkTime, freshnessSeconds: 900) == false)
    // The source was fresh when collected but became stale in transit.
    #expect(visit.observe(nearbyCheck("delayed", 300, age: 800), now: checkTime.addingTimeInterval(401), freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("fresh", 600), now: checkTime.addingTimeInterval(600), freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("conflict", 600, .away), now: checkTime.addingTimeInterval(600), freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("next", 900), now: checkTime.addingTimeInterval(900), freshnessSeconds: 900) == false)
    #expect(visit.observe(nearbyCheck("confirmed", 1200), now: checkTime.addingTimeInterval(1200), freshnessSeconds: 900) == true)
}
