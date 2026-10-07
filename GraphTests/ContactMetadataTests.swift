import Foundation
import Testing
@testable import CircleGraph

private let eventTime = Date(timeIntervalSince1970: 1_700_000_000)
private let importReceipt = ContactImportMetadata(id: "import-1", sourceNamespace: "account-1", completed: true)
private let directEvent = ContactEventMetadata(id: "event-1", firstImportID: "import-1", occurredAt: eventTime,
    kind: "message", direction: "outgoing", messageState: "sent", conversationKind: "direct",
    expectedParticipantRows: 2, participantCoverage: "complete_for_event", participantCoverageReason: "verified_event_endpoints")
private let endpoints = [
    ContactParticipantMetadata(id: "row-self", eventID: "event-1", firstImportID: "import-1", role: "sender", isSelf: true, personID: nil),
    ContactParticipantMetadata(id: "row-other", eventID: "event-1", firstImportID: "import-1", role: "recipient", isSelf: false, personID: "person-1")
]

@Test func metadataProjectionSeparatesDirectSourceProofPublicationAndIdentity() throws {
    func project(_ event: ContactEventMetadata, _ rows: [ContactParticipantMetadata] = endpoints,
                 imports: [ContactImportMetadata] = [importReceipt]) throws -> [ContactInteraction] {
        try ContactMetadataProjection.interactions(event: event, participants: rows, imports: imports)
    }
    let contact = try #require(project(directEvent).first)
    #expect(contact.personID == "person-1")
    #expect(contact.kind == .outgoingMessage)
    #expect(contact.qualifies(settings: .init(), now: eventTime.addingTimeInterval(60)))
    #expect(try project(directEvent, endpoints + [endpoints[1]]).count == 1)
    for state in ["pending", "failed", "unknown", "received"] {
        var e = directEvent; e.messageState = state
        #expect(try project(e).isEmpty)
    }
    for scope in ["group", "self", "unknown"] {
        var e = directEvent; e.conversationKind = scope
        #expect(try project(e).isEmpty)
    }
    for proof in ["partial", "unknown"] {
        var e = directEvent; e.participantCoverage = proof
        #expect(try project(e).isEmpty)
    }
    var e = directEvent; e.participantCoverageReason = "current_roster_only"
    #expect(try project(e).isEmpty)
    e = directEvent; e.expectedParticipantRows = 1
    #expect(try project(e).isEmpty)
    e = directEvent; e.needsReview = true
    #expect(try project(e).isEmpty)
    e = directEvent; e.occurredAt = nil
    #expect(try project(e).isEmpty)
    e = directEvent; e.deleted = true
    #expect(try project(e).isEmpty)
    var unresolved = endpoints; unresolved[1].personID = nil
    #expect(try project(directEvent, unresolved).isEmpty)
    var extra = directEvent; extra.expectedParticipantRows = 3
    let unknown = ContactParticipantMetadata(id: "row-unresolved", eventID: "event-1", firstImportID: "import-1", role: "recipient", isSelf: false, personID: nil)
    #expect(try project(extra, endpoints + [unknown]).isEmpty)
    #expect(try project(directEvent, imports: []).isEmpty)
    var incomplete = importReceipt; incomplete.completed = false
    #expect(try project(directEvent, imports: [incomplete]).isEmpty)
    var tombstone = endpoints; tombstone[1].deleted = true
    #expect(try project(directEvent, tombstone).isEmpty)
    var changed = endpoints[1]; changed.personID = "person-2"
    #expect(throws: (any Error).self) { try project(directEvent, endpoints + [changed]) }
}

@Test func incomingMessagesAndAnsweredCallsRequireTheirOwnEndpointSemantics() throws {
    var received = directEvent; received.direction = "incoming"; received.messageState = "received"
    var rows = endpoints; rows[0].role = "recipient"; rows[1].role = "sender"
    let incoming = try #require(ContactMetadataProjection.interactions(event: received, participants: rows, imports: [importReceipt]).first)
    #expect(incoming.kind == .incomingMessage)
    #expect(!incoming.qualifies(settings: .init(), now: eventTime.addingTimeInterval(60)))
    var call = directEvent; call.kind = "call"; call.messageState = nil; call.callOutcome = "answered"
    rows = endpoints; rows[0].role = "caller"; rows[1].role = "callee"
    #expect(try ContactMetadataProjection.interactions(event: call, participants: rows, imports: [importReceipt]).first?.kind == .answeredCall)
    for outcome in ["missed", "declined", "failed", "unknown"] {
        call.callOutcome = outcome
        #expect(try ContactMetadataProjection.interactions(event: call, participants: rows, imports: [importReceipt]).isEmpty)
    }
    call.callOutcome = "answered"
    #expect(try ContactMetadataProjection.interactions(event: call, participants: endpoints, imports: [importReceipt]).isEmpty)
    rows[1].role = "caller"
    #expect(try ContactMetadataProjection.interactions(event: call, participants: rows, imports: [importReceipt]).isEmpty)
}

@Test func correctedParticipantRetractsTheOldPersonWithoutKeepingARecencyMaximum() throws {
    let before = try ContactMetadataProjection.interactions(event: directEvent, participants: endpoints, imports: [importReceipt])
    var rows = endpoints; rows[1].personID = "person-2"
    let after = try ContactMetadataProjection.interactions(event: directEvent, participants: rows, imports: [importReceipt])
    #expect(before.map(\.personID) == ["person-1"])
    #expect(after.map(\.personID) == ["person-2"])
    let assessment = ReachOutAssessment(personID: "person-1", interactions: after, history: .incomplete,
        settings: .init(), now: eventTime.addingTimeInterval(60))
    #expect(assessment.lastContact == nil)
    #expect(!assessment.notificationEligible)
}
