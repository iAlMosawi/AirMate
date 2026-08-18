import CoreBluetooth
import Foundation

@MainActor
final class BluetoothScanner: NSObject, ObservableObject {
    @Published private(set) var discovered: [UUID: AirMateDevice] = [:]
    @Published private(set) var state: CBManagerState = .unknown

    private var central: CBCentralManager!

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func start() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stop() {
        central.stopScan()
    }

    private func classify(name: String) -> AirMateDevice.Kind {
        let lower = name.lowercased()
        if lower.contains("airpods") { return .airPods }
        if lower.contains("beats") { return .beats }
        if lower.contains("iphone") { return .iPhone }
        if lower.contains("ipad") { return .iPad }
        if lower.contains("watch") { return .appleWatch }
        if lower.contains("keyboard") { return .keyboard }
        if lower.contains("mouse") { return .mouse }
        if lower.contains("trackpad") { return .trackpad }
        return .bluetooth
    }
}

extension BluetoothScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            state = central.state
            if central.state == .poweredOn {
                start()
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? "Nearby Bluetooth Device"
        let identifier = peripheral.identifier

        Task { @MainActor in
            let device = AirMateDevice(
                id: identifier,
                name: name,
                kind: classify(name: name),
                connectionState: .nearby,
                rssi: RSSI.intValue,
                lastSeen: .now
            )
            discovered[identifier] = device
        }
    }
}
