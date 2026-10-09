import Foundation
import Testing
@testable import CircleGraph

private actor CountingGeocoder: CircleGeocoding {
    var queries: [String] = []
    var answers: [String: CircleCoordinate] = [:]
    var failing = false
    init(_ answers: [String: CircleCoordinate]) { self.answers = answers }
    func fail(_ value: Bool) { failing = value }
    func locate(_ query: String) async throws -> CircleCoordinate? {
        queries.append(query)
        if failing { throw CircleConnectionError.unavailable }
        return answers[query]
    }
}

@Test func geocodeCacheResolvesEachPlaceOnceAndPersistsPrivately() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("places.json")
    let found = CirclePlace(city: "City 1", country: "Country 1"), missing = CirclePlace(city: "Nowhere", country: nil)
    let geocoder = CountingGeocoder([found.query: CircleCoordinate(latitude: 1, longitude: 2)])
    let locator = CirclePlaceLocator(cache: CircleGeocodeCache(file: file), geocoder: geocoder)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    var pending = locator.cached([found, missing], now: now)
    #expect(pending.found.isEmpty && pending.missing.count == 2)
    for place in pending.missing { _ = try await locator.lookup(place, now: now) }
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)

    // A fresh locator over the same file needs no geocoder calls: hits and known misses are cached.
    let reopened = CirclePlaceLocator(cache: CircleGeocodeCache(file: file), geocoder: geocoder)
    pending = reopened.cached([found, missing], now: now.addingTimeInterval(3600))
    #expect(pending.found == [found.key: CircleCoordinate(latitude: 1, longitude: 2)])
    #expect(pending.missing.isEmpty)
    #expect(await geocoder.queries == [found.query, missing.query])

    // Misses are retried after a week; transient failures are never cached.
    pending = reopened.cached([found, missing], now: now.addingTimeInterval(8 * 86_400))
    #expect(pending.missing == [missing])
    await geocoder.fail(true)
    await #expect(throws: (any Error).self) { try await reopened.lookup(missing, now: now.addingTimeInterval(8 * 86_400)) }
    #expect(reopened.cached([missing], now: now.addingTimeInterval(8 * 86_400)).missing == [missing])
}

@Test func unreadableGeocodeCacheStartsEmptyInsteadOfFailingTheMap() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("places.json")
    try Data("not json".utf8).write(to: file)
    let place = CirclePlace(city: "City 1", country: nil)
    #expect(CirclePlaceLocator(cache: CircleGeocodeCache(file: file), geocoder: CountingGeocoder([:]))
        .cached([place], now: Date()).missing == [place])
}
