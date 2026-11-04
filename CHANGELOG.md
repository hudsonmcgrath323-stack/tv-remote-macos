# Changelog

All notable changes to **TV Remote** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-04

### Added
- Native **macOS Liquid Glass** UI (`GlassEffectContainer`, `.glassEffect()`, `.buttonStyle(.glass)` / `.glassProminent`, `.glassEffectID`, `.glassEffectTransition(.materialize)`).
- Dual presentation mode: runs simultaneously as a **standalone movable macOS window** (with Dock icon, `⌘0` shortcut, and optional **Float on Top** pin) and a **menu bar popover** (`MenuBarExtra(.window)`).
- Persistent `asyncio` `pyatv` JSON-RPC subprocess bridge (`src/Helper/atv_bridge.py`) with automatic crash recovery and wake/network auto-reconnect (`NSWorkspace.didWakeNotification` + `NWPathMonitor`).
- Hybrid local network discovery combining macOS `mDNSResponder` (`dns-sd`) with `pyatv` scanning plus optional `TVREMOTE_DEFAULT_HOST` unicast host configuration.
- Guided multi-step in-app PIN pairing (`Companion` + `AirPlay`/`MRP`) with automatic `BackOff` cooldown handling and encrypted **macOS Keychain** credential storage.
- Full Siri Remote control surface: circular D-Pad, tap & long-press `Select`, `Back/Menu`, tap & long-press `Home` (opens Control Center), `Play/Pause`, `Previous`, `Next`, `Volume −/+`, and `Mute` (supports both absolute volume save/restore and HDMI-CEC USB HID Consumer Mute).
- Explicit on-demand **Mac Keyboard Capture (`⌨`)** button supporting live typing, `⌫` delete, `⌘V` paste, and `⌘⌫` clear across both native tvOS `RemoteTextInput` fields and custom app keyboards (such as YouTube Search via USB HID Page `0x07`).
- Live **Now Playing** strip with artwork thumbnail, title, app/subtitle, and playback toggle.
- Optional Carbon global shortcut recorder, Launch at Login (`SMAppService.mainApp`), VoiceOver labels, and Reduce Transparency / Reduce Motion / Increase Contrast support.
