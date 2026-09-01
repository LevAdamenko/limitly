import Foundation

struct GhosttyTerminal: Equatable, Sendable {
    let title: String
    let workingDirectory: String
}

enum IdleNotificationUserInfo {
    static let workingDirectory = "limitly.idleWorkingDirectory"
}

enum GhosttyController {
    private static let recordSeparator: Character = "\u{001e}"
    private static let fieldSeparator: Character = "\u{001f}"

    static func openTerminals() -> [GhosttyTerminal] {
        let script = #"""
        if application "Ghostty" is not running then return ""
        set output to ""
        set fieldSeparator to character id 31
        set recordSeparator to character id 30
        tell application "Ghostty"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with term in terminals of t
                        try
                            set output to output & (name of term as text) & fieldSeparator & (working directory of term as text) & recordSeparator
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        return output
        """#
        guard let output = runAppleScript(script) else { return [] }

        return output.split(separator: recordSeparator, omittingEmptySubsequences: true).compactMap { record in
            let fields = record.split(separator: fieldSeparator, maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            let title = String(fields[0])
            let workingDirectory = URL(fileURLWithPath: String(fields[1])).standardizedFileURL.path
            guard !workingDirectory.isEmpty else { return nil }
            return GhosttyTerminal(title: title, workingDirectory: workingDirectory)
        }
    }

    /// `workingDirectory` was normalized (via `standardizedFileURL.path`) by
    /// `openTerminals()` when this value was first captured, but Ghostty's
    /// own live "working directory of term" string here isn't run through
    /// the same normalization — so both sides strip a trailing slash before
    /// comparing, which is the one mismatch a standardized path can
    /// actually introduce here (`standardizedFileURL` doesn't resolve
    /// symlinks or change case, just path syntax).
    static func focusTerminal(workingDirectory: String) {
        var target = workingDirectory
        if target.hasSuffix("/") { target.removeLast() }
        let script = #"""
        on run argv
            if application "Ghostty" is not running then return
            set targetDirectory to item 1 of argv
            tell application "Ghostty"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with term in terminals of t
                            try
                                set liveDirectory to (working directory of term as text)
                                if liveDirectory ends with "/" then set liveDirectory to text 1 thru -2 of liveDirectory
                                if liveDirectory is targetDirectory then
                                    focus term
                                    return
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat
            end tell
        end run
        """#
        _ = runAppleScript(script, arguments: [target])
    }

    /// `osascript` is bounded because this is sampled frequently and an
    /// automation-permission prompt or wedged Ghostty must not stall usage
    /// refreshes indefinitely.
    private static func runAppleScript(
        _ script: String,
        arguments: [String] = [],
        timeout: TimeInterval = 1.5
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard !process.isRunning else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
