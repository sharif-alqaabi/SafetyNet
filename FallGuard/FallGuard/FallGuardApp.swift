import SwiftUI
import FirebaseAppCheck
import FirebaseCore

#if DEBUG
private enum AppCheckDebugSecret {
    static let token = "28d302c1-782a-40ca-9b69-7a6515ac7fc7"
}
#endif

@main
struct FallGuardApp: App {
    @StateObject private var model = AppModel()

    init() {
        #if DEBUG
        setenv("AppCheckDebugToken", AppCheckDebugSecret.token, 1)
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #endif
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            Group {
                if model.role == .hub {
                    MonitorView(model: model)
                } else {
                    FamilyHomeView(model: model)
                }
            }
            .tabItem { Label(model.role == .hub ? "Monitor" : "Family", systemImage: model.role == .hub ? "video" : "bell") }

            NavigationStack {
                SettingsView(model: model)
            }
            .tabItem { Label("Settings", systemImage: "gear") }
        }
        .onChange(of: model.role) { _, role in
            if role == .hub {
                model.startHub()
            } else {
                model.stopHub()
            }
        }
    }
}
