import Foundation
import Observation

@MainActor
public protocol AppleTVService: AnyObject, Observable {
    var devices: [AppleTVDevice] { get }
    var selectedDevice: AppleTVDevice? { get }
    var connectionState: ConnectionState { get }
    var capabilities: DeviceCapabilities { get }
    var nowPlaying: NowPlayingInfo? { get }
    var pairingSession: PairingSessionState? { get }
    var transientNotice: String? { get }

    func start() async
    func scanDevices() async
    func selectDevice(_ device: AppleTVDevice) async
    func reconnect() async
    func beginPairing(for device: AppleTVDevice) async
    func retryPairingStep() async
    func skipOptionalPairingStep() async
    func submitPairingPIN(_ pin: String) async
    func cancelPairing() async
    func resetPairing(for device: AppleTVDevice) async
    func hasStoredCredentials(for device: AppleTVDevice) -> Bool
    func send(_ command: RemoteCommand) async
    func sendKeyboard(action: String, text: String) async
    func installPythonHelper() async
    func dismissNotice()
}
