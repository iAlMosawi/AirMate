#if os(macOS)
import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var settings: AppSettings

    private var visibleDevices: [AirMateDevice] {
        var filtered = store.devices.filter { $0.connectionState == .connected }

        if settings.showBatteryDevicesOnly {
            filtered = filtered.filter(\.hasAnyBattery)
        }

        return filtered.sorted { lhs, rhs in
            let leftFavorite = settings.isFavorite(lhs.id)
            let rightFavorite = settings.isFavorite(rhs.id)
            if leftFavorite != rightFavorite { return leftFavorite && !rightFavorite }
            if lhs.kind == .mac && rhs.kind != .mac { return true }
            if lhs.kind != .mac && rhs.kind == .mac { return false }
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
                    "No connected devices",
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
        if settings.showBatteryDevicesOnly {
            return "No connected devices with battery information are currently available. Turn off Battery devices only in Settings to see all connected devices."
        }
        return "AirMate now lists connected devices only. Connect a Bluetooth accessory in macOS Settings or start AirMate on another Mac, iPhone or iPad on this network."
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 38, height: 38)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 19, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("AirMate")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(.green)
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
            .help("Refresh connected devices")
        }
        .padding(12)
    }

    private var summary: some View {
        HStack(spacing: 12) {
            Label("\(visibleDevices.count) connected", systemImage: "link.circle")
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
