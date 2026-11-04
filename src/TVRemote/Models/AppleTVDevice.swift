import Foundation

public struct AppleTVDevice: Identifiable, Codable, Hashable, Sendable {
    public let identifier: String
    public var allIdentifiers: [String]
    public var name: String
    public var address: String
    public var model: String
    public var osVersion: String
    public var pairingProtocols: [String]

    public var id: String { identifier }

    public init(
        identifier: String,
        allIdentifiers: [String] = [],
        name: String,
        address: String,
        model: String = "Apple TV",
        osVersion: String = "",
        pairingProtocols: [String] = ["Companion", "AirPlay"]
    ) {
        self.identifier = identifier
        self.allIdentifiers = allIdentifiers.isEmpty ? [identifier] : allIdentifiers
        self.name = name
        self.address = address
        self.model = model
        self.osVersion = osVersion
        self.pairingProtocols = pairingProtocols
    }
}

public struct DeviceCapabilities: Codable, Equatable, Sendable {
    public var volumeSupported: Bool
    public var setVolumeSupported: Bool
    public var volume: Double?
    public var isMuted: Bool
    public var controlCenterSupported: Bool
    public var longPressSelectSupported: Bool

    public init(
        volumeSupported: Bool = true,
        setVolumeSupported: Bool = true,
        volume: Double? = nil,
        isMuted: Bool = false,
        controlCenterSupported: Bool = true,
        longPressSelectSupported: Bool = true
    ) {
        self.volumeSupported = volumeSupported
        self.setVolumeSupported = setVolumeSupported
        self.volume = volume
        self.isMuted = isMuted
        self.controlCenterSupported = controlCenterSupported
        self.longPressSelectSupported = longPressSelectSupported
    }

    public static let disconnected = DeviceCapabilities(
        volumeSupported: false,
        setVolumeSupported: false,
        volume: nil,
        isMuted: false,
        controlCenterSupported: false,
        longPressSelectSupported: false
    )
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case scanning
    case connecting(deviceName: String)
    case connected(deviceName: String)
    case pairingRequired(device: AppleTVDevice)
    case offline(deviceName: String, reason: String)
    case helperMissing
    case helperInstalling
    case error(message: String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .scanning, .connecting, .helperInstalling:
            return true
        default:
            return false
        }
    }

    public var statusLabel: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .scanning:
            return "Scanning network…"
        case .connecting(let name):
            return "Connecting to \(name)…"
        case .connected:
            return "Connected"
        case .pairingRequired:
            return "Pairing required"
        case .offline(_, let reason):
            return reason.isEmpty ? "Offline" : reason
        case .helperMissing:
            return "Python helper required"
        case .helperInstalling:
            return "Installing pyatv helper…"
        case .error(let msg):
            return msg
        }
    }
}

public struct PairingSessionState: Equatable, Sendable {
    public let device: AppleTVDevice
    public let protocols: [String]
    public var currentIndex: Int
    public var awaitingPin: Bool
    public var isSubmitting: Bool
    public var cooldownSeconds: Int?
    public var errorMessage: String?

    public var currentProtocol: String {
        guard protocols.indices.contains(currentIndex) else {
            return protocols.last ?? "Companion"
        }
        return protocols[currentIndex]
    }

    public var canSkipCurrentStep: Bool {
        currentIndex > 0 && currentProtocol != "Companion"
    }

    public var stepSummary: String {
        if protocols.count <= 1 {
            return "\(currentProtocol) Pairing"
        }
        return "Step \(currentIndex + 1) of \(protocols.count) · \(currentProtocol)"
    }

    public init(
        device: AppleTVDevice,
        protocols: [String],
        currentIndex: Int = 0,
        awaitingPin: Bool = false,
        isSubmitting: Bool = false,
        cooldownSeconds: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.device = device
        self.protocols = protocols.isEmpty ? ["Companion"] : protocols
        self.currentIndex = currentIndex
        self.awaitingPin = awaitingPin
        self.isSubmitting = isSubmitting
        self.cooldownSeconds = cooldownSeconds
        self.errorMessage = errorMessage
    }
}
