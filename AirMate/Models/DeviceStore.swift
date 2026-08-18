import AppKit
import Combine
import Foundation

@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [AirMateDevice] = []
    @Published private(set) var bluetoothStateText = "Starting…"

    let bluetoothScanner = BluetoothScanner()
    let macBatteryMonitor = MacBatteryMonitor()

    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false

    init() {
        bluetoothScanner.$discovered
            .combineLatest(macBatteryMonitor.$level, macBatteryMonitor.$isCharging)
            .receive(on: RunLoop.main)
            .sink { [weak self] discovered, level, charging in
                self?.rebuildDevices(discovered: discovered, macLevel: level, macCharging: charging)
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

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        bluetoothScanner.start()
        macBatteryMonitor.start()
        rebuildDevices(
            discovered: bluetoothScanner.discovered,
            macLevel: macBatteryMonitor.level,
            macCharging: macBatteryMonitor.isCharging
        )
    }

    func refresh() {
        macBatteryMonitor.refresh()
        bluetoothScanner.stop()
        bluetoothScanner.start()
    }

    private func rebuildDevices(discovered: [UUID: AirMateDevice], macLevel: Int?, macCharging: Bool) {
        var result: [AirMateDevice] = []

        let localMac = AirMateDevice(
            name: Host.current().localizedName ?? "This Mac",
            kind: .mac,
            batteryLevel: macLevel,
            isCharging: macCharging,
            connectionState: .connected
        )
        result.append(localMac)

        let nearby = discovered.values.sorted {
            if $0.kind == .airPods && $1.kind != .airPods { return true }
            if $0.kind != .airPods && $1.kind == .airPods { return false }
            return ($0.rssi ?? -100) > ($1.rssi ?? -100)
        }
        result.append(contentsOf: nearby)
        devices = result
    }
}
