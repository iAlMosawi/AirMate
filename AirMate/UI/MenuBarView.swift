#if os(macOS)
import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var settings: AppSettings

    private var visibleDevices: [AirMateDevice] {
        var filtered = settings.showNearbyBluetooth ? store.devices : store.devices.filter { $0.kind != .bluetooth }

        if settings.hideDisconnectedDevices {
            filtered = filtered.filter { $0.connectionState != .disconnected }
        }

        if settings.showBatteryDevicesOnly {
            filtered = filtered.filter(\.hasAnyBattery)
        }

        return filtered.sorted { lhs, rhs in
            let leftFavorite = settings.isFavorite(lhs.id)
            let rightFavorite = settings.isFavorite(rhs.id)
            if leftFavorite != rightFavorite { return leftFavorite && !rightFavorite }
            if lhs.connectionState != rhs.connectionState { return lhs.connectionState == .connected }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var lowBatteryDevices: [AirMateDevice] {
        visibleDevices.filter { device in
            guard let level = device.batteryLevel else { return false }
            return level <= settings.lowBatteryThreshold && !device.isCharging
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            summary

            if visibleDevices.isEmpty {
                ContentUnavailableView(
                    "No matching devices",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(emptyStateMessage)
                )
                .frame(height: 220)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleDevices) { device in
                            DeviceCard(device: device)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 440)
            }

            Divider()
            footer
        }
        .background(.regularMaterial)
    }

    private var emptyStateMessage: String {
        if settings.showBatteryDevicesOnly || settings.hideDisconnectedDevices {
            return "No devices match the current visibility filters. Adjust them in Settings or refresh discovery."
        }
        return "AirMate is scanning for nearby devices. Keep Bluetooth enabled and open your AirPods case nearby."
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 38, height: 38)
                Image(systemName: "airpodspro")
                    .font(.system(size: 19, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("AirMate")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .frame(width: 6, height: 6)
                    Text(store.bluetoothStateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh devices")
        }
        .padding(12)
    }

    private var summary: some View {
        HStack(spacing: 12) {
            Label("\(visibleDevices.count) devices", systemImage: "rectangle.stack")
            Spacer()
            if !lowBatteryDevices.isEmpty {
                Label("\(lowBatteryDevices.count) low", systemImage: "battery.25percent")
                    .foregroundStyle(.orange)
            } else {
                Label("Battery OK", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Quit AirMate") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(12)
    }
}
#endif
