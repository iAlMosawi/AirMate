# AirMate

AirMate is a clean-room, native Apple-platform companion project inspired by the convenience of device dashboards such as AirBuddy. It does not use AirBuddy source code, artwork, branding, or proprietary assets.

## Projects

- `AirMate.xcodeproj` — macOS 26+ menu-bar app, HUD and WidgetKit extension
- `AirMateMobile.xcodeproj` — iPhone/iPad 26+ battery companion
- `AirMateWatch.xcodeproj` — watchOS 26+ battery companion

Primary macOS bundle ID: `com.almosawi.airmate`

## Implemented beta features

- Menu-bar Apple/Bluetooth device dashboard
- Automatic AirPods/Beats-style floating connection HUD
- Best-effort AirPods/Beats Apple manufacturer-advertisement decoder
- Left/right/case battery model and charging states
- Mac battery monitoring with IOKit
- Magic Keyboard, Mouse and Trackpad discovery through HID
- iPhone/iPad battery reporting through the AirMate Mobile companion
- Apple Watch battery reporting through the AirMate Watch companion
- Nearby Mac discovery and local-network device snapshot exchange
- Low-battery notifications
- Persistent battery history
- Battery history charts with Swift Charts
- CoreAudio output-device discovery and switching
- Launch at login
- Shortcuts/App Intents entry point
- WidgetKit extension
- Swift 6 / Xcode 27 project structure
- GitHub Actions builds for macOS, iOS and watchOS targets

## Important compatibility notes

Apple exposes normal iPhone/iPad and Apple Watch battery monitoring APIs to their respective apps, so AirMate uses companion apps to report those battery values to the Mac over the local network.

Detailed AirPods proximity-pairing advertisement formats, closed-case battery state, some listening-mode controls, and several seamless Apple ecosystem behaviors are not documented as stable public APIs. AirMate therefore keeps AirPods advertisement decoding in an isolated compatibility layer. The first hardware test cycle is expected to calibrate that parser against actual AirPods/Beats models and macOS 26/27 behavior.

The WidgetKit target is included in this beta. Live cross-process widget snapshots will be enabled after the signing team/App Group is selected in Xcode so the app and widget can share a signed container.

## Build

Requirements:

- Xcode 27+
- macOS 26+
- Apple Silicon recommended

Clone and open the Mac project:

```bash
git clone https://github.com/iAlMosawi/AirMate.git
cd AirMate
open AirMate.xcodeproj
```

For iPhone/iPad:

```bash
open AirMateMobile.xcodeproj
```

For Apple Watch:

```bash
open AirMateWatch.xcodeproj
```

Choose your Apple Development team in Signing & Capabilities before installing the companion apps on physical devices.

## Local network services

AirMate uses Bonjour only on the local network:

- `_airmate._tcp` — Mac-to-Mac AirMate exchange
- `_airmate-mobile._tcp` — iPhone/iPad/Watch battery reporting to the Mac

## Privacy

The current beta does not require an AirMate cloud service. Device discovery, battery reporting, history and Nearby Mac exchange are designed to operate locally. Battery history is stored in the Mac user's Application Support directory.

## Status

Version: **0.5.0 beta**

The codebase contains all planned beta phases. Real-device testing remains necessary for Bluetooth advertisement calibration, device-specific compatibility and final UI/behavior polish.
