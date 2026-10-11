import CryptoKit
import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

extension GraphPerson {
    /// Newest retained photo per platform, newest first. Upstream has no preferred-photo flag.
    var photoChoices: [GraphPhoto] {
        let older: (GraphPhoto, GraphPhoto) -> Bool = {
            ($0.fetchedAt ?? "", $0.updatedAt ?? "", $0.key) < ($1.fetchedAt ?? "", $1.updatedAt ?? "", $1.key)
        }
        return Dictionary(grouping: photos ?? [], by: \.platform).values
            .compactMap { $0.max(by: older) }.sorted { older($1, $0) }
    }

    /// Residence claims, current bases first, then the most recently ended.
    var baseHistory: [GraphResidence] {
        (residences ?? []).sorted { a, b in
            if (a.end == nil) != (b.end == nil) { return a.end == nil }
            return (a.end ?? "", a.start ?? "") > (b.end ?? "", b.start ?? "")
        }
    }

    /// Only an accepted collector reading may set presence. Residence and offline copies never do.
    var presence: String {
        guard let city = currentCity?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty else { return "Unknown" }
        return city
    }

    /// The single current base, if there is exactly one.
    var basePlace: CirclePlace? {
        guard let city = baseCity?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty else { return nil }
        return CirclePlace(city: city, country: baseCountry)
    }
}

struct CirclePlace: Hashable, Sendable {
    let city: String
    let country: String?
    init(city: String, country: String?) {
        self.city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let country = country?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.country = country?.isEmpty == false ? country : nil
    }
    var query: String { [city, country].compactMap { $0 }.joined(separator: ", ") }
    var key: String { query.lowercased() }
}

struct CircleCoordinate: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

protocol CircleGeocoding: Sendable {
    /// nil means the place was not found and may be cached; throwing means try again later.
    func locate(_ query: String) async throws -> CircleCoordinate?
}

/// Private geocode results for one connected profile.
struct CircleGeocodeCache: Sendable {
    let file: URL
    struct Entry: Codable, Sendable {
        let coordinate: CircleCoordinate?
        let resolvedAt: Date
    }

    /// An unreadable cache is only lost work, never a reason to hide the map.
    func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }

    func save(_ entries: [String: Entry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

struct CirclePlaceLocator: Sendable {
    let cache: CircleGeocodeCache?
    let geocoder: any CircleGeocoding
    static let missRetry: TimeInterval = 7 * 86_400

    /// Cached coordinates, and the places that still need a lookup, in input order.
    func cached(_ places: [CirclePlace], now: Date) -> (found: [String: CircleCoordinate], missing: [CirclePlace]) {
        let entries = cache?.load() ?? [:]
        var found: [String: CircleCoordinate] = [:], missing: [CirclePlace] = [], seen = Set<String>()
        for place in places where seen.insert(place.key).inserted {
            if let entry = entries[place.key] {
                if let coordinate = entry.coordinate { found[place.key] = coordinate; continue }
                if now.timeIntervalSince(entry.resolvedAt) < Self.missRetry { continue }
            }
            missing.append(place)
        }
        return (found, missing)
    }

    /// Looks up one place and records the answer. Failures are not recorded.
    func lookup(_ place: CirclePlace, now: Date) async throws -> CircleCoordinate? {
        let coordinate = try await geocoder.locate(place.query)
        if let cache {
            var entries = cache.load()
            entries[place.key] = Entry(coordinate: coordinate, resolvedAt: now)
            try? cache.save(entries)
        }
        return coordinate
    }
    typealias Entry = CircleGeocodeCache.Entry
}

#if canImport(CoreLocation)
struct CircleSystemGeocoder: CircleGeocoding {
    func locate(_ query: String) async throws -> CircleCoordinate? {
        do {
            guard let location = try await CLGeocoder().geocodeAddressString(query).first?.location else { return nil }
            return CircleCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        } catch let error as CLError where error.code == .geocodeFoundNoResult {
            return nil
        }
    }
}
#endif

struct CircleMapPin: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let place: CirclePlace
    let coordinate: CircleCoordinate
}

enum CirclePeopleMap {
    /// Display name for a photo platform id; brands keep their own capitalization.
    static func platformName(_ value: String) -> String {
        ["linkedin": "LinkedIn", "whatsapp": "WhatsApp"][value] ?? value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// One pin per person at their single current base. Bases are city-level, so people sharing
    /// one are spread on a small deterministic spiral to stay tappable.
    static func pins(graph: SocialGraph, coordinates: [String: CircleCoordinate], circle: String?) -> [CircleMapPin] {
        var byPlace: [String: [GraphPerson]] = [:]
        for person in graph.people where circle.map(person.circles.contains) ?? true {
            if let place = person.basePlace, coordinates[place.key] != nil { byPlace[place.key, default: []].append(person) }
        }
        return byPlace.flatMap { key, people in
            let center = coordinates[key]!, scale = max(cos(center.latitude * .pi / 180), 0.1)
            return people.sorted { $0.id < $1.id }.enumerated().map { index, person in
                let radius = people.count == 1 ? 0 : 0.004 * (Double(index) + 0.5).squareRoot()
                let angle = Double(index) * 2.399963
                return CircleMapPin(id: person.id, name: person.name, place: person.basePlace!, coordinate: CircleCoordinate(
                    latitude: center.latitude + radius * cos(angle), longitude: center.longitude + radius * sin(angle) / scale))
            }
        }.sorted { $0.id < $1.id }
    }

    /// Circles with member counts, largest first. A place-named circle means met there, never lives there.
    static func circles(graph: SocialGraph) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for person in graph.people { for circle in Set(person.circles) { counts[circle, default: 0] += 1 } }
        return counts.map { (name: $0.key, count: $0.value) }.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

enum CirclePhotoResult: Equatable, Sendable { case image(Data), notShared, unavailable }

/// Photo bytes addressed by their SHA-256, verified on every read.
struct CirclePhotoCache: Sendable {
    let directory: URL

    private func file(_ sha256: String) -> URL? {
        sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) == nil ? nil : directory.appendingPathComponent(sha256)
    }

    func load(sha256: String) -> Data? {
        guard let file = file(sha256), let data = try? Data(contentsOf: file) else { return nil }
        guard CirclePhotoLoader.digest(data) == sha256 else { try? FileManager.default.removeItem(at: file); return nil }
        return data
    }

    func store(_ data: Data, sha256: String) throws {
        guard let file = file(sha256), CirclePhotoLoader.digest(data) == sha256 else { throw CircleConnectionError.invalidResponse }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

struct CirclePhotoLoader: Sendable {
    let client: any CircleHTTPClient
    let prefixes: [String]
    let cache: CirclePhotoCache?

    /// Slash-terminated key namespaces, the same shape the service accepts for file grants.
    static func validPrefix(_ value: String) -> Bool {
        value.range(of: "^([A-Za-z0-9_][A-Za-z0-9._-]*/)+$", options: .regularExpression) != nil
    }

    /// Keys the transport sends verbatim: no escapes, empty, dot or dot-dot segments.
    static func readable(_ key: String, prefixes: [String]) -> Bool {
        key.count <= 1024 && prefixes.contains { key.hasPrefix($0) }
            && key.range(of: "^[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]*)*$", options: .regularExpression) != nil
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func load(_ photo: GraphPhoto) async -> CirclePhotoResult {
        guard Self.readable(photo.key, prefixes: prefixes) else { return .notShared }
        let expected = photo.sha256?.lowercased()
        if let expected, let data = cache?.load(sha256: expected) { return .image(data) }
        guard let reply = try? await client.request(path: "/v1/files/" + photo.key, method: "GET", body: nil,
                                                    maxBytes: 2 * 1024 * 1024) else { return .unavailable }
        if reply.status == 403 { return .notShared }
        guard reply.status == 200 else { return .unavailable }
        guard let expected else { return .image(reply.data) }
        guard Self.digest(reply.data) == expected else { return .unavailable }
        try? cache?.store(reply.data, sha256: expected)
        return .image(reply.data)
    }
}
