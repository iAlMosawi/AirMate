#if os(macOS)
import AppKit
@preconcurrency import CloudKit
import Combine
import Foundation
@preconcurrency import Network
import SwiftUI

@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [AirMateDevice] = []
    @Published private(set) var bluetoothStateText = "Starting…"
    @Published private(set) var lastRefresh = Date()

    let bluetoothScanner = BluetoothScanner()
    let macBatteryMonitor = MacBatteryMonitor()
    let hidMonitor = HIDAccessoryMonitor()
    let history = BatteryHistoryStore()
    let nearbyMacs = NearbyDeviceExchange()
    let mobileBridge = MobileDeviceBridge()
    let cloudSync = AirMateCloudSync()
    let notifications = BatteryNotificationService()

    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false
    private var pruneTimer: Timer?
    private var settings: AppSettings?
    private let hud = DeviceHUDController()

    init() {
        Publishers.CombineLatest4(
            bluetoothScanner.$discovered,
            macBatteryMonitor.$level.combineLatest(macBatteryMonitor.$isCharging),
            hidMonitor.$devices.combineLatest(mobileBridge.$devices),
            nearbyMacs.$peers
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] discovered, macState, accessoryState, peers in
            guard let self else { return }
            self.rebuildDevices(
                discovered: discovered,
                macLevel: macState.0,
                macCharging: macState.1,
                hid: accessoryState.0,
                mobile: accessoryState.1,
                peers: peers,
                cloudPeers: self.cloudSync.peers
            )
        }
        .store(in: &cancellables)

        cloudSync.$peers
            .receive(on: RunLoop.main)
            .sink { [weak self] cloudPeers in
                guard let self else { return }
                self.rebuildDevices(
                    discovered: self.bluetoothScanner.discovered,
                    macLevel: self.macBatteryMonitor.level,
                    macCharging: self.macBatteryMonitor.isCharging,
                    hid: self.hidMonitor.devices,
                    mobile: self.mobileBridge.devices,
                    peers: self.nearbyMacs.peers,
                    cloudPeers: cloudPeers
                )
            }
            .store(in: &cancellables)

        bluetoothScanner.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.bluetoothStateText = switch state {
                case .unknown: "Starting…"
                case .resetting: "Resetting"
                case .unsupported: "Unsupported"
                case .unauthorized: "Permission required"
                case .poweredOff: "Bluetooth off"
                case .poweredOn: "Connected-device sync active"
                @unknown default: "Unknown"
                }
            }
            .store(in: &cancellables)
    }

    func start(settings: AppSettings) {
        self.settings = settings
        guard !hasStarted else { return }
        hasStarted = true
        notifications.requestAuthorization()
        bluetoothScanner.start()
        macBatteryMonitor.start()
        hidMonitor.start()
        mobileBridge.start()
        cloudSync.start()
        if settings.nearbyMacsEnabled { nearbyMacs.start() }

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.bluetoothScanner.prune()
                self?.hidMonitor.refresh()
                self?.mobileBridge.prune()
                self?.nearbyMacs.refreshPeers()
                self?.cloudSync.refresh()
            }
        }

        rebuildDevices(
            discovered: bluetoothScanner.discovered,
            macLevel: macBatteryMonitor.level,
            macCharging: macBatteryMonitor.isCharging,
            hid: hidMonitor.devices,
            mobile: mobileBridge.devices,
            peers: nearbyMacs.peers,
            cloudPeers: cloudSync.peers
        )
    }

    func refresh() {
        macBatteryMonitor.refresh()
        hidMonitor.refresh()
        mobileBridge.prune()
        nearbyMacs.refreshPeers()
        cloudSync.refresh()
        bluetoothScanner.stop()
        bluetoothScanner.start()
        lastRefresh = .now
    }

    func historySamples(for device: AirMateDevice) -> [BatteryHistorySample] {
        history.samples(for: device.id)
    }

    func setNearbyMacsEnabled(_ enabled: Bool) {
        if enabled { nearbyMacs.start() } else { nearbyMacs.stop() }
    }

    private func rebuildDevices(
        discovered: [UUID: AirMateDevice],
        macLevel: Int?,
        macCharging: Bool,
        hid: [AirMateDevice],
        mobile: [AirMateDevice],
        peers: [AirMateDevice],
        cloudPeers: [AirMateDevice]
    ) {
        let previous = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        var localResult: [AirMateDevice] = []
        let localMacID = cloudSync.installationID
        localResult.append(AirMateDevice(
            id: localMacID,
            name: Host.current().localizedName ?? "This Mac",
            kind: .mac,
            batteryLevel: macLevel,
            isCharging: macCharging,
            connectionState: .connected,
            source: .localMac,
            metadata: ["transport": "local"]
        ))

        var seen = Set<UUID>([localMacID])
        for device in hid where device.connectionState == .connected && seen.insert(device.id).inserted {
            localResult.append(device)
        }
        for device in mobile where device.connectionState == .connected && seen.insert(device.id).inserted {
            localResult.append(device)
        }

        let connectedBluetooth = discovered.values
            .filter { $0.connectionState == .connected }
            .sorted { lhs, rhs in lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
        for device in connectedBluetooth where seen.insert(device.id).inserted {
            localResult.append(device)
        }

        // Publish only this Mac's currently connected/local snapshot. Both transports
        // carry the same Codable payload: Bonjour for LAN speed, CloudKit for reachability
        // across different Wi-Fi networks or cellular connections.
        nearbyMacs.updateLocalDevices(localResult)
        cloudSync.updateLocalDevices(localResult)

        var result = localResult
        if settings?.nearbyMacsEnabled != false {
            // Prefer a live Bonjour copy when the same device also arrived through cloud.
            for device in peers where device.connectionState == .connected && seen.insert(device.id).inserted {
                result.append(device)
            }
            for device in cloudPeers where device.connectionState == .connected && seen.insert(device.id).inserted {
                result.append(device)
            }
        }

        devices = result
        lastRefresh = .now

        if settings?.batteryHistoryEnabled != false { history.record(result) }
        if settings?.batteryAlertsEnabled != false {
            notifications.evaluate(result, threshold: settings?.lowBatteryThreshold ?? 20)
        }

        if settings?.showConnectionHUD != false,
           let newHeadset = result.first(where: { device in
               (device.kind == .airPods || device.kind == .beats) &&
               device.connectionState == .connected && previous[device.id] == nil
           }) {
            hud.show(device: newHeadset)
        }
    }
}

@MainActor
final class AirMateCloudSync: ObservableObject {
    @Published private(set) var peers: [AirMateDevice] = []
    @Published private(set) var statusText = "Starting…"
    @Published private(set) var lastSync: Date?

    let installationID: UUID

    private let container = CKContainer(identifier: "iCloud.com.almosawi.airmate")
    private var localDevices: [AirMateDevice] = []
    private var scheduledSync: Task<Void, Never>?
    private let recordType = "AirMateSnapshot"
    private let liveWindow: TimeInterval = 180

    init() {
        let key = "AirMateCloudInstallationID"
        if let value = UserDefaults.standard.string(forKey: key), let existing = UUID(uuidString: value) {
            installationID = existing
        } else {
            let id = UUID()
            UserDefaults.standard.set(id.uuidString, forKey: key)
            installationID = id
        }
    }

    private var recordID: CKRecord.ID {
        CKRecord.ID(recordName: "snapshot-\(installationID.uuidString)")
    }

    private var hostName: String {
        Host.current().localizedName ?? "AirMate Mac"
    }

    func start() {
        refresh()
    }

    func updateLocalDevices(_ devices: [AirMateDevice]) {
        localDevices = devices.filter { $0.connectionState == .connected && $0.source != .nearbyMac }
        scheduleSync(after: .seconds(2))
    }

    func refresh() {
        statusText = "Syncing…"
        scheduleSync(after: .zero)
    }

    private func scheduleSync(after delay: Duration) {
        scheduledSync?.cancel()
        scheduledSync = Task { [weak self] in
            if delay != .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private func syncNow() async {
        do {
            let account = try await container.accountStatus()
            guard account == .available else {
                peers = []
                statusText = "iCloud account unavailable"
                lastSync = nil
                return
            }

            statusText = "Syncing…"
            let database = container.privateCloudDatabase
            try await uploadLocalSnapshot(to: database)
            peers = try await fetchRemoteSnapshots(from: database)
            lastSync = .now
            statusText = peers.isEmpty ? "Cloud connected" : "Cloud connected • \(peerHostCount) peers"
        } catch {
            statusText = "Cloud error: \(error.localizedDescription)"
        }
    }

    private func uploadLocalSnapshot(to database: CKDatabase) async throws {
        guard let payload = try? JSONEncoder().encode(localDevices) else { return }
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }

        record["hostName"] = hostName as CKRecordValue
        record["platform"] = "macOS" as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue
        record["payload"] = payload as CKRecordValue
        _ = try await database.save(record)
    }

    private func fetchRemoteSnapshots(from database: CKDatabase) async throws -> [AirMateDevice] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        let response = try await database.records(
            matching: query,
            inZoneWith: nil,
            desiredKeys: ["hostName", "platform", "updatedAt", "payload"],
            resultsLimit: 100
        )

        var output: [AirMateDevice] = []
        let now = Date()
        for (id, result) in response.matchResults where id != recordID {
            guard case .success(let record) = result,
                  let payload = record["payload"] as? Data,
                  let decoded = try? JSONDecoder().decode([AirMateDevice].self, from: payload) else { continue }

            let updatedAt = (record["updatedAt"] as? Date) ?? record.modificationDate ?? .distantPast
            guard now.timeIntervalSince(updatedAt) <= liveWindow else { continue }
            let remoteHost = (record["hostName"] as? String) ?? "AirMate Device"

            for original in decoded where original.connectionState == .connected {
                if original.kind == .mac {
                    output.append(AirMateDevice(
                        id: stablePeerUUID(id.recordName),
                        name: remoteHost,
                        kind: .nearbyMac,
                        modelName: original.modelName,
                        batteryLevel: original.batteryLevel,
                        isCharging: original.isCharging,
                        connectionState: .connected,
                        source: .nearbyMac,
                        lastSeen: updatedAt,
                        metadata: ["cloudPeer": remoteHost, "sync": "CloudKit"]
                    ))
                } else {
                    var device = original
                    device.source = .nearbyMac
                    device.connectionState = .connected
                    device.lastSeen = updatedAt
                    device.metadata["cloudPeer"] = remoteHost
                    device.metadata["sync"] = "CloudKit"
                    output.append(device)
                }
            }
        }
        return output
    }

    private var peerHostCount: Int {
        Set(peers.compactMap { $0.metadata["cloudPeer"] }).count
    }

    private func stablePeerUUID(_ value: String) -> UUID {
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

@MainActor
final class DeviceHUDController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(device: AirMateDevice) {
        dismissTask?.cancel()
        let hosting = NSHostingView(rootView: DeviceHUDView(device: device))
        hosting.frame = NSRect(x: 0, y: 0, width: 390, height: 150)

        let panel = self.panel ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - panel.frame.height - 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { [weak panel] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
        }
    }
}

@MainActor
final class MobileDeviceBridge: ObservableObject {
    @Published private(set) var devices: [AirMateDevice] = []
    private var byID: [UUID: AirMateDevice] = [:]
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.almosawi.airmate.mobile", qos: .utility)

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "AirMate Mac", type: "_airmate-mobile._tcp")
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.receive(on: connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            listener = nil
        }
    }

    func prune(olderThan age: TimeInterval = 120) {
        let cutoff = Date().addingTimeInterval(-age)
        byID = byID.filter { $0.value.lastSeen >= cutoff }
        devices = byID.values.sorted { $0.name < $1.name }
    }

    private func receive(on connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, _, _ in
            defer { connection.cancel() }
            guard let data else { return }
            if let device = try? JSONDecoder().decode(AirMateDevice.self, from: data) {
                Task { @MainActor in self?.store(device) }
            } else if let list = try? JSONDecoder().decode([AirMateDevice].self, from: data) {
                Task { @MainActor in list.forEach { self?.store($0) } }
            }
        }
    }

    private func store(_ incoming: AirMateDevice) {
        var device = incoming
        device.source = .pairedMobile
        device.connectionState = .connected
        device.lastSeen = .now
        byID[device.id] = device
        devices = byID.values.sorted { $0.name < $1.name }
    }
}

@MainActor
final class NearbyDeviceExchange: ObservableObject {
    @Published private(set) var peers: [AirMateDevice] = []

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
    private var peerSnapshots: [String: [AirMateDevice]] = [:]
    private var localDevices: [AirMateDevice] = []
    private let queue = DispatchQueue(label: "com.almosawi.airmate.nearby", qos: .utility)

    func updateLocalDevices(_ devices: [AirMateDevice]) {
        localDevices = devices.filter { $0.source != .nearbyMac && $0.connectionState == .connected }
    }

    func start() {
        guard listener == nil, browser == nil else { return }
        startListener()
        let browser = NWBrowser(for: .bonjour(type: "_airmate._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                var found: [String: NWEndpoint] = [:]
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint,
                       name != Host.current().localizedName {
                        found[name] = result.endpoint
                    }
                }
                self.endpoints = found
                self.peerSnapshots = self.peerSnapshots.filter { found[$0.key] != nil }
                self.refreshPeers()
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        listener?.cancel()
        browser = nil
        listener = nil
        endpoints = [:]
        peerSnapshots = [:]
        peers = []
    }

    func refreshPeers() {
        for (name, endpoint) in endpoints { requestSnapshot(peerName: name, endpoint: endpoint) }
    }

    private func startListener() {
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "AirMate Mac", type: "_airmate._tcp")
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.sendSnapshot(on: connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            listener = nil
        }
    }

    private func sendSnapshot(on connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(localDevices) else { connection.cancel(); return }
        connection.start(queue: queue)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func requestSnapshot(peerName: String, endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            if case .ready = state {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { data, _, _, _ in
                    defer { connection.cancel() }
                    guard let data, let decoded = try? JSONDecoder().decode([AirMateDevice].self, from: data) else { return }
                    Task { @MainActor in self?.storeSnapshot(decoded, peerName: peerName) }
                }
            }
        }
        connection.start(queue: queue)
    }

    private func storeSnapshot(_ snapshot: [AirMateDevice], peerName: String) {
        let converted = snapshot
            .filter { $0.connectionState == .connected }
            .map { original -> AirMateDevice in
                if original.kind == .mac {
                    return AirMateDevice(
                        id: peerUUID(peerName),
                        name: peerName,
                        kind: .nearbyMac,
                        modelName: original.modelName,
                        batteryLevel: original.batteryLevel,
                        isCharging: original.isCharging,
                        connectionState: .connected,
                        source: .nearbyMac,
                        lastSeen: .now,
                        metadata: ["nearbyPeer": peerName, "sync": "Bonjour"]
                    )
                }
                var device = original
                device.source = .nearbyMac
                device.connectionState = .connected
                device.lastSeen = .now
                device.metadata["nearbyPeer"] = peerName
                device.metadata["sync"] = "Bonjour"
                return device
            }
        peerSnapshots[peerName] = converted
        peers = peerSnapshots.keys.sorted().flatMap { peerSnapshots[$0] ?? [] }
    }

    private func peerUUID(_ name: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in name.utf8.enumerated() { bytes[index % 16] = bytes[index % 16] &+ byte }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let tuple: uuid_t = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: tuple)
    }
}
#endif
