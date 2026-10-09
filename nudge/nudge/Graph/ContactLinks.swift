import Foundation

enum ContactAction: String, CaseIterable, Sendable {
    case message, whatsapp, call, facetime, facetimeAudio

    var label: String {
        switch self {
        case .message: "Message"
        case .whatsapp: "WhatsApp"
        case .call: "Call"
        case .facetime: "FaceTime"
        case .facetimeAudio: "FaceTime audio"
        }
    }
    var symbol: String {
        switch self {
        case .message: "message"
        case .whatsapp: "bubble.left.and.text.bubble.right"
        case .call: "phone"
        case .facetime: "video"
        case .facetimeAudio: "phone.badge.waveform"
        }
    }
    var needsPhone: Bool { self == .whatsapp || self == .call }
}

/// A phone number or email read from the device's Contacts at the moment of use. Never stored.
struct ContactHandle: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case phone, email }
    var kind: Kind
    var value: String
    var label: String?
}

struct ContactCard: Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var handles: [ContactHandle]
}

enum ContactMatch: Equatable, Sendable {
    /// Found through the person's confirmed address-book link.
    case linked([ContactCard])
    /// Found by the canonical name only; the user chooses.
    case byName([ContactCard])
    case none
}

enum ContactLinks {
    /// Confirmed address-book links first (Mac identifiers end in ":ABPerson"; iOS ones do not),
    /// then the canonical name.
    static func resolve(sourceIDs: [String], name: String, byID: (String) throws -> ContactCard?,
                        byName: (String) throws -> [ContactCard]) rethrows -> ContactMatch {
        var linked: [ContactCard] = []
        for id in sourceIDs {
            let bare = id.hasSuffix(":ABPerson") ? String(id.dropLast(":ABPerson".count)) : id
            for candidate in Set([id, bare]).sorted() {
                if let card = try byID(candidate), !linked.contains(card) { linked.append(card); break }
            }
        }
        if !linked.isEmpty { return .linked(linked) }
        let named = try byName(name)
        return named.isEmpty ? .none : .byName(named)
    }

    static func handles(for action: ContactAction, in card: ContactCard) -> [ContactHandle] {
        let phones = card.handles.filter { $0.kind == .phone }
        return action.needsPhone ? phones : phones + card.handles.filter { $0.kind == .email }
    }

    /// Ordered candidates: the first is the app's own scheme, the rest are fallbacks.
    /// Opening one is a compose view, never a contact.
    static func urls(for action: ContactAction, handle: ContactHandle, mac: Bool, callingCode: String?) -> [URL] {
        let address: String
        switch handle.kind {
        case .phone: address = dialable(handle.value)
        case .email: address = handle.value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        }
        guard !address.isEmpty else { return [] }
        let candidates: [String]
        switch (action, handle.kind) {
        case (.message, _): candidates = mac ? ["imessage:\(address)", "sms:\(address)"] : ["sms:\(address)"]
        case (.whatsapp, .phone):
            guard let number = whatsAppNumber(handle.value, callingCode: callingCode) else { return [] }
            candidates = ["whatsapp://send?phone=\(number)", "https://wa.me/\(number)"]
        case (.call, .phone): candidates = mac ? ["tel:\(address)", "facetime-audio:\(address)"] : ["tel:\(address)"]
        case (.facetime, _): candidates = ["facetime:\(address)"]
        case (.facetimeAudio, _): candidates = ["facetime-audio:\(address)"]
        case (.whatsapp, .email), (.call, .email): return []
        }
        return candidates.compactMap(URL.init(string:))
    }

    private static func dialable(_ raw: String) -> String {
        let digits = raw.filter(\.isASCII).filter(\.isNumber)
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("+") { return "+" + digits }
        if trimmed.hasPrefix("00"), digits.count > 2 { return "+" + digits.dropFirst(2) }
        return digits
    }

    /// WhatsApp needs the full international number as digits.
    static func whatsAppNumber(_ raw: String, callingCode: String?) -> String? {
        let number = dialable(raw)
        if number.hasPrefix("+") { return number.count > 4 ? String(number.dropFirst()) : nil }
        // ponytail: national numbers are completed for NANP regions only; elsewhere they need a "+" in Contacts.
        guard let callingCode, callingCode == "1" else { return nil }
        if number.count == 10 { return "1" + number }
        if number.count == 11, number.hasPrefix("1") { return number }
        return nil
    }

    static func callingCode(region: String?) -> String? {
        ["US", "CA", "PR", "GU", "VI", "AS", "MP", "BS", "BB", "JM", "TT", "DO"].contains(region ?? "") ? "1" : nil
    }
}
