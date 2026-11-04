import Foundation
import Observation

@MainActor
@Observable
public final class MockAppleTVService: AppleTVService {
    public var devices: [AppleTVDevice]
    public var selectedDevice: AppleTVDevice?
    public var connectionState: ConnectionState
    public var capabilities: DeviceCapabilities
    public var nowPlaying: NowPlayingInfo?
    public var pairingSession: PairingSessionState?
    public var transientNotice: String?

    private var savedVolume: Double = 45.0
    private var pairedIDs: Set<String> = []

    public init(
        scenario: Scenario = .connectedPlaying
    ) {
        let livingRoom = AppleTVDevice(
            identifier: "00000000-1111-2222-3333-444444444444",
            name: "Living Room",
            address: "192.168.1.40",
            model: "Apple TV 4K (gen 3)",
            osVersion: "26.6"
        )
        let bedroom = AppleTVDevice(
            identifier: "AABBCCDD-1122-3344-5566-77889900AABB",
            name: "Bedroom TV",
            address: "192.168.1.54",
            model: "Apple TV 4K",
            osVersion: "26.6"
        )

        self.devices = [livingRoom, bedroom]
        self.selectedDevice = livingRoom

        switch scenario {
        case .connectedPlaying:
            self.pairedIDs = [livingRoom.identifier]
            self.connectionState = .connected(deviceName: livingRoom.name)
            self.capabilities = DeviceCapabilities(
                volumeSupported: true,
                setVolumeSupported: true,
                volume: 42.0,
                isMuted: false,
                controlCenterSupported: true,
                longPressSelectSupported: true
            )
            self.nowPlaying = NowPlayingInfo(
                isActive: true,
                deviceState: "playing",
                title: "Severance",
                subtitle: "S2 · E4 — Woe's Hollow",
                appName: "Apple TV",
                position: 1120,
                totalTime: 3180
            )

        case .volumeUnsupported:
            self.pairedIDs = [livingRoom.identifier]
            self.connectionState = .connected(deviceName: livingRoom.name)
            self.capabilities = DeviceCapabilities(
                volumeSupported: false,
                setVolumeSupported: false,
                volume: nil,
                isMuted: false,
                controlCenterSupported: true,
                longPressSelectSupported: true
            )
            self.nowPlaying = nil

        case .pairing:
            self.connectionState = .pairingRequired(device: livingRoom)
            self.capabilities = .disconnected
            self.pairingSession = PairingSessionState(
                device: livingRoom,
                protocols: ["Companion", "AirPlay"],
                currentIndex: 0,
                awaitingPin: true
            )

        case .offline:
            self.pairedIDs = [livingRoom.identifier]
            self.connectionState = .offline(deviceName: livingRoom.name, reason: "Device sleeping or unreachable")
            self.capabilities = .disconnected
        }
    }

    public enum Scenario {
        case connectedPlaying
        case volumeUnsupported
        case pairing
        case offline
    }

    public func start() async {}

    public func scanDevices() async {
        connectionState = .scanning
        try? await Task.sleep(nanoseconds: 400_000_000)
        if let device = selectedDevice {
            connectionState = .connected(deviceName: device.name)
        }
    }

    public func selectDevice(_ device: AppleTVDevice) async {
        selectedDevice = device
        if pairedIDs.contains(device.identifier) {
            connectionState = .connected(deviceName: device.name)
        } else {
            connectionState = .pairingRequired(device: device)
        }
    }

    public func reconnect() async {
        if let device = selectedDevice {
            connectionState = .connecting(deviceName: device.name)
            try? await Task.sleep(nanoseconds: 350_000_000)
            connectionState = .connected(deviceName: device.name)
        }
    }

    public func beginPairing(for device: AppleTVDevice) async {
        pairingSession = PairingSessionState(
            device: device,
            protocols: device.pairingProtocols,
            currentIndex: 0,
            awaitingPin: true
        )
    }

    public func retryPairingStep() async {
        pairingSession?.errorMessage = nil
        pairingSession?.awaitingPin = true
    }

    public func skipOptionalPairingStep() async {
        guard let session = pairingSession else { return }
        pairedIDs.insert(session.device.identifier)
        pairingSession = nil
        connectionState = .connected(deviceName: session.device.name)
    }

    public func submitPairingPIN(_ pin: String) async {
        guard let session = pairingSession else { return }
        pairedIDs.insert(session.device.identifier)
        pairingSession = nil
        connectionState = .connected(deviceName: session.device.name)
        capabilities = DeviceCapabilities(volumeSupported: true, setVolumeSupported: true, volume: 40)
    }

    public func cancelPairing() async {
        pairingSession = nil
    }

    public func resetPairing(for device: AppleTVDevice) async {
        pairedIDs.remove(device.identifier)
        connectionState = .pairingRequired(device: device)
    }

    public func hasStoredCredentials(for device: AppleTVDevice) -> Bool {
        pairedIDs.contains(device.identifier)
    }

    public func send(_ command: RemoteCommand) async {
        switch command {
        case .playPause:
            if var np = nowPlaying {
                np.deviceState = np.isPlaying ? "paused" : "playing"
                nowPlaying = np
            }
        case .toggleMute:
            guard capabilities.volumeSupported, capabilities.setVolumeSupported else {
                transientNotice = "Volume control requires HDMI-CEC/eARC or HomePod."
                return
            }
            if capabilities.isMuted {
                capabilities.isMuted = false
                capabilities.volume = savedVolume
            } else {
                savedVolume = capabilities.volume ?? 40.0
                capabilities.isMuted = true
                capabilities.volume = 0
            }
        case .volumeUp:
            capabilities.isMuted = false
            capabilities.volume = min(100, (capabilities.volume ?? 40) + 6)
        case .volumeDown:
            capabilities.volume = max(0, (capabilities.volume ?? 40) - 6)
        default:
            break
        }
    }

    public func sendKeyboard(action: String, text: String) async {}

    public func installPythonHelper() async {}

    public func dismissNotice() {
        transientNotice = nil
    }
}
