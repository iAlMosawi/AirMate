@preconcurrency import CloudKit
@preconcurrency import Network
import AVFAudio
import SwiftUI
import UIKit
import WidgetKit

struct MobileDevicePayload: Codable {
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

struct EcosystemItem: Identifiable {
    let host: String
    let device: MobileDevicePayload
    var id: String { "\(host)|\(device.id.uuidString)" }
}

@MainActor
final class MobileReporter: ObservableObject {
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var discoveredPeers: [String] = []
    @Published private(set) var ecosystemItems: [EcosystemItem] = []
    @Published private(set) var connectedBluetoothAudio: [MobileDevicePayload] = []
    @Published private(set) var lastSent: Date?
    @Published private(set) var lastEcosystemRefresh: Date?
    @Published private(set) var cloudStatusText = "Starting…"
    @Published private(set) var lastCloudSync: Date?
    @Published private(set) var isSearching = true

    private var bridgeBrowser: NWBrowser?
    private var ecosystemBrowser: NWBrowser?
    private var ecosystemListener: NWListener?
    private var bridgeEndpoints: [String: NWEndpoint] = [:]
    private var ecosystemEndpoints: [String: NWEndpoint] = [:]
    private var ecosystemSnapshots: [String: [MobileDevicePayload]] = [:]
    private var cloudPeerNames = Set<String>()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "com.almosawi.airmate.mobile.reporter", qos: .utility)
    private let cloudContainer = CKContainer(identifier: "iCloud.com.almosawi.airmate")
    private let cloudRecordType = "AirMateSnapshot"
    private let cloudLiveWindow: TimeInterval = 180
    private var cloudSyncTask: Task<Void, Never>?

    private var stableID: UUID {
        let key = "AirMateMobileDeviceID"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    private var peerServiceName: String {
        "\(UIDevice.current.name) • \(stableID.uuidString.prefix(4))"
    }

    private var cloudRecordID: CKRecord.ID {
        CKRecord.ID(recordName: "snapshot-\(stableID.uuidString)")
    }

    var deviceName: String { UIDevice.current.name }
    var modelName: String { UIDevice.current.model }
    var osVersion: String { "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)" }
    var hasPeer: Bool { !discoveredPeers.isEmpty }
    var peerCount: Int { discoveredPeers.count }
    var connectedEcosystemCount: Int { ecosystemItems.count }

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
            refreshLocalState()
            scheduleCloudSync(after: .zero)
            return
        }

        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshLocalState()

        observers.append(NotificationCenter.default.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateAndSend() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateAndSend() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateAndSend() }
        })

        startBridgeBrowser()
        startEcosystemListener()
        startEcosystemBrowser()
        scheduleCloudSync(after: .zero)

        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateAndSend()
                self?.refreshEcosystem()
            }
        }
    }

    func sendNow() {
        refreshLocalState()
        let payloads = makeLocalPayloads()
        guard let data = try? JSONEncoder().encode(payloads) else { return }

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
        ecosystemSnapshots[peerServiceName] = payloads
        rebuildEcosystemItems()
        scheduleCloudSync(after: .seconds(2))
        WidgetCenter.shared.reloadTimelines(ofKind: "AirMateMobileBatteryWidget")
    }

    func refreshEcosystem() {
        refreshLocalState()
        ecosystemSnapshots[peerServiceName] = makeLocalPayloads()
        for (name, endpoint) in ecosystemEndpoints { requestSnapshot(peerName: name, endpoint: endpoint) }
        rebuildEcosystemItems()
        lastEcosystemRefresh = .now
        scheduleCloudSync(after: .zero)
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
                self.updatePeerNames()
                self.isSearching = false
                self.sendNow()
            }
        }
        browser.start(queue: queue)
        bridgeBrowser = browser
    }

    private func startEcosystemListener() {
        guard ecosystemListener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.service = NWListener.Service(name: peerServiceName, type: "_airmate._tcp")
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.sendLocalSnapshot(on: connection) }
            }
            listener.start(queue: queue)
            ecosystemListener = listener
        } catch {
            ecosystemListener = nil
        }
    }

    private func sendLocalSnapshot(on connection: NWConnection) {
        refreshLocalState()
        guard let data = try? JSONEncoder().encode(makeLocalPayloads()) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func startEcosystemBrowser() {
        let browser = NWBrowser(for: .bonjour(type: "_airmate._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                var map: [String: NWEndpoint] = [:]
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint, name != self.peerServiceName {
                        map[name] = result.endpoint
                    }
                }
                self.ecosystemEndpoints = map
                self.ecosystemSnapshots = self.ecosystemSnapshots.filter { key, _ in
                    key == self.peerServiceName || map[key] != nil || key.hasPrefix("Cloud • ")
                }
                self.updatePeerNames()
                self.refreshEcosystem()
            }
        }
        browser.start(queue: queue)
        ecosystemBrowser = browser
    }

    private func updatePeerNames() {
        discoveredPeers = Array(Set(bridgeEndpoints.keys).union(ecosystemEndpoints.keys).union(cloudPeerNames)).sorted()
    }

    private func requestSnapshot(peerName: String, endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            if case .ready = state {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { data, _, _, _ in
                    defer { connection.cancel() }
                    guard let data, let list = try? JSONDecoder().decode([MobileDevicePayload].self, from: data) else { return }
                    Task { @MainActor in self?.storeSnapshot(list, peerName: peerName) }
                }
            }
        }
        connection.start(queue: queue)
    }

    private func storeSnapshot(_ devices: [MobileDevicePayload], peerName: String) {
        ecosystemSnapshots[peerName] = devices.filter { $0.connectionState == .connected }
        rebuildEcosystemItems()
    }

    private func rebuildEcosystemItems() {
        var deduplicated: [String: EcosystemItem] = [:]
        for host in ecosystemSnapshots.keys.sorted() {
            for device in ecosystemSnapshots[host] ?? [] where device.connectionState == .connected {
                let key = "\(device.kind.rawValue)|\(device.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
                let candidate = EcosystemItem(host: host, device: device)
                if let existing = deduplicated[key] {
                    if sourcePriority(host) > sourcePriority(existing.host) {
                        deduplicated[key] = candidate
                    }
                } else {
                    deduplicated[key] = candidate
                }
            }
        }
        ecosystemItems = deduplicated.values.sorted { lhs, rhs in
            lhs.device.name.localizedCaseInsensitiveCompare(rhs.device.name) == .orderedAscending
        }
    }

    private func sourcePriority(_ host: String) -> Int {
        if host == peerServiceName { return 3 }
        if host.hasPrefix("Cloud • ") { return 1 }
        return 2
    }

    private func updateAndSend() {
        refreshLocalState()
        sendNow()
    }

    private func refreshLocalState() {
        updateBattery()
        connectedBluetoothAudio = currentBluetoothAudioDevices()
    }

    private func updateBattery() {
        let level = UIDevice.current.batteryLevel
        batteryLevel = level >= 0 ? Int((level * 100).rounded()) : nil
        switch UIDevice.current.batteryState {
        case .charging, .full: isCharging = batteryLevel != nil
        default: isCharging = false
        }
    }

    private func makeLocalPayloads() -> [MobileDevicePayload] {
        [makeDevicePayload()] + connectedBluetoothAudio
    }

    private func makeDevicePayload() -> MobileDevicePayload {
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
            metadata: ["platform": device.systemName, "os": device.systemVersion, "transport": "AirMate"]
        )
    }

    private func currentBluetoothAudioDevices() -> [MobileDevicePayload] {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.compactMap { port in
            guard port.portType == .bluetoothA2DP || port.portType == .bluetoothHFP || port.portType == .bluetoothLE else { return nil }
            let name = port.portName
            let lower = name.lowercased()
            let kind: MobileDevicePayload.Kind
            if lower.contains("airpods") { kind = .airPods }
            else if lower.contains("beats") { kind = .beats }
            else { kind = .bluetooth }

            return MobileDevicePayload(
                id: stableUUID(for: "audio|\(port.uid)|\(name)"),
                name: name,
                kind: kind,
                modelName: nil,
                batteryLevel: nil,
                secondaryBatteryLevel: nil,
                caseBatteryLevel: nil,
                isCharging: false,
                isSecondaryCharging: false,
                isCaseCharging: false,
                connectionState: .connected,
                source: .pairedMobile,
                rssi: nil,
                lastSeen: .now,
                metadata: ["transport": "AVAudioSession", "portType": port.portType.rawValue, "reportedBy": deviceName]
            )
        }
    }

    private func scheduleCloudSync(after delay: Duration) {
        cloudSyncTask?.cancel()
        cloudSyncTask = Task { [weak self] in
            if delay != .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.syncCloudNow()
        }
    }

    private func syncCloudNow() async {
        do {
            let account = try await cloudContainer.accountStatus()
            guard account == .available else {
                cloudStatusText = "iCloud unavailable"
                clearCloudSnapshots()
                return
            }

            cloudStatusText = "Syncing…"
            let database = cloudContainer.privateCloudDatabase
            try await uploadCloudSnapshot(to: database)
            try await fetchCloudSnapshots(from: database)
            lastCloudSync = .now
            cloudStatusText = cloudPeerNames.isEmpty ? "Cloud connected" : "Cloud connected • \(cloudPeerNames.count) peers"
        } catch {
            cloudStatusText = "Cloud sync unavailable"
        }
    }

    private func uploadCloudSnapshot(to database: CKDatabase) async throws {
        let payloads = makeLocalPayloads().filter { $0.connectionState == .connected }
        guard let data = try? JSONEncoder().encode(payloads) else { return }

        let record: CKRecord
        do {
            record = try await database.record(for: cloudRecordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: cloudRecordType, recordID: cloudRecordID)
        }

        record["hostName"] = peerServiceName as CKRecordValue
        record["platform"] = (UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS") as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue
        record["payload"] = data as CKRecordValue
        _ = try await database.save(record)
    }

    private func fetchCloudSnapshots(from database: CKDatabase) async throws {
        let query = CKQuery(recordType: cloudRecordType, predicate: NSPredicate(value: true))
        let response = try await database.records(
            matching: query,
            inZoneWith: nil,
            desiredKeys: ["hostName", "platform", "updatedAt", "payload"],
            resultsLimit: 100
        )

        var fresh: [String: [MobileDevicePayload]] = [:]
        var names = Set<String>()
        let now = Date()

        for (id, result) in response.matchResults where id != cloudRecordID {
            guard case .success(let record) = result,
                  let data = record["payload"] as? Data,
                  let decoded = try? JSONDecoder().decode([MobileDevicePayload].self, from: data) else { continue }

            let updatedAt = (record["updatedAt"] as? Date) ?? record.modificationDate ?? .distantPast
            guard now.timeIntervalSince(updatedAt) <= cloudLiveWindow else { continue }
            let remoteHost = (record["hostName"] as? String) ?? "AirMate Device"
            names.insert(remoteHost)

            let converted = decoded
                .filter { $0.connectionState == .connected }
                .map { original -> MobileDevicePayload in
                    var device = original
                    device.connectionState = .connected
                    device.lastSeen = updatedAt
                    device.metadata["cloudPeer"] = remoteHost
                    device.metadata["sync"] = "CloudKit"
                    return device
                }
            fresh["Cloud • \(remoteHost)"] = converted
        }

        ecosystemSnapshots = ecosystemSnapshots.filter { !$0.key.hasPrefix("Cloud • ") }
        for (key, value) in fresh { ecosystemSnapshots[key] = value }
        cloudPeerNames = names
        updatePeerNames()
        rebuildEcosystemItems()
    }

    private func clearCloudSnapshots() {
        ecosystemSnapshots = ecosystemSnapshots.filter { !$0.key.hasPrefix("Cloud • ") }
        cloudPeerNames = []
        updatePeerNames()
        rebuildEcosystemItems()
    }

    private func stableUUID(for value: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in value.utf8.enumerated() {
            bytes[index % 16] = bytes[index % 16] &+ byte &+ UInt8(truncatingIfNeeded: index)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple: uuid_t = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: tuple)
    }
}

struct MobileOverviewView: View {
    @ObservedObject var reporter: MobileReporter

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 12) {
                    Image(systemName: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone.gen3")
                        .font(.system(size: 50, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                    Text(reporter.deviceName).font(.title2.bold()).multilineTextAlignment(.center)
                    if let level = reporter.batteryLevel {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(level)").font(.system(size: 56, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text("%").font(.title2.bold()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(level), total: 100).frame(maxWidth: 220)
                    } else {
                        Text("—").font(.system(size: 56, weight: .semibold, design: .rounded))
                        #if targetEnvironment(simulator)
                        Text("Simulator does not provide a reliable device battery level. Use a physical iPhone or iPad for battery testing.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
                        #endif
                    }
                    Label(reporter.batteryAvailabilityText, systemImage: reporter.isCharging ? "bolt.fill" : (reporter.batteryLevel == nil ? "questionmark.circle" : "battery.75percent"))
                        .foregroundStyle(reporter.isCharging ? .green : .secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                HStack(spacing: 12) {
                    StatusTile(title: "AirMate Link", value: reporter.hasPeer ? "Connected" : (reporter.isSearching ? "Searching" : "Cloud Ready"), systemImage: reporter.hasPeer ? "link.circle.fill" : "icloud")
                    StatusTile(title: "Ecosystem", value: "\(reporter.connectedEcosystemCount) Devices", systemImage: "rectangle.3.group")
                }
                HStack(spacing: 12) {
                    StatusTile(title: "Peers", value: "\(reporter.peerCount)", systemImage: "network")
                    StatusTile(title: "Cloud", value: reporter.cloudStatusText, systemImage: "icloud.fill")
                }

                Button { reporter.refreshAll() } label: {
                    Label("Sync AirMate Now", systemImage: "arrow.trianglehead.2.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                VStack(alignment: .leading, spacing: 8) {
                    Label("Local + Cloud ecosystem", systemImage: "icloud.and.arrow.up.fill").font(.headline)
                    Text("AirMate uses Bonjour when peers are on the same LAN and private CloudKit when your Mac, iPhone or iPad are on different Wi-Fi networks or cellular data. Only recently reported connected devices are treated as live.")
                        .font(.subheadline).foregroundStyle(.secondary)
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
            Image(systemName: systemImage).font(.title2).foregroundStyle(.tint)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.72)
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
            Section {
                LabeledContent("Connected devices", value: "\(reporter.connectedEcosystemCount)")
                LabeledContent("AirMate peers", value: "\(reporter.peerCount)")
                LabeledContent("Cloud sync", value: reporter.cloudStatusText)
                if let date = reporter.lastEcosystemRefresh {
                    LabeledContent("Updated", value: date.formatted(date: .omitted, time: .shortened))
                }
            }

            if reporter.ecosystemItems.isEmpty {
                ContentUnavailableView(
                    "No Connected Devices Yet",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("Run AirMate on your Mac, iPhone and iPad. Peers on the same network sync with Bonjour; peers elsewhere sync through your private iCloud database.")
                )
            } else {
                Section("Connected Across AirMate") {
                    ForEach(reporter.ecosystemItems) { item in
                        EcosystemDeviceRow(item: item)
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
                Text("Connected • \(item.host)").font(.caption).foregroundStyle(.secondary)
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

struct NearbyPeersView: View {
    @ObservedObject var reporter: MobileReporter

    var body: some View {
        List {
            Section("AirMate Peers") {
                if reporter.discoveredPeers.isEmpty {
                    ContentUnavailableView("No AirMate Peer Found", systemImage: "network", description: Text("AirMate can still sync through iCloud when your other devices are on another network. Make sure they use the same iCloud account and have AirMate running recently."))
                } else {
                    ForEach(reporter.discoveredPeers, id: \.self) { peer in
                        HStack(spacing: 14) {
                            Image(systemName: "network").font(.title2).foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(peer).font(.headline)
                                Text("AirMate ecosystem source").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
            }
            Section { Button("Sync AirMate Now") { reporter.refreshAll() } }
        }
        .navigationTitle("Peers")
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
                LabeledContent("Bluetooth audio", value: "\(reporter.connectedBluetoothAudio.count) connected")
            }
            Section("AirMate Ecosystem") {
                LabeledContent("Peers discovered", value: "\(reporter.peerCount)")
                LabeledContent("Connected devices", value: "\(reporter.connectedEcosystemCount)")
                LabeledContent("Cloud sync", value: reporter.cloudStatusText)
                if let date = reporter.lastCloudSync {
                    LabeledContent("Last cloud sync", value: date.formatted(date: .omitted, time: .shortened))
                }
                Text("Bonjour provides fast same-network sync. Private CloudKit provides cross-network sync between your AirMate Macs, iPhones and iPads signed into the same iCloud account.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("App", value: "AirMate")
                LabeledContent("Version", value: "0.8.0 beta")
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
                NavigationStack { NearbyPeersView(reporter: reporter) }
                    .tabItem { Label("Peers", systemImage: "network") }
                NavigationStack { MobileSettingsView(reporter: reporter) }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .task { reporter.start() }
        }
    }
}
