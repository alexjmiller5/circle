import SwiftUI

struct GraphDetails: View {
    let graph: SocialGraph
    let state: ExplorerState
    @Binding var trackedIDs: Set<String>
    let select: (GraphFocus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch state.focus {
            case .person(let id):
                if let person = graph.byID[id] {
                    Text("IN FOCUS").font(.caption).foregroundStyle(.secondary)
                    Text(person.name).font(.system(.title2, design: .rounded).weight(.semibold))
                    Text(person.circles.isEmpty ? "No circles recorded" : person.circles.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if id != graph.selfID {
                        Button(trackedIDs.contains(id) ? "Stop tracking" : "Track for reach-out") {
                            if trackedIDs.contains(id) { trackedIDs.remove(id) } else { trackedIDs.insert(id) }
                        }.buttonStyle(.bordered)
                            .accessibilityIdentifier("tracking-\(id)")
                            .accessibilityValue(trackedIDs.contains(id) ? "Tracked" : "Not tracked")
                        Text("Saved in Circle. Nearby alerts include everyone with a fresh location.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    location("Based in", value: graph.city(of: person, mode: .base))
                    location("Currently in", value: person.currentCity)
                    Divider()
                    Text("Recorded connections").font(.subheadline.weight(.medium))
                    if graph.neighbors(of: id).isEmpty {
                        Text("No connections recorded").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(graph.people.filter { graph.neighbors(of: id).contains($0.id) }) { neighbor in
                        VStack(alignment: .leading, spacing: 3) {
                            Button(neighbor.name) { select(.person(neighbor.id)) }.buttonStyle(.bordered)
                            Text(relationLabel(from: id, to: neighbor.id)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            case .group(let id):
                if let group = graph.groups(by: state.grouping, location: state.location).first(where: { $0.id == id }) {
                    Text("GROUP IN FOCUS").font(.caption).foregroundStyle(.secondary)
                    Text(group.name).font(.system(.title2, design: .rounded).weight(.semibold))
                    Text("\(group.members.count) people").foregroundStyle(.secondary)
                    ForEach(group.members, id: \.self) { id in
                        if let person = graph.byID[id] {
                            Button(person.name) { select(.person(id)) }.buttonStyle(.bordered)
                        }
                    }
                    Text("Shared membership does not imply a friendship.").font(.caption).foregroundStyle(.secondary)
                }
            case nil:
                Text("Select a person or group").font(.headline)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func location(_ title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value?.isEmpty == false ? value! : "Unknown").font(.subheadline)
        }
    }

    private func relationLabel(from id: String, to neighbor: String) -> String {
        let relevant = graph.relations.filter {
            ($0.personID == id && $0.relatedID == neighbor) || ($0.personID == neighbor && $0.relatedID == id)
        }
        if let intro = relevant.first(where: { $0.kind == "met_through" }) {
            return intro.personID == id ? "Met through this person" : "Introduced through the selected person"
        }
        return relevant.map { $0.kind.replacingOccurrences(of: "_", with: " ") }.sorted().joined(separator: ", ")
    }
}
