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
                .frame(width: 580, height: 500)
        }
    }
}

struct RefreshAirMateIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh AirMate Devices"
    static let description = IntentDescription("Opens AirMate so its nearby device information can refresh.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result(dialog: "AirMate is ready.")
    }
}
