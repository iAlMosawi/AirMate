#if os(macOS)
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    @Published var showNearbyBluetooth: Bool { didSet { save(showNearbyBluetooth, "showNearbyBluetooth") } }
    @Published var showConnectionHUD: Bool { didSet { save(showConnectionHUD, "showConnectionHUD") } }
    @Published var lowBatteryThreshold: Int { didSet { save(lowBatteryThreshold, "lowBatteryThreshold") } }
    @Published var batteryAlertsEnabled: Bool { didSet { save(batteryAlertsEnabled, "batteryAlertsEnabled") } }
    @Published var batteryHistoryEnabled: Bool { didSet { save(batteryHistoryEnabled, "batteryHistoryEnabled") } }
    @Published var nearbyMacsEnabled: Bool { didSet { save(nearbyMacsEnabled, "nearbyMacsEnabled") } }
    @Published var showSignalStrength: Bool { didSet { save(showSignalStrength, "showSignalStrength") } }
    @Published var launchAtLogin: Bool { didSet { save(launchAtLogin, "launchAtLogin"); updateLoginItem() } }
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
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
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
