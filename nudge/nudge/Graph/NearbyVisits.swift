import Foundation

enum NearbyRelation: String, Codable, Sendable { case nearby, away, unknown }

/// One successful source check, after canonical identity, area and freshness
/// reconciliation. checkedAt is collection time, never an invented GPS fix.
/// Unknown source age, paused sources and incomplete area matches stay unknown.
struct NearbyCheck: Sendable {
    let id: String
    let checkedAt: Date
    let relation: NearbyRelation
    let sourceAgeSeconds: Double?
    let available: Bool
}

/// Persist per canonical person and consumer profile. This models one device's
/// visit evidence; cross-device delivery deduplication is a separate service.
struct NearbyVisit: Codable, Sendable {
    private struct Candidate: Codable, Sendable {
        let nearby: Bool
        let checkedAt: Date
        let checkID: String
    }
    private var confirmedInside = false
    private var candidate: Candidate?
    private var latestCheckedAt: Date?
    private var latestCheckID: String?

    /// Returns true once on confirmed entry. Unknown/missing evidence cannot
    /// establish departure. Both entry and departure need checks five minutes
    /// apart; freshness has no default until actual source cadence is measured.
    mutating func observe(_ check: NearbyCheck, now: Date, freshnessSeconds: Double) -> Bool {
        guard !check.id.isEmpty, check.checkedAt.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite, check.checkedAt <= now else { return false }
        if let latestCheckedAt, check.checkedAt < latestCheckedAt { return false }
        guard check.id != latestCheckID, check.id != candidate?.checkID else { return false }
        if let latestCheckedAt, check.checkedAt == latestCheckedAt {
            candidate = nil // Conflicting checks at the same source collection time.
            return false
        }
        latestCheckedAt = check.checkedAt
        latestCheckID = check.id
        guard freshnessSeconds.isFinite, freshnessSeconds > 0, check.available,
              let age = check.sourceAgeSeconds, age.isFinite, age >= 0,
              age + now.timeIntervalSince(check.checkedAt) <= freshnessSeconds,
              check.relation != .unknown else {
            candidate = nil
            return false
        }
        let nearby = check.relation == .nearby
        guard nearby != confirmedInside else { candidate = nil; return false }
        if let candidate, candidate.nearby == nearby {
            guard check.checkedAt.timeIntervalSince(candidate.checkedAt) >= 300 else { return false }
            confirmedInside = nearby
            self.candidate = nil
            return nearby
        }
        candidate = Candidate(nearby: nearby, checkedAt: check.checkedAt, checkID: check.id)
        return false
    }
}
