import AppKit
import SwiftUI

public struct NowPlayingStripView: View {
    let info: NowPlayingInfo
    let namespace: Namespace.ID
    let onPlayPause: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private var glassInk: Color {
        colorScheme == .dark ? .white.opacity(0.94) : .black.opacity(0.86)
    }

    public init(info: NowPlayingInfo, namespace: Namespace.ID, onPlayPause: @escaping () -> Void) {
        self.info = info
        self.namespace = namespace
        self.onPlayPause = onPlayPause
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        let cardContent = HStack(spacing: 10) {
            artworkThumbnail

            VStack(alignment: .leading, spacing: 2) {
                Text(info.title ?? info.appName ?? "Now Playing")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(glassInk)
                    .lineLimit(1)

                if let subtitle = info.displaySubtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(glassInk.opacity(0.68))
                        .lineLimit(1)
                } else {
                    Text(info.isPlaying ? "Playing" : "Paused")
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(glassInk.opacity(0.68))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button(action: onPlayPause) {
                Image(systemName: info.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(glassInk)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.glass)
            .accessibilityLabel(info.isPlaying ? "Pause" : "Play")
        }
        .padding(10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now Playing: \(info.title ?? "Media")")

        if reduceTransparency {
            cardContent
                .background(
                    shape
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(shape.strokeBorder(.primary.opacity(0.14), lineWidth: 1))
                )
        } else {
            cardContent
                .glassEffect(.regular, in: shape)
                .glassEffectID("now-playing-card", in: namespace)
                .glassEffectTransition(.materialize)
        }
    }

    @ViewBuilder
    private var artworkThumbnail: some View {
        let thumbShape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if let data = info.artworkData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 38, height: 38)
                .clipShape(thumbShape)
        } else {
            ZStack {
                thumbShape
                    .fill(.primary.opacity(0.08))
                Image(systemName: info.isPlaying ? "waveform" : "tv.inset.filled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 38, height: 38)
        }
    }
}
