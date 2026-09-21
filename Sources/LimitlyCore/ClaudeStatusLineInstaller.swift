import Foundation

public enum ClaudeStatusLineInstallerError: LocalizedError {
    case settingsUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case .settingsUnreadable(let reason):
            return "Claude settings unreadable: \(reason)"
        }
    }
}

public enum ClaudeStatusLineInstaller {
    public enum State: Equatable {
        case notInstalled
        case installed
        case installedAlongside(existing: String)
        case claudeSettingsUnreadable(String)
    }

    public static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public static var limitlyDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".limitly", isDirectory: true)
    }

    public static var statusLineScriptURL: URL {
        limitlyDirectoryURL.appendingPathComponent("statusline.sh")
    }

    public static var chainFileURL: URL {
        limitlyDirectoryURL.appendingPathComponent("statusline-chain")
    }

    public static let scriptContent: String = """
#!/bin/sh
# Limitly statusLine sidecar for Claude Code.
#
# Claude Code pipes its status-line JSON to this script on stdin. That payload
# carries `rate_limits`, which is the only place on this machine that reports
# Anthropic's own five-hour and seven-day percentages together with their real
# `resets_at` — everything else available locally is a reconstruction. We
# record just that fragment for Limitly and hand the untouched input on to
# whatever status line was configured before, so installing this changes
# nothing the user sees in their terminal.

INPUT=$(cat)
LIMITLY_DIR="${LIMITLY_DIR:-$HOME/.limitly}"

if [ -n "$INPUT" ]; then
    printf '%s' "$INPUT" | /usr/bin/python3 -c '
import sys, json, os, time

try:
    raw = sys.stdin.read()
    if raw.strip():
        data = json.loads(raw)
        rate_limits = data.get("rate_limits")
        if isinstance(rate_limits, dict):
            limits = {}
            for key in ("five_hour", "seven_day"):
                if isinstance(rate_limits.get(key), dict):
                    limits[key] = rate_limits[key]
            # Written even when a window is missing. Claude Code drops a
            # window from this payload the moment its resets_at passes, so
            # "five_hour is gone but seven_day is still here" is exactly how a
            # session reset announces itself — the most valuable thing this
            # script can record. Skipping the write there would leave the last
            # pre-reset reading (often 100%) on disk with nothing to
            # contradict it.
            out_dir = sys.argv[1]
            os.makedirs(out_dir, exist_ok=True)
            tmp_path = os.path.join(out_dir, "claude-rate-limits.json.tmp.%d" % os.getpid())
            final_path = os.path.join(out_dir, "claude-rate-limits.json")
            payload = {"writtenAt": int(time.time()), "rate_limits": limits}
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump(payload, f)
                f.flush()
                os.fsync(f.fileno())
            # Rename rather than write in place: Limitly polls this file every
            # few seconds and must never read a half-written one.
            os.replace(tmp_path, final_path)
except Exception:
    pass
' "$LIMITLY_DIR" 2>/dev/null || true
fi

# Hand the original input to the status line that was configured before
# Limitly took the slot, and print its output verbatim. Failures here are
# swallowed: a broken chained command must not blank out the status line.
CHAIN_FILE="$LIMITLY_DIR/statusline-chain"
if [ -f "$CHAIN_FILE" ]; then
    CHAIN_CMD=$(cat "$CHAIN_FILE" 2>/dev/null)
    if [ -n "$CHAIN_CMD" ]; then
        printf '%s' "$INPUT" | eval "$CHAIN_CMD" || true
    fi
fi

exit 0

"""

    public static func state() -> State {
        state(settingsURL: claudeSettingsURL, chainURL: chainFileURL, scriptURL: statusLineScriptURL)
    }

    public static func state(
        settingsURL: URL = claudeSettingsURL,
        chainURL: URL = chainFileURL,
        scriptURL: URL = statusLineScriptURL
    ) -> State {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return .notInstalled
        }

        let data: Data
        do {
            data = try Data(contentsOf: settingsURL)
        } catch {
            return .claudeSettingsUnreadable("Failed to read settings file: \(error.localizedDescription)")
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .claudeSettingsUnreadable("Invalid JSON in settings file: \(error.localizedDescription)")
        }

        guard let dict = jsonObject as? [String: Any] else {
            return .claudeSettingsUnreadable("settings.json root is not a JSON object")
        }

        guard let statusLine = dict["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return .notInstalled
        }

        if isOurScriptCommand(command, scriptPath: scriptURL.path) {
            if FileManager.default.fileExists(atPath: chainURL.path),
               let content = try? String(contentsOf: chainURL, encoding: .utf8) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return .installedAlongside(existing: trimmed)
                }
            }
            return .installed
        }

        return .notInstalled
    }

    public static func install() throws {
        try install(settingsURL: claudeSettingsURL, limitlyDir: limitlyDirectoryURL)
    }

    public static func install(
        settingsURL: URL = claudeSettingsURL,
        limitlyDir: URL = limitlyDirectoryURL
    ) throws {
        let scriptURL = limitlyDir.appendingPathComponent("statusline.sh")
        let chainURL = limitlyDir.appendingPathComponent("statusline-chain")

        // 1. Read ~/.claude/settings.json (may not exist -> create)
        var settingsDict: [String: Any] = [:]
        let settingsExist = FileManager.default.fileExists(atPath: settingsURL.path)
        if settingsExist {
            let data: Data
            do {
                data = try Data(contentsOf: settingsURL)
            } catch {
                throw ClaudeStatusLineInstallerError.settingsUnreadable("Failed to read settings: \(error.localizedDescription)")
            }

            let jsonObject: Any
            do {
                jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
            } catch {
                throw ClaudeStatusLineInstallerError.settingsUnreadable("Invalid JSON in settings: \(error.localizedDescription)")
            }

            guard let dict = jsonObject as? [String: Any] else {
                throw ClaudeStatusLineInstallerError.settingsUnreadable("settings.json top-level is not a JSON object")
            }
            settingsDict = dict
        }

        let scriptPath = scriptURL.path

        // Check if statusLine.command is already ours (idempotent check)
        if let statusLine = settingsDict["statusLine"] as? [String: Any],
           let existingCommand = statusLine["command"] as? String,
           isOurScriptCommand(existingCommand, scriptPath: scriptPath) {
            // Already ours: ensure script file exists and return
            if !FileManager.default.fileExists(atPath: scriptURL.path) {
                try writeScript(to: scriptURL, limitlyDir: limitlyDir)
            }
            return
        }

        // If it is some OTHER command, record that command inside ~/.limitly/statusline-chain
        if let statusLine = settingsDict["statusLine"] as? [String: Any],
           let existingCommand = statusLine["command"] as? String,
           !existingCommand.isEmpty {
            try FileManager.default.createDirectory(at: limitlyDir, withIntermediateDirectories: true)
            try existingCommand.write(to: chainURL, atomically: true, encoding: .utf8)
        }

        // Write the executable script to ~/.limitly/statusline.sh
        try writeScript(to: scriptURL, limitlyDir: limitlyDir)

        // Take a timestamped backup copy of settings.json next to it before the first mutation
        if settingsExist {
            try createBackupIfNeeded(of: settingsURL)
        }

        // Update statusLine in settingsDict
        var statusLineDict = (settingsDict["statusLine"] as? [String: Any]) ?? [:]
        statusLineDict["type"] = statusLineDict["type"] ?? "command"
        statusLineDict["command"] = scriptPath
        statusLineDict["padding"] = statusLineDict["padding"] ?? 0
        settingsDict["statusLine"] = statusLineDict

        // Save atomically
        try writeSettingsAtomically(settingsDict, to: settingsURL)
    }

    public static func uninstall() throws {
        try uninstall(settingsURL: claudeSettingsURL, limitlyDir: limitlyDirectoryURL)
    }

    public static func uninstall(
        settingsURL: URL = claudeSettingsURL,
        limitlyDir: URL = limitlyDirectoryURL
    ) throws {
        let scriptURL = limitlyDir.appendingPathComponent("statusline.sh")
        let chainURL = limitlyDir.appendingPathComponent("statusline-chain")

        // 1. Read chained command if present
        var chainedCommand: String? = nil
        if FileManager.default.fileExists(atPath: chainURL.path) {
            if let content = try? String(contentsOf: chainURL, encoding: .utf8) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    chainedCommand = trimmed
                }
            }
        }

        // 2. Modify settings.json if it exists
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: settingsURL)
            } catch {
                throw ClaudeStatusLineInstallerError.settingsUnreadable("Failed to read settings: \(error.localizedDescription)")
            }

            guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
                  var settingsDict = jsonObject as? [String: Any] else {
                throw ClaudeStatusLineInstallerError.settingsUnreadable("Invalid JSON in settings.json")
            }

            if var statusLineDict = settingsDict["statusLine"] as? [String: Any] {
                let currentCmd = statusLineDict["command"] as? String
                if let currentCmd = currentCmd, isOurScriptCommand(currentCmd, scriptPath: scriptURL.path) {
                    if let chainedCommand = chainedCommand {
                        statusLineDict["command"] = chainedCommand
                        settingsDict["statusLine"] = statusLineDict
                    } else {
                        settingsDict.removeValue(forKey: "statusLine")
                    }
                    try writeSettingsAtomically(settingsDict, to: settingsURL)
                }
            }
        }

        // 3. Remove statusline-chain if present
        if FileManager.default.fileExists(atPath: chainURL.path) {
            try? FileManager.default.removeItem(at: chainURL)
        }

        // 4. Delete ~/.limitly/statusline.sh
        if FileManager.default.fileExists(atPath: scriptURL.path) {
            try? FileManager.default.removeItem(at: scriptURL)
        }
    }

    public static func isOurScriptCommand(_ command: String, scriptPath: String) -> Bool {
        let unquoted = command.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if unquoted == scriptPath || unquoted == "~/.limitly/statusline.sh" {
            return true
        }
        return NSString(string: unquoted).expandingTildeInPath == scriptPath
    }

    static func writeScript(to scriptURL: URL, limitlyDir: URL) throws {
        try FileManager.default.createDirectory(at: limitlyDir, withIntermediateDirectories: true)
        guard let scriptData = scriptContent.data(using: .utf8) else { return }
        try scriptData.write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    static func writeSettingsAtomically(_ dict: [String: Any], to url: URL) throws {
        let parentDir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func createBackupIfNeeded(of settingsURL: URL) throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let parentDir = settingsURL.deletingLastPathComponent()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let timestamp = formatter.string(from: Date())
        var backupURL = parentDir.appendingPathComponent("settings.json.backup-\(timestamp)")
        if FileManager.default.fileExists(atPath: backupURL.path) {
            backupURL = parentDir.appendingPathComponent("settings.json.backup-\(timestamp)-\(UUID().uuidString.prefix(8))")
        }
        try FileManager.default.copyItem(at: settingsURL, to: backupURL)
    }
}
