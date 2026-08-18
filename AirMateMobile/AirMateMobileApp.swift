import Network
import SwiftUI
import UIKit

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

    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
    private var timer: Timer?
    private let queue = DispatchQueue(label: "com.almosawi.airmate.mobile.reporter", qos: .utility)

    private var stableID: UUID {
        let key = "AirMateMobileDeviceID"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBattery()

        NotificationCenter.default.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateAndSend() }
        }
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateAndSend() }
        }

        let browser = NWBrowser(for: .bonjour(type: "_airmate-mobile._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                var map: [String: NWEndpoint] = [:]
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint { map[name] = result.endpoint }
                }
                self.endpoints = map
                self.discoveredMacs = map.keys.sorted()
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

@main
struct AirMateMobileApp: App {
    @StateObject private var reporter = MobileReporter()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                VStack(spacing: 22) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 60))
                    Text("AirMate Mobile")
                        .font(.title2.bold())
                    Text("\(reporter.batteryLevel)%")
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Label(reporter.isCharging ? "Charging" : "On Battery", systemImage: reporter.isCharging ? "bolt.fill" : "battery.75percent")
                        .foregroundStyle(.secondary)

                    GroupBox("Nearby AirMate Macs") {
                        if reporter.discoveredMacs.isEmpty {
                            Text("No AirMate Mac discovered yet.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(reporter.discoveredMacs, id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    }

                    Button("Send Battery Now") { reporter.sendNow() }
                        .buttonStyle(.borderedProminent)
                    if let lastSent = reporter.lastSent {
                        Text("Last sent \(lastSent.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .navigationTitle("AirMate")
            }
            .task { reporter.start() }
        }
    }
}
