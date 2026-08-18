import Foundation

struct AirMateDevice: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case mac
        case airPods
        case beats
        case iPhone
        case iPad
        case appleWatch
        case keyboard
        case mouse
        case trackpad
        case bluetooth
    }

    enum ConnectionState: String {
        case connected
        case nearby
        case disconnected
    }

    let id: UUID
    var name: String
    var kind: Kind
    var batteryLevel: Int?
    var secondaryBatteryLevel: Int?
    var caseBatteryLevel: Int?
    var isCharging: Bool
    var connectionState: ConnectionState
    var rssi: Int?
    var lastSeen: Date

    init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        batteryLevel: Int? = nil,
        secondaryBatteryLevel: Int? = nil,
        caseBatteryLevel: Int? = nil,
        isCharging: Bool = false,
        connectionState: ConnectionState = .nearby,
        rssi: Int? = nil,
        lastSeen: Date = .now
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.batteryLevel = batteryLevel
        self.secondaryBatteryLevel = secondaryBatteryLevel
        self.caseBatteryLevel = caseBatteryLevel
        self.isCharging = isCharging
        self.connectionState = connectionState
        self.rssi = rssi
        self.lastSeen = lastSeen
    }

    var symbolName: String {
        switch kind {
        case .mac: return "desktopcomputer"
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
