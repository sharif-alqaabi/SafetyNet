import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("This device") {
                Picker("Role", selection: $model.role) {
                    ForEach(DeviceRole.allCases) { role in
                        Text(role.title).tag(role)
                    }
                }
                Toggle("This device is the home hub", isOn: hubBinding)
                Toggle("Dev camera preview", isOn: $model.showDevPreview)
                    .disabled(model.role != .hub)
            }
            Section("Pairing") {
                Text("Family pastes this home code. Hub can show it as a QR on a second screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let image = QRCode.image(from: model.profile.homeCode) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                        .padding(.vertical, 8)
                }
            }
            Section("Home") {
                TextField("Person", text: $model.profile.personName)
                TextField("Address", text: $model.profile.address)
                TextField("Room", text: $model.profile.room)
                TextField("Family name", text: $model.profile.contactName)
                TextField("Family number", text: $model.profile.contactNumber)
                    .keyboardType(.phonePad)
                Toggle("Blood thinners", isOn: $model.profile.bloodThinners)
                TextField("Home code", text: $model.profile.homeCode)
                    .textInputAutocapitalization(.characters)
            }
            Section("Backend") {
                TextField("API base", text: $model.backendBase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Use this URL") { model.applyBackend() }
            }
            Section("Disclaimer") {
                Text("Not a medical device. Demo calls a designated number. Never real 911.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("FallGuard")
    }

    private var hubBinding: Binding<Bool> {
        Binding(
            get: { model.role == .hub },
            set: { model.role = $0 ? .hub : .family }
        )
    }
}
