import SwiftUI

enum ReachOutScope: String, CaseIterable { case tracked = "Tracked", all = "All with history" }

struct ReachOutTab: View {
    let graph: SocialGraph
    @Environment(ReachOutModel.self) private var model
    @State private var scope: ReachOutScope?
    @State private var selected: GraphPerson?
    @State private var showReminders = false

    private var effectiveScope: ReachOutScope { scope ?? (model.trackedIDs.isEmpty ? .all : .tracked) }

    private var people: [GraphPerson] {
        graph.people.filter { person in
            person.id != graph.selfID && (model.trackedIDs.contains(person.id)
                || (effectiveScope == .all && model.history?.channels[person.id] != nil))
        }
    }

    var body: some View {
        let now = Date()
        let rows = people.map { ($0, model.assessment($0.id, now: now)) }
        NavigationStack {
            List {
                Section { ReachOutCoverageSummary() }
                Section {
                    Picker("Show", selection: Binding(get: { effectiveScope }, set: { scope = $0 })) {
                        ForEach(ReachOutScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).accessibilityIdentifier("reachout-scope")
                    if effectiveScope == .tracked && model.trackedIDs.isEmpty {
                        Text("Track people from the explorer to keep a short list here.").font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = model.settingsError { Text(error).foregroundStyle(.red) }
                }
                ForEach(ReachOutBucket.allCases, id: \.self) { bucket in
                    let members = rows.filter { $0.1.bucket == bucket }.sorted { left, right in
                        let l = left.1.score == 0 ? Double(model.settings(left.0.id).priority.rawValue) : left.1.score
                        let r = right.1.score == 0 ? Double(model.settings(right.0.id).priority.rawValue) : right.1.score
                        return l == r ? left.0.name.localizedStandardCompare(right.0.name) == .orderedAscending : l > r
                    }
                    if !members.isEmpty {
                        Section {
                            ForEach(members, id: \.0.id) { person, assessment in
                                ReachOutRow(person: person, assessment: assessment, channels: model.history?.channels[person.id] ?? [],
                                            sourceIDs: model.history?.contactIDs[person.id] ?? []) { selected = person }
                            }
                        } header: {
                            Text("\(bucket.rawValue) · \(members.count)").accessibilityIdentifier("reachout-group-\(bucket)")
                        }
                    }
                }
            }
            .navigationTitle("Reach out")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showReminders = true } label: { Label("Reminder settings", systemImage: "bell.badge") }
                        .accessibilityIdentifier("reminder-settings")
                }
            }
        }
        .sheet(item: $selected) { person in ReachOutPersonSheet(person: person) }
        .sheet(isPresented: $showReminders) { ReminderSettingsSheet() }
        // Tracking is edited in the explorer; read it fresh whenever this tab shows.
        .onAppear { model.reload() }
    }
}

struct ReachOutCoverageSummary: View {
    @Environment(ReachOutModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let history = model.history {
                if let refreshed = history.refreshedAt {
                    Text("History refreshed \(refreshed.formatted(date: .abbreviated, time: .shortened))").font(.subheadline)
                } else {
                    Text("No direct conversations in the connected history yet.").font(.subheadline)
                }
                ForEach(history.sources, id: \.source) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(source.label): \(source.state.rawValue) · read \(source.completedAt.formatted(date: .abbreviated, time: .shortened))")
                        if let reason = source.reason, source.state != .complete { Text(reason).lineLimit(2) }
                    }
                    .font(.caption).foregroundStyle(source.state == .complete ? Color.secondary : Color.orange)
                    .accessibilityElement(children: .combine)
                }
                if history.sources.isEmpty { Text("Import coverage is unknown.").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("Contact history is not connected. Groups show Unknown, never \u{201C}never contacted\u{201D}.").font(.subheadline)
            }
            if let failure = model.historyFailure { Text(failure).font(.caption).foregroundStyle(.red) }
            Text(model.isPreview ? "Synthetic preview history." : "Missing or partial coverage means unknown, not never contacted.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ReachOutRow: View {
    let person: GraphPerson
    let assessment: ReachOutAssessment
    let channels: [ChannelSummary]
    let sourceIDs: [String]
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(person.name).font(.headline)
                        Spacer(minLength: 8)
                        if let days = assessment.elapsedDays { Text("\(days)d").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                    Text(assessment.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let line = Self.channelLine(channels) { Text(line).font(.caption2).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reachout-\(person.id)")
            ContactActionBar(person: person, sourceIDs: sourceIDs, compact: true)
        }
        .padding(.vertical, 4)
    }

    /// Up to three channels, most recent activity first.
    static func channelLine(_ channels: [ChannelSummary]) -> String? {
        let style = Date.FormatStyle().month(.abbreviated).day()
        let parts = channels.map { summary -> (Date, String) in
            let events = [("sent", summary.lastSent), ("received", summary.lastReceived), ("answered", summary.lastAnsweredCall)]
                .compactMap { label, date in date.map { (label, $0) } }
            let text = events.map { "\($0.0) \($0.1.formatted(style))" }.joined(separator: ", ")
            return (([summary.lastCall] + events.map { Optional($0.1) }).compactMap { $0 }.max() ?? .distantPast,
                    "\(summary.channel.label): \(text.isEmpty ? "calls only" : text)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.sorted { $0.0 > $1.0 }.prefix(3).map(\.1).joined(separator: " · ")
    }
}

struct ReachOutPersonSheet: View {
    let person: GraphPerson
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { ReachOutSections(person: person) }
                .formStyle(.grouped)
                .navigationTitle(person.name)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 620)
        #endif
    }
}

/// Reach-out status, history per channel, coverage and settings for one person.
struct ReachOutSections: View {
    let person: GraphPerson
    @Environment(ReachOutModel.self) private var model

    var body: some View {
        let assessment = model.assessment(person.id)
        let channels = model.history?.channels[person.id] ?? []
        let settings = Binding(get: { model.settings(person.id) }, set: { model.preferences[person.id] = $0 })
        Section("Reach out") {
            Text(assessment.bucket.rawValue).font(.headline).accessibilityIdentifier("reachout-status")
            Text(assessment.reason).font(.callout)
            ContactActionBar(person: person, sourceIDs: model.history?.contactIDs[person.id] ?? [])
            Text("Opening a conversation does not count as contact. Numbers come from this device's Contacts and are never saved.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("History by channel") {
            if model.history == nil { Text("Contact history is not connected.").foregroundStyle(.secondary) }
            else if channels.isEmpty { Text("No direct messages or calls in the connected history.").foregroundStyle(.secondary) }
            ForEach(channels.sorted { $0.channel.rawValue < $1.channel.rawValue }, id: \.channel) { summary in
                ChannelHistoryRow(summary: summary, coverage: model.history?.coverage(of: summary.channel) ?? [])
            }
        }
        Section("Cadence and priority") {
            cadence(settings.cadence, prefix: "cadence")
            HStack {
                ForEach(ContactPriority.allCases, id: \.self) { priority in
                    option(priority.label, selected: settings.wrappedValue.priority == priority, id: "priority-\(priority)") {
                        settings.wrappedValue.priority = priority
                    }
                }
            }
        }
        Section {
            resetToggle("A successfully sent direct message", kind: .outgoingMessage, settings: settings)
            resetToggle("An answered direct call", kind: .answeredCall, settings: settings)
            resetToggle("An explicitly logged hangout", kind: .hangout, settings: settings)
            resetToggle("A received direct message", kind: .incomingMessage, settings: settings)
        } header: { Text("Reset the clock after") } footer: {
            Text("Group conversations, unanswered calls and opening a conversation never count.")
        }
        HangoutSection(person: person, days: model.history?.hangoutDays(for: person.id, calendar: .current) ?? [])
        Section("Reminders") {
            Toggle("Reach-out reminders", isOn: Binding(get: { settings.wrappedValue.remindersEnabled }, set: { on in
                Task { await model.enableReminders(on, for: person.id) }
            })).accessibilityIdentifier("reminders-toggle")
            if let message = model.reminderMessage { Text(message).font(.caption).foregroundStyle(.red) }
            if let until = settings.wrappedValue.snoozedUntil, until > Date() {
                Text("Snoozed until \(until.formatted(date: .abbreviated, time: .omitted))")
                Button("Clear snooze") { settings.wrappedValue.snoozedUntil = nil }
            } else {
                Button("Snooze for a week") {
                    settings.wrappedValue.snoozedUntil = Calendar.current.date(byAdding: .day, value: 7, to: Date())
                }
            }
        }
        .disabled(model.settingsError != nil)
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

struct ChannelHistoryRow: View {
    let summary: ChannelSummary
    let coverage: [SourceCoverage]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary.channel.label).font(.headline)
            Group {
                if summary.sent + summary.received > 0 || summary.lastSent != nil || summary.lastReceived != nil {
                    line("Sent", summary.lastSent, count: summary.sent)
                    line("Received", summary.lastReceived, count: summary.received)
                }
                if summary.callsAnswered + summary.callsMissed > 0 || summary.lastCall != nil {
                    line("Answered call", summary.lastAnsweredCall, count: summary.callsAnswered,
                         extra: summary.answeredSeconds.map { " (\(Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))))" })
                    if summary.callsMissed > 0 { Text("Missed calls: \(summary.callsMissed)") }
                    if let call = summary.lastCall { Text("Last call of any kind: \(call.formatted(date: .abbreviated, time: .omitted))") }
                }
                Text(window).foregroundStyle(.secondary)
                ForEach(coverage, id: \.source) { source in
                    Text("\(source.label) import: \(source.state.rawValue)").foregroundStyle(source.state == .complete ? Color.secondary : Color.orange)
                }
                if let review = summary.needsReview { Text("Needs review: \(review)").foregroundStyle(.orange) }
            }.font(.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history-\(summary.channel.rawValue)")
    }

    private var window: String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        switch (summary.coverageStart, summary.coverageEnd) {
        case (let start?, let end?): return "Known from \(start.formatted(style)) through \(end.formatted(style))"
        case (nil, let end?): return "Known through \(end.formatted(style))"
        default: return "Coverage window unknown"
        }
    }

    private func line(_ label: String, _ date: Date?, count: Int, extra: String? = nil) -> some View {
        Text("\(label): \(date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "none in coverage")\(extra ?? "") · \(count) total")
    }
}

struct ReminderSettingsSheet: View {
    @Environment(ReachOutModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Toggle("Hide names on the lock screen", isOn: $model.reminders.hideNames).accessibilityIdentifier("hide-names")
                } footer: { Text("Reminders then read \u{201C}Someone in Circle is due for a reach-out.\u{201D}") }
                Section {
                    Picker("Quiet from", selection: $model.reminders.quietStartHour) { hours }
                    Picker("Quiet until", selection: $model.reminders.quietEndHour) { hours }
                } header: { Text("Quiet hours") } footer: {
                    Text("A reminder due in quiet hours waits until they end. The same hour twice turns quiet hours off.")
                }
                Section {
                    Text("Reminders are off by default. Turn them on per person in their reach-out settings. They are local notifications on this device, recomputed when new history arrives; there is no push server.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Reminders")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    private var hours: some View {
        ForEach(0..<24, id: \.self) { hour in
            Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!.formatted(date: .omitted, time: .shortened)).tag(hour)
        }
    }
}

/// Recomputes local reminders whenever history or settings change.
struct ReachOutReminderScheduling: ViewModifier {
    let model: ReachOutModel
    let people: [GraphPerson]

    func body(content: Content) -> some View {
        content
            .task(id: "\(model.revision)|\(model.history?.refreshedAt?.timeIntervalSince1970 ?? 0)") {
                await model.schedule(people: people)
            }
            .onReceive(NotificationCenter.default.publisher(for: .circleReachOutChanged)) { _ in model.reload() }
    }
}

/// In-person time: the cadence lives on the person in Soma (shared with the push service and
/// Iris), and a logged hangout is a create-only Soma row. Reminders come from the alerts server.
struct HangoutSection: View {
    let person: GraphPerson
    let days: [Date]
    @Environment(\.circleEditor) private var editor
    @Environment(\.circleApp) private var app
    @State private var cadence: String?
    @State private var revision: GraphRowRevision?
    @State private var pendingLog: UUID?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Section {
            if let editor, editor.canEditCadence, revision != nil {
                Picker("Hang out", selection: Binding(get: { cadence }, set: { save($0) })) {
                    Text("No reminders").tag(String?.none)
                    ForEach(ContactCadence.allCases, id: \.self) { Text($0.label).tag(Optional($0.rawValue)) }
                }
                .disabled(busy).accessibilityIdentifier("hangout-cadence")
            } else {
                LabeledContent("Hang out", value: label(cadence))
            }
            Text(lastHangout).font(.callout)
            if editor?.canLogHangouts == true {
                Button("Log a hangout today") { log() }.disabled(busy).accessibilityIdentifier("log-hangout")
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: { Text("In-person hangouts") } footer: {
            Text("A logged hangout resets the reach-out clock. Your alerts server reminds you when it's been longer than this and you're both in the same city.")
        }
        .task(id: person.revision?.hubAt) { cadence = person.hangoutCadence; revision = person.revision }
    }

    private var lastHangout: String {
        guard let last = days.filter({ $0 <= Date() }).max() else { return "No hangout logged yet." }
        let ago = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: last),
                                                  to: Calendar.current.startOfDay(for: Date())).day ?? 0
        return "Last hangout \(last.formatted(date: .abbreviated, time: .omitted)) (\(ago == 0 ? "today" : ReachOutAssessment.days(ago) + " ago"))."
    }

    private func label(_ value: String?) -> String {
        value.flatMap(ContactCadence.init(rawValue:))?.label ?? "No reminders"
    }

    private func save(_ value: String?) {
        guard let editor, let current = revision, value != cadence else { return }
        let previous = cadence
        cadence = value; busy = true; message = nil
        Task {
            do {
                revision = try await editor.setHangoutCadence(value, personID: person.id, revision: current)
                message = value == nil ? "Hangout reminders off." : "Saved."
            } catch {
                cadence = previous
                message = error.localizedDescription
            }
            busy = false
        }
    }

    private func log() {
        guard let editor else { return }
        // The same tap identity is reused until it succeeds, so a lost reply never logs twice.
        let source = pendingLog ?? UUID()
        pendingLog = source; busy = true; message = nil
        let day = Date().formatted(.iso8601.year().month().day())
        Task {
            do {
                _ = try await editor.logHangout(day: day, people: [person.id], sourceID: source, now: Date())
                pendingLog = nil
                message = "Hangout logged for today."
                app?.refresh()
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }
}
