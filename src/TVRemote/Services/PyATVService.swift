import AppKit
import Foundation
import Network
import Observation

@MainActor
@Observable
public final class PyATVService: AppleTVService {
    private static let savedDeviceKey = "com.hudson.TVRemote.selectedDevice"

    public private(set) var devices: [AppleTVDevice] = []
    public private(set) var selectedDevice: AppleTVDevice?
    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var capabilities: DeviceCapabilities = .disconnected
    public private(set) var nowPlaying: NowPlayingInfo?
    public private(set) var pairingSession: PairingSessionState?
    public private(set) var transientNotice: String?

    private let bridge = BridgeProcessActor()
    private let keychain = KeychainStore()
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.hudson.TVRemote.networkMonitor")

    private var hasStarted = false
    private var initialNetworkEventReceived = false
    private var reconnectTask: Task<Void, Never>?
    private var noticeDismissTask: Task<Void, Never>?
    private var eventStreamTask: Task<Void, Never>?
    private var cooldownTimerTask: Task<Void, Never>?
    private var isStartingPairingStep = false
    private var wakeObserver: NSObjectProtocol?

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.savedDeviceKey),
           let saved = try? JSONDecoder().decode(AppleTVDevice.self, from: data) {
            self.selectedDevice = saved
            self.devices = [saved]
        }
    }

    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        listenToBridgeEvents()
        setupLifecycleMonitors()

        guard BridgeProcessActor.locateRuntime() != nil else {
            connectionState = .helperMissing
            return
        }

        do {
            try await bridge.ensureRunning()
        } catch BridgeError.helperPythonMissing {
            connectionState = .helperMissing
            return
        } catch {
            connectionState = .error(message: error.localizedDescription)
            return
        }

        if let saved = selectedDevice {
            await connectOrPromptPairing(for: saved)
            // Refresh device list quietly in background
            Task { await refreshDevicesInBackground() }
        } else {
            await scanDevices()
        }
    }

    public func installPythonHelper() async {
        connectionState = .helperInstalling
        do {
            try await bridge.bootstrapPythonEnvironment()
            try await bridge.ensureRunning()
            await scanDevices()
        } catch {
            connectionState = .error(message: error.localizedDescription)
        }
    }

    public func scanDevices() async {
        guard BridgeProcessActor.locateRuntime() != nil else {
            connectionState = .helperMissing
            return
        }

        let wasConnected = connectionState.isConnected
        if !wasConnected {
            connectionState = .scanning
        }

        do {
            var scanParams: [String: Any] = [:]
            if !AppEnvironment.defaultHosts.isEmpty {
                scanParams["hosts"] = AppEnvironment.defaultHosts
            }
            let response: ScanResponsePayload = try await bridge.request(
                cmd: "scan",
                params: scanParams,
                timeoutSeconds: 12.0
            )
            mergeDiscoveredDevices(response.devices)

            if let current = selectedDevice,
               let updated = devices.first(where: { $0.identifier == current.identifier || !Set($0.allIdentifiers).isDisjoint(with: current.allIdentifiers) }) {
                persistSelectedDevice(updated)
                if !wasConnected {
                    await connectOrPromptPairing(for: updated)
                }
            } else if selectedDevice == nil, let first = devices.first {
                if devices.count == 1 {
                    persistSelectedDevice(first)
                    await connectOrPromptPairing(for: first)
                } else {
                    connectionState = .disconnected
                    showNotice("Select an Apple TV from the menu above.")
                }
            } else if devices.isEmpty && !wasConnected {
                connectionState = .offline(
                    deviceName: selectedDevice?.name ?? "No Apple TV Found",
                    reason: "Wake your Apple TV and check Wi-Fi"
                )
            }
        } catch BridgeError.helperPythonMissing {
            connectionState = .helperMissing
        } catch {
            if !wasConnected {
                connectionState = .error(message: error.localizedDescription)
            } else {
                showNotice(error.localizedDescription)
            }
        }
    }

    private func refreshDevicesInBackground() async {
        guard let response: ScanResponsePayload = try? await bridge.request(
            cmd: "scan",
            params: [:],
            timeoutSeconds: 12.0
        ) else { return }
        mergeDiscoveredDevices(response.devices)
    }

    private func mergeDiscoveredDevices(_ found: [AppleTVDevice]) {
        var merged = found
        if let selected = selectedDevice,
           !merged.contains(where: { $0.identifier == selected.identifier || !Set($0.allIdentifiers).isDisjoint(with: selected.allIdentifiers) }) {
            merged.insert(selected, at: 0)
        }
        devices = merged
    }

    public func selectDevice(_ device: AppleTVDevice) async {
        pairingSession = nil
        persistSelectedDevice(device)
        await connectOrPromptPairing(for: device)
    }

    public func reconnect() async {
        guard let device = selectedDevice else {
            await scanDevices()
            return
        }
        await connectOrPromptPairing(for: device)
    }

    public func hasStoredCredentials(for device: AppleTVDevice) -> Bool {
        !keychain.loadCredentials(for: device).isEmpty
    }

    private func connectOrPromptPairing(for device: AppleTVDevice) async {
        let creds = keychain.loadCredentials(for: device)
        let needed = device.pairingProtocols
        if !needed.isEmpty && creds.isEmpty {
            capabilities = .disconnected
            nowPlaying = nil
            connectionState = .pairingRequired(device: device)
            return
        }

        connectionState = .connecting(deviceName: device.name)
        do {
            let snapshot: ConnectSnapshotPayload = try await bridge.request(
                cmd: "connect",
                params: [
                    "identifier": device.identifier,
                    "address": device.address,
                    "credentials": creds,
                ],
                timeoutSeconds: 14.0
            )
            persistSelectedDevice(snapshot.device)
            mergeDiscoveredDevices([snapshot.device] + devices.filter { $0.identifier != snapshot.device.identifier })
            capabilities = snapshot.capabilities
            nowPlaying = snapshot.nowPlaying
            connectionState = .connected(deviceName: snapshot.device.name)
        } catch let bridgeErr as BridgeError {
            capabilities = .disconnected
            nowPlaying = nil
            switch bridgeErr.code {
            case "not_paired", "auth_failed":
                connectionState = .pairingRequired(device: device)
                if bridgeErr.code == "auth_failed" {
                    showNotice("Credentials expired—re-pair with \(device.name).")
                }
            case "device_offline":
                connectionState = .offline(deviceName: device.name, reason: "Offline on network")
            default:
                connectionState = .offline(deviceName: device.name, reason: bridgeErr.localizedDescription)
            }
        } catch {
            capabilities = .disconnected
            nowPlaying = nil
            connectionState = .offline(deviceName: device.name, reason: error.localizedDescription)
        }
    }

    // MARK: - Pairing Walkthrough

    public func beginPairing(for device: AppleTVDevice) async {
        // Avoid aborting an already-active pairing prompt on the same Apple TV
        if let existing = pairingSession,
           existing.device.identifier == device.identifier,
           (existing.awaitingPin || isStartingPairingStep) {
            return
        }

        persistSelectedDevice(device)
        let existingCreds = keychain.loadCredentials(for: device)
        let remaining = device.pairingProtocols.filter { existingCreds[$0] == nil }
        let protocolsToPair = remaining.isEmpty ? (device.pairingProtocols.isEmpty ? ["Companion"] : device.pairingProtocols) : remaining

        var session = PairingSessionState(
            device: device,
            protocols: protocolsToPair,
            currentIndex: 0,
            awaitingPin: false,
            isSubmitting: false
        )
        pairingSession = session
        connectionState = .pairingRequired(device: device)

        await startCurrentPairingProtocol(&session, preserveErrorMessage: nil)
    }

    public func retryPairingStep() async {
        guard var session = pairingSession, !isStartingPairingStep else { return }
        session.errorMessage = nil
        await startCurrentPairingProtocol(&session, preserveErrorMessage: nil)
    }

    public func skipOptionalPairingStep() async {
        struct EmptyResponse: Decodable {}
        _ = try? await bridge.request(cmd: "cancel_pairing", timeoutSeconds: 3.0, as: EmptyResponse.self)
        cooldownTimerTask?.cancel()
        guard let session = pairingSession else { return }
        let device = session.device
        pairingSession = nil
        await connectOrPromptPairing(for: device)
    }

    private func startCurrentPairingProtocol(
        _ session: inout PairingSessionState,
        preserveErrorMessage: String?
    ) async {
        guard !isStartingPairingStep else { return }
        isStartingPairingStep = true
        defer { isStartingPairingStep = false }

        let proto = session.currentProtocol
        session.awaitingPin = false
        session.cooldownSeconds = nil
        session.errorMessage = preserveErrorMessage
        pairingSession = session

        do {
            let _: StartPairingPayload = try await bridge.request(
                cmd: "start_pairing",
                params: [
                    "identifier": session.device.identifier,
                    "address": session.device.address,
                    "protocol": proto,
                    "name": "TV Remote",
                ],
                timeoutSeconds: 240.0
            )
            cooldownTimerTask?.cancel()
            guard var current = pairingSession, current.device.identifier == session.device.identifier else { return }
            current.cooldownSeconds = nil
            current.awaitingPin = true
            pairingSession = current
        } catch {
            cooldownTimerTask?.cancel()
            guard var current = pairingSession, current.device.identifier == session.device.identifier else { return }
            current.cooldownSeconds = nil
            current.awaitingPin = false
            current.errorMessage = Self.friendlyPairingError(error.localizedDescription)
            pairingSession = current
        }
    }

    public func submitPairingPIN(_ pin: String) async {
        guard var session = pairingSession, !session.isSubmitting else { return }
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 4, trimmed.allSatisfy(\.isNumber) else {
            session.errorMessage = "Enter the 4-digit PIN shown on your Apple TV."
            pairingSession = session
            return
        }

        session.isSubmitting = true
        session.errorMessage = nil
        pairingSession = session

        do {
            let finished: FinishPairingPayload = try await bridge.request(
                cmd: "finish_pairing",
                params: ["pin": trimmed],
                timeoutSeconds: 16.0
            )

            var stored = keychain.loadCredentials(for: session.device)
            stored[finished.protocol] = finished.credentials
            try keychain.saveCredentials(stored, for: session.device.identifier)

            if session.currentIndex + 1 < session.protocols.count {
                session.currentIndex += 1
                session.isSubmitting = false
                session.awaitingPin = false
                session.errorMessage = nil
                pairingSession = session
                // Let tvOS dismiss Step 1's overlay cleanly before requesting Step 2
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await startCurrentPairingProtocol(&session, preserveErrorMessage: nil)
            } else {
                let pairedDevice = session.device
                cooldownTimerTask?.cancel()
                pairingSession = nil
                await connectOrPromptPairing(for: pairedDevice)
            }
        } catch {
            let reason = Self.friendlyPairingError(error.localizedDescription)
            session.isSubmitting = false
            session.awaitingPin = false
            session.errorMessage = reason
            pairingSession = session

            // Respect Apple TV's post-attempt SRP rate limit before requesting a fresh PIN
            startCooldownCountdown(seconds: 3)
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard var retrySession = pairingSession,
                  retrySession.device.identifier == session.device.identifier else { return }
            await startCurrentPairingProtocol(&retrySession, preserveErrorMessage: reason)
        }
    }

    public func cancelPairing() async {
        cooldownTimerTask?.cancel()
        struct EmptyResponse: Decodable {}
        _ = try? await bridge.request(cmd: "cancel_pairing", timeoutSeconds: 3.0, as: EmptyResponse.self)
        let device = pairingSession?.device ?? selectedDevice
        pairingSession = nil
        if let device {
            if hasStoredCredentials(for: device) {
                await connectOrPromptPairing(for: device)
            } else {
                connectionState = .pairingRequired(device: device)
            }
        } else {
            connectionState = .disconnected
        }
    }

    private func startCooldownCountdown(seconds: Int) {
        cooldownTimerTask?.cancel()
        guard var current = pairingSession else { return }
        current.cooldownSeconds = seconds
        pairingSession = current

        cooldownTimerTask = Task { [weak self] in
            var remaining = seconds
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self, var s = self.pairingSession else { return }
                remaining -= 1
                s.cooldownSeconds = remaining > 0 ? remaining : nil
                self.pairingSession = s
            }
        }
    }

    private static func friendlyPairingError(_ raw: String) -> String {
        if raw.localizedCaseInsensitiveContains("BackOff") {
            return "Apple TV rate-limit active. Wait a few seconds and click Retry."
        }
        if raw.localizedCaseInsensitiveContains("Authentication") || raw.localizedCaseInsensitiveContains("proofs do not match") {
            return "Incorrect PIN. Enter the new 4-digit PIN shown on your TV."
        }
        return raw
    }

    public func resetPairing(for device: AppleTVDevice) async {
        struct EmptyResponse: Decodable {}
        _ = try? await bridge.request(cmd: "disconnect", timeoutSeconds: 3.0, as: EmptyResponse.self)
        keychain.deleteCredentials(for: device)
        if selectedDevice?.identifier == device.identifier {
            capabilities = .disconnected
            nowPlaying = nil
            connectionState = .pairingRequired(device: device)
        }
        showNotice("Removed saved Keychain credentials for \(device.name).")
    }

    // MARK: - Remote Commands

    public func send(_ command: RemoteCommand) async {
        guard connectionState.isConnected else {
            if let device = selectedDevice, hasStoredCredentials(for: device) {
                await connectOrPromptPairing(for: device)
            } else {
                showNotice("Connect to your Apple TV first.")
            }
            return
        }

        do {
            let response: CommandResponsePayload = try await bridge.request(
                cmd: "command",
                params: ["action": command.rawValue],
                timeoutSeconds: 6.0
            )
            capabilities = response.capabilities
        } catch let bridgeErr as BridgeError {
            if bridgeErr.code == "not_supported" {
                showNotice(bridgeErr.localizedDescription)
            } else {
                showNotice(bridgeErr.localizedDescription)
                if bridgeErr.code == "bridge_error" || bridgeErr.code == "device_offline" {
                    scheduleAutoReconnect(delaySeconds: 1.0)
                }
            }
        } catch {
            showNotice(error.localizedDescription)
        }
    }

    public func sendKeyboard(action: String, text: String = "") async {
        guard connectionState.isConnected else {
            showNotice("Connect to your Apple TV first.")
            return
        }

        struct KeyboardAckPayload: Decodable {
            let sent: Bool?
        }

        do {
            _ = try await bridge.request(
                cmd: "keyboard",
                params: [
                    "action": action,
                    "text": text,
                ],
                timeoutSeconds: 5.0,
                as: KeyboardAckPayload.self
            )
        } catch {
            showNotice(error.localizedDescription)
        }
    }

    public func dismissNotice() {
        noticeDismissTask?.cancel()
        transientNotice = nil
    }

    private func showNotice(_ text: String) {
        noticeDismissTask?.cancel()
        transientNotice = text
        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            self?.transientNotice = nil
        }
    }

    private func persistSelectedDevice(_ device: AppleTVDevice) {
        selectedDevice = device
        if let data = try? JSONEncoder().encode(device) {
            UserDefaults.standard.set(data, forKey: Self.savedDeviceKey)
        }
    }

    // MARK: - Bridge Events & Wake/Network Auto-Reconnect

    private func listenToBridgeEvents() {
        eventStreamTask?.cancel()
        let events = bridge.events
        eventStreamTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                switch event {
                case .ready:
                    if let device = self.selectedDevice,
                       !self.connectionState.isConnected,
                       self.pairingSession == nil,
                       self.hasStoredCredentials(for: device) {
                        self.scheduleAutoReconnect(delaySeconds: 0.4)
                    }

                case .nowPlaying(let np, let caps):
                    self.nowPlaying = np
                    self.capabilities = caps

                case .audioUpdate(let caps):
                    self.capabilities = caps

                case .pairingBackoff(let seconds, _):
                    self.startCooldownCountdown(seconds: seconds)

                case .connectionLost:
                    if let device = self.selectedDevice {
                        self.connectionState = .offline(deviceName: device.name, reason: "Reconnecting…")
                        self.capabilities = .disconnected
                        self.scheduleAutoReconnect(delaySeconds: 1.2)
                    }

                case .helperCrashed(let willRestart):
                    self.capabilities = .disconnected
                    if willRestart {
                        self.showNotice("Helper crashed—restarting automatically…")
                        if let device = self.selectedDevice {
                            self.connectionState = .connecting(deviceName: device.name)
                        }
                    } else {
                        self.connectionState = .error(message: "Helper stopped repeatedly. Click Reconnect to retry.")
                    }
                }
            }
        }
    }

    private func setupLifecycleMonitors() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleAutoReconnect(delaySeconds: 1.8)
            }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.initialNetworkEventReceived {
                    self.initialNetworkEventReceived = true
                    return
                }
                self.scheduleAutoReconnect(delaySeconds: 1.5)
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    private func scheduleAutoReconnect(delaySeconds: Double) {
        guard pairingSession == nil, let device = selectedDevice, hasStoredCredentials(for: device) else {
            return
        }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.pairingSession == nil else { return }
            await self.connectOrPromptPairing(for: device)
        }
    }
}
