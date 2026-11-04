# Security Policy

## Supported Versions

| Version | Supported |
| ------- | --------- |
| 0.1.x   | :white_check_mark: |

## Security Model Overview

TV Remote communicates over your local network with Apple TV devices using the `Companion` and `AirPlay`/`MRP` protocols via an isolated `pyatv` subprocess:

- **Keychain-Only Credential Storage**: Pairing tokens (`Companion` and `AirPlay` HAP credentials) are stored exclusively in the encrypted **macOS Keychain** (`Security.framework`, `kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock`) and are never written to plaintext files, `UserDefaults`, or `.env`.
- **Local Subprocess Isolation**: Swift communicates with `src/Helper/atv_bridge.py` strictly over anonymous `Pipe` file descriptors (`stdin`/`stdout`), without opening any local TCP/HTTP ports on `localhost` or `0.0.0.0`.

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, please use [GitHub Private Vulnerability Reporting](https://github.com/hudsonmcgrath323-stack/tv-remote-macos/security/advisories/new) on this repository:

1. Navigate to the **Security** tab of `hudsonmcgrath323-stack/tv-remote-macos`.
2. Click **Report a vulnerability** and include reproduction steps, affected versions, and potential impact.
3. You can expect an initial acknowledgement within **72 hours**, followed by a coordinated fix and release timeline.
