import Contacts
import SwiftUI

enum DeviceContactsError: Error { case denied }

/// Reads handles from this device's Contacts at the moment of use. Nothing is stored or sent.
enum DeviceContacts {
    static func match(sourceIDs: [String], name: String) async throws -> ContactMatch {
        try await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            guard try await store.requestAccess(for: .contacts) else { throw DeviceContactsError.denied }
            let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                           CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
            func card(_ contact: CNContact) -> ContactCard {
                let label = { (raw: String?) in raw.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } }
                return ContactCard(id: contact.identifier, name: CNContactFormatter.string(from: contact, style: .fullName) ?? name,
                                   handles: contact.phoneNumbers.map { ContactHandle(kind: .phone, value: $0.value.stringValue, label: label($0.label)) }
                                       + contact.emailAddresses.map { ContactHandle(kind: .email, value: $0.value as String, label: label($0.label)) })
            }
            return try ContactLinks.resolve(sourceIDs: sourceIDs, name: name,
                byID: { id in (try? store.unifiedContact(withIdentifier: id, keysToFetch: keys)).map(card) },
                byName: { try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: $0), keysToFetch: keys).map(card) })
        }.value
    }
}

/// Opens a compose view or call in the right app. Opening never counts as contact.
struct ContactActionBar: View {
    let person: GraphPerson
    let sourceIDs: [String]
    var compact = false
    @Environment(\.openURL) private var openURL
    @State private var choices: Choices?
    @State private var message: String?

    private struct Choice: Hashable { let card: ContactCard; let handle: ContactHandle }
    private struct Choices { let action: ContactAction; let options: [Choice]; let byName: Bool }

    var body: some View {
        Group {
            if compact { HStack(spacing: 8) { buttons } }
            else { LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 8) { buttons } }
        }
        .confirmationDialog(choices.map { "\($0.action.label) \(person.name)" } ?? "", isPresented: Binding(
            get: { choices != nil }, set: { if !$0 { choices = nil } }), titleVisibility: .visible, presenting: choices) { choices in
            ForEach(choices.options, id: \.self) { choice in
                Button(describe(choice, showName: choices.byName || Set(choices.options.map(\.card.id)).count > 1)) {
                    open(choices.action, choice.handle)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { choices in
            Text(choices.byName ? "Matched by name in this device's Contacts. Choose the right card." : "From this device's Contacts.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private var buttons: some View {
        ForEach([ContactAction.message, .call, .whatsapp, .facetime], id: \.self) { action in
            Button { Task { await start(action) } } label: {
                if compact { Image(systemName: action.symbol).frame(minWidth: 28, minHeight: 28) }
                else { Label(action.label, systemImage: action.symbol).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("\(action.label) \(person.name)")
            .accessibilityIdentifier("contact-\(action.rawValue)-\(person.id)")
        }
    }

    private func describe(_ choice: Choice, showName: Bool) -> String {
        [showName ? choice.card.name : nil, choice.handle.label, choice.handle.value].compactMap { $0 }.joined(separator: " · ")
    }

    private func start(_ action: ContactAction) async {
        do {
            let match = try await DeviceContacts.match(sourceIDs: sourceIDs, name: person.name)
            let cards: [ContactCard], byName: Bool
            switch match {
            case .linked(let found): (cards, byName) = (found, false)
            case .byName(let found): (cards, byName) = (found, true)
            case .none: (cards, byName) = ([], false)
            }
            let options = cards.flatMap { card in ContactLinks.handles(for: action, in: card).map { Choice(card: card, handle: $0) } }
            if options.isEmpty {
                message = cards.isEmpty ? "No contact card for \(person.name) on this device."
                    : "The contact card has no \(action.needsPhone ? "phone number" : "phone number or email") for \(action.label)."
            } else if options.count == 1 && !byName {
                open(action, options[0].handle)
            } else {
                choices = Choices(action: action, options: options, byName: byName)
            }
        } catch DeviceContactsError.denied {
            message = "Allow Circle to read Contacts in Settings to open conversations."
        } catch {
            message = "Contacts could not be read."
        }
    }

    private func open(_ action: ContactAction, _ handle: ContactHandle) {
        #if os(macOS)
        let mac = true
        #else
        let mac = false
        #endif
        let urls = ContactLinks.urls(for: action, handle: handle, mac: mac,
                                     callingCode: ContactLinks.callingCode(region: Locale.current.region?.identifier))
        if urls.isEmpty { message = "\(handle.value) cannot be used for \(action.label). Add the full international number in Contacts." }
        attempt(urls[...], action, handle)
    }

    /// Tries the app's own scheme, then each fallback; reports when nothing here can open it.
    private func attempt(_ urls: ArraySlice<URL>, _ action: ContactAction, _ handle: ContactHandle) {
        guard let url = urls.first else { return }
        openURL(url) { accepted in
            if accepted { return }
            if urls.count > 1 { attempt(urls.dropFirst(), action, handle) }
            else { message = "No app on this device opens \(action.label) for \(handle.value)." }
        }
    }
}
