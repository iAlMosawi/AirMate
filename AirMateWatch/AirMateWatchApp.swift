@preconcurrency import Network
import SwiftUI
import WatchKit

private struct WatchDevicePayload: Codable {
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
final class WatchReporter: ObservableObject {
    @Published private(set) var batteryLevel = 0
    @Published private(set) var isCharging = false
    @Published private(set) var macs: [String] = []
    @Published private(set) var lastSent: Date?

    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.almosawi.airmate.watch", qos: .utility)

    private var stableID: UUID {
        let key = "AirMateWatchDeviceID"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    func start() {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        updateBattery()

        let browser = NWBrowser(for: .bonjour(type: "_airmate-mobile._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                var found: [String: NWEndpoint] = [:]
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint { found[name] = result.endpoint }
                }
                self.endpoints = found
                self.macs = found.keys.sorted()
                self.sendNow()
            }
        }
        browser.start(queue: queue)
        self.browser = browser

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateAndSend() }
        }
    }

    func sendNow() {
        updateBattery()
        guard let data = try? JSONEncoder().encode(makePayload()) else { return }
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
    }

    private func updateAndSend() {
        updateBattery()
        sendNow()
    }

    private func updateBattery() {
        let device = WKInterfaceDevice.current()
        let level = device.batteryLevel
        batteryLevel = level >= 0 ? Int((level * 100).rounded()) : 0
        switch device.batteryState {
        case .charging, .full: isCharging = true
        default: isCharging = false
        }
    }

    private func makePayload() -> WatchDevicePayload {
        let device = WKInterfaceDevice.current()
        return WatchDevicePayload(
            id: stableID,
            name: device.name,
            kind: .appleWatch,
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

@main
struct AirMateWatchApp: App {
    @StateObject private var reporter = WatchReporter()

    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(spacing: 10) {
                    Image(systemName: "applewatch")
                        .font(.largeTitle)
                    Text("AirMate")
                        .font(.headline)
                    Text("\(reporter.batteryLevel)%")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Label(reporter.isCharging ? "Charging" : "Battery", systemImage: reporter.isCharging ? "bolt.fill" : "battery.75percent")
                        .font(.caption)
                    if reporter.macs.isEmpty {
                        Text("Looking for your Mac…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(reporter.macs.joined(separator: ", "))
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                    }
                    Button("Send Now") { reporter.sendNow() }
                    if let date = reporter.lastSent {
                        Text(date, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .task { reporter.start() }
        }
    }
}
