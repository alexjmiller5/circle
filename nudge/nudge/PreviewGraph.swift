import Foundation
import ImageIO

// Synthetic identities only. This fixture is reachable only from explicit development entry points.
enum PreviewGraph {
    static let graph: SocialGraph = {
        // Public city names so the map can place synthetic people.
        let cities = [("Lisbon", "Portugal"), ("Chicago", "United States"), ("Osaka", "Japan")]
        let people = (0...16).map { i in
            let base = cities[i % 3], past = cities[(i + 1) % 3]
            return GraphPerson(id: String(format: "person-%02d", i), name: i == 0 ? "You" : "Person \(i)",
                               circles: ["Circle \(i == 0 ? 1 : (i - 1) / 4 + 1)"],
                               baseCity: i == 16 ? nil : base.0, baseCountry: i == 16 ? nil : base.1,
                               currentCity: i % 3 == 0 ? nil : cities[i % 2].0,
                               residences: i == 16 ? nil : [GraphResidence(city: base.0, country: base.1, start: "2021", end: nil),
                                                            GraphResidence(city: past.0, country: past.1, start: "2015", end: "2021")],
                               // Most synthetic people have a generated portrait; the rest show initials.
                               photos: i % 4 == 3 ? nil : [GraphPhoto(platform: "instagram", key: String(format: "preview/%02d.png", i),
                                                                      sha256: nil, fetchedAt: "2026-01-01", updatedAt: nil)])
        }
        let relations = (1...15).map { i in
            GraphRelation(personID: people[i].id, relatedID: people[(i - 1) / 3].id, kind: "met_through")
        }
        return SocialGraph(people: people, relations: relations, selfID: people[0].id)
    }()

    /// Generated portraits served without a network, only to the explicit preview.
    static let photos = CirclePhotoLoader(client: PortraitServer(), prefixes: ["preview/"], cache: nil)

    private struct PortraitServer: CircleHTTPClient {
        func request(path: String, method: String, body: Data?, maxBytes: Int) async throws -> CircleHTTPReply {
            let seed = Double(path.filter(\.isNumber).suffix(2)).map { $0 } ?? 0
            let size = 160, context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let hue = seed.truncatingRemainder(dividingBy: 7) / 7
            context.setFillColor(CGColor(red: 0.35 + hue * 0.5, green: 0.55 - hue * 0.3, blue: 0.85 - hue * 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
            context.fillEllipse(in: CGRect(x: 52, y: 78, width: 56, height: 56))
            context.fillEllipse(in: CGRect(x: 24, y: -40, width: 112, height: 108))
            let data = NSMutableData()
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
                return CircleHTTPReply(status: 503, data: Data())
            }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            return CircleHTTPReply(status: 200, data: data as Data)
        }
    }

    /// Synthetic contact history relative to launch, covering every reach-out group.
    static let history: CommunicationHistory = {
        let now = Date(), day = 86_400.0
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * day) }
        let start = ago(3_000), refreshed = ago(0.1)
        func summary(_ channel: CommunicationChannel, sent: Double? = nil, received: Double? = nil,
                     answered: Double? = nil, review: String? = nil) -> ChannelSummary {
            ChannelSummary(channel: channel, lastSent: sent.map(ago), lastReceived: received.map(ago), lastAnsweredCall: answered.map(ago),
                           answeredSeconds: answered.map { _ in 420 }, lastCall: answered.map(ago),
                           sent: sent == nil ? 0 : 12, received: received == nil ? 0 : 9, callsAnswered: answered == nil ? 0 : 3,
                           callsMissed: answered == nil ? 0 : 1, coverageStart: start, coverageEnd: refreshed, refreshedAt: refreshed,
                           needsReview: review)
        }
        var history = CommunicationHistory()
        history.channels = [
            "person-01": [summary(.imessage, sent: 40, received: 3), summary(.phone, answered: 52)],
            "person-02": [summary(.phone, answered: 24)],
            "person-03": [summary(.sms, sent: 5, received: 5)],
            "person-05": [summary(.whatsapp, sent: 70, received: 64)],
            "person-06": [summary(.imessage, sent: 33, received: 31)],
            "person-07": [summary(.facetimeVideo, answered: 10)],
            "person-08": [summary(.imessage, received: 2, review: "An event resolved to a different person at import.")]
        ]
        history.sources = [
            SourceCoverage(source: "apple_messages", state: .complete, reason: nil, completedAt: refreshed, firstEvent: start),
            SourceCoverage(source: "apple_calls", state: .complete, reason: nil, completedAt: refreshed, firstEvent: ago(450)),
            SourceCoverage(source: "whatsapp_messages", state: .partial, reason: "The desktop store is a partial mirror of the phone.",
                           completedAt: refreshed, firstEvent: ago(2_900)),
            SourceCoverage(source: "whatsapp_calls", state: .partial, reason: "The desktop store is a partial mirror of the phone.",
                           completedAt: refreshed, firstEvent: ago(200))
        ]
        return history
    }()
}
