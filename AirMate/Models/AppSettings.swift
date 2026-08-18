import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var showNearbyBluetooth: Bool {
        didSet { UserDefaults.standard.set(showNearbyBluetooth, forKey: "showNearbyBluetooth") }
    }

    @Published var showConnectionHUD: Bool {
        didSet { UserDefaults.standard.set(showConnectionHUD, forKey: "showConnectionHUD") }
    }

    @Published var lowBatteryThreshold: Int {
        didSet { UserDefaults.standard.set(lowBatteryThreshold, forKey: "lowBatteryThreshold") }
    }

    init() {
        let defaults = UserDefaults.standard
        showNearbyBluetooth = defaults.object(forKey: "showNearbyBluetooth") as? Bool ?? true
        showConnectionHUD = defaults.object(forKey: "showConnectionHUD") as? Bool ?? true
        let storedThreshold = defaults.integer(forKey: "lowBatteryThreshold")
        lowBatteryThreshold = storedThreshold == 0 ? 20 : storedThreshold
    }
}
