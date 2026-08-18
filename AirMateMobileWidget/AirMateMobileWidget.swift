import SwiftUI
import UIKit
import WidgetKit

struct AirMateMobileWidgetEntry: TimelineEntry {
    let date: Date
    let batteryLevel: Int?
    let isCharging: Bool
    let deviceName: String
}

struct AirMateMobileWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> AirMateMobileWidgetEntry {
        AirMateMobileWidgetEntry(date: .now, batteryLevel: 82, isCharging: false, deviceName: "iPhone")
    }

    func getSnapshot(in context: Context, completion: @escaping (AirMateMobileWidgetEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AirMateMobileWidgetEntry>) -> Void) {
        let entry = makeEntry()
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func makeEntry() -> AirMateMobileWidgetEntry {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let raw = UIDevice.current.batteryLevel
        let level = raw >= 0 ? Int((raw * 100).rounded()) : nil
        let charging: Bool
        switch UIDevice.current.batteryState {
        case .charging, .full: charging = true
        default: charging = false
        }
        return AirMateMobileWidgetEntry(
            date: .now,
            batteryLevel: level,
            isCharging: charging,
            deviceName: UIDevice.current.name
        )
    }
}

struct AirMateMobileWidgetView: View {
    let entry: AirMateMobileWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "iphone.gen3")
                    .font(.title2)
                Text("AirMate")
                    .font(.headline)
                Spacer()
                if entry.isCharging {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            if let level = entry.batteryLevel {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(level)")
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("%")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(level), total: 100)
                    .progressViewStyle(.linear)
            } else {
                Text("Open AirMate")
                    .font(.title3.bold())
                Text("to refresh battery status")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(entry.deviceName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct AirMateMobileBatteryWidget: Widget {
    let kind = "AirMateMobileBatteryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AirMateMobileWidgetProvider()) { entry in
            AirMateMobileWidgetView(entry: entry)
        }
        .configurationDisplayName("AirMate Batteries")
        .description("See this iPhone or iPad battery level at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct AirMateMobileWidgetBundle: WidgetBundle {
    var body: some Widget {
        AirMateMobileBatteryWidget()
    }
}
