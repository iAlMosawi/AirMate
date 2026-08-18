@preconcurrency import Network
import SwiftUI
import UIKit
import WidgetKit

private struct MobileDevicePayload: Codable {
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
        case .mac, .nearbyMac: return "desktopcomputer"
        case .airPods: return "airpodspro"
        case .beats: return "headphones"
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        case .appleWatch: return "applewatch"
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        }
    }
}

private struct EcosystemItem: Identifiable {
    let host: String
    let device: MobileDevicePayload
    var id: String { "\(host)|\(device.id.uuidString)" }
}

@MainActor
final class MobileReporter: ObservableObject {
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var discoveredMacs: [String] = []
    @Published private(set) var ecosystemItems: [EcosystemItem] = []
    @Published private(set) var lastSent: Date?
    @Published private(set) var lastEcosystemRefresh: Date?
    @Published private(set) var isSearching = true

    private var bridgeBrowser: NWBrowser?
    private var ecosystemBrowser: NWBrowser?
    private var bridgeEndpoints: [String: NWEndpoint] = [:]
    private var ecosystemEndpoints: [String: NWEndpoint] = [:]
    private var ecosystemSnapshots: [String: [MobileDevicePayload]] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "com.almosawi.airmate.mobile.reporter", qos: .utility)

    private var stableID: UUID {
        let key = "AirMateMobileDeviceID"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    var deviceName: String { UIDevice.current.name }
    var modelName: String { UIDevice.current.model }
    var osVersion: String { "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)" }
    var hasMac: Bool { !discoveredMacs.isEmpty || !ecosystemEndpoints.isEmpty }
    var ecosystemMacCount: Int { ecosystemSnapshots.count }
    var connectedEcosystemCount: Int { ecosystemItems.filter { $0.device.connectionState == .connected }.count }

    var batteryAvailabilityText: String {
        if batteryLevel != nil { return isCharging ? "Charging" : "On Battery" }
        #if targetEnvironment(simulator)
        return "Battery unavailable in Simulator"
        #else
        return "Battery unavailable"
        #endif
    }

    func start() {
        if bridgeBrowser != nil {
            updateBattery()
            return
        }

        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBattery()

        observers.append(NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateAndSend() }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateAndSend() }
        })

        startBridgeBrowser()
        startEcosystemBrowser()

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateAndSend()
                self?.refreshEcosystem()
            }
        }
    }

    func sendNow() {
        updateBattery()
        let payload = makePayload()
        guard let data = try? JSONEncoder().encode(payload) else { return }
        for endpoint in bridgeEndpoints.values {
            let connection = NWConnection(to: endpoint, using: .tcp)
            connection.stateUpdateHandler = { [weak connection] state in
                guard let connection else { return }
                if case .ready = state {
                    connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            connection.start(queue: queue)
        }
        if !bridgeEndpoints.isEmpty { lastSent = .now }
        WidgetCenter.shared.reloadTimelines(ofKind: "AirMateMobileBatteryWidget")
    }

    func refreshEcosystem() {
        for (name, endpoint) in ecosystemEndpoints {
            requestSnapshot(macName: name, endpoint: endpoint)
        }
        lastEcosystemRefresh = .now
    }

    func refreshAll() {
        sendNow()
        refreshEcosystem()
    }

    private func startBridgeBrowser() {
        let browser = NWBrowser(for: .bonjour(type: "_airmate-mobile._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready, .failed, .cancelled: self.isSearching = false
                default: self.isSearching = true
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                var map: [String: NWEndpoint] = [:]
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint { map[name] = result.endpoint }
                }
                self.bridgeEndpoints = map
                self.discoveredMacs = Array(Set(map.keys).union(self.ecosystemEndpoints.keys)).sorted()
                self.isSearching = false
                self.sendNow()
            }
        }
        browser.start(queue: queue)
        bridgeBrowser = browser
    }

    private func startEcosystemBrowser() {
        let browser = NWBrowser(for: .bonjour(type: "_airmate._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                var map: [String: NWEndpoint] = [:]
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint { map[name] = result.endpoint }
                }
                self.ecosystemEndpoints = map
                self.discoveredMacs = Array(Set(self.bridgeEndpoints.keys).union(map.keys)).sorted()
                self.ecosystemSnapshots = self.ecosystemSnapshots.filter { map[$0.key] != nil }
                self.rebuildEcosystemItems()
                self.refreshEcosystem()
            }
        }
        browser.start(queue: queue)
        ecosystemBrowser = browser
    }

    private func requestSnapshot(macName: String, endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            if case .ready = state {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { data, _, _, _ in
                    defer { connection.cancel() }
                    guard let data, let list = try? JSONDecoder().decode([MobileDevicePayload].self, from: data) else { return }
                    Task { @MainActor in self?.storeSnapshot(list, macName: macName) }
                }
            }
        }
        connection.start(queue: queue)
    }

    private func storeSnapshot(_ devices: [MobileDevicePayload], macName: String) {
        ecosystemSnapshots[macName] = devices
        rebuildEcosystemItems()
    }

    private func rebuildEcosystemItems() {
        ecosystemItems = ecosystemSnapshots.keys.sorted().flatMap { host in
            (ecosystemSnapshots[host] ?? []).map { EcosystemItem(host: host, device: $0) }
        }
        .sorted { lhs, rhs in
            if lhs.device.connectionState != rhs.device.connectionState {
                return lhs.device.connectionState == .connected
            }
            if lhs.host != rhs.host { return lhs.host.localizedCaseInsensitiveCompare(rhs.host) == .orderedAscending }
            return lhs.device.name.localizedCaseInsensitiveCompare(rhs.device.name) == .orderedAscending
        }
    }

    private func updateAndSend() {
        updateBattery()
        sendNow()
    }

    private func updateBattery() {
        let level = UIDevice.current.batteryLevel
        batteryLevel = level >= 0 ? Int((level * 100).rounded()) : nil
        switch UIDevice.current.batteryState {
        case .charging, .full: isCharging = batteryLevel != nil
        default: isCharging = false
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "AirMateMobileBatteryWidget")
    }

    private func makePayload() -> MobileDevicePayload {
        let device = UIDevice.current
        let kind: MobileDevicePayload.Kind = device.userInterfaceIdiom == .pad ? .iPad : .iPhone
        return MobileDevicePayload(
            id: stableID,
            name: device.name,
            kind: kind,
            modelName: device.model,
            batteryLevel: batteryLevel,
            secondaryBatteryLevel: nil,
            caseBatteryLevel: nil,
            isCharging: isCharging,
            isSecondaryCharging: false,
            isCaseCharging: false,
            connectionState: .connected,
            source: .pairedMobile,
            rssi: nil,
            lastSeen: .now,
            metadata: ["platform": device.systemName, "os": device.systemVersion]
        )
    }
}

struct MobileOverviewView: View {
    @ObservedObject var reporter: MobileReporter

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                batteryHero

                HStack(spacing: 12) {
                    StatusTile(
                        title: "Mac Link",
                        value: reporter.hasMac ? "Connected" : (reporter.isSearching ? "Searching" : "Not Found"),
                        systemImage: reporter.hasMac ? "macmini.fill" : "macmini"
                    )
                    StatusTile(
                        title: "Ecosystem",
                        value: reporter.ecosystemItems.isEmpty ? "No Devices" : "\(reporter.ecosystemItems.count) Devices",
                        systemImage: "rectangle.3.group"
                    )
                }

                HStack(spacing: 12) {
                    StatusTile(
                        title: "AirMate Macs",
                        value: "\(reporter.discoveredMacs.count)",
                        systemImage: "desktopcomputer"
                    )
                    StatusTile(
                        title: "Last Sync",
                        value: reporter.lastSent?.formatted(date: .omitted, time: .shortened) ?? "Never",
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                    )
                }

                Button { reporter.refreshAll() } label: {
                    Label("Sync AirMate Now", systemImage: "arrow.trianglehead.2.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                VStack(alignment: .leading, spacing: 8) {
                    Label("AirMate Widget", systemImage: "rectangle.grid.2x2.fill")
                        .font(.headline)
                    Text("Add AirMate Batteries from the Home Screen widget gallery for quick battery status.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding()
        }
        .navigationTitle("AirMate")
    }

    private var batteryHero: some View {
        VStack(spacing: 12) {
            Image(systemName: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone.gen3")
                .font(.system(size: 50, weight: .medium))
                .symbolRenderingMode(.hierarchical)

            Text(reporter.deviceName)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            if let level = reporter.batteryLevel {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(level)")
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("%")
                        .font(.title2.bold())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(level), total: 100)
                    .frame(maxWidth: 220)
            } else {
                Text("—")
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                #if targetEnvironment(simulator)
                Text("Simulator does not provide a reliable device battery level. Run AirMate on a physical iPhone or iPad to test battery reporting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                #endif
            }

            Label(
                reporter.batteryAvailabilityText,
                systemImage: reporter.isCharging ? "bolt.fill" : (reporter.batteryLevel == nil ? "questionmark.circle" : "battery.75percent")
            )
            .foregroundStyle(reporter.isCharging ? .green : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

private struct StatusTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct EcosystemDevicesView: View {
    @ObservedObject var reporter: MobileReporter

    var body: some View {
        List {
            if reporter.ecosystemItems.isEmpty {
                ContentUnavailableView(
                    "No Ecosystem Devices Yet",
                    systemImage: "rectangle.3.group",
                    description: Text("Run AirMate on your Macs and keep them on the same local network. Each Mac shares the Bluetooth and accessory devices it can see.")
                )
            } else {
                Section {
                    LabeledContent("AirMate Macs", value: "\(reporter.ecosystemMacCount)")
                    LabeledContent("Connected devices", value: "\(reporter.connectedEcosystemCount)")
                    if let date = reporter.lastEcosystemRefresh {
                        LabeledContent("Updated", value: date.formatted(date: .omitted, time: .shortened))
                    }
                }

                ForEach(reporter.discoveredMacs, id: \.self) { mac in
                    let items = reporter.ecosystemItems.filter { $0.host == mac }
                    if !items.isEmpty {
                        Section(mac) {
                            ForEach(items) { item in
                                EcosystemDeviceRow(item: item)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { reporter.refreshEcosystem() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
    }
}

private struct EcosystemDeviceRow: View {
    let item: EcosystemItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.device.symbolName)
                .font(.title2)
                .frame(width: 30)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.device.name).font(.headline)
                HStack(spacing: 6) {
                    Text(item.device.connectionState.rawValue.capitalized)
                    if let rssi = item.device.rssi { Text("\(rssi) dBm") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let battery = item.device.batteryLevel {
                HStack(spacing: 4) {
                    if item.device.isCharging { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                    Text("\(battery)%").monospacedDigit().fontWeight(.semibold)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct NearbyMacsView: View {
    @ObservedObject var reporter: MobileReporter

    var body: some View {
        List {
            Section {
                if reporter.discoveredMacs.isEmpty {
                    ContentUnavailableView(
                        "No AirMate Mac Found",
                        systemImage: "macmini",
                        description: Text("Keep AirMate running on your Mac and make sure both devices are on the same local network.")
                    )
                } else {
                    ForEach(reporter.discoveredMacs, id: \.self) { mac in
                        HStack(spacing: 14) {
                            Image(systemName: "macmini.fill")
                                .font(.title2)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(mac).font(.headline)
                                Text("AirMate ecosystem source")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
            } header: { Text("Nearby Macs") }

            Section {
                Button("Sync AirMate Now") { reporter.refreshAll() }
            }
        }
        .navigationTitle("Macs")
    }
}

struct MobileSettingsView: View {
    @ObservedObject var reporter: MobileReporter

    var body: some View {
        List {
            Section("This Device") {
                LabeledContent("Name", value: reporter.deviceName)
                LabeledContent("Model", value: reporter.modelName)
                LabeledContent("Software", value: reporter.osVersion)
                LabeledContent("Battery", value: reporter.batteryLevel.map { "\($0)%" } ?? "Unavailable")
            }
            Section("AirMate Ecosystem") {
                LabeledContent("Macs discovered", value: "\(reporter.discoveredMacs.count)")
                LabeledContent("Devices received", value: "\(reporter.ecosystemItems.count)")
                Text("Install and run AirMate on each Mac you want included. Device snapshots stay on your local network.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("App", value: "AirMate")
                LabeledContent("Version", value: "0.6.0 beta")
                Text("AirMate reports this iPhone or iPad battery state to your Macs and can display device snapshots shared by AirMate Macs on the same network.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}

@main
struct AirMateMobileApp: App {
    @StateObject private var reporter = MobileReporter()

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { MobileOverviewView(reporter: reporter) }
                    .tabItem { Label("Overview", systemImage: "square.grid.2x2.fill") }

                NavigationStack { EcosystemDevicesView(reporter: reporter) }
                    .tabItem { Label("Devices", systemImage: "rectangle.3.group") }

                NavigationStack { NearbyMacsView(reporter: reporter) }
                    .tabItem { Label("Macs", systemImage: "macmini") }

                NavigationStack { MobileSettingsView(reporter: reporter) }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .task { reporter.start() }
        }
    }
}
