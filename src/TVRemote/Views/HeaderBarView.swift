import AppKit
import SwiftUI

public struct HeaderBarView: View {
    @Bindable var appState: AppState
    let namespace: Namespace.ID
    let surface: RemoteSurface

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private var glassInk: Color {
        colorScheme == .dark ? .white.opacity(0.95) : .black.opacity(0.88)
    }

    public init(
        appState: AppState,
        namespace: Namespace.ID,
        surface: RemoteSurface = .popover
    ) {
        self.appState = appState
        self.namespace = namespace
        self.surface = surface
    }

    private var deviceTitle: String {
        if let selected = appState.service.selectedDevice {
            return selected.name
        }
        if case .scanning = appState.service.connectionState {
            return "Scanning…"
        }
        return "No Apple TV"
    }

    private var statusColor: Color {
        switch appState.service.connectionState {
        case .connected:
            return .green
        case .scanning, .connecting, .helperInstalling:
            return .orange
        case .pairingRequired:
            return .yellow
        case .disconnected, .offline, .helperMissing, .error:
            return .red.opacity(0.85)
        }
    }

    private var statusSymbol: String {
        switch appState.service.connectionState {
        case .connected:
            return "checkmark.circle.fill"
        case .scanning, .connecting, .helperInstalling:
            return "ellipsis.circle.fill"
        case .pairingRequired:
            return "lock.circle.fill"
        default:
            return "circle.slash"
        }
    }

    public var body: some View {
        HStack(spacing: 8) {
            statusPill

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 6) {
                    if surface == .popover {
                        openWindowButton
                    }
                    devicePickerMenu
                    settingsButton
                }
            }
        }
    }

    private var openWindowButton: some View {
        Button {
            appState.setKeyboardCapture(false)
            MenuBarPopoverController.closePopoverIfOpen()
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: RemoteWindowCoordinator.mainWindowID)
        } label: {
            Image(systemName: "macwindow")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(glassInk)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .glassEffectID("header-open-window", in: namespace)
        .help("Open Standalone Remote Window")
        .accessibilityLabel("Open Remote Window")
    }

    @ViewBuilder
    private var statusPill: some View {
        let content = HStack(spacing: 8) {
            statusIndicator

            VStack(alignment: .leading, spacing: 1) {
                Text(deviceTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(glassInk)
                    .lineLimit(1)

                Text(appState.service.connectionState.statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(glassInk.opacity(0.66))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(deviceTitle), \(appState.service.connectionState.statusLabel)")

        if reduceTransparency {
            content
                .background(
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(Capsule().strokeBorder(.primary.opacity(0.18), lineWidth: 1))
                )
        } else {
            // Apply .glassEffect directly to the foreground container so text always renders above the glass lens
            content
                .glassEffect(.regular, in: Capsule())
        }
    }

    private var devicePickerMenu: some View {
        Menu {
            Section("Apple TVs") {
                if appState.service.devices.isEmpty {
                    Text("No Apple TVs discovered")
                } else {
                    ForEach(appState.service.devices) { device in
                        Button {
                            Task { await appState.service.selectDevice(device) }
                        } label: {
                            if appState.service.selectedDevice?.identifier == device.identifier {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                }
            }

            Divider()

            Button {
                Task { await appState.service.scanDevices() }
            } label: {
                Label("Scan Network", systemImage: "arrow.clockwise")
            }

            if appState.service.selectedDevice != nil,
               !appState.service.connectionState.isConnected {
                Button {
                    Task { await appState.service.reconnect() }
                } label: {
                    Label("Reconnect", systemImage: "bolt.horizontal.circle")
                }
            }
        } label: {
            Image(systemName: "tv.and.mediabox")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(glassInk)
                .frame(width: 24, height: 24)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .glassEffectID("header-picker", in: namespace)
        .help("Switch Apple TV or Scan Network")
        .accessibilityLabel("Choose Apple TV")
    }

    private var settingsButton: some View {
        Button {
            appState.setKeyboardCapture(false)
            appState.showingSettings.toggle()
        } label: {
            Image(systemName: appState.showingSettings ? "xmark" : "gearshape.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(glassInk)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .glassEffectID("header-settings", in: namespace)
        .help(appState.showingSettings ? "Back to Remote" : "Settings")
        .accessibilityLabel(appState.showingSettings ? "Close Settings" : "Settings")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if differentiateWithoutColor {
            Image(systemName: statusSymbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(statusColor)
        } else {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(
                    color: appState.service.connectionState.isConnected ? statusColor.opacity(0.65) : .clear,
                    radius: 4
                )
        }
    }
}
