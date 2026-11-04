import AppKit
import SwiftUI

public struct ControlRowsView: View {
    @Bindable var appState: AppState
    let namespace: Namespace.ID

    @Environment(\.colorScheme) private var colorScheme

    private var glassInk: Color {
        colorScheme == .dark ? .white.opacity(0.95) : .black.opacity(0.86)
    }

    public init(appState: AppState, namespace: Namespace.ID) {
        self.appState = appState
        self.namespace = namespace
    }

    private var caps: DeviceCapabilities {
        appState.service.capabilities
    }

    private var isConnected: Bool {
        appState.service.connectionState.isConnected
    }

    public var body: some View {
        VStack(spacing: 10) {
            primaryActionRow
            trackTransportRow
            volumeRow
            volumeCapabilityCaption
        }
    }

    private var primaryActionRow: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                remoteButton(
                    command: .menu,
                    symbol: "chevron.backward",
                    label: "Back",
                    hint: "Return to previous screen (Escape)"
                )

                homeButton

                remoteButton(
                    command: .playPause,
                    symbol: "playpause.fill",
                    label: "Play or Pause",
                    hint: "Spacebar toggles playback"
                )
            }
        }
    }

    private var homeButton: some View {
        Button {
            appState.handleHomeTap()
        } label: {
            Image(systemName: "house.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(glassInk)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .glassEffectID("btn-home", in: namespace)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    appState.handleHomeLongPress()
                }
        )
        .contextMenu {
            Button {
                appState.trigger(.home)
            } label: {
                Label("Home", systemImage: "house.fill")
            }
            Button {
                appState.trigger(.controlCenter)
            } label: {
                Label("Open Control Center", systemImage: "switch.2")
            }
        }
        .help("Click for Home · Hold for Control Center")
        .accessibilityLabel("Home")
        .accessibilityHint("Click for Home, or press and hold to open Control Center")
        .accessibilityAction(named: "Open Control Center") {
            appState.trigger(.controlCenter)
        }
    }

    private var trackTransportRow: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                remoteButton(
                    command: .previous,
                    symbol: "backward.end.fill",
                    label: "Previous Track",
                    hint: "Skip to previous item or chapter",
                    height: 36
                )

                keyboardCaptureButton

                remoteButton(
                    command: .next,
                    symbol: "forward.end.fill",
                    label: "Next Track",
                    hint: "Skip to next item or chapter",
                    height: 36
                )
            }
        }
    }

    private var keyboardCaptureButton: some View {
        let capturing = appState.isCapturingKeyboard
        let disabled = !isConnected

        return Button {
            appState.toggleKeyboardCapture()
        } label: {
            Image(systemName: capturing ? "keyboard.fill" : "keyboard")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    capturing
                        ? Color.cyan
                        : glassInk.opacity(disabled ? 0.35 : 1.0)
                )
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .glassEffectID("btn-keyboard", in: namespace)
        .disabled(disabled)
        .help(capturing ? "Stop Keyboard Capture (Esc)" : "Capture Mac Keyboard for TV Typing")
        .accessibilityLabel(capturing ? "Stop Keyboard Capture" : "Capture Keyboard")
        .accessibilityValue(capturing ? "Active" : "Off")
        .accessibilityHint("Click to type into Apple TV search fields using your Mac keyboard")
    }

    private var volumeRow: some View {
        let volDisabled = isConnected && !caps.volumeSupported

        return GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    appState.trigger(.volumeDown)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(glassInk.opacity(volDisabled ? 0.35 : 1.0))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .glassEffectID("btn-voldown", in: namespace)
                .disabled(volDisabled)
                .accessibilityLabel("Volume Down")
                .accessibilityHint(volDisabled ? "Volume control unavailable on this TV output" : "Decreases Apple TV volume")

                muteToggleButton(disabled: volDisabled)

                Button {
                    appState.trigger(.volumeUp)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(glassInk.opacity(volDisabled ? 0.35 : 1.0))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .glassEffectID("btn-volup", in: namespace)
                .disabled(volDisabled)
                .accessibilityLabel("Volume Up")
                .accessibilityHint(volDisabled ? "Volume control unavailable on this TV output" : "Increases Apple TV volume")
            }
        }
    }

    private func muteToggleButton(disabled: Bool) -> some View {
        Button {
            appState.trigger(.toggleMute)
        } label: {
            Image(systemName: caps.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(
                    caps.isMuted
                        ? Color.orange
                        : glassInk.opacity(disabled ? 0.35 : 1.0)
                )
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .glassEffectID("btn-mute", in: namespace)
        .disabled(disabled)
        .accessibilityLabel(caps.isMuted ? "Unmute" : "Mute")
        .accessibilityValue(
            caps.isMuted
                ? "Muted"
                : (caps.volume.map { "\(Int($0.rounded())) percent" } ?? "")
        )
        .accessibilityHint(disabled ? "Volume control unavailable on this TV output" : "Mutes or unmutes Apple TV audio")
    }

    @ViewBuilder
    private var volumeCapabilityCaption: some View {
        if isConnected && !caps.volumeSupported {
            HStack(spacing: 5) {
                Image(systemName: "speaker.badge.exclamationmark")
                    .font(.system(size: 10, weight: .semibold))
                Text("Volume control isn't supported (enable HDMI-CEC/eARC or HomePod).")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
        }
    }

    private func remoteButton(
        command: RemoteCommand,
        symbol: String,
        label: String,
        hint: String,
        height: CGFloat = 38
    ) -> some View {
        Button {
            appState.trigger(command)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(glassInk)
                .frame(maxWidth: .infinity)
                .frame(height: height)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .glassEffectID("btn-\(command.rawValue)", in: namespace)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }
}
