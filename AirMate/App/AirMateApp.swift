#if os(macOS)
import AppIntents
import SwiftUI

@main
struct AirMateApp: App {
    @StateObject private var deviceStore = DeviceStore()
    @StateObject private var appSettings = AppSettings()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(deviceStore)
                .environmentObject(appSettings)
                .preferredColorScheme(appSettings.appearance.colorScheme)
                .frame(width: 380)
                .task {
                    deviceStore.start(settings: appSettings)
                }
        } label: {
            Label("AirMate", systemImage: "airpodspro")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appSettings)
                .environmentObject(deviceStore)
                .preferredColorScheme(appSettings.appearance.colorScheme)
                .frame(width: 580, height: 540)
        }
    }
}

struct RefreshAirMateIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh AirMate Devices"
    static let description = IntentDescription("Opens AirMate so its connected device information can refresh.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result(dialog: "AirMate is ready.")
    }
}
#endif
