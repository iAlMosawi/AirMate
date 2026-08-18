#if os(macOS)
import Charts
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: DeviceStore
    @StateObject private var audio = AudioDeviceService()
    @State private var selectedDeviceID: UUID?

    private var selectedSamples: [BatteryHistorySample] {
        guard let selectedDeviceID else { return Array(store.history.samples.suffix(120)) }
        return Array(store.history.samples.filter { $0.deviceID == selectedDeviceID }.suffix(240))
    }

    var body: some View {
        Form {
            Section("Devices") {
                Toggle("Show generic nearby Bluetooth devices", isOn: $settings.showNearbyBluetooth)
                Toggle("Hide disconnected devices", isOn: $settings.hideDisconnectedDevices)
                Toggle("Show only devices with battery data", isOn: $settings.showBatteryDevicesOnly)
                Toggle("Show connection HUD", isOn: $settings.showConnectionHUD)
                Toggle("Show signal strength", isOn: $settings.showSignalStrength)
                Toggle("Discover nearby Macs running AirMate", isOn: $settings.nearbyMacsEnabled)
                LabeledContent("Pinned devices", value: "\(settings.favoriteDeviceIDs.count)")
                Text("AirMate's main device list is connected-only. Bonjour provides fast local sync; private CloudKit adds cross-network sync between your AirMate devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cloud Sync") {
                LabeledContent("Status", value: store.cloudSync.statusText)
                if let date = store.cloudSync.lastSync {
                    LabeledContent("Last sync", value: date.formatted(date: .omitted, time: .shortened))
                }
                LabeledContent("Live cloud devices", value: "\(store.cloudSync.peers.count)")
                Text("Cloud sync uses the private iCloud container iCloud.com.almosawi.airmate. A remote snapshot is treated as live only when that AirMate device has refreshed recently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Sync Cloud Now") { store.cloudSync.refresh() }
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

            Section("Battery Statistics") {
                Picker("Device", selection: $selectedDeviceID) {
                    Text("All recent samples").tag(nil as UUID?)
                    ForEach(store.devices.filter { $0.hasAnyBattery }) { device in
                        Text(device.name).tag(device.id as UUID?)
                    }
                }

                if selectedSamples.isEmpty {
                    ContentUnavailableView(
                        "No history yet",
                        systemImage: "chart.xyaxis.line",
                        description: Text("AirMate will build battery history while it runs.")
                    )
                    .frame(height: 120)
                } else {
                    Chart(selectedSamples) { sample in
                        LineMark(
                            x: .value("Time", sample.date),
                            y: .value("Battery", sample.level)
                        )
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value("Time", sample.date),
                            y: .value("Battery", sample.level)
                        )
                        .symbolSize(12)
                    }
                    .chartYScale(domain: 0...100)
                    .frame(height: 160)
                }
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
                Toggle("Launch AirMate at login", isOn: $settings.launchAtLogin)
                Text("AirMate exposes a Refresh AirMate Devices action to the Shortcuts app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                LabeledContent("Bluetooth", value: store.bluetoothStateText)
                LabeledContent("Devices visible", value: "\(store.devices.count)")
                LabeledContent("Battery-capable", value: "\(store.devices.filter { $0.hasAnyBattery }.count)")
                LabeledContent("Nearby Mac sharing", value: settings.nearbyMacsEnabled ? "Enabled" : "Disabled")
                LabeledContent("CloudKit", value: store.cloudSync.statusText)
                Button("Refresh all device services") { store.refresh() }
            }

            Section("About") {
                LabeledContent("Application", value: "AirMate")
                LabeledContent("Version", value: "0.8.0 beta")
                LabeledContent("Minimum macOS", value: "26.0")
                LabeledContent("Bundle ID", value: "com.almosawi.airmate")
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { audio.start() }
        .onChange(of: settings.nearbyMacsEnabled) { _, enabled in
            store.setNearbyMacsEnabled(enabled)
        }
    }
}
#endif
