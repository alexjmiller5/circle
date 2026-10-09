import Foundation
import Testing
@testable import CircleGraph

private let phone = ContactHandle(kind: .phone, value: "(555) 010-0199", label: "mobile")
private let email = ContactHandle(kind: .email, value: "someone@example.com", label: "home")
private let card = ContactCard(id: "C1", name: "Person 1", handles: [email, phone])

@Test func deepLinksUseEachAppsSchemeWithFallbacks() {
    func strings(_ action: ContactAction, _ handle: ContactHandle, mac: Bool) -> [String] {
        ContactLinks.urls(for: action, handle: handle, mac: mac, callingCode: "1").map(\.absoluteString)
    }
    #expect(strings(.message, phone, mac: false) == ["sms:5550100199"])
    #expect(strings(.message, email, mac: false) == ["sms:someone@example.com"])
    #expect(strings(.message, email, mac: true) == ["imessage:someone@example.com", "sms:someone@example.com"])
    #expect(strings(.whatsapp, phone, mac: false) == ["whatsapp://send?phone=15550100199", "https://wa.me/15550100199"])
    #expect(strings(.whatsapp, email, mac: false).isEmpty)
    #expect(strings(.call, phone, mac: false) == ["tel:5550100199"])
    #expect(strings(.call, phone, mac: true) == ["tel:5550100199", "facetime-audio:5550100199"])
    #expect(strings(.call, email, mac: false).isEmpty)
    #expect(strings(.facetime, email, mac: false) == ["facetime:someone@example.com"])
    #expect(strings(.facetimeAudio, phone, mac: true) == ["facetime-audio:5550100199"])
    let international = ContactHandle(kind: .phone, value: "+44 20 7946 0000", label: nil)
    #expect(strings(.call, international, mac: false) == ["tel:+442079460000"])
}

@Test func whatsAppNumbersAreInternationalDigitsOnly() {
    #expect(ContactLinks.whatsAppNumber("+44 20 7946 0000", callingCode: "1") == "442079460000")
    #expect(ContactLinks.whatsAppNumber("0044 20 7946 0000", callingCode: nil) == "442079460000")
    #expect(ContactLinks.whatsAppNumber("(555) 010-0199", callingCode: "1") == "15550100199")
    #expect(ContactLinks.whatsAppNumber("1 555 010 0199", callingCode: "1") == "15550100199")
    // A national number without a known calling code cannot be addressed.
    #expect(ContactLinks.whatsAppNumber("020 7946 0000", callingCode: nil) == nil)
    #expect(ContactLinks.whatsAppNumber("call me", callingCode: "1") == nil)
    #expect(ContactLinks.callingCode(region: "US") == "1")
    #expect(ContactLinks.callingCode(region: "FR") == nil)
}

@Test func actionsOfferOnlyHandlesTheyCanUse() {
    #expect(ContactLinks.handles(for: .call, in: card) == [phone])
    #expect(ContactLinks.handles(for: .whatsapp, in: card) == [phone])
    #expect(ContactLinks.handles(for: .message, in: card) == [phone, email])
    #expect(ContactLinks.handles(for: .facetime, in: card) == [phone, email])
}

@Test func linkedAddressBookCardWinsOverANameMatch() {
    var nameSearches = 0
    let cards = ["C1:ABPerson": card]
    let linked = ContactLinks.resolve(sourceIDs: ["C1:ABPerson"], name: "Person 1",
                                      byID: { cards[$0] }, byName: { _ in nameSearches += 1; return [] })
    #expect(linked == .linked([card]))
    #expect(nameSearches == 0)
    // iOS identifiers carry no ":ABPerson" suffix.
    let bare = ContactLinks.resolve(sourceIDs: ["C1:ABPerson"], name: "Person 1",
                                    byID: { $0 == "C1" ? card : nil }, byName: { _ in [] })
    #expect(bare == .linked([card]))
    let other = ContactCard(id: "C2", name: "Person 1", handles: [phone])
    let byName = ContactLinks.resolve(sourceIDs: ["gone:ABPerson"], name: "Person 1",
                                      byID: { _ in nil }, byName: { $0 == "Person 1" ? [card, other] : [] })
    #expect(byName == .byName([card, other]))
    #expect(ContactLinks.resolve(sourceIDs: [], name: "Nobody", byID: { _ in nil }, byName: { _ in [] }) == .none)
    let empty = ContactCard(id: "C3", name: "Person 3", handles: [])
    #expect(ContactLinks.resolve(sourceIDs: ["C3"], name: "Person 3", byID: { _ in empty }, byName: { _ in [] }) == .linked([empty]))
}
