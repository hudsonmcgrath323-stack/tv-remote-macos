import Foundation

/// Centralized environment configuration loader for TV Remote.
/// Reads process environment variables first, falling back to an optional `.env` file
/// in the working directory or `~/Library/Application Support/TVRemote/.env`.
public enum AppEnvironment {
    private static let dotEnvValues: [String: String] = loadDotEnv()

    public static func string(_ key: String) -> String? {
        if let raw = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return expandTilde(raw)
        }
        if let fromFile = dotEnvValues[key], !fromFile.isEmpty {
            return expandTilde(fromFile)
        }
        return nil
    }

    public static var customPythonBinary: String? {
        string("TVREMOTE_PYTHON_BIN")
    }

    public static var venvDirectoryURL: URL {
        if let custom = string("TVREMOTE_VENV_DIR") {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TVRemote/venv", isDirectory: true)
    }

    public static var keychainService: String {
        string("TVREMOTE_KEYCHAIN_SERVICE") ?? "com.hudson.TVRemote.credentials"
    }

    public static var defaultHosts: [String] {
        guard let raw = string("TVREMOTE_DEFAULT_HOST") else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static var logLevel: String {
        string("TVREMOTE_LOG_LEVEL") ?? "WARNING"
    }

    private static func expandTilde(_ value: String) -> String {
        NSString(string: value).expandingTildeInPath
    }

    private static func loadDotEnv() -> [String: String] {
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".env"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TVRemote/.env"),
        ]

        for url in candidates {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var parsed: [String: String] = [:]
            for line in contents.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
                let key = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespaces)
                var val = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                if (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                    val = String(val.dropFirst().dropLast())
                }
                if !key.isEmpty {
                    parsed[key] = val
                }
            }
            return parsed
        }
        return [:]
    }
}
