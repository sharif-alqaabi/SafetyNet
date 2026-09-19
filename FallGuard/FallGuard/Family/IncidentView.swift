import SwiftUI

struct IncidentView: View {
    let incident: Incident
    var onTalk: () -> Void
    var onTheWay: () -> Void
    var talking: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let banner = incident.call911Banner {
                    Text(banner)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.red.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else if incident.cleared {
                    Text("They said they are okay after a check. You can look in anytime.")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.green.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Text("\(incident.personName) fell")
                    .font(.largeTitle.weight(.bold))
                Text(incident.address)
                    .font(.title3)
                cardGrid
                if let clip = incident.clipURL, let url = URL(string: clip) {
                    Link("Watch the fall", destination: url)
                }
                HStack(spacing: 12) {
                    Button("I'm on my way") { onTheWay() }
                        .buttonStyle(HubButtonStyle(kind: .secondary))
                    Button(talking ? "Talking…" : "Talk") { onTalk() }
                        .buttonStyle(HubButtonStyle(kind: .primary))
                        .disabled(talking)
                }
                Text("Not a medical device. If this is real, call 911 to \(incident.address).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private var cardGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Mechanism", incident.mechanism)
            row("Direction", incident.direction)
            row("Impact", incident.impact.isEmpty ? "—" : incident.impact.joined(separator: ", "))
            row("Possible hurt", incident.hurt.isEmpty ? "—" : incident.hurt.joined(separator: ", "))
            if !incident.hurtNote.isEmpty { row("Hurt note", incident.hurtNote) }
            row("Room", incident.room)
            row("Time down", "\(incident.timeDownSec)s")
            row("Responsive", incident.responsive ? "yes" : "no")
            row("Can move", incident.ableToMove == nil ? "—" : (incident.ableToMove! ? "yes" : "no"))
            row("Severity", incident.severity.rawValue)
            if !incident.notes.isEmpty { row("Notes", incident.notes) }
        }
        .padding()
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).fontWeight(.medium)
            Spacer()
        }
        .font(.body)
    }
}
