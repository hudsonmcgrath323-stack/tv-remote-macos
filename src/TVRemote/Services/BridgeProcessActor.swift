import Foundation

public enum BridgeError: LocalizedError, Sendable {
    case helperPythonMissing
    case helperScriptMissing
    case processNotRunning
    case timeout(String)
    case remoteError(code: String, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .helperPythonMissing:
            return "Python helper environment (pyatv) is not installed yet."
        case .helperScriptMissing:
            return "Bundled atv_bridge.py helper script could not be found."
        case .processNotRunning:
            return "Apple TV helper process is restarting."
        case .timeout(let cmd):
            return "Timed out waiting for Apple TV (\(cmd))."
        case .remoteError(_, let message):
            return message
        case .invalidResponse:
            return "Received an invalid response from the Apple TV helper."
        }
    }

    public var code: String? {
        if case .remoteError(let code, _) = self {
            return code
        }
        return nil
    }
}

public enum BridgeEvent: Sendable {
    case ready(version: String)
    case nowPlaying(NowPlayingInfo?, DeviceCapabilities)
    case audioUpdate(DeviceCapabilities)
    case pairingBackoff(seconds: Int, protocolName: String)
    case connectionLost(reason: String)
    case helperCrashed(willRestart: Bool)
}

public struct ScanResponsePayload: Decodable, Sendable {
    public let devices: [AppleTVDevice]
}

public struct StartPairingPayload: Decodable, Sendable {
    public let `protocol`: String
    public let deviceProvidesPin: Bool
    public let deviceName: String
}

public struct FinishPairingPayload: Decodable, Sendable {
    public let paired: Bool
    public let `protocol`: String
    public let credentials: String
}

public struct ConnectSnapshotPayload: Decodable, Sendable {
    public let device: AppleTVDevice
    public let capabilities: DeviceCapabilities
    public let nowPlaying: NowPlayingInfo?
}

public struct CommandResponsePayload: Decodable, Sendable {
    public let capabilities: DeviceCapabilities
}

public actor BridgeProcessActor {
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var intentionalStop = false
    private var restartCount = 0

    private let eventContinuation: AsyncStream<BridgeEvent>.Continuation
    public nonisolated let events: AsyncStream<BridgeEvent>

    public init() {
        var cont: AsyncStream<BridgeEvent>.Continuation!
        self.events = AsyncStream { continuation in
            cont = continuation
        }
        self.eventContinuation = cont
    }

    // MARK: - Environment Discovery & Bootstrap

    public static func locateRuntime() -> (pythonURL: URL, pythonPath: String?)? {
        let fm = FileManager.default
        let venvPython = AppEnvironment.venvDirectoryURL.appendingPathComponent("bin/python3")

        if fm.isExecutableFile(atPath: venvPython.path) {
            return (venvPython, nil)
        }

        if let customBin = AppEnvironment.customPythonBinary,
           fm.isExecutableFile(atPath: customBin) {
            let bundledSite = Bundle.main.resourceURL?.appendingPathComponent("site-packages")
            let extraPath = (bundledSite != nil && fm.fileExists(atPath: bundledSite!.path)) ? bundledSite!.path : nil
            return (URL(fileURLWithPath: customBin), extraPath)
        }

        if let bundledSitePackages = Bundle.main.resourceURL?.appendingPathComponent("site-packages"),
           fm.fileExists(atPath: bundledSitePackages.path) {
            let candidates = [
                "/opt/homebrew/bin/python3.11",
                "/opt/homebrew/bin/python3.12",
                "/opt/homebrew/bin/python3.13",
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3",
            ]
            for path in candidates where fm.isExecutableFile(atPath: path) {
                return (URL(fileURLWithPath: path), bundledSitePackages.path)
            }
        }

        return nil
    }

    public static func locateBridgeScript() -> URL? {
        if let bundled = Bundle.main.url(forResource: "atv_bridge", withExtension: "py") {
            return bundled
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for rel in ["src/Helper/atv_bridge.py", "Helper/atv_bridge.py"] {
            let candidate = cwd.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public nonisolated func bootstrapPythonEnvironment() async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var candidates: [String] = []
            if let custom = AppEnvironment.customPythonBinary {
                candidates.append(custom)
            }
            candidates.append(contentsOf: [
                "/opt/homebrew/bin/python3.13",
                "/opt/homebrew/bin/python3.12",
                "/opt/homebrew/bin/python3.11",
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3",
                "/usr/bin/python3",
            ])
            guard let pythonPath = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
                throw BridgeError.remoteError(
                    code: "no_python",
                    message: "Python 3 not found. Install Python via Homebrew (brew install python@3.12)."
                )
            }

            let venvDir = AppEnvironment.venvDirectoryURL
            try fm.createDirectory(at: venvDir.deletingLastPathComponent(), withIntermediateDirectories: true)

            try Self.runBlockingProcess(
                executable: pythonPath,
                arguments: ["-m", "venv", venvDir.path]
            )
            let pipPath = venvDir.appendingPathComponent("bin/pip").path
            try Self.runBlockingProcess(
                executable: pipPath,
                arguments: ["install", "--upgrade", "pip", "pyatv>=0.16.0", "srptools<2.0.0", "ifaddr>=0.2.0"]
            )
        }.value
    }

    private nonisolated static func runBlockingProcess(executable: String, arguments: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? "Exit code \(proc.terminationStatus)"
            throw BridgeError.remoteError(code: "install_failed", message: errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Process Lifecycle

    public func ensureRunning() async throws {
        if let proc = process, proc.isRunning {
            return
        }
        try startProcess()
    }

    private func startProcess() throws {
        guard let runtime = Self.locateRuntime() else {
            throw BridgeError.helperPythonMissing
        }
        guard let scriptURL = Self.locateBridgeScript() else {
            throw BridgeError.helperScriptMissing
        }

        intentionalStop = false

        let proc = Process()
        proc.executableURL = runtime.pythonURL
        proc.arguments = ["-u", scriptURL.path]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["TVREMOTE_LOG_LEVEL"] = AppEnvironment.logLevel
        let defaultHosts = AppEnvironment.defaultHosts
        if !defaultHosts.isEmpty {
            env["TVREMOTE_DEFAULT_HOST"] = defaultHosts.joined(separator: ",")
        }
        let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { "\($0):\(defaultPath)" } ?? defaultPath
        if let extraPythonPath = runtime.pythonPath {
            env["PYTHONPATH"] = extraPythonPath
        }
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        self.process = proc
        self.stdinHandle = inPipe.fileHandleForWriting

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let pid = proc.processIdentifier

        Task.detached { [weak self] in
            var buffer = Data()
            let newline = UInt8(ascii: "\n")
            while true {
                let chunk = outHandle.availableData
                if chunk.isEmpty {
                    break
                }
                buffer.append(chunk)
                while let idx = buffer.firstIndex(of: newline) {
                    let lineData = Data(buffer[buffer.startIndex..<idx])
                    buffer.removeSubrange(buffer.startIndex...idx)
                    if !lineData.isEmpty {
                        await self?.handleStdoutLine(lineData)
                    }
                }
            }
            await self?.handleProcessExit(pid: pid)
        }

        Task.detached {
            // Drain stderr so pipe buffer never blocks long-running sessions
            while !errHandle.availableData.isEmpty {}
        }
    }

    public func shutdown() {
        intentionalStop = true
        failAllPending(with: BridgeError.processNotRunning)
        try? stdinHandle?.close()
        stdinHandle = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
    }

    private func handleProcessExit(pid: Int32) async {
        guard process?.processIdentifier == pid else { return }
        process = nil
        stdinHandle = nil
        failAllPending(with: BridgeError.processNotRunning)

        guard !intentionalStop else { return }

        restartCount += 1
        let willRestart = restartCount <= 6
        eventContinuation.yield(.helperCrashed(willRestart: willRestart))

        guard willRestart else { return }
        let backoffNanoseconds = UInt64(min(Double(restartCount) * 0.8, 4.0) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: backoffNanoseconds)
        if !intentionalStop {
            try? startProcess()
        }
    }

    private func failAllPending(with error: Error) {
        let current = pending
        pending.removeAll()
        for (_, cont) in current {
            cont.resume(throwing: error)
        }
    }

    // MARK: - JSON Framing

    private func handleStdoutLine(_ data: Data) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = envelope["type"] as? String else {
            return
        }

        switch type {
        case "ready":
            restartCount = 0
            let version = envelope["pyatvVersion"] as? String ?? "unknown"
            eventContinuation.yield(.ready(version: version))

        case "response":
            guard let id = envelope["id"] as? String,
                  let cont = pending.removeValue(forKey: id) else {
                return
            }
            let ok = envelope["ok"] as? Bool ?? false
            if ok {
                let resultObj = envelope["result"] ?? [:]
                if let resultData = try? JSONSerialization.data(withJSONObject: resultObj) {
                    cont.resume(returning: resultData)
                } else {
                    cont.resume(throwing: BridgeError.invalidResponse)
                }
            } else {
                let errDict = envelope["error"] as? [String: Any]
                let code = errDict?["code"] as? String ?? "bridge_error"
                let message = errDict?["message"] as? String ?? "Unknown Apple TV error."
                cont.resume(throwing: BridgeError.remoteError(code: code, message: message))
            }

        case "event":
            guard let eventName = envelope["event"] as? String,
                  let eventDataObj = envelope["data"] else {
                return
            }
            handleEvent(name: eventName, payloadObject: eventDataObj)

        default:
            break
        }
    }

    private func handleEvent(name: String, payloadObject: Any) {
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payloadObject) else {
            return
        }
        let decoder = JSONDecoder()

        switch name {
        case "now_playing":
            struct NowPlayingEventPayload: Decodable {
                let nowPlaying: NowPlayingInfo?
                let capabilities: DeviceCapabilities
            }
            if let decoded = try? decoder.decode(NowPlayingEventPayload.self, from: payloadData) {
                eventContinuation.yield(.nowPlaying(decoded.nowPlaying, decoded.capabilities))
            }

        case "audio_update":
            if let caps = try? decoder.decode(DeviceCapabilities.self, from: payloadData) {
                eventContinuation.yield(.audioUpdate(caps))
            }

        case "pairing_backoff":
            if let dict = payloadObject as? [String: Any],
               let secs = dict["seconds"] as? Int {
                let proto = dict["protocol"] as? String ?? "Companion"
                eventContinuation.yield(.pairingBackoff(seconds: secs, protocolName: proto))
            }

        case "connection_lost":
            if let dict = payloadObject as? [String: Any] {
                let reason = dict["reason"] as? String ?? "Connection interrupted"
                eventContinuation.yield(.connectionLost(reason: reason))
            }

        default:
            break
        }
    }

    // MARK: - Typed RPC Calls

    public func request<T: Decodable>(
        cmd: String,
        params: [String: Any] = [:],
        timeoutSeconds: Double = 10.0,
        as type: T.Type = T.self
    ) async throws -> T {
        try await ensureRunning()
        guard let stdin = stdinHandle else {
            throw BridgeError.processNotRunning
        }

        let reqID = UUID().uuidString
        let payload: [String: Any] = [
            "id": reqID,
            "cmd": cmd,
            "params": params,
        ]
        var lineData = try JSONSerialization.data(withJSONObject: payload)
        lineData.append(UInt8(ascii: "\n"))

        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            pending[reqID] = continuation

            do {
                try stdin.write(contentsOf: lineData)
            } catch {
                if let cont = pending.removeValue(forKey: reqID) {
                    cont.resume(throwing: error)
                }
                return
            }

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                await self?.timeoutRequestIfPending(id: reqID, cmd: cmd)
            }
        }

        return try JSONDecoder().decode(T.self, from: responseData)
    }

    private func timeoutRequestIfPending(id: String, cmd: String) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: BridgeError.timeout(cmd))
        }
    }
}
