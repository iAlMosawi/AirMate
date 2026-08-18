import Foundation
import IOKit.ps

@MainActor
final class MacBatteryMonitor: ObservableObject {
    @Published private(set) var level: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var hasInternalBattery = false

    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            hasInternalBattery = false
            level = nil
            return
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let type = description[kIOPSTypeKey as String] as? String
            guard type == kIOPSInternalBatteryType else { continue }

            hasInternalBattery = true
            let current = description[kIOPSCurrentCapacityKey as String] as? Int
            let maximum = description[kIOPSMaxCapacityKey as String] as? Int
            if let current, let maximum, maximum > 0 {
                level = Int((Double(current) / Double(maximum) * 100).rounded())
            }

            let state = description[kIOPSPowerSourceStateKey as String] as? String
            isCharging = state == kIOPSACPowerValue
            return
        }

        hasInternalBattery = false
        level = nil
        isCharging = false
    }
}
