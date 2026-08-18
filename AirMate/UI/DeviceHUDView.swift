import SwiftUI

struct DeviceHUDView: View {
    let device: AirMateDevice

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: 92, height: 92)
                Image(systemName: device.symbolName)
                    .font(.system(size: 42, weight: .medium))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(device.name)
                    .font(.title3.weight(.semibold))
                Text(device.connectionState == .connected ? "Connected" : "Nearby")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let level = device.batteryLevel {
                    ProgressView(value: Double(level), total: 100)
                        .frame(width: 150)
                    Text("\(level)% battery")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        )
        .shadow(radius: 24, y: 12)
    }
}
