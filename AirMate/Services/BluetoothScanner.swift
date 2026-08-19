#if os(macOS)
import Combine
import CoreBluetooth
import Foundation
import IOBluetooth
import IOKit.hid
import Network
import UserNotifications


private struct SystemBluetoothBatterySample: Sendable {
    let name: String
    let address: String?
    let main: Int?
    let left: Int?
    let right: Int?
    let caseLevel: Int?
}

@MainActor
final class BluetoothScanner: NSObject, ObservableObject {
    @Published private(set) var discovered: [UUID: AirMateDevice] = [:]
    @Published private(set) var state: CBManagerState = .unknown

    private var central: CBCentralManager!
    private let airPodsParser = AppleAdvertisementParser()
    private var classicTimer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func start() {
        refreshClassicBluetoothDevices()
        refreshSystemBluetoothBatteryLevels()
        classicTimer?.invalidate()
        classicTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshClassicBluetoothDevices(); self?.refreshSystemBluetoothBatteryLevels() }
        }
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stop() {
        central.stopScan()
        classicTimer?.invalidate()
        classicTimer = nil
    }

    func prune(olderThan age: TimeInterval = 90) {
        let cutoff = Date().addingTimeInterval(-age)
        discovered = discovered.filter { $0.value.lastSeen >= cutoff || $0.value.connectionState == .connected }
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

    private func refreshClassicBluetoothDevices() {
        guard let paired = IOBluetoothDevice.pairedDevices() else { return }
        var connectedAddresses = Set<String>()

        for object in paired {
            guard let bt = object as? IOBluetoothDevice, bt.isConnected() else { continue }
            let name = bt.nameOrAddress ?? bt.name ?? "Connected Bluetooth Device"
            let address = (bt.addressString ?? "").uppercased()
            connectedAddresses.insert(address)
            let rssi = Int(bt.rawRSSI())

            if let existing = discovered.first(where: { $0.value.name.caseInsensitiveCompare(name) == .orderedSame }) {
                var updated = existing.value
                updated.connectionState = .connected
                updated.rssi = rssi
                updated.lastSeen = .now
                updated.metadata["transport"] = "IOBluetooth"
                updated.metadata["address"] = address
                discovered[existing.key] = updated
                continue
            }

            let id = stableBluetoothUUID(address: address, fallback: name)
            discovered[id] = AirMateDevice(
                id: id,
                name: name,
                kind: classify(name: name),
                connectionState: .connected,
                source: .coreBluetooth,
                rssi: rssi,
                lastSeen: .now,
                metadata: ["transport": "IOBluetooth", "address": address]
            )
        }

        for (id, device) in discovered where device.metadata["transport"] == "IOBluetooth" {
            let address = device.metadata["address"] ?? ""
            if !connectedAddresses.contains(address) {
                var updated = device
                updated.connectionState = .disconnected
                updated.lastSeen = .now
                discovered[id] = updated
            }
        }
    }

    private func refreshSystemBluetoothBatteryLevels() {
        Task.detached(priority: .utility) {
            let samples = Self.loadSystemBluetoothBatteryLevels()
            await MainActor.run { [weak self] in
                guard let self else { return }
                for sample in samples {
                    guard let existing = self.discovered.first(where: { pair in
                        let device = pair.value
                        if device.name.caseInsensitiveCompare(sample.name) == .orderedSame { return true }
                        if let address = sample.address,
                           let existingAddress = device.metadata["address"],
                           existingAddress.caseInsensitiveCompare(address) == .orderedSame { return true }
                        return false
                    }) else { continue }

                    var device = existing.value
                    if let main = sample.main { device.batteryLevel = main }
                    if let left = sample.left { device.batteryLevel = left }
                    if let right = sample.right { device.secondaryBatteryLevel = right }
                    if let caseLevel = sample.caseLevel { device.caseBatteryLevel = caseLevel }
                    if device.hasAnyBattery { device.metadata["batterySource"] = "macOS" }
                    self.discovered[existing.key] = device
                }
            }
        }
    }

    nonisolated private static func loadSystemBluetoothBatteryLevels() -> [SystemBluetoothBatterySample] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "mini"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

            func percent(_ value: Any?) -> Int? {
                if let number = value as? NSNumber { return max(0, min(100, number.intValue)) }
                guard let text = value as? String else { return nil }
                let digits = text.filter(\.isNumber)
                guard let value = Int(digits) else { return nil }
                return max(0, min(100, value))
            }

            var output: [SystemBluetoothBatterySample] = []
            func walk(_ value: Any, keyName: String? = nil) {
                if let dict = value as? [String: Any] {
                    let batteryEntries = dict.filter { $0.key.lowercased().contains("battery") }
                    if !batteryEntries.isEmpty, let name = keyName {
                        func battery(_ components: [String]) -> Int? {
                            for (key, value) in batteryEntries {
                                let lower = key.lowercased()
                                if components.allSatisfy({ lower.contains($0) }), let result = percent(value) { return result }
                            }
                            return nil
                        }
                        let exactMain = batteryEntries.first { key, _ in
                            let lower = key.lowercased()
                            return lower.contains("main") || lower.hasSuffix("battery") || lower.hasSuffix("batterylevel")
                        }.flatMap { percent($0.value) }
                        let address = dict.first { $0.key.lowercased().contains("address") }?.value as? String
                        output.append(SystemBluetoothBatterySample(
                            name: name,
                            address: address,
                            main: battery(["main"]) ?? exactMain,
                            left: battery(["left"]),
                            right: battery(["right"]),
                            caseLevel: battery(["case"])
                        ))
                    }
                    for (key, child) in dict { walk(child, keyName: key) }
                } else if let array = value as? [Any] {
                    for child in array { walk(child, keyName: keyName) }
                }
            }
            walk(root)
            return output
        } catch {
            return []
        }
    }

    private func stableBluetoothUUID(address: String, fallback: String) -> UUID {
        let hex = address.uppercased().filter { $0.isHexDigit }
        if hex.count >= 12 {
            let tail = String(hex.suffix(12))
            if let uuid = UUID(uuidString: "B1000000-0000-4000-8000-\(tail)") { return uuid }
        }
        var hash: UInt64 = 1469598103934665603
        for byte in fallback.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let tail = String(format: "%012llX", hash & 0xFFFFFFFFFFFF)
        return UUID(uuidString: "B1000000-0000-4000-8000-\(tail)") ?? UUID()
    }
}

extension BluetoothScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateRawValue = central.state.rawValue
        Task { @MainActor [stateRawValue] in
            let newState = CBManagerState(rawValue: stateRawValue) ?? .unknown
            state = newState
            if newState == .poweredOn { start() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? "Nearby Bluetooth Device"
        let identifier = peripheral.identifier
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let rssiValue = RSSI.intValue

        Task { @MainActor in
            var device = AirMateDevice(id: identifier, name: name, kind: classify(name: name), connectionState: .nearby, source: .coreBluetooth, rssi: rssiValue, lastSeen: .now)

            if let manufacturerData, let parsed = airPodsParser.parse(manufacturerData, fallbackName: name) {
                device.kind = parsed.kind
                device.modelName = parsed.modelName
                device.batteryLevel = parsed.leftBattery
                device.secondaryBatteryLevel = parsed.rightBattery
                device.caseBatteryLevel = parsed.caseBattery
                device.isCharging = parsed.leftCharging
                device.isSecondaryCharging = parsed.rightCharging
                device.isCaseCharging = parsed.caseCharging
                device.source = .appleAdvertisement
                device.metadata["parser"] = "apple-manufacturer-data"
            }
            discovered[identifier] = device
        }
    }
}

struct AppleAdvertisementParser {
    struct Result {
        let kind: AirMateDevice.Kind
        let modelName: String?
        let leftBattery: Int?
        let rightBattery: Int?
        let caseBattery: Int?
        let leftCharging: Bool
        let rightCharging: Bool
        let caseCharging: Bool
    }

    func parse(_ data: Data, fallbackName: String) -> Result? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }
        let hasAppleCompanyID = bytes[0] == 0x4C && bytes[1] == 0x00
        guard hasAppleCompanyID else { return nil }
        guard bytes.dropFirst(2).contains(0x07) else { return nil }

        let lowerName = fallbackName.lowercased()
        let kind: AirMateDevice.Kind = lowerName.contains("beats") ? .beats : .airPods
        let candidates = bytes.suffix(min(bytes.count, 8)).flatMap { byte -> [Int] in [Int(byte & 0x0F), Int((byte >> 4) & 0x0F)] }.filter { $0 <= 10 }

        func percentage(_ index: Int) -> Int? {
            guard candidates.indices.contains(index) else { return nil }
            return min(100, candidates[index] * 10)
        }

        let chargingByte = bytes.last ?? 0
        return Result(kind: kind, modelName: lowerName.contains("airpods") || lowerName.contains("beats") ? fallbackName : nil, leftBattery: percentage(0), rightBattery: percentage(1), caseBattery: percentage(2), leftCharging: (chargingByte & 0x01) != 0, rightCharging: (chargingByte & 0x02) != 0, caseCharging: (chargingByte & 0x04) != 0)
    }
}

@MainActor
final class HIDAccessoryMonitor: ObservableObject {
    @Published private(set) var devices: [AirMateDevice] = []
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess, let deviceSet = IOHIDManagerCopyDevices(manager) else { devices = []; return }

        let hidObjects = (deviceSet as NSSet).allObjects
        var result: [AirMateDevice] = []
        for object in hidObjects {
            let device = unsafeBitCast(object as AnyObject, to: IOHIDDevice.self)
            guard let product = IOHIDDeviceGetProperty(device, "Product" as CFString) as? String else { continue }
            let lower = product.lowercased()
            let kind: AirMateDevice.Kind
            if lower.contains("keyboard") { kind = .keyboard }
            else if lower.contains("trackpad") { kind = .trackpad }
            else if lower.contains("mouse") { kind = .mouse }
            else { continue }

            let battery = (IOHIDDeviceGetProperty(device, "BatteryPercent" as CFString) as? NSNumber)?.intValue
            let registryID = (IOHIDDeviceGetProperty(device, "RegistryID" as CFString) as? NSNumber)?.uint64Value ?? UInt64(bitPattern: Int64(product.hashValue))
            let uuid = UUID(uuidString: String(format: "%08X-0000-4000-8000-%012llX", UInt32(truncatingIfNeeded: registryID), registryID & 0xFFFFFFFFFFFF)) ?? UUID()
            result.append(AirMateDevice(id: uuid, name: product, kind: kind, batteryLevel: battery, connectionState: .connected, source: .hid, lastSeen: .now))
        }
        devices = result
    }
}

@MainActor
final class BatteryHistoryStore: ObservableObject {
    @Published private(set) var samples: [BatteryHistorySample] = []
    private var lastRecorded: [UUID: (level: Int, date: Date)] = [:]
    init() { load() }
    func record(_ devices: [AirMateDevice]) {
        var changed = false
        for device in devices {
            guard let level = device.batteryLevel else { continue }
            let previous = lastRecorded[device.id]
            if previous == nil || previous?.level != level || Date().timeIntervalSince(previous!.date) >= 600 {
                samples.append(BatteryHistorySample(device: device, level: level)); lastRecorded[device.id] = (level, .now); changed = true
            }
        }
        if samples.count > 10_000 { samples.removeFirst(samples.count - 10_000) }
        if changed { save() }
    }
    func samples(for deviceID: UUID) -> [BatteryHistorySample] { samples.filter { $0.deviceID == deviceID } }
    private var url: URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = root.appendingPathComponent("AirMate", isDirectory: true); try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); return folder.appendingPathComponent("battery-history.json")
    }
    private func load() {
        guard let url, let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([BatteryHistorySample].self, from: data) else { return }
        samples = decoded; for sample in decoded.suffix(1000) { lastRecorded[sample.deviceID] = (sample.level, sample.date) }
    }
    private func save() { guard let url, let data = try? JSONEncoder().encode(samples) else { return }; try? data.write(to: url, options: .atomic) }
}

@MainActor
final class BatteryNotificationService {
    private var notifiedLevels: [UUID: Int] = [:]
    func requestAuthorization() { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    func evaluate(_ devices: [AirMateDevice], threshold: Int) {
        for device in devices {
            guard let level = device.batteryLevel, level <= threshold, !device.isCharging else { if let level = device.batteryLevel, level > threshold + 5 { notifiedLevels[device.id] = nil }; continue }
            guard notifiedLevels[device.id] != level else { continue }
            notifiedLevels[device.id] = level
            let content = UNMutableNotificationContent(); content.title = "\(device.name) battery is low"; content.body = "Battery is at \(level)%."; content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "low-\(device.id.uuidString)-\(level)", content: content, trigger: nil))
        }
    }
}

@MainActor
final class NearbyMacService: ObservableObject {
    @Published private(set) var peers: [AirMateDevice] = []
    private var browser: NWBrowser?
    private var listener: NWListener?
    func start() {
        startAdvertising()
        let browser = NWBrowser(for: .bonjour(type: "_airmate._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.peers = results.compactMap { result in guard case let .service(name, _, _, _) = result.endpoint, name != Host.current().localizedName else { return nil }; return AirMateDevice(name: name, kind: .nearbyMac, connectionState: .nearby, source: .nearbyMac, lastSeen: .now) } }
        }
        browser.start(queue: DispatchQueue.global(qos: .utility)); self.browser = browser
    }
    func stop() { browser?.cancel(); listener?.cancel(); browser = nil; listener = nil }
    private func startAdvertising() {
        do { let listener = try NWListener(using: .tcp, on: .any); listener.service = NWListener.Service(name: Host.current().localizedName ?? "AirMate Mac", type: "_airmate._tcp"); listener.newConnectionHandler = { connection in connection.cancel() }; listener.start(queue: DispatchQueue.global(qos: .utility)); self.listener = listener } catch { listener = nil }
    }
}
#endif
