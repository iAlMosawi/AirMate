import Network
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
}

@MainActor
final class MobileReporter: ObservableObject {
    @Published private(set) var batteryLevel = 0
    @Published private(set) var isCharging = false
    @Published private(set) var discoveredMacs: [String] = []
    @Published private(set) var lastSent: Date?
    @Published private(set) var isSearching = true

    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
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
    var hasMac: Bool { !discoveredMacs.isEmpty }

    func start() {
        guard browser == nil else {
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

        let browser = NWBrowser(for: .bonjour(type: "_airmate-mobile._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready, .failed, .cancelled:
                    self.isSearching = false
                default:
                    self.isSearching = true
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
                self.endpoints = map
                self.discoveredMacs = map.keys.sorted()
                self.isSearching = false
                self.sendNow()
            }
        }
        browser.start(queue: queue)
        self.browser = browser

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateAndSend() }
        }
    }

    func sendNow() {
        updateBattery()
        let payload = makePayload()
        guard let data = try? JSONEncoder().encode(payload) else { return }
        for endpoint in endpoints.values {
            let connection = NWConnection(to: endpoint, using: .tcp)
            connection.stateUpdateHandler = { [weak connection] state in
                guard let connection else { return }
                if case .ready = state {
                    connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            connection.start(queue: queue)
        }
        if !endpoints.isEmpty { lastSent = .now }
        WidgetCenter.shared.reloadTimelines(ofKind: "AirMateMobileBatteryWidget")
    }

    private func updateAndSend() {
        updateBattery()
        sendNow()
    }

    private func updateBattery() {
        let level = UIDevice.current.batteryLevel
        batteryLevel = level >= 0 ? Int((level * 100).rounded()) : 0
        switch UIDevice.current.batteryState {
        case .charging, .full: isCharging = true
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
            VStack(spacing: 18) {
                VStack(spacing: 12) {
                    Image(systemName: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone.gen3")
                        .font(.system(size: 54, weight: .medium))
                        .symbolRenderingMode(.hierarchical)

                    Text(reporter.deviceName)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)

                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("\(reporter.batteryLevel)")
                            .font(.system(size: 58, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("%")
                            .font(.title.bold())
                            .foregroundStyle(.secondary)
                    }

                    Label(
                        reporter.isCharging ? "Charging" : "On Battery",
                        systemImage: reporter.isCharging ? "bolt.fill" : "battery.75percent"
                    )
                    .foregroundStyle(reporter.isCharging ? .green : .secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                HStack(spacing: 12) {
                    StatusTile(
                        title: "Mac Link",
                        value: reporter.hasMac ? "Connected" : (reporter.isSearching ? "Searching" : "Not Found"),
                        systemImage: reporter.hasMac ? "macmini.fill" : "macmini"
                    )
                    StatusTile(
                        title: "Last Sync",
                        value: reporter.lastSent?.formatted(date: .omitted, time: .shortened) ?? "Never",
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                    )
                }

                Button {
                    reporter.sendNow()
                } label: {
                    Label("Sync Battery Now", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                VStack(alignment: .leading, spacing: 10) {
                    Label("AirMate Widget", systemImage: "rectangle.grid.2x2.fill")
                        .font(.headline)
                    Text("Add the AirMate Batteries widget from the Home Screen widget gallery for quick battery status.")
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
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                                Text("AirMate available")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
            } header: {
                Text("Nearby Macs")
            }

            Section {
                Button("Send Battery Now") { reporter.sendNow() }
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
            }
            Section("About AirMate Mobile") {
                Text("AirMate Mobile securely reports this iPhone or iPad battery state to AirMate Macs discovered on your local network. No AirMate cloud account is required for this beta.")
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

                NavigationStack { NearbyMacsView(reporter: reporter) }
                    .tabItem { Label("Macs", systemImage: "macmini") }

                NavigationStack { MobileSettingsView(reporter: reporter) }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .task { reporter.start() }
        }
    }
}
