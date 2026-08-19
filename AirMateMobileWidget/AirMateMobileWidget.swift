@preconcurrency import CloudKit
import SwiftUI
import WidgetKit

struct WidgetDevice: Codable, Identifiable {
    enum Kind: String, Codable { case mac, airPods, beats, iPhone, iPad, appleWatch, keyboard, mouse, trackpad, bluetooth, nearbyMac }
    enum ConnectionState: String, Codable { case connected, nearby, disconnected }
    enum Source: String, Codable { case localMac, coreBluetooth, appleAdvertisement, hid, nearbyMac, pairedMobile }

    let id: UUID
    var name: String
    var kind: Kind
    var modelName: String?
    var batteryLevel: Int?
    var secondaryBatteryLevel: Int?
    var caseBatteryLevel: Int?
    var isCharging: Bool
    var isSecondaryCharging: Bool
    var isCaseCharging: Bool
    var connectionState: ConnectionState
    var source: Source
    var rssi: Int?
    var lastSeen: Date
    var metadata: [String: String]

    var symbolName: String {
        switch kind {
        case .mac, .nearbyMac: "desktopcomputer"
        case .airPods: "airpodspro"
        case .beats: "headphones"
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .appleWatch: "applewatch"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .bluetooth: "dot.radiowaves.left.and.right"
        }
    }

    var hasAnyBattery: Bool {
        batteryLevel != nil || secondaryBatteryLevel != nil || caseBatteryLevel != nil
    }
}

struct WidgetEcosystemDevice: Identifiable {
    let host: String
    let device: WidgetDevice
    var id: String { "\(host)|\(device.id.uuidString)" }
}

struct AirMateMobileWidgetEntry: TimelineEntry {
    let date: Date
    let devices: [WidgetEcosystemDevice]
    let cloudAvailable: Bool
}

private final class SendableCompletion<Value>: @unchecked Sendable {
    private let callback: (Value) -> Void

    init(_ callback: @escaping (Value) -> Void) {
        self.callback = callback
    }

    func call(_ value: Value) {
        callback(value)
    }
}

struct AirMateMobileWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> AirMateMobileWidgetEntry {
        AirMateMobileWidgetEntry(
            date: .now,
            devices: [
                WidgetEcosystemDevice(host: "Mac mini", device: Self.sample(name: "AirPods Pro", kind: .airPods, battery: 82)),
                WidgetEcosystemDevice(host: "Mac mini", device: Self.sample(name: "Magic Keyboard", kind: .keyboard, battery: 94)),
                WidgetEcosystemDevice(host: "iPhone", device: Self.sample(name: "iPhone", kind: .iPhone, battery: 71))
            ],
            cloudAvailable: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (AirMateMobileWidgetEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        let callback = SendableCompletion(completion)
        Task {
            callback.call(await Self.makeEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AirMateMobileWidgetEntry>) -> Void) {
        let callback = SendableCompletion(completion)
        Task {
            let entry = await Self.makeEntry()
            callback.call(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60))))
        }
    }

    private static func makeEntry() async -> AirMateMobileWidgetEntry {
        let container = CKContainer(identifier: "iCloud.com.almosawi.airmate")
        let liveWindow: TimeInterval = 180

        do {
            guard try await container.accountStatus() == .available else {
                return AirMateMobileWidgetEntry(date: .now, devices: [], cloudAvailable: false)
            }

            let database = container.privateCloudDatabase
            let query = CKQuery(recordType: "AirMateSnapshot", predicate: NSPredicate(value: true))
            let response = try await database.records(
                matching: query,
                inZoneWith: nil,
                desiredKeys: ["hostName", "updatedAt", "payload"],
                resultsLimit: 100
            )

            var deduplicated: [String: WidgetEcosystemDevice] = [:]
            let now = Date()

            for (_, result) in response.matchResults {
                guard case .success(let record) = result,
                      let data = record["payload"] as? Data,
                      let decoded = try? JSONDecoder().decode([WidgetDevice].self, from: data) else { continue }

                let updatedAt = (record["updatedAt"] as? Date) ?? record.modificationDate ?? .distantPast
                guard now.timeIntervalSince(updatedAt) <= liveWindow else { continue }
                let host = (record["hostName"] as? String) ?? "AirMate Device"

                for var device in decoded where device.connectionState == .connected {
                    device.lastSeen = updatedAt
                    let key = "\(device.kind.rawValue)|\(device.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
                    let candidate = WidgetEcosystemDevice(host: host, device: device)
                    if let existing = deduplicated[key] {
                        if device.hasAnyBattery && !existing.device.hasAnyBattery {
                            deduplicated[key] = candidate
                        } else if device.lastSeen > existing.device.lastSeen {
                            deduplicated[key] = candidate
                        }
                    } else {
                        deduplicated[key] = candidate
                    }
                }
            }

            let devices = deduplicated.values.sorted { lhs, rhs in
                if lhs.device.hasAnyBattery != rhs.device.hasAnyBattery { return lhs.device.hasAnyBattery }
                return lhs.device.name.localizedCaseInsensitiveCompare(rhs.device.name) == .orderedAscending
            }
            return AirMateMobileWidgetEntry(date: .now, devices: devices, cloudAvailable: true)
        } catch {
            return AirMateMobileWidgetEntry(date: .now, devices: [], cloudAvailable: false)
        }
    }

    private static func sample(name: String, kind: WidgetDevice.Kind, battery: Int) -> WidgetDevice {
        WidgetDevice(
            id: UUID(), name: name, kind: kind, modelName: nil,
            batteryLevel: battery, secondaryBatteryLevel: nil, caseBatteryLevel: nil,
            isCharging: false, isSecondaryCharging: false, isCaseCharging: false,
            connectionState: .connected, source: .pairedMobile,
            rssi: nil, lastSeen: .now, metadata: [:]
        )
    }
}

struct AirMateMobileWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AirMateMobileWidgetEntry

    private var maxRows: Int {
        switch family {
        case .systemSmall: 2
        case .systemMedium: 4
        case .systemLarge: 8
        case .systemExtraLarge: 12
        default: 4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.3.group.fill")
                    .foregroundStyle(.tint)
                Text("AirMate")
                    .font(.headline)
                Spacer()
                Text("\(entry.devices.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if entry.devices.isEmpty {
                Spacer()
                VStack(alignment: .leading, spacing: 5) {
                    Image(systemName: entry.cloudAvailable ? "battery.0percent" : "icloud.slash")
                        .font(.title2)
                    Text(entry.cloudAvailable ? "No live devices" : "Cloud unavailable")
                        .font(.subheadline.weight(.semibold))
                    Text(entry.cloudAvailable ? "Open AirMate on a device to refresh." : "Check iCloud and AirMate CloudKit access.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ForEach(Array(entry.devices.prefix(maxRows))) { item in
                    widgetRow(item)
                }
                if entry.devices.count > maxRows {
                    Text("+ \(entry.devices.count - maxRows) more connected")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func widgetRow(_ item: WidgetEcosystemDevice) -> some View {
        HStack(spacing: 7) {
            Image(systemName: item.device.symbolName)
                .frame(width: 20)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.device.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if family != .systemSmall {
                    Text(item.host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            batteryView(item.device)
        }
    }

    @ViewBuilder
    private func batteryView(_ device: WidgetDevice) -> some View {
        if (device.kind == .airPods || device.kind == .beats),
           device.secondaryBatteryLevel != nil || device.caseBatteryLevel != nil,
           family != .systemSmall {
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 4) {
                    tinyBattery("L", device.batteryLevel)
                    tinyBattery("R", device.secondaryBatteryLevel)
                }
                if let caseLevel = device.caseBatteryLevel {
                    Text("Case \(caseLevel)%")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } else if let level = device.batteryLevel {
            HStack(spacing: 2) {
                if device.isCharging { Image(systemName: "bolt.fill").font(.system(size: 8)).foregroundStyle(.green) }
                Text("\(level)%")
                    .font(.caption2.monospacedDigit().weight(.semibold))
            }
        } else {
            Text("—")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func tinyBattery(_ label: String, _ value: Int?) -> some View {
        Text("\(label) \(value.map(String.init) ?? "—")%")
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .monospacedDigit()
    }
}

struct AirMateMobileBatteryWidget: Widget {
    let kind = "AirMateMobileBatteryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AirMateMobileWidgetProvider()) { entry in
            AirMateMobileWidgetView(entry: entry)
        }
        .configurationDisplayName("AirMate Ecosystem")
        .description("See connected AirMate devices and their available battery levels across Mac, iPhone and iPad.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main
struct AirMateMobileWidgetBundle: WidgetBundle {
    var body: some Widget {
        AirMateMobileBatteryWidget()
    }
}
