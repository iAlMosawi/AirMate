import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Devices") {
                Toggle("Show generic nearby Bluetooth devices", isOn: $settings.showNearbyBluetooth)
                Toggle("Show connection HUD", isOn: $settings.showConnectionHUD)
            }

            Section("Battery alerts") {
                HStack {
                    Text("Low battery threshold")
                    Spacer()
                    Picker("Threshold", selection: $settings.lowBatteryThreshold) {
                        Text("10%").tag(10)
                        Text("15%").tag(15)
                        Text("20%").tag(20)
                        Text("25%").tag(25)
                        Text("30%").tag(30)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }

            Section("About") {
                LabeledContent("Application", value: "AirMate")
                LabeledContent("Minimum macOS", value: "26.0")
                LabeledContent("Bundle ID", value: "com.almosawi.airmate")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
