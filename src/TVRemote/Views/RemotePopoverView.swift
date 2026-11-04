import AppKit
import SwiftUI

public struct RemotePopoverView: View {
    @Bindable var appState: AppState
    let surface: RemoteSurface
    @Namespace private var glassNamespace

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private var glassInk: Color {
        colorScheme == .dark ? .white.opacity(0.94) : .black.opacity(0.86)
    }

    public init(appState: AppState, surface: RemoteSurface = .popover) {
        self.appState = appState
        self.surface = surface
    }

    private var transitionAnim: Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)
    }

    public var body: some View {
        VStack(spacing: 14) {
            HeaderBarView(appState: appState, namespace: glassNamespace, surface: surface)

            if appState.showingSettings {
                SettingsView(appState: appState, namespace: glassNamespace)
                    .transition(.opacity)
            } else if let session = appState.service.pairingSession {
                PairingFlowView(appState: appState, session: session, namespace: glassNamespace)
                    .transition(.opacity)
            } else {
                statusBannerIfNeeded

                CircularDPadView(appState: appState, namespace: glassNamespace)
                    .padding(.vertical, 2)

                ControlRowsView(appState: appState, namespace: glassNamespace)

                if appState.isCapturingKeyboard {
                    keyboardCaptureBanner
                }

                if let np = appState.service.nowPlaying, np.isActive {
                    NowPlayingStripView(info: np, namespace: glassNamespace) {
                        appState.trigger(.playPause)
                    }
                }
            }

            if let notice = appState.service.transientNotice {
                transientNoticeBanner(notice)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, surface == .window ? 8 : 16)
        .frame(width: 284)
        .animation(transitionAnim, value: appState.showingSettings)
        .animation(transitionAnim, value: appState.service.pairingSession != nil)
        .animation(transitionAnim, value: appState.isCapturingKeyboard)
        .animation(transitionAnim, value: appState.service.nowPlaying?.isActive)
        .animation(transitionAnim, value: appState.service.transientNotice)
        .onAppear {
            RemoteWindowCoordinator.register(openWindow: openWindow)
            appState.surfaceDidAppear()
        }
        .onDisappear {
            appState.surfaceDidDisappear()
        }
    }

    @ViewBuilder
    private var statusBannerIfNeeded: some View {
        switch appState.service.connectionState {
        case .pairingRequired(let device):
            calloutCard(
                symbol: "lock.applewatch",
                title: "Pair with \(device.name)",
                subtitle: "One-time TV PIN saved to macOS Keychain.",
                buttonTitle: "Enter TV PIN",
                prominent: true
            ) {
                Task { await appState.service.beginPairing(for: device) }
            }

        case .helperMissing:
            calloutCard(
                symbol: "shippingbox.fill",
                title: "Python Helper Needed",
                subtitle: "Installs pyatv into an isolated app environment.",
                buttonTitle: "Install Helper",
                prominent: true
            ) {
                Task { await appState.service.installPythonHelper() }
            }

        case .helperInstalling:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing pyatv helper…")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

        case .offline(_, let reason):
            calloutCard(
                symbol: "wifi.exclamationmark",
                title: "Apple TV Offline",
                subtitle: reason,
                buttonTitle: "Reconnect",
                prominent: false
            ) {
                Task { await appState.service.reconnect() }
            }

        case .error(let message):
            calloutCard(
                symbol: "exclamationmark.triangle.fill",
                title: "Connection Issue",
                subtitle: message,
                buttonTitle: "Retry",
                prominent: false
            ) {
                Task { await appState.service.reconnect() }
            }

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func calloutCard(
        symbol: String,
        title: String,
        subtitle: String,
        buttonTitle: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        let cardContent = HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(glassInk)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(glassInk)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(glassInk.opacity(0.68))
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if prominent {
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.glassProminent)
            } else {
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(glassInk)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(10)

        if reduceTransparency {
            cardContent
                .background(
                    shape
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(shape.strokeBorder(.primary.opacity(0.16), lineWidth: 1))
                )
        } else {
            cardContent
                .glassEffect(.regular, in: shape)
                .glassEffectID("status-callout", in: glassNamespace)
        }
    }

    @ViewBuilder
    private var keyboardCaptureBanner: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let bannerContent = HStack(spacing: 8) {
            Image(systemName: "keyboard.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 1) {
                Text(
                    appState.capturedPreviewText.isEmpty
                        ? "Keyboard Captured — Type now"
                        : "“\(appState.capturedPreviewText)”"
                )
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(glassInk)
                .lineLimit(1)
                .truncationMode(.head)

                Text("⌫ Delete · ⌘V Paste · Esc Stop")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(glassInk.opacity(0.64))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                appState.clearTVKeyboard()
            } label: {
                Text("Clear")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(glassInk)
            }
            .buttonStyle(.glass)
            .controlSize(.mini)
            .accessibilityLabel("Clear Apple TV text")

            Button {
                appState.setKeyboardCapture(false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(glassInk.opacity(0.7))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop keyboard capture")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)

        if reduceTransparency {
            bannerContent
                .background(
                    shape
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(shape.strokeBorder(.cyan.opacity(0.45), lineWidth: 1))
                )
        } else {
            bannerContent
                .glassEffect(.regular, in: shape)
                .glassEffectID("keyboard-capture-card", in: glassNamespace)
                .glassEffectTransition(.materialize)
        }
    }

    @ViewBuilder
    private func transientNoticeBanner(_ text: String) -> some View {
        let shape = Capsule()
        let bannerContent = HStack(spacing: 6) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(glassInk.opacity(0.75))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(glassInk.opacity(0.82))
                .lineLimit(2)
            Spacer(minLength: 2)
            Button {
                appState.service.dismissNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(glassInk.opacity(0.55))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notice")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)

        if reduceTransparency {
            bannerContent
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
        } else {
            bannerContent
                .glassEffect(.regular, in: shape)
        }
    }
}

struct RemotePopoverView_Previews: PreviewProvider {
    static var previews: some View {
        RemotePopoverView(
            appState: AppState(service: MockAppleTVService(scenario: .connectedPlaying))
        )
        .previewDisplayName("Connected + Now Playing")

        RemotePopoverView(
            appState: AppState(service: MockAppleTVService(scenario: .volumeUnsupported))
        )
        .previewDisplayName("Volume Unsupported")

        RemotePopoverView(
            appState: AppState(service: MockAppleTVService(scenario: .pairing))
        )
        .previewDisplayName("Pairing PIN")
    }
}
