import AppKit
import SwiftUI

@MainActor
public enum RemoteWindowCoordinator {
    public static let mainWindowID = "main-remote"
    private static var openWindowAction: OpenWindowAction?

    public static func register(openWindow: OpenWindowAction) {
        openWindowAction = openWindow
    }

    public static func showMainWindow() {
        MenuBarPopoverController.closePopoverIfOpen()
        NSApp.activate(ignoringOtherApps: true)

        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "TVRemoteMainWindow" }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        openWindowAction?(id: mainWindowID)
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    let alwaysOnTop: Bool
    let reduceTransparency: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        configure(effectView)
        return effectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ effectView: NSVisualEffectView) {
        effectView.material = reduceTransparency ? .windowBackground : .hudWindow
        effectView.state = .active

        DispatchQueue.main.async {
            guard let window = effectView.window else { return }
            if window.identifier?.rawValue != "TVRemoteMainWindow" {
                window.identifier = NSUserInterfaceItemIdentifier("TVRemoteMainWindow")
            }
            window.title = "TV Remote"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.zoomButton)?.isHidden = true

            let desiredLevel: NSWindow.Level = alwaysOnTop ? .floating : .normal
            if window.level != desiredLevel {
                window.level = desiredLevel
            }
            window.collectionBehavior = alwaysOnTop
                ? [.canJoinAllSpaces, .fullScreenAuxiliary]
                : [.managed]
        }
    }
}

public struct RemoteWindowView: View {
    @Bindable var appState: AppState

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private var titleInk: Color {
        colorScheme == .dark ? .white.opacity(0.65) : .black.opacity(0.62)
    }

    private var buttonInk: Color {
        colorScheme == .dark ? .white.opacity(0.92) : .black.opacity(0.84)
    }

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            windowTitleBar
            RemotePopoverView(appState: appState, surface: .window)
        }
        .background(
            WindowChromeConfigurator(
                alwaysOnTop: appState.alwaysOnTop,
                reduceTransparency: reduceTransparency
            )
            .ignoresSafeArea()
        )
        .onAppear {
            RemoteWindowCoordinator.register(openWindow: openWindow)
        }
    }

    private var windowTitleBar: some View {
        HStack(spacing: 0) {
            // Clearance for macOS Close & Minimize traffic lights
            Color.clear
                .frame(width: 56, height: 28)

            Spacer(minLength: 4)

            Text("TV Remote")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(titleInk)
                .lineLimit(1)

            Spacer(minLength: 4)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button {
                    appState.toggleAlwaysOnTop()
                } label: {
                    Image(systemName: appState.alwaysOnTop ? "pin.fill" : "pin")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(appState.alwaysOnTop ? Color.cyan : buttonInk.opacity(0.78))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help(appState.alwaysOnTop ? "Unpin Window (Normal Window Level)" : "Float Remote Above Other Windows")
                .accessibilityLabel(appState.alwaysOnTop ? "Disable Always on Top" : "Keep Window on Top")
            }
            .frame(width: 56, height: 28)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }
}
