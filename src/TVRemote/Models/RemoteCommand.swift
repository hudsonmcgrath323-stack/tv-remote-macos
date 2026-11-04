import Foundation

public enum RemoteCommand: String, CaseIterable, Sendable {
    case up = "up"
    case down = "down"
    case left = "left"
    case right = "right"
    case select = "select"
    case selectHold = "select_hold"
    case menu = "menu"
    case home = "home"
    case homeHold = "home_hold"
    case controlCenter = "control_center"
    case playPause = "play_pause"
    case previous = "previous"
    case next = "next"
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
    case toggleMute = "toggle_mute"

    public var displayName: String {
        switch self {
        case .up: return "Move Up"
        case .down: return "Move Down"
        case .left: return "Move Left"
        case .right: return "Move Right"
        case .select: return "Select"
        case .selectHold: return "Select (Long Press)"
        case .menu: return "Back / Menu"
        case .home: return "Home"
        case .homeHold, .controlCenter: return "Control Center"
        case .playPause: return "Play / Pause"
        case .previous: return "Previous Track"
        case .next: return "Next Track"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .toggleMute: return "Mute"
        }
    }
}
