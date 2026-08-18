import SwiftUI
import WidgetKit

struct AirMateWidgetEntry: TimelineEntry {
    let date: Date
}

struct AirMateWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> AirMateWidgetEntry { AirMateWidgetEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (AirMateWidgetEntry) -> Void) {
        completion(AirMateWidgetEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AirMateWidgetEntry>) -> Void) {
        let entry = AirMateWidgetEntry(date: .now)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct AirMateWidgetView: View {
    let entry: AirMateWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "airpodspro")
                Text("AirMate").font(.headline)
                Spacer()
            }
            Text("Open AirMate to view live device batteries.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(entry.date, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct AirMateBatteryWidget: Widget {
    let kind = "AirMateBatteryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AirMateWidgetProvider()) { entry in
            AirMateWidgetView(entry: entry)
        }
        .configurationDisplayName("AirMate Batteries")
        .description("Quick access to your AirMate device overview.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct AirMateWidgetBundle: WidgetBundle {
    var body: some Widget {
        AirMateBatteryWidget()
    }
}
