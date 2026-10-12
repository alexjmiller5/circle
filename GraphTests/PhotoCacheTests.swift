import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import CircleGraph

private actor FileServer: CircleHTTPClient {
    var files: [String: (Int, Data)] = [:]
    var requests: [String] = []
    init(_ files: [String: (Int, Data)]) { self.files = files }
    func request(path: String, method: String, body: Data?, maxBytes: Int) async throws -> CircleHTTPReply {
        requests.append("\(method) \(path)")
        guard let (status, data) = files[path] else { return CircleHTTPReply(status: 404, data: Data()) }
        return CircleHTTPReply(status: status, data: data)
    }
}

private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@Test func photoCacheIsContentAddressedVerifiedAndPrivate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data("synthetic image bytes".utf8), sha = digest(bytes)
    let photo = GraphPhoto(platform: "platform_a", key: "pictures/people/a/one.jpg", sha256: sha, fetchedAt: nil, updatedAt: nil)
    let server = FileServer(["/v1/files/pictures/people/a/one.jpg": (200, bytes)])
    let cache = CirclePhotoCache(directory: directory)
    let loader = CirclePhotoLoader(client: server, prefixes: ["pictures/people/"], cache: cache)

    #expect(await loader.load(photo) == .image(bytes))
    #expect(await loader.load(photo) == .image(bytes))
    #expect(await server.requests == ["GET /v1/files/pictures/people/a/one.jpg"])
    let stored = directory.appendingPathComponent(sha)
    #expect(try FileManager.default.attributesOfItem(atPath: stored.path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)

    // The same bytes under another key or platform reuse the cached content.
    let copy = GraphPhoto(platform: "platform_b", key: "pictures/people/b/copy.jpg", sha256: sha, fetchedAt: nil, updatedAt: nil)
    #expect(await loader.load(copy) == .image(bytes))
    #expect(await server.requests.count == 1)

    // A tampered cache entry is discarded and fetched again.
    try Data("tampered".utf8).write(to: stored)
    #expect(cache.load(sha256: sha) == nil)
    #expect(await loader.load(photo) == .image(bytes))
    #expect(await server.requests.count == 2)
}

@Test func photoLoaderRequestsOnlyGrantedSafeKeysAndRejectsMismatchedBytes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bytes = Data("synthetic".utf8)
    let server = FileServer(["/v1/files/pictures/people/a/wrong.jpg": (200, bytes),
                             "/v1/files/pictures/people/a/denied.jpg": (403, Data())])
    let loader = CirclePhotoLoader(client: server, prefixes: ["pictures/people/"], cache: CirclePhotoCache(directory: directory))
    func photo(_ key: String, _ sha: String? = String(repeating: "0", count: 64)) -> GraphPhoto {
        GraphPhoto(platform: "platform_a", key: key, sha256: sha, fetchedAt: nil, updatedAt: nil)
    }
    #expect(await loader.load(photo("pictures/records/a/one.jpg")) == .notShared)
    #expect(await loader.load(photo("pictures/people/../records/x.jpg")) == .notShared)
    #expect(await loader.load(photo("pictures/people/a b.jpg")) == .notShared)
    #expect(await loader.load(photo("pictures/people/a/denied.jpg")) == .notShared)
    #expect(await loader.load(photo("pictures/people/a/missing.jpg")) == .unavailable)
    #expect(await loader.load(photo("pictures/people/a/wrong.jpg")) == .unavailable)
    #expect(await server.requests.count == 3)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    // Without a digest the bytes are shown but never cached.
    #expect(await loader.load(photo("pictures/people/a/wrong.jpg", nil)) == .image(bytes))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

@Test func disconnectCleanupRemovesGraphPlacesAndPhotos() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = CircleGraphCache(directory: directory), key = String(repeating: "d", count: 64)
    try cache.save(SocialGraph(people: [], relations: [], selfID: nil), refreshedAt: Date(), profile: key)
    try CircleGeocodeCache(file: try cache.placesFile(profile: key)).save([:])
    let bytes = Data("x".utf8)
    try CirclePhotoCache(directory: try cache.photosDirectory(profile: key)).store(bytes, sha256: digest(bytes))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 3)
    try cache.remove(profile: key)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

private func png(width: Int, height: Int) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.3, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@Test func thumbnailsAreDownsampledAndRejectNonImages() throws {
    let image = try #require(CirclePhotoLoader.thumbnail(png(width: 800, height: 600), maxPixels: 120))
    #expect(max(image.width, image.height) == 120)
    #expect(image.width > image.height)
    let small = try #require(CirclePhotoLoader.thumbnail(png(width: 40, height: 40), maxPixels: 120))
    #expect(small.width == 40)
    #expect(CirclePhotoLoader.thumbnail(Data("not an image".utf8), maxPixels: 120) == nil)
}
