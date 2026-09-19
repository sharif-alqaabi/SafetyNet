import SwiftUI

struct FamilyHomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Watching \(model.profile.personName)’s \(model.profile.room)")
                .font(.title2.weight(.semibold))
            Text(model.live.isConnected || model.incident != nil ? "Hub online" : "Waiting for hub")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Home code \(model.profile.homeCode)")
                .font(.footnote.monospaced())
            if let incident = model.incident {
                IncidentView(
                    incident: incident,
                    onTalk: {
                        Task {
                            if let url = URL(string: model.backendBase) {
                                await model.talk.start(incidentId: incident.id, baseURL: url)
                            }
                        }
                    },
                    onTheWay: { model.markOnTheWay() },
                    talking: model.talk.isTalking
                )
            } else {
                ContentUnavailableView(
                    "No incident",
                    systemImage: "heart.text.clipboard",
                    description: Text("You’ll get a card and a call if \(model.profile.personName) falls.")
                )
            }
            Button("Refresh") {
                Task { await model.refreshFamilyIncident() }
            }
        }
        .padding()
        .task {
            await model.refreshFamilyIncident()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await model.refreshFamilyIncident()
            }
        }
    }
}
