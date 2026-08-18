import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: DeviceStore
    @StateObject private var audio = AudioDeviceService()

    var body: some View {
        Form {
            Section("Devices") {
                Toggle("Show generic nearby Bluetooth devices", isOn: $settings.showNearbyBluetooth)
                Toggle("Show connection HUD", isOn: $settings.showConnectionHUD)
                Toggle("Show signal strength", isOn: $settings.showSignalStrength)
                Toggle("Discover nearby Macs running AirMate", isOn: $settings.nearbyMacsEnabled)
            }

            Section("Battery") {
                Toggle("Battery alerts", isOn: $settings.batteryAlertsEnabled)
                Toggle("Keep battery history", isOn: $settings.batteryHistoryEnabled)
                HStack {
                    Text("Low battery threshold")
                    Spacer()
                    Picker("Threshold", selection: $settings.lowBatteryThreshold) {
                        ForEach([10, 15, 20, 25, 30], id: \.self) { Text("\($0)%").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
                LabeledContent("History samples", value: "\(store.history.samples.count)")
            }

            Section("Audio") {
                LabeledContent("Current output", value: audio.currentOutputName)
                Picker("Output device", selection: Binding(
                    get: { audio.currentOutputID },
                    set: { newValue in
                        if let device = audio.outputs.first(where: { $0.id == newValue }) {
                            _ = audio.setDefaultOutput(device)
                        }
                    }
                )) {
                    ForEach(audio.outputs) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                Button("Refresh audio devices") { audio.refresh() }
            }

            Section("Automation") {
                Text("AirMate exposes a Refresh AirMate Devices action to the Shortcuts app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Application", value: "AirMate")
                LabeledContent("Version", value: "0.5.0 beta")
                LabeledContent("Minimum macOS", value: "26.0")
                LabeledContent("Bundle ID", value: "com.almosawi.airmate")
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { audio.start() }
    }
}
