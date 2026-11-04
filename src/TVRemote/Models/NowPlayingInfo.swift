import Foundation

public struct NowPlayingInfo: Codable, Equatable, Sendable {
    public var isActive: Bool
    public var deviceState: String
    public var title: String?
    public var subtitle: String?
    public var appName: String?
    public var appId: String?
    public var position: Double?
    public var totalTime: Double?
    public var artworkBase64: String?

    public init(
        isActive: Bool,
        deviceState: String = "idle",
        title: String? = nil,
        subtitle: String? = nil,
        appName: String? = nil,
        appId: String? = nil,
        position: Double? = nil,
        totalTime: Double? = nil,
        artworkBase64: String? = nil
    ) {
        self.isActive = isActive
        self.deviceState = deviceState
        self.title = title
        self.subtitle = subtitle
        self.appName = appName
        self.appId = appId
        self.position = position
        self.totalTime = totalTime
        self.artworkBase64 = artworkBase64
    }

    public var isPlaying: Bool {
        deviceState == "playing"
    }

    public var artworkData: Data? {
        guard let artworkBase64, !artworkBase64.isEmpty else { return nil }
        return Data(base64Encoded: artworkBase64)
    }

    public var displaySubtitle: String? {
        switch (subtitle, appName) {
        case (.some(let sub), .some(let app)) where !sub.isEmpty && !app.isEmpty && sub != app:
            return "\(sub) · \(app)"
        case (.some(let sub), _) where !sub.isEmpty:
            return sub
        case (_, .some(let app)) where !app.isEmpty:
            return app
        default:
            return nil
        }
    }
}
