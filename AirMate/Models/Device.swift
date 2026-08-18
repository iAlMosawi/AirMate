#if os(macOS)
import Foundation

struct AirMateDevice: Identifiable, Hashable, Codable {
    enum Kind: String, CaseIterable, Codable {
        case mac, airPods, beats, iPhone, iPad, appleWatch, keyboard, mouse, trackpad, bluetooth, nearbyMac
    }
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

    init(id: UUID = UUID(), name: String, kind: Kind, modelName: String? = nil, batteryLevel: Int? = nil, secondaryBatteryLevel: Int? = nil, caseBatteryLevel: Int? = nil, isCharging: Bool = false, isSecondaryCharging: Bool = false, isCaseCharging: Bool = false, connectionState: ConnectionState = .nearby, source: Source = .coreBluetooth, rssi: Int? = nil, lastSeen: Date = .now, metadata: [String: String] = [:]) {
        self.id = id; self.name = name; self.kind = kind; self.modelName = modelName
        self.batteryLevel = batteryLevel; self.secondaryBatteryLevel = secondaryBatteryLevel; self.caseBatteryLevel = caseBatteryLevel
        self.isCharging = isCharging; self.isSecondaryCharging = isSecondaryCharging; self.isCaseCharging = isCaseCharging
        self.connectionState = connectionState; self.source = source; self.rssi = rssi; self.lastSeen = lastSeen; self.metadata = metadata
    }

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
    var hasAnyBattery: Bool { batteryLevel != nil || secondaryBatteryLevel != nil || caseBatteryLevel != nil }
    var primaryBatteryText: String { batteryLevel.map { "\($0)%" } ?? "—" }
}

struct BatteryHistorySample: Identifiable, Codable, Hashable {
    let id: UUID; let deviceID: UUID; let deviceName: String; let level: Int; let charging: Bool; let date: Date
    init(device: AirMateDevice, level: Int, date: Date = .now) {
        id = UUID(); deviceID = device.id; deviceName = device.name; self.level = level; charging = device.isCharging; self.date = date
    }
}
#endif
