#if os(macOS)
import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var store: DeviceStore
    @EnvironmentObject private var settings: AppSettings

    private var visibleDevices: [AirMateDevice] {
        settings.showNearbyBluetooth ? store.devices : store.devices.filter { $0.kind != .bluetooth }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if visibleDevices.isEmpty {
                ContentUnavailableView(
                    "No devices yet",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("AirMate is scanning for nearby devices.")
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
