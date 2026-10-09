import Foundation

struct CircleGraphCache: Sendable {
    let directory: URL
    static var application: Self {
        Self(directory: URL.applicationSupportDirectory.appendingPathComponent("Circle/People", isDirectory: true))
    }
    struct Snapshot: Codable {
        var people: [GraphPerson]
        let relations: [GraphRelation]
        let selfID: String?
        let refreshedAt: Date
        /// Optional so offline copies saved before contact history existed still load.
        var history: CommunicationHistory? = nil
        var graph: SocialGraph { SocialGraph(people: people, relations: relations, selfID: selfID) }
    }

    private func file(_ profile: String) throws -> URL {
        guard profile.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw CircleConnectionError.invalidConfiguration
        }
        return directory.appendingPathComponent(profile + ".json")
    }

    /// Geocoded bases for this profile, beside its graph and removed with it.
    func placesFile(profile: String) throws -> URL {
        directory.appendingPathComponent(try file(profile).deletingPathExtension().lastPathComponent + ".places.json")
    }

    /// Content-addressed photo bytes for this profile.
    func photosDirectory(profile: String) throws -> URL {
        directory.appendingPathComponent(try file(profile).deletingPathExtension().lastPathComponent + ".photos", isDirectory: true)
    }

    func load(profile: String) throws -> Snapshot? {
        let path = try file(profile)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 32 * 1024 * 1024 else {
            throw CircleConnectionError.invalidResponse
        }
        var snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: path))
        // Presence requires new source/freshness evaluation, never cache age alone.
        for index in snapshot.people.indices { snapshot.people[index].currentCity = nil }
        return snapshot
    }

    func save(_ graph: SocialGraph, history: CommunicationHistory? = nil, refreshedAt: Date, profile: String) throws {
        let path = try file(profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let snapshot = Snapshot(people: graph.people, relations: graph.relations, selfID: graph.selfID, refreshedAt: refreshedAt, history: history)
        try JSONEncoder().encode(snapshot).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    func remove(profile: String) throws {
        for path in [try file(profile), try placesFile(profile: profile), try photosDirectory(profile: profile)]
        where FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }
}
