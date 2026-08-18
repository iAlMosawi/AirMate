#if os(macOS)
import SwiftUI

struct DeviceHUDView: View {
    let device: AirMateDevice
    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial).frame(width: 96, height: 96)
                Image(systemName: device.symbolName).font(.system(size: 44, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(device.name).font(.title3.weight(.semibold))
                Text(device.connectionState == .connected ? "Connected" : "Nearby").font(.subheadline).foregroundStyle(.secondary)
                if device.kind == .airPods || device.kind == .beats {
                    HStack(spacing: 14) {
                        hudBattery("Left", device.batteryLevel, device.isCharging)
                        hudBattery("Right", device.secondaryBatteryLevel, device.isSecondaryCharging)
                        hudBattery("Case", device.caseBatteryLevel, device.isCaseCharging)
                    }
                } else if let level = device.batteryLevel {
                    ProgressView(value: Double(level), total: 100).frame(width: 170)
                    Text("\(level)% battery").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.quaternary, lineWidth: 0.5))
        .shadow(radius: 24, y: 12)
    }
    private func hudBattery(_ label: String, _ value: Int?, _ charging: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Text(value.map { "\($0)%" } ?? "—").font(.caption.monospacedDigit().weight(.semibold))
                if charging { Image(systemName: "bolt.fill").font(.system(size: 8)) }
            }
        }
    }
}
#endif
