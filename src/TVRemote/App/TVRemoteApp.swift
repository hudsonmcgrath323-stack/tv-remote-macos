import AppKit
import SwiftUI

@MainActor
final class TVRemoteAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        if !args.contains("--snapshot-dir") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in both the Dock and Menu Bar when the standalone window is closed
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            RemoteWindowCoordinator.showMainWindow()
        } else {
            let hasVisibleMain = sender.windows.contains {
                $0.isVisible && $0.identifier?.rawValue == "TVRemoteMainWindow"
            }
            if !hasVisibleMain {
                RemoteWindowCoordinator.showMainWindow()
            }
        }
        return true
    }
}

@main
struct TVRemoteApp: App {
    @NSApplicationDelegateAdaptor(TVRemoteAppDelegate.self) private var appDelegate
    private let appState: AppState

    init() {
        let args = ProcessInfo.processInfo.arguments
        let service: any AppleTVService
        if args.contains("--mock-connected") {
            service = MockAppleTVService(scenario: .connectedPlaying)
        } else if args.contains("--mock-pairing") {
            service = MockAppleTVService(scenario: .pairing)
        } else if args.contains("--mock-no-volume") {
            service = MockAppleTVService(scenario: .volumeUnsupported)
        } else {
            service = PyATVService()
        }

        let state = AppState(service: service)
        if args.contains("--open-settings") {
            state.showingSettings = true
        }
        self.appState = state

        Task { @MainActor in
            await service.start()
        }

        if args.contains("--open-popover") || args.contains("--snapshot-dir") {
            NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    MenuBarPopoverController.openPopoverIfClosed()
                    if let idx = args.firstIndex(of: "--snapshot-dir"), idx + 1 < args.count {
                        let outDir = args[idx + 1]
                        await Self.captureUISnapshots(to: outDir)
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
    }

    @MainActor
    private static func captureUISnapshots(to dirPath: String) async {
        let outURL = URL(fileURLWithPath: dirPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        let states: [(String, NSAppearance.Name, AppState, RemoteSurface)] = [
            ("1_connected_dark.png", .darkAqua, AppState(service: MockAppleTVService(scenario: .connectedPlaying)), .popover),
            ("2_connected_light.png", .aqua, AppState(service: MockAppleTVService(scenario: .connectedPlaying)), .popover),
            ("3_pairing_pin.png", .darkAqua, AppState(service: MockAppleTVService(scenario: .pairing)), .popover),
            ("4_volume_unsupported.png", .darkAqua, AppState(service: MockAppleTVService(scenario: .volumeUnsupported)), .popover),
            ("5_settings_view.png", .darkAqua, {
                let s = AppState(service: MockAppleTVService(scenario: .connectedPlaying))
                s.showingSettings = true
                return s
            }(), .popover),
            ("6_standalone_window_dark.png", .darkAqua, AppState(service: MockAppleTVService(scenario: .connectedPlaying)), .window),
        ]

        for (filename, appearanceName, sampleState, surface) in states {
            let scheme: ColorScheme = appearanceName == .darkAqua ? .dark : .light
            let backdropView = ZStack {
                LinearGradient(
                    colors: appearanceName == .darkAqua
                        ? [Color(red: 0.11, green: 0.14, blue: 0.22), Color(red: 0.06, green: 0.07, blue: 0.11)]
                        : [Color(red: 0.86, green: 0.90, blue: 0.96), Color(red: 0.94, green: 0.95, blue: 0.98)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Group {
                    if surface == .window {
                        RemoteWindowView(appState: sampleState)
                    } else {
                        RemotePopoverView(appState: sampleState, surface: .popover)
                    }
                }
                .environment(\.colorScheme, scheme)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(appearanceName == .darkAqua ? Color.black.opacity(0.28) : Color.white.opacity(0.55))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.primary.opacity(0.14), lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
                    .padding(24)
            }
            .fixedSize()

            let hosting = NSHostingView(rootView: backdropView)
            hosting.appearance = NSAppearance(named: appearanceName)
            hosting.layoutSubtreeIfNeeded()
            let fitting = hosting.fittingSize
            let window = NSWindow(
                contentRect: NSRect(origin: CGPoint(x: 200, y: 200), size: fitting),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: appearanceName)
            window.contentView = hosting
            window.orderFrontRegardless()
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 250_000_000)

            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: outURL.appendingPathComponent(filename))
                }
            }
            window.orderOut(nil)
        }
    }

    var body: some Scene {
        Window("TV Remote", id: RemoteWindowCoordinator.mainWindowID) {
            RemoteWindowView(appState: appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(after: .windowList) {
                Button("Show TV Remote") {
                    RemoteWindowCoordinator.showMainWindow()
                }
                .keyboardShortcut("0", modifiers: [.command])

                Toggle(
                    "Float Above Other Windows",
                    isOn: Binding(
                        get: { appState.alwaysOnTop },
                        set: { _ in appState.toggleAlwaysOnTop() }
                    )
                )
            }
        }

        MenuBarExtra {
            RemotePopoverView(appState: appState, surface: .popover)
        } label: {
            Image(systemName: "appletvremote.gen4.fill")
                .symbolRenderingMode(.hierarchical)
                .accessibilityLabel("TV Remote")
        }
        .menuBarExtraStyle(.window)
    }
}
