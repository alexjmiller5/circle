import SwiftUI

struct ReachOutView: View {
    let graph: SocialGraph
    let trackedIDs: Set<String>
    @Binding var preferences: [String: ReachOutPreferences]
    let settingsError: String?
    var interactions: [ContactInteraction] = []
    var history: ContactHistoryReadiness = .incomplete
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPersonID: String?

    private var people: [GraphPerson] { graph.people.filter { trackedIDs.contains($0.id) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    if selectedPersonID != nil { Button("Back to list") { selectedPersonID = nil } }
                    Text("Reach out").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Close") { dismiss() }
                }
                if let settingsError { Text(settingsError).foregroundStyle(.red) }
                if let id = selectedPersonID, let person = graph.byID[id] {
                    personSettings(person)
                } else {
                    Text("Track people from the explorer to keep them here. Nearby alerts use their own location rules.")
                        .font(.callout).foregroundStyle(.secondary)
                    if people.isEmpty { Text("No tracked people yet").font(.headline) }
                    ForEach(ReachOutBucket.allCases, id: \.self) { bucket in
                        let members = people.filter { assessment($0.id).bucket == bucket }.sorted {
                            let left = assessment($0.id).score, right = assessment($1.id).score
                            return left == right ? $0.id < $1.id : left > right
                        }
                        if !members.isEmpty {
                            Text(bucket.rawValue).font(.headline)
                            ForEach(members) { person in
                                Button { selectedPersonID = person.id } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(person.name).font(.headline)
                                        reason(assessment(person.id))
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                }.buttonStyle(.bordered).accessibilityIdentifier("reachout-\(person.id)")
                            }
                        }
                    }
                }
            }.padding(24)
        }
        .frame(minWidth: 300, idealWidth: 540, maxWidth: 650, minHeight: 480)
    }

    private func assessment(_ id: String) -> ReachOutAssessment {
        ReachOutAssessment(personID: id, interactions: interactions, history: history,
                           settings: preferences[id] ?? ReachOutPreferences(), now: Date())
    }

    @ViewBuilder private func reason(_ value: ReachOutAssessment) -> some View {
        if value.bucket == .historyIncomplete {
            Text("History is unavailable or incomplete; no due claim is made.").font(.caption).foregroundStyle(.secondary)
        } else if let due = value.dueAt {
            Text("Due \(due.formatted(date: .abbreviated, time: .omitted)) for the chosen cadence.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let last = value.lastContact {
            Text("Last qualifying contact: \(last.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func personSettings(_ person: GraphPerson) -> some View {
        let settings = binding(person.id)
        return VStack(alignment: .leading, spacing: 16) {
            Text(person.name).font(.title.weight(.semibold))
            if interactions.isEmpty { Text("No verified contact history is connected.").foregroundStyle(.secondary) }
            reason(assessment(person.id))
            Divider()
            Text("Contact cadence").font(.headline)
            cadence(settings.cadence, prefix: "cadence")
            Text("Priority").font(.headline)
            HStack {
                ForEach(ContactPriority.allCases, id: \.self) { priority in
                    option(priority.label, selected: settings.wrappedValue.priority == priority, id: "priority-\(priority)") {
                        settings.wrappedValue.priority = priority
                    }
                }
            }
            Text("Reset the outreach clock after").font(.headline)
            resetToggle("A successfully sent direct message", kind: .outgoingMessage, settings: settings)
            resetToggle("An answered direct call", kind: .answeredCall, settings: settings)
            resetToggle("An explicitly logged hangout", kind: .hangout, settings: settings)
            resetToggle("A received direct message", kind: .incomingMessage, settings: settings)
            Text("Only verified events with complete, resolved participants qualify. Opening a conversation does not count.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("In-person hangouts").font(.headline)
            cadence(settings.hangoutCadence, prefix: "hangout-cadence")
            Text("This cadence uses explicit hangout history, independently of calls and messages.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Reach-out reminders", isOn: settings.remindersEnabled)
            Toggle("Hangout reminders", isOn: settings.hangoutRemindersEnabled)
            Text("Preferences are saved locally. Notification delivery is not connected yet.")
                .font(.caption).foregroundStyle(.secondary)
            if let until = settings.wrappedValue.snoozedUntil, until > Date() {
                Text("Snoozed until \(until.formatted(date: .abbreviated, time: .omitted))")
                Button("Clear snooze") { settings.wrappedValue.snoozedUntil = nil }
            } else {
                Button("Snooze for a week") {
                    settings.wrappedValue.snoozedUntil = Calendar.current.date(byAdding: .day, value: 7, to: Date())
                }
            }
        }.disabled(settingsError != nil)
    }

    private func binding(_ id: String) -> Binding<ReachOutPreferences> {
        Binding(get: { preferences[id] ?? ReachOutPreferences() }, set: { preferences[id] = $0 })
    }

    private func cadence(_ value: Binding<ContactCadence>, prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ContactCadence.allCases, id: \.self) { cadence in
                option(cadence.label, selected: value.wrappedValue == cadence, id: "\(prefix)-\(cadence.rawValue)") {
                    value.wrappedValue = cadence
                }
            }
        }
    }

    private func option(_ label: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action).buttonStyle(.bordered)
            .tint(selected ? GraphTheme.accent : .secondary)
            .accessibilityIdentifier(id).accessibilityValue(selected ? "Selected" : "")
    }

    private func resetToggle(_ label: String, kind: ContactInteractionKind, settings: Binding<ReachOutPreferences>) -> some View {
        Toggle(label, isOn: Binding(get: { settings.wrappedValue.resetKinds.contains(kind) }, set: { on in
            if on { settings.wrappedValue.resetKinds.insert(kind) } else { settings.wrappedValue.resetKinds.remove(kind) }
        }))
    }
}
