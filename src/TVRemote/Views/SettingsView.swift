import AppKit
import SwiftUI

public struct SettingsView: View {
    @Bindable var appState: AppState
    let namespace: Namespace.ID

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private var glassInk: Color {
        colorScheme == .dark ? .white.opacity(0.94) : .black.opacity(0.86)
    }

    public init(appState: AppState, namespace: Namespace.ID) {
        self.appState = appState
        self.namespace = namespace
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            deviceSection
            shortcutSection
            startupSection
            keyboardLegendSection

            Divider()

            HStack {
                Button {
                    appState.showingSettings = false
                } label: {
                    Label("Back to Remote", systemImage: "chevron.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(glassInk)
                }
                .buttonStyle(.glass)

                Spacer()

                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Quit")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(glassInk)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Quit TV Remote")
            }
        }
        .onAppear {
            appState.refreshLaunchAtLoginStatus()
        }
        .onDisappear {
            appState.hotkeyManager.stopRecording()
        }
    }

    private var deviceSection: some View {
        settingsCard(title: "Apple TV", symbol: "appletv.fill") {
            if let device = appState.service.selectedDevice {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(device.name)
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Text(appState.service.hasStoredCredentials(for: device) ? "Paired" : "Unpaired")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(appState.service.hasStoredCredentials(for: device) ? .green : .orange)
                    }

                    Text("\(device.model)\(device.osVersion.isEmpty ? "" : " · tvOS \(device.osVersion)")")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(device.address)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            appState.showingSettings = false
                            Task { await appState.service.beginPairing(for: device) }
                        } label: {
                            Text(appState.service.hasStoredCredentials(for: device) ? "Re-Pair" : "Pair TV")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .accessibilityLabel("Pair with \(device.name)")

                        if appState.service.hasStoredCredentials(for: device) {
                            Button {
                                Task { await appState.service.resetPairing(for: device) }
                            } label: {
                                Text("Reset Pairing")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(glassInk)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            .accessibilityLabel("Reset Keychain pairing credentials")
                        }
                    }
                }
            } else {
                Text("No Apple TV selected.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await appState.service.scanDevices() }
            } label: {
                HStack(spacing: 6) {
                    if appState.service.connectionState == .scanning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Scan Local Network")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(glassInk)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Scan local network for Apple TVs")
        }
    }

    private var shortcutSection: some View {
        settingsCard(title: "Global Hotkey", symbol: "command") {
            HStack(spacing: 8) {
                Button {
                    if appState.hotkeyManager.isRecording {
                        appState.hotkeyManager.stopRecording()
                    } else {
                        appState.hotkeyManager.startRecording()
                    }
                } label: {
                    Text(
                        appState.hotkeyManager.isRecording
                            ? "Press ⌘/⌃/⌥ + Key…"
                            : (appState.hotkeyManager.shortcut?.displayString ?? "Disabled — Set Shortcut")
                    )
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(glassInk)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Record global shortcut to open TV Remote")

                if appState.hotkeyManager.shortcut != nil {
                    Button {
                        appState.hotkeyManager.stopRecording()
                        appState.hotkeyManager.setShortcut(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(glassInk)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Clear global shortcut")
                }
            }
        }
    }

    private var startupSection: some View {
        settingsCard(title: "General", symbol: "power") {
            Toggle(
                isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }
                )
            ) {
                Text("Launch at Login")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if let err = appState.launchAtLoginError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var keyboardLegendSection: some View {
        settingsCard(title: "Popover Keys", symbol: "keyboard") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("↑ ↓ ← →").fontWeight(.semibold)
                    Text("Navigate")
                    Text("↩").fontWeight(.semibold)
                    Text("Select")
                }
                GridRow {
                    Text("Esc / ⌫").fontWeight(.semibold)
                    Text("Back")
                    Text("Space").fontWeight(.semibold)
                    Text("Play/Pause")
                }
                GridRow {
                    Text("− / +").fontWeight(.semibold)
                    Text("Volume")
                    Text("M").fontWeight(.semibold)
                    Text("Mute")
                }
                GridRow {
                    Text("⌨ Button").fontWeight(.semibold)
                    Text("Type to TV")
                    Text("Esc").fontWeight(.semibold)
                    Text("Exit Typing")
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let cardContent = VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(glassInk.opacity(0.68))
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)

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
        }
    }
}
