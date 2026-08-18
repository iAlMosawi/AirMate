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
                .frame(width: 360)
                .task {
                    deviceStore.start()
                }
        } label: {
            Label("AirMate", systemImage: "airpodspro")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appSettings)
                .frame(width: 520, height: 380)
        }
    }
}
