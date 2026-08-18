# AirMate

AirMate is a clean-room, native Apple-platform companion project inspired by the convenience of device dashboards such as AirBuddy. It does not use AirBuddy source code, artwork, branding, or proprietary assets.

## One Xcode project

Open only `AirMate.xcodeproj`. It contains all AirMate targets:

- `AirMate` — macOS 26+ menu-bar app and HUD
- `AirMateWidget` — macOS WidgetKit extension
- `AirMateMobile` — iPhone/iPad 26+ companion
- `AirMateMobileWidget` — iPhone/iPad WidgetKit extension
- `AirMateWatch` — watchOS 26+ companion

Primary macOS bundle ID: `com.almosawi.airmate`

The repository includes three canonical shared schemes:

- `AirMate` → macOS only
- `AirMateMobile` → iPhone/iPad only
- `AirMateWatch` → watchOS only

Using the shared schemes prevents Xcode from accidentally building a macOS resource catalog for iOS, or a Watch target for an iPhone destination.

## Implemented beta features

- Menu-bar Apple/Bluetooth device dashboard
- Automatic AirPods/Beats-style floating connection HUD
- Best-effort AirPods/Beats Apple manufacturer-advertisement decoder
- Left/right/case battery model and charging states
- Mac battery monitoring with IOKit
- CoreBluetooth BLE discovery
- IOBluetooth connected classic-Bluetooth discovery
- Magic Keyboard, Mouse and Trackpad discovery through HID
- iPhone/iPad battery reporting through the AirMate companion
- Apple Watch battery reporting through the AirMate Watch companion
- Nearby Mac discovery and local-network device snapshot exchange
- iPhone/iPad ecosystem view of devices reported by AirMate Macs
- Favorites/pinning and device filtering
- Low-battery notifications
- Persistent battery history
- Battery history charts with Swift Charts
- CoreAudio output-device discovery and switching
- Launch at login
- Shortcuts/App Intents entry point
- macOS and iPhone/iPad WidgetKit extensions
- Swift 6 / Xcode 27 project structure
- GitHub Actions builds for macOS, iOS and watchOS from the same Xcode project

## Signing

All embedded extensions must use the same Apple Development team/certificate as their parent app.

For local Mac testing, select the same Team under **Signing & Capabilities** for both `AirMate` and `AirMateWidget`.

For iPhone/iPad testing, select the same Team for `AirMateMobile` and `AirMateMobileWidget`.

The repository intentionally does not hard-code a personal Apple Developer Team ID because it is account-specific.

## Important compatibility notes

Apple exposes normal iPhone/iPad and Apple Watch battery monitoring APIs to their respective apps, so AirMate uses companion apps to report those battery values to the Mac over the local network.

Detailed AirPods proximity-pairing advertisement formats, closed-case battery state, some listening-mode controls, and several seamless Apple ecosystem behaviors are not documented as stable public APIs. AirMate therefore keeps AirPods advertisement decoding in an isolated compatibility layer. Real-device testing is required to calibrate that parser against actual AirPods/Beats models and current macOS behavior.

## Build

Requirements:

- Xcode 27+
- macOS 26+
- Apple Silicon recommended

Clone and open the single project:

```bash
git clone https://github.com/iAlMosawi/AirMate.git
cd AirMate
open AirMate.xcodeproj
```

Run the appropriate shared scheme:

- `AirMate` → **My Mac**
- `AirMateMobile` → **iPhone/iPad or Simulator**
- `AirMateWatch` → **Apple Watch or Watch Simulator**

## Local network services

AirMate uses Bonjour only on the local network:

- `_airmate._tcp` — Mac-to-Mac AirMate exchange
- `_airmate-mobile._tcp` — iPhone/iPad/Watch battery reporting to the Mac

## Privacy

The current beta does not require an AirMate cloud service. Device discovery, battery reporting, history and Nearby Mac exchange are designed to operate locally. Battery history is stored in the Mac user's Application Support directory.

## Status

Version: **0.6.0 beta**

The unified Xcode project is validated in Xcode 27 CI using the same shared schemes used for local development: Mac + Widget, iPhone/iPad + Widget, and Apple Watch. Real-device testing remains necessary for Bluetooth advertisement calibration, code signing/provisioning, device-specific compatibility and final UI/behavior polish.
