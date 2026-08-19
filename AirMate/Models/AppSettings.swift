#if os(macOS)
import Combine
import Foundation
import ServiceManagement
import SwiftUI

enum AirMateAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var showNearbyBluetooth: Bool { didSet { save(showNearbyBluetooth, "showNearbyBluetooth") } }
    @Published var showConnectionHUD: Bool { didSet { save(showConnectionHUD, "showConnectionHUD") } }
    @Published var lowBatteryThreshold: Int { didSet { save(lowBatteryThreshold, "lowBatteryThreshold") } }
    @Published var batteryAlertsEnabled: Bool { didSet { save(batteryAlertsEnabled, "batteryAlertsEnabled") } }
    @Published var batteryHistoryEnabled: Bool { didSet { save(batteryHistoryEnabled, "batteryHistoryEnabled") } }
    @Published var nearbyMacsEnabled: Bool { didSet { save(nearbyMacsEnabled, "nearbyMacsEnabled") } }
    @Published var showSignalStrength: Bool { didSet { save(showSignalStrength, "showSignalStrength") } }
    @Published var hideDisconnectedDevices: Bool { didSet { save(hideDisconnectedDevices, "hideDisconnectedDevices") } }
    @Published var showBatteryDevicesOnly: Bool { didSet { save(showBatteryDevicesOnly, "showBatteryDevicesOnly") } }
    @Published var launchAtLogin: Bool { didSet { save(launchAtLogin, "launchAtLogin"); updateLoginItem() } }
    @Published var appearance: AirMateAppearance { didSet { save(appearance.rawValue, "airmateAppearance") } }
    @Published private(set) var favoriteDeviceIDs: Set<String>

    init() {
        let defaults = UserDefaults.standard
        showNearbyBluetooth = defaults.object(forKey: "showNearbyBluetooth") as? Bool ?? true
        showConnectionHUD = defaults.object(forKey: "showConnectionHUD") as? Bool ?? true
        let storedThreshold = defaults.integer(forKey: "lowBatteryThreshold")
        lowBatteryThreshold = storedThreshold == 0 ? 20 : storedThreshold
        batteryAlertsEnabled = defaults.object(forKey: "batteryAlertsEnabled") as? Bool ?? true
        batteryHistoryEnabled = defaults.object(forKey: "batteryHistoryEnabled") as? Bool ?? true
        nearbyMacsEnabled = defaults.object(forKey: "nearbyMacsEnabled") as? Bool ?? true
        showSignalStrength = defaults.object(forKey: "showSignalStrength") as? Bool ?? true
        hideDisconnectedDevices = defaults.object(forKey: "hideDisconnectedDevices") as? Bool ?? false
        showBatteryDevicesOnly = defaults.object(forKey: "showBatteryDevicesOnly") as? Bool ?? false
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        appearance = AirMateAppearance(rawValue: defaults.string(forKey: "airmateAppearance") ?? "system") ?? .system
        favoriteDeviceIDs = Set(defaults.stringArray(forKey: "favoriteDeviceIDs") ?? [])
    }

    func isFavorite(_ id: UUID) -> Bool {
        favoriteDeviceIDs.contains(id.uuidString)
    }

    func toggleFavorite(_ id: UUID) {
        let key = id.uuidString
        if favoriteDeviceIDs.contains(key) {
            favoriteDeviceIDs.remove(key)
        } else {
            favoriteDeviceIDs.insert(key)
        }
        UserDefaults.standard.set(Array(favoriteDeviceIDs).sorted(), forKey: "favoriteDeviceIDs")
    }

    private func save(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
    private func updateLoginItem() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch { }
    }
}
#endif
