from pathlib import Path
import json
import re


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"Missing patch marker: {label}")
    return text.replace(old, new, 1)


# Remove temporary orchestration files inherited from main.
for temp in ["tools/repair_airmate.py.tmp", "tools/README.tmp"]:
    Path(temp).unlink(missing_ok=True)

# ---------------------------------------------------------------------------
# Project metadata: one version/build and AirMate product name everywhere.
# ---------------------------------------------------------------------------
pbx = Path("AirMate.xcodeproj/project.pbxproj")
text = pbx.read_text()
text = re.sub(r"MARKETING_VERSION=[^;]+;", "MARKETING_VERSION=26.15;", text)
text = re.sub(r"CURRENT_PROJECT_VERSION=[^;]+;", "CURRENT_PROJECT_VERSION=10;", text)
text = text.replace('PRODUCT_NAME="$(TARGET_NAME)";SDKROOT=macosx;', 'PRODUCT_NAME="AirMate";SDKROOT=macosx;', 1)
pbx.write_text(text)

for plist in ["AirMate/Resources/Info.plist", "AirMateMobile/Info.plist", "AirMateWatch/Info.plist"]:
    path = Path(plist)
    source = path.read_text()
    for key, value in [
        ("CFBundleDisplayName", "AirMate"),
        ("CFBundleName", "AirMate"),
        ("CFBundleShortVersionString", "26.15"),
        ("CFBundleVersion", "10"),
    ]:
        pattern = rf"(<key>{re.escape(key)}</key>\s*<string>)(.*?)(</string>)"
        if re.search(pattern, source, re.S):
            source = re.sub(pattern, rf"\g<1>{value}\g<3>", source, flags=re.S)
    path.write_text(source)

# ---------------------------------------------------------------------------
# macOS icon catalog: all required macOS icon sizes.
# ---------------------------------------------------------------------------
icon_contents = {
    "images": [
        {"filename": "icon_16x16.png", "idiom": "mac", "scale": "1x", "size": "16x16"},
        {"filename": "icon_16x16@2x.png", "idiom": "mac", "scale": "2x", "size": "16x16"},
        {"filename": "icon_32x32.png", "idiom": "mac", "scale": "1x", "size": "32x32"},
        {"filename": "icon_32x32@2x.png", "idiom": "mac", "scale": "2x", "size": "32x32"},
        {"filename": "icon_128x128.png", "idiom": "mac", "scale": "1x", "size": "128x128"},
        {"filename": "icon_128x128@2x.png", "idiom": "mac", "scale": "2x", "size": "128x128"},
        {"filename": "icon_256x256.png", "idiom": "mac", "scale": "1x", "size": "256x256"},
        {"filename": "icon_256x256@2x.png", "idiom": "mac", "scale": "2x", "size": "256x256"},
        {"filename": "icon_512x512.png", "idiom": "mac", "scale": "1x", "size": "512x512"},
        {"filename": "AirMateIcon.png", "idiom": "mac", "scale": "2x", "size": "512x512"},
    ],
    "info": {"author": "xcode", "version": 1},
}
Path("AirMate/Assets.xcassets/AppIcon.appiconset/Contents.json").write_text(json.dumps(icon_contents, indent=2) + "\n")

# ---------------------------------------------------------------------------
# macOS CloudKit: verify same iCloud account, keep remote snapshots usable
# after backgrounding, and expose useful diagnostics/errors.
# ---------------------------------------------------------------------------
path = Path("AirMate/Models/DeviceStore.swift")
source = path.read_text()
source = replace_once(
    source,
    '@Published private(set) var lastSync: Date?\n',
    '@Published private(set) var lastSync: Date?\n    @Published private(set) var accountFingerprint = "Checking…"\n    @Published private(set) var lastError: String?\n',
    "Mac Cloud published state",
)
source = source.replace("private let liveWindow: TimeInterval = 180", "private let liveWindow: TimeInterval = 86_400")
source = replace_once(
    source,
    'statusText = "Syncing…"\n            let database = container.privateCloudDatabase',
    'statusText = "Syncing…"\n            lastError = nil\n            let userRecordID = try await container.userRecordID()\n            accountFingerprint = Self.shortAccountFingerprint(userRecordID.recordName)\n            let database = container.privateCloudDatabase',
    "Mac Cloud account verification",
)
source = replace_once(
    source,
    '} catch {\n            statusText = "Cloud error: \\(error.localizedDescription)"\n        }',
    '} catch {\n            lastError = error.localizedDescription\n            statusText = "Cloud error: \\(error.localizedDescription)"\n        }',
    "Mac Cloud detailed error",
)
helper = '''    private static func shortAccountFingerprint(_ value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(format: "%08X", UInt32(truncatingIfNeeded: hash))
    }

'''
if "private static func shortAccountFingerprint" not in source:
    source = replace_once(source, "    private var peerHostCount: Int {", helper + "    private var peerHostCount: Int {", "Mac account helper")
path.write_text(source)

path = Path("AirMate/UI/SettingsView.swift")
source = path.read_text()
source = replace_once(
    source,
    'LabeledContent("Status", value: store.cloudSync.statusText)',
    'LabeledContent("Status", value: store.cloudSync.statusText)\n                LabeledContent("iCloud account", value: store.cloudSync.accountFingerprint)',
    "Mac Cloud account UI",
)
source = source.replace(
    'LabeledContent("Live cloud devices", value: "\\(store.cloudSync.peers.count)")',
    'LabeledContent("Cloud devices", value: "\\(store.cloudSync.peers.count)")\n                if let error = store.cloudSync.lastError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }',
)
source = source.replace('LabeledContent("Version", value: "0.9.0 beta")', 'LabeledContent("Version", value: "26.15 (10)")')
path.write_text(source)

# ---------------------------------------------------------------------------
# iPhone/iPad CloudKit: same account verification, better retention, visible
# error diagnostics, and immediate foreground refresh.
# ---------------------------------------------------------------------------
path = Path("AirMateMobile/AirMateMobileApp.swift")
source = path.read_text()
source = replace_once(
    source,
    '@Published private(set) var cloudStatusText = "Starting…"\n',
    '@Published private(set) var cloudStatusText = "Starting…"\n    @Published private(set) var cloudAccountFingerprint = "Checking…"\n    @Published private(set) var cloudLastError: String?\n',
    "Mobile Cloud published state",
)
source = source.replace("private let cloudLiveWindow: TimeInterval = 180", "private let cloudLiveWindow: TimeInterval = 86_400")
source = replace_once(
    source,
    'cloudStatusText = "Syncing…"\n            let database = cloudContainer.privateCloudDatabase',
    'cloudStatusText = "Syncing…"\n            cloudLastError = nil\n            let userRecordID = try await cloudContainer.userRecordID()\n            cloudAccountFingerprint = Self.shortAccountFingerprint(userRecordID.recordName)\n            let database = cloudContainer.privateCloudDatabase',
    "Mobile Cloud account verification",
)
source = replace_once(
    source,
    '} catch {\n            cloudStatusText = "Cloud error: \\(error.localizedDescription)"\n        }',
    '} catch {\n            cloudLastError = error.localizedDescription\n            cloudStatusText = "Cloud error: \\(error.localizedDescription)"\n        }',
    "Mobile Cloud detailed error",
)
helper = '''    private static func shortAccountFingerprint(_ value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(format: "%08X", UInt32(truncatingIfNeeded: hash))
    }

'''
if "private static func shortAccountFingerprint" not in source:
    source = replace_once(source, "    private func stableUUID", helper + "    private func stableUUID", "Mobile account helper")

source = source.replace(
    'LabeledContent("Cloud", value: reporter.cloudStatusText)',
    'LabeledContent("Cloud", value: reporter.cloudStatusText)\n                LabeledContent("iCloud account", value: reporter.cloudAccountFingerprint)\n                if let error = reporter.cloudLastError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }',
)
source = replace_once(
    source,
    '@StateObject private var reporter = MobileReporter()\n',
    '@StateObject private var reporter = MobileReporter()\n    @Environment(\\.scenePhase) private var scenePhase\n',
    "Mobile scene phase",
)
if ".onChange(of: scenePhase)" not in source:
    source = replace_once(
        source,
        ".preferredColorScheme(preferredScheme)",
        '.preferredColorScheme(preferredScheme)\n            .onChange(of: scenePhase) { _, phase in\n                if phase == .active { reporter.refreshAll() }\n            }',
        "Mobile foreground refresh",
    )
path.write_text(source)

# Keep widget cloud snapshots available after the source app backgrounds.
path = Path("AirMateMobileWidget/AirMateMobileWidget.swift")
source = path.read_text().replace("let liveWindow: TimeInterval = 180", "let liveWindow: TimeInterval = 86_400")
path.write_text(source)

# ---------------------------------------------------------------------------
# macOS Bluetooth battery reporting. IOBluetooth provides connection state;
# supplement it with macOS system_profiler battery fields when available.
# ---------------------------------------------------------------------------
path = Path("AirMate/Services/BluetoothScanner.swift")
source = path.read_text()
sample_type = '''
private struct SystemBluetoothBatterySample: Sendable {
    let name: String
    let address: String?
    let main: Int?
    let left: Int?
    let right: Int?
    let caseLevel: Int?
}

'''
if "struct SystemBluetoothBatterySample" not in source:
    source = replace_once(source, "@MainActor\nfinal class BluetoothScanner", sample_type + "@MainActor\nfinal class BluetoothScanner", "System battery sample")
source = replace_once(
    source,
    "refreshClassicBluetoothDevices()\n        classicTimer?.invalidate()",
    "refreshClassicBluetoothDevices()\n        refreshSystemBluetoothBatteryLevels()\n        classicTimer?.invalidate()",
    "Initial system battery refresh",
)
source = source.replace(
    "Task { @MainActor in self?.refreshClassicBluetoothDevices() }",
    "Task { @MainActor in self?.refreshClassicBluetoothDevices(); self?.refreshSystemBluetoothBatteryLevels() }",
)

battery_methods = r'''    private func refreshSystemBluetoothBatteryLevels() {
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

'''
if "loadSystemBluetoothBatteryLevels" not in source:
    source = replace_once(source, "    private func stableBluetoothUUID(address: String, fallback: String) -> UUID {", battery_methods + "    private func stableBluetoothUUID(address: String, fallback: String) -> UUID {", "System battery methods")
path.write_text(source)

# README version marker.
readme = Path("README.md")
readme.write_text(re.sub(r"0\.9\.0(?: beta)?", "26.15", readme.read_text()))
