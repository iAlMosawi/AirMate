import SwiftUI

struct DeviceCard: View {
    let device: AirMateDevice

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 54, height: 54)
                Image(systemName: device.symbolName)
                    .font(.system(size: 24, weight: .medium))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(device.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 7) {
                    connectionBadge
                    if let rssi = device.rssi {
                        Text("\(rssi) dBm")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if device.kind == .airPods,
                   device.secondaryBatteryLevel != nil || device.caseBatteryLevel != nil {
                    HStack(spacing: 12) {
                        batteryLabel("L", value: device.batteryLevel)
                        batteryLabel("R", value: device.secondaryBatteryLevel)
                        batteryLabel("Case", value: device.caseBatteryLevel)
                    }
                }
            }

            Spacer(minLength: 8)

            if let level = device.batteryLevel {
                BatteryGauge(level: level, charging: device.isCharging)
            } else if device.kind == .mac {
                Text("AC")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        )
    }

    private var connectionBadge: some View {
        Text(device.connectionState.rawValue.capitalized)
            .font(.caption2.weight(.medium))
            .foregroundStyle(device.connectionState == .connected ? .primary : .secondary)
    }

    private func batteryLabel(_ title: String, value: Int?) -> some View {
        HStack(spacing: 3) {
            Text(title)
            Text(value.map { "\($0)%" } ?? "—")
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct BatteryGauge: View {
    let level: Int
    let charging: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Image(systemName: charging ? "battery.100percent.bolt" : batterySymbol)
                .font(.title3)
            Text("\(level)%")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var batterySymbol: String {
        switch level {
        case 76...: return "battery.100percent"
        case 51...: return "battery.75percent"
        case 26...: return "battery.50percent"
        case 11...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}
