import AppKit
import Carbon
import Foundation
import Observation

public struct HotkeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32
    public var displayString: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, displayString: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.displayString = displayString
    }

    public static func from(event: NSEvent) -> HotkeyCombo? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonMods: UInt32 = 0
        var symbols = ""

        if flags.contains(.control) {
            carbonMods |= UInt32(controlKey)
            symbols += "⌃"
        }
        if flags.contains(.option) {
            carbonMods |= UInt32(optionKey)
            symbols += "⌥"
        }
        if flags.contains(.shift) {
            carbonMods |= UInt32(shiftKey)
            symbols += "⇧"
        }
        if flags.contains(.command) {
            carbonMods |= UInt32(cmdKey)
            symbols += "⌘"
        }

        // Require at least Control, Option, or Command for a global shortcut
        let hasPrimaryModifier = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
        guard hasPrimaryModifier else { return nil }

        guard let keyName = keyLabel(for: event.keyCode, characters: event.charactersIgnoringModifiers) else {
            return nil
        }

        return HotkeyCombo(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: carbonMods,
            displayString: symbols + keyName
        )
    }

    private static func keyLabel(for keyCode: UInt16, characters: String?) -> String? {
        switch keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return nil // Escape cancels recording
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            guard let chars = characters?.uppercased(), !chars.isEmpty else { return nil }
            let trimmed = chars.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(1))
        }
    }
}

@MainActor
@Observable
public final class GlobalHotkeyManager {
    public static let shared = GlobalHotkeyManager()

    private static let defaultsKey = "com.hudson.TVRemote.globalHotkey"

    public private(set) var shortcut: HotkeyCombo?
    public var isRecording: Bool = false

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var recorderMonitor: Any?

    private init() {
        installEventHandlerIfNeeded()
        // Disabled by default until user explicitly sets one in Settings
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(HotkeyCombo.self, from: data) {
            self.shortcut = saved
            register(saved)
        }
    }

    public func setShortcut(_ combo: HotkeyCombo?) {
        unregister()
        self.shortcut = combo
        if let combo {
            if let data = try? JSONEncoder().encode(combo) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
            register(combo)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
    }

    public func startRecording() {
        stopRecording()
        isRecording = true
        recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    self?.stopRecording()
                }
                return nil
            }
            if let combo = HotkeyCombo.from(event: event) {
                Task { @MainActor in
                    self?.setShortcut(combo)
                    self?.stopRecording()
                }
                return nil
            }
            return nil
        }
    }

    public func stopRecording() {
        isRecording = false
        if let monitor = recorderMonitor {
            NSEvent.removeMonitor(monitor)
            recorderMonitor = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, _, _ in
            Task { @MainActor in
                MenuBarPopoverController.togglePopover()
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            nil,
            &eventHandlerRef
        )
    }

    private func register(_ combo: HotkeyCombo) {
        unregister()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5456524D), id: 1) // 'TVRM'
        RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }
}

@MainActor
public enum MenuBarPopoverController {
    public static func togglePopover() {
        for window in NSApp.windows {
            let className = NSStringFromClass(type(of: window))
            let rootView = window.contentView?.superview ?? window.contentView
            if className.localizedCaseInsensitiveContains("StatusBar"),
               let button = findButton(in: rootView) {
                NSApp.activate(ignoringOtherApps: true)
                button.performClick(nil)
                return
            }
        }
    }

    public static func openPopoverIfClosed() {
        let isAlreadyOpen = NSApp.windows.contains { window in
            let className = NSStringFromClass(type(of: window))
            return window.isVisible && window.frame.height > 80 && !className.localizedCaseInsensitiveContains("StatusBar")
        }
        if !isAlreadyOpen {
            togglePopover()
        }
    }

    public static func focusPopoverWindowIfOpen() {
        focusActiveRemoteWindow()
    }

    public static func focusActiveRemoteWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let keyWin = NSApp.keyWindow, keyWin.isVisible {
            return
        }
        for window in NSApp.windows {
            let className = NSStringFromClass(type(of: window))
            if window.isVisible && window.frame.height > 80 && !className.localizedCaseInsensitiveContains("StatusBar") {
                window.makeKey()
                return
            }
        }
    }

    public static func closePopoverIfOpen() {
        for window in NSApp.windows {
            let className = NSStringFromClass(type(of: window))
            if window.isVisible && className.localizedCaseInsensitiveContains("MenuBarExtraWindow") {
                window.orderOut(nil)
            }
        }
    }

    private static func findButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(in: subview) {
                return found
            }
        }
        return nil
    }
}
