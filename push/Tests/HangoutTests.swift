import Foundation
import Testing
@testable import CircleGraph
@testable import CirclePush

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()
private func at(_ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
private let here = CurrentPlace(city: "City A", district: "District A", region: "AA", country: "Country A", countryCode: "CA")

private let people = [
    HangoutCandidate(id: "p1", name: "Person 1", cadence: "monthly", baseCity: "City A, State A", baseCountry: nil),
    HangoutCandidate(id: "p2", name: "Person 2", cadence: "monthly", baseCity: "City A", baseCountry: nil),
    HangoutCandidate(id: "p3", name: "Person 3", cadence: "weekly", baseCity: "City B", baseCountry: nil),
    HangoutCandidate(id: "p4", name: "Person 4", cadence: nil, baseCity: "City A", baseCountry: nil),
    HangoutCandidate(id: "p5", name: "Person 5", cadence: "monthly", baseCity: "District A", baseCountry: "Country A"),
    HangoutCandidate(id: "p6", name: "Person 6", cadence: "monthly", baseCity: "City A", baseCountry: "Country B"),
]
private let days = ["p1": ["2026-08-01", "2026-09-01"], "p2": ["2026-10-03"], "p3": ["2026-09-01"]]

@Test func dueHangoutsNeedTheCadenceToHavePassedAndTheSameCity() {
    let nudges = HangoutNudges.due(people, hangoutDays: days, place: here, reminded: [:], now: at(12, 12), calendar: calendar)
    // p2 saw you 9 days ago, p3 lives elsewhere, p4 wants no reminders, p6's City A is another country.
    #expect(nudges.map(\.personID) == ["p1", "p5"])
    #expect(nudges[0].lastDay == "2026-09-01" && nudges[0].city == "City A")
    #expect(nudges[1].lastDay == nil)
    #expect(HangoutNudges.due(people, hangoutDays: days, place: nil, reminded: [:], now: at(12, 12), calendar: calendar).isEmpty)
}

@Test func hangoutRemindersWaitACadencePeriodAndRespectQuietHours() {
    let recent = HangoutNudges.due(people, hangoutDays: days, place: here, reminded: ["p1": at(7, 12)], now: at(12, 12), calendar: calendar)
    #expect(!recent.map(\.personID).contains("p1"))
    let later = HangoutNudges.due(people, hangoutDays: days, place: here, reminded: ["p1": calendar.date(byAdding: .month, value: -1, to: at(12, 11))!],
                                  now: at(12, 12), calendar: calendar)
    #expect(later.map(\.personID).contains("p1"))
    #expect(HangoutNudges.due(people, hangoutDays: days, place: here, reminded: [:], now: at(12, 22), calendar: calendar).isEmpty)
    #expect(HangoutNudges.due(people, hangoutDays: days, place: here, reminded: [:], now: at(12, 8), calendar: calendar).isEmpty)
}

@Test func hangoutNotificationsNameTheGapAndCityUnlessNamesAreHidden() {
    let nudge = HangoutNudge(personID: "p1", name: "Person 1", cadence: "monthly", city: "City A", lastDay: "2026-09-01")
    let text = HangoutNudges.notification(nudge, hideNames: false, now: at(12, 12), calendar: calendar)
    #expect(text.title == "Hang out with Person 1?")
    #expect(text.body == "Last hangout 41 days ago (monthly). You're both in City A.")
    let never = HangoutNudges.notification(HangoutNudge(personID: "p5", name: "Person 5", cadence: "weekly", city: "City A", lastDay: nil),
                                           hideNames: false, now: at(12, 12), calendar: calendar)
    #expect(never.body == "No hangout logged yet (weekly). You're both in City A.")
    let hidden = HangoutNudges.notification(nudge, hideNames: true, now: at(12, 12), calendar: calendar)
    #expect(!hidden.title.contains("Person 1") && !hidden.body.contains("Person 1") && !hidden.body.contains("City A"))
}
