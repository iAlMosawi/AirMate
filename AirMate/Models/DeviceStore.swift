import AppKit
import Combine
import Foundation
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
    let nearbyMacs = NearbyMacService()
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
            hidMonitor.$devices,
            nearbyMacs.$peers
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] discovered, macState, hid, peers in
            self?.rebuildDevices(
                discovered: discovered,
                macLevel: macState.0,
                macCharging: macState.1,
                hid: hid,
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
        if settings.nearbyMacsEnabled { nearbyMacs.start() }

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.bluetoothScanner.prune()
                self?.hidMonitor.refresh()
            }
        }

        rebuildDevices(
            discovered: bluetoothScanner.discovered,
            macLevel: macBatteryMonitor.level,
            macCharging: macBatteryMonitor.isCharging,
            hid: hidMonitor.devices,
            peers: nearbyMacs.peers
        )
    }

    func refresh() {
        macBatteryMonitor.refresh()
        hidMonitor.refresh()
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
        peers: [AirMateDevice]
    ) {
        let previous = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        var result: [AirMateDevice] = []
        let localMacID = UUID(uuidString: "A1A1A1A1-0000-4000-8000-000000000001")!
        result.append(AirMateDevice(
            id: localMacID,
            name: Host.current().localizedName ?? "This Mac",
            kind: .mac,
            batteryLevel: macLevel,
            isCharging: macCharging,
            connectionState: .connected,
            source: .localMac
        ))

        var seen = Set<UUID>([localMacID])
        for device in hid where seen.insert(device.id).inserted { result.append(device) }

        let nearby = discovered.values.sorted {
            if $0.kind == .airPods && $1.kind != .airPods { return true }
            if $0.kind != .airPods && $1.kind == .airPods { return false }
            return ($0.rssi ?? -100) > ($1.rssi ?? -100)
        }
        for device in nearby where seen.insert(device.id).inserted { result.append(device) }

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
            let x = frame.maxX - panel.frame.width - 24
            let y = frame.maxY - panel.frame.height - 24
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { [weak panel] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run { panel?.orderOut(nil) }
        }
    }
}
