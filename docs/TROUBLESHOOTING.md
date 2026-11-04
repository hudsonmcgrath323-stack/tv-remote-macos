# Troubleshooting Guide

## 1. Apple TV Not Found During Scan

- **Wake the Apple TV**: Sleeping Apple TVs may stop advertising `_companion-link._tcp` on some network setups. Wake it once with a physical/iOS remote, then click **Scan Network**.
- **Check macOS Local Network Permission**: Open **System Settings → Privacy & Security → Local Network** and verify **TV Remote** is enabled.
- **Segmented VLANs / Subnets**: If your Apple TV lives on an IoT VLAN where mDNS multicast is not reflected, set `TVREMOTE_DEFAULT_HOST=192.168.x.x` in `.env` (or `~/Library/Application Support/TVRemote/.env`) to scan its IP directly via unicast.

---

## 2. Pairing Errors

### `Apple TV cooldown — showing PIN in Xs…` (`Error=BackOff`)
tvOS enforces a short SRP rate-limit cooldown if a pairing attempt is cancelled or restarted rapidly. TV Remote automatically parses the `BackOff` timer from tvOS, displays a live countdown, and requests a fresh PIN once the cooldown expires.

### `SRPClientSession.__init__() takes 2 positional arguments but 3 were given`
This occurs if `srptools 2.0.0+` is installed alongside `pyatv 0.18.0`. Run `./scripts/setup_python.sh` (which pins `srptools<2.0.0` via `requirements.txt`) to fix it immediately.

### Authentication Failed After tvOS Update or Reset
Open **Settings (gear icon) → Reset Pairing** in TV Remote to delete the stale credentials from macOS Keychain, then click **Pair TV** to save fresh credentials.

---

## 3. Volume & Mute Behavior

- **Volume buttons (`−` / `+`) disabled**: Network volume control requires your Apple TV to route audio over **HDMI-CEC**, **eARC**, **HomePod**, or **AirPlay** (`Settings → Remotes and Devices → Volume Control` on Apple TV). Infrared-only (IR) remotes work via line-of-sight LED hardware in the physical Siri Remote and cannot be triggered over Wi-Fi.
- **Mute on HDMI-CEC vs. HomePod**:
  - **HomePod / AirPlay / eARC (Absolute Volume)**: Mute saves your exact volume percentage, sets volume to `0%`, and restores your saved level on unmute.
  - **HDMI-CEC Receiver / TV (Relative Step Volume)**: Mute sends the native Siri Remote USB HID Consumer Mute (`0x0C / 0xE2`) command over the AirPlay-tunneled MRP channel—make sure you completed **both** Step 1 (`Companion`) and Step 2 (`AirPlay`) during pairing.

---

## 4. Typing / Keyboard Capture in YouTube & Apps

- Keyboard capture is **off by default** so arrow keys, `Space` (Play/Pause), and `M` (Mute) act as instant remote shortcuts.
- To type into YouTube Search or any tvOS text box:
  1. Navigate to the app's search screen on your Apple TV.
  2. Click the **`⌨` (Keyboard)** button in the middle of the remote.
  3. Type on your Mac keyboard (`⌫` deletes, `⌘V` pastes, `⌘⌫` clears, arrow keys still move focus).
  4. Press **`Esc`** or click **`⌨`** again to exit typing mode.

---

## 5. Launch at Login

macOS `SMAppService.mainApp` requires the app bundle to reside in `/Applications` to register as a login item. Move `dist/TV Remote.app` into `/Applications/TV Remote.app` before toggling **Launch at Login** in Settings.
