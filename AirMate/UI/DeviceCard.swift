#if os(macOS)
import SwiftUI

struct DeviceCard: View {
    let device: AirMateDevice
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary).frame(width: 56, height: 56)
                Image(systemName: device.symbolName).font(.system(size: 25, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(device.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 7) {
                    Text(device.connectionState.rawValue.capitalized).font(.caption2.weight(.medium)).foregroundStyle(device.connectionState == .connected ? .primary : .secondary)
                    if let rssi = device.rssi { Text("\(rssi) dBm").font(.caption2).foregroundStyle(.tertiary) }
                    Text(device.source.rawValue.replacingOccurrences(of: "appleAdvertisement", with: "Apple")).font(.caption2).foregroundStyle(.tertiary)
                }
                if device.kind == .airPods || device.kind == .beats {
                    HStack(spacing: 10) {
                        batteryLabel("L", value: device.batteryLevel, charging: device.isCharging)
                        batteryLabel("R", value: device.secondaryBatteryLevel, charging: device.isSecondaryCharging)
                        batteryLabel("Case", value: device.caseBatteryLevel, charging: device.isCaseCharging)
                    }
                }
            }
            Spacer(minLength: 8)
            if let level = device.batteryLevel { BatteryGauge(level: level, charging: device.isCharging) }
            else if device.kind == .mac { Text("AC").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.thinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.quaternary, lineWidth: 0.5))
    }
    private func batteryLabel(_ title: String, value: Int?, charging: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title); Text(value.map { "\($0)%" } ?? "—").monospacedDigit()
            if charging { Image(systemName: "bolt.fill").font(.system(size: 7)) }
        }.font(.caption2).foregroundStyle(.secondary)
    }
}

private struct BatteryGauge: View {
    let level: Int; let charging: Bool
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Image(systemName: charging ? "battery.100percent.bolt" : batterySymbol).font(.title3)
            Text("\(level)%").font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
        }
    }
    private var batterySymbol: String {
        switch level { case 76...: return "battery.100percent"; case 51...: return "battery.75percent"; case 26...: return "battery.50percent"; case 11...: return "battery.25percent"; default: return "battery.0percent" }
    }
}
#endif
