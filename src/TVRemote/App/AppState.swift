import AppKit
import Foundation
import Observation
import ServiceManagement

public enum RemoteSurface: Sendable, Equatable {
    case popover
    case window
}

@MainActor
@Observable
public final class AppState {
    private static let alwaysOnTopKey = "com.hudson.TVRemote.alwaysOnTop"

    public let service: any AppleTVService
    public let hotkeyManager: GlobalHotkeyManager

    public var showingSettings: Bool = false
    public var highlightedCommand: RemoteCommand?
    public var launchAtLogin: Bool = false
    public var launchAtLoginError: String?
    public var alwaysOnTop: Bool = false

    // Gesture & input state
    public var pressedDirection: RemoteCommand?
    public var selectPressed: Bool = false
    public var pairingPinInput: String = ""
    public var isCapturingKeyboard: Bool = false
    public var capturedPreviewText: String = ""

    private enum QueuedKeyboardOp {
        case text(String)
        case backspace
        case clear
        case returnKey
    }

    private var selectHoldTriggered = false
    private var selectHoldTask: Task<Void, Never>?
    private var suppressNextHomeTap = false
    private var highlightClearTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var activeSurfaceCount: Int = 0
    private var keyboardQueue: [QueuedKeyboardOp] = []
    private var isDrainingKeyboardQueue = false

    public init(
        service: any AppleTVService,
        hotkeyManager: GlobalHotkeyManager = .shared
    ) {
        self.service = service
        self.hotkeyManager = hotkeyManager
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.alwaysOnTop = UserDefaults.standard.bool(forKey: Self.alwaysOnTopKey)
        self.resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setKeyboardCapture(false)
            }
        }
    }

    public func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        UserDefaults.standard.set(alwaysOnTop, forKey: Self.alwaysOnTopKey)
    }

    public func surfaceDidAppear() {
        activeSurfaceCount += 1
        installKeyboardMonitorIfNeeded()
    }

    public func surfaceDidDisappear() {
        activeSurfaceCount = max(0, activeSurfaceCount - 1)
        if activeSurfaceCount == 0 {
            setKeyboardCapture(false)
            removeKeyboardMonitor()
        }
    }

    public func refreshLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = "Launch at Login requires TV Remote.app in /Applications (\(error.localizedDescription))."
        }
    }

    public func trigger(_ command: RemoteCommand, fromKeyboard: Bool = false, haptic: Bool = false) {
        if fromKeyboard {
            flashHighlight(command)
        }
        if haptic {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        Task {
            await service.send(command)
        }
    }

    public func flashHighlight(_ command: RemoteCommand) {
        highlightClearTask?.cancel()
        highlightedCommand = command
        highlightClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            if self?.highlightedCommand == command {
                self?.highlightedCommand = nil
            }
        }
    }

    // MARK: - Select Tap vs Long-Press

    public func beginSelectPress() {
        guard !selectPressed else { return }
        selectPressed = true
        selectHoldTriggered = false
        selectHoldTask?.cancel()
        selectHoldTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self, self.selectPressed else { return }
            self.selectHoldTriggered = true
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            self.trigger(.selectHold, haptic: false)
        }
    }

    public func endSelectPress() {
        let didHold = selectHoldTriggered
        selectPressed = false
        selectHoldTask?.cancel()
        selectHoldTask = nil
        if !didHold {
            trigger(.select)
        }
    }

    // MARK: - Home Tap vs Long-Press (Control Center)

    public func handleHomeTap() {
        if suppressNextHomeTap {
            suppressNextHomeTap = false
            return
        }
        trigger(.home)
    }

    public func handleHomeLongPress() {
        suppressNextHomeTap = true
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        trigger(.controlCenter)
    }

    // MARK: - Live Keyboard Capture (Explicit Toggle Only)

    public func toggleKeyboardCapture() {
        setKeyboardCapture(!isCapturingKeyboard)
    }

    public func setKeyboardCapture(_ enabled: Bool) {
        if enabled {
            guard service.connectionState.isConnected else { return }
            isCapturingKeyboard = true
            capturedPreviewText = ""
            MenuBarPopoverController.focusPopoverWindowIfOpen()
        } else {
            isCapturingKeyboard = false
            capturedPreviewText = ""
        }
    }

    public func clearTVKeyboard() {
        capturedPreviewText = ""
        enqueueKeyboardOp(.clear)
    }

    private func enqueueKeyboardOp(_ op: QueuedKeyboardOp) {
        if case .text(let incoming) = op,
           case .text(let existing)? = keyboardQueue.last {
            keyboardQueue[keyboardQueue.count - 1] = .text(existing + incoming)
        } else {
            keyboardQueue.append(op)
        }
        drainKeyboardQueueIfNeeded()
    }

    private func drainKeyboardQueueIfNeeded() {
        guard !isDrainingKeyboardQueue, !keyboardQueue.isEmpty else { return }
        isDrainingKeyboardQueue = true
        Task { [weak self] in
            guard let self else { return }
            while !self.keyboardQueue.isEmpty {
                let next = self.keyboardQueue.removeFirst()
                switch next {
                case .text(let str):
                    await self.service.sendKeyboard(action: "append", text: str)
                case .backspace:
                    await self.service.sendKeyboard(action: "backspace", text: "")
                case .clear:
                    await self.service.sendKeyboard(action: "clear", text: "")
                case .returnKey:
                    await self.service.sendKeyboard(action: "return", text: "")
                }
            }
            self.isDrainingKeyboardQueue = false
        }
    }

    // MARK: - Popover & Window Keyboard Shortcuts

    public func installKeyboardMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let win = event.window, win.isVisible else { return event }
            if self.showingSettings || self.service.pairingSession != nil || self.hotkeyManager.isRecording {
                return event
            }
            if let responder = win.firstResponder, responder is NSText {
                return event
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // When the user explicitly clicked the Keyboard button on the remote, capture live typing
            if self.isCapturingKeyboard {
                if event.keyCode == 53 {
                    self.setKeyboardCapture(false)
                    return nil
                }

                if flags.contains(.command) {
                    if let cmdChar = event.charactersIgnoringModifiers?.lowercased() {
                        if cmdChar == "v",
                           let pasted = NSPasteboard.general.string(forType: .string) {
                            let clean = pasted
                                .replacingOccurrences(of: "\r\n", with: " ")
                                .replacingOccurrences(of: "\n", with: " ")
                                .replacingOccurrences(of: "\r", with: " ")
                            if !clean.isEmpty {
                                self.capturedPreviewText = String((self.capturedPreviewText + clean).suffix(36))
                                self.enqueueKeyboardOp(.text(clean))
                            }
                            return nil
                        }
                    }
                    if event.keyCode == 51 {
                        self.clearTVKeyboard()
                        return nil
                    }
                    return event
                }

                if flags.contains(.control) {
                    return event
                }

                switch event.keyCode {
                case 126:
                    self.trigger(.up, fromKeyboard: true)
                    return nil
                case 125:
                    self.trigger(.down, fromKeyboard: true)
                    return nil
                case 123:
                    self.trigger(.left, fromKeyboard: true)
                    return nil
                case 124:
                    self.trigger(.right, fromKeyboard: true)
                    return nil
                case 51, 117:
                    if !self.capturedPreviewText.isEmpty {
                        self.capturedPreviewText.removeLast()
                    }
                    self.enqueueKeyboardOp(.backspace)
                    return nil
                case 36, 76:
                    self.enqueueKeyboardOp(.returnKey)
                    return nil
                default:
                    break
                }

                if let rawChars = event.characters {
                    let printableScalars = rawChars.unicodeScalars.filter { scalar in
                        scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
                    }
                    let printable = String(String.UnicodeScalarView(printableScalars))
                    if !printable.isEmpty {
                        self.capturedPreviewText = String((self.capturedPreviewText + printable).suffix(36))
                        self.enqueueKeyboardOp(.text(printable))
                        return nil
                    }
                }

                return nil
            }

            if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
                return event
            }

            switch event.keyCode {
            case 126:
                self.trigger(.up, fromKeyboard: true)
                return nil
            case 125:
                self.trigger(.down, fromKeyboard: true)
                return nil
            case 123:
                self.trigger(.left, fromKeyboard: true)
                return nil
            case 124:
                self.trigger(.right, fromKeyboard: true)
                return nil
            case 36, 76:
                self.trigger(.select, fromKeyboard: true)
                return nil
            case 53, 51:
                self.trigger(.menu, fromKeyboard: true)
                return nil
            case 49:
                self.trigger(.playPause, fromKeyboard: true)
                return nil
            default:
                break
            }

            if let chars = event.charactersIgnoringModifiers?.lowercased() {
                switch chars {
                case "+", "=":
                    self.trigger(.volumeUp, fromKeyboard: true)
                    return nil
                case "-", "_":
                    self.trigger(.volumeDown, fromKeyboard: true)
                    return nil
                case "m":
                    self.trigger(.toggleMute, fromKeyboard: true)
                    return nil
                default:
                    break
                }
            }

            return event
        }
    }

    public func removeKeyboardMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
