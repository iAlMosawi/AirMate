import CoreAudio
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

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

@MainActor
final class AudioDeviceService: ObservableObject {
    @Published private(set) var outputs: [AudioOutputDevice] = []
    @Published private(set) var currentOutputID: AudioDeviceID = kAudioObjectUnknown

    var currentOutputName: String {
        outputs.first(where: { $0.id == currentOutputID })?.name ?? "System Default"
    }

    func start() { refresh() }

    func refresh() {
        currentOutputID = defaultOutputID()
        outputs = allAudioDevices().map { AudioOutputDevice(id: $0, name: deviceName($0) ?? "Audio Device \($0)") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func setDefaultOutput(_ device: AudioOutputDevice) -> Bool {
        var id = device.id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        if status == noErr { refresh() }
        return status == noErr
    }

    private func defaultOutputID() -> AudioDeviceID {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else {
            return kAudioObjectUnknown
        }
        return id
    }

    private func allAudioDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name as String?
    }
}
