import AppKit
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
            self?.rebuildDevices(
                discovered: discovered,
                macLevel: macState.0,
                macCharging: macState.1,
                hid: accessoryState.0,
                mobile: accessoryState.1,
                peers: peers
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
                case .poweredOn: "Scanning"
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
        if settings.nearbyMacsEnabled { nearbyMacs.start() }

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.bluetoothScanner.prune()
                self?.hidMonitor.refresh()
                self?.mobileBridge.prune()
                self?.nearbyMacs.refreshPeers()
            }
        }

        rebuildDevices(
            discovered: bluetoothScanner.discovered,
            macLevel: macBatteryMonitor.level,
            macCharging: macBatteryMonitor.isCharging,
            hid: hidMonitor.devices,
            mobile: mobileBridge.devices,
            peers: nearbyMacs.peers
        )
    }

    func refresh() {
        macBatteryMonitor.refresh()
        hidMonitor.refresh()
        mobileBridge.prune()
        nearbyMacs.refreshPeers()
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
        peers: [AirMateDevice]
    ) {
        let previous = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        var localResult: [AirMateDevice] = []
        let localMacID = UUID(uuidString: "A1A1A1A1-0000-4000-8000-000000000001")!
        localResult.append(AirMateDevice(
            id: localMacID,
            name: Host.current().localizedName ?? "This Mac",
            kind: .mac,
            batteryLevel: macLevel,
            isCharging: macCharging,
            connectionState: .connected,
            source: .localMac
        ))

        var seen = Set<UUID>([localMacID])
        for device in hid where seen.insert(device.id).inserted { localResult.append(device) }
        for device in mobile where seen.insert(device.id).inserted { localResult.append(device) }

        let nearby = discovered.values.sorted {
            if $0.kind == .airPods && $1.kind != .airPods { return true }
            if $0.kind != .airPods && $1.kind == .airPods { return false }
            return ($0.rssi ?? -100) > ($1.rssi ?? -100)
        }
        for device in nearby where seen.insert(device.id).inserted { localResult.append(device) }

        nearbyMacs.updateLocalDevices(localResult)

        var result = localResult
        if settings?.nearbyMacsEnabled != false {
            for device in peers where seen.insert(device.id).inserted { result.append(device) }
        }

        devices = result
        lastRefresh = .now

        if settings?.batteryHistoryEnabled != false { history.record(result) }
        if settings?.batteryAlertsEnabled != false {
            notifications.evaluate(result, threshold: settings?.lowBatteryThreshold ?? 20)
        }

        if settings?.showConnectionHUD != false,
           let newHeadset = result.first(where: { device in
               (device.kind == .airPods || device.kind == .beats) && previous[device.id] == nil
           }) {
            hud.show(device: newHeadset)
        }
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
        localDevices = devices.filter { $0.source != .nearbyMac }
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
        let converted = snapshot.map { original -> AirMateDevice in
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
                    metadata: ["nearbyMac": peerName]
                )
            }
            var device = original
            device.source = .nearbyMac
            device.metadata["nearbyMac"] = peerName
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
