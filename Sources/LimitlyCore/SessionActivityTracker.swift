import Foundation

public struct SessionCandidate: Equatable, Sendable {
    public let agent: AgentID
    public let workingDirectory: String
    public let tabTitle: String

    public init(agent: AgentID, workingDirectory: String, tabTitle: String) {
        self.agent = agent
        self.workingDirectory = workingDirectory
        self.tabTitle = tabTitle
    }
}

public struct SessionIdleEvent: Equatable, Sendable {
    public let agent: AgentID
    public let workingDirectory: String
    public let tabTitle: String
    public let idleSince: Date

    public init(agent: AgentID, workingDirectory: String, tabTitle: String, idleSince: Date) {
        self.agent = agent
        self.workingDirectory = workingDirectory
        self.tabTitle = tabTitle
        self.idleSince = idleSince
    }
}

public struct SessionActivityObservation: Equatable, Sendable {
    public let idleEvents: [SessionIdleEvent]
    public let matchedAgents: Set<AgentID>

    public init(idleEvents: [SessionIdleEvent], matchedAgents: Set<AgentID>) {
        self.idleEvents = idleEvents
        self.matchedAgents = matchedAgents
    }
}

/// Tracks activity in the transcript file associated with each open terminal.
/// Filesystem discovery lives here so it can be exercised independently of
/// Ghostty and AppKit; the app supplies the terminal candidates.
public struct SessionActivityTracker {
    private struct SessionKey: Hashable {
        let agent: AgentID
        let workingDirectory: String
    }

    private struct State {
        var modificationDate: Date
        var lastActivity: Date?
        var isActive: Bool
    }

    private let fileManager: FileManager
    private let claudeProjectsDirectory: URL
    private let codexSessionsDirectory: URL
    private let calendar: Calendar
    private let codexScanCacheInterval: TimeInterval
    private let codexRecentFileInterval: TimeInterval

    private var states: [SessionKey: State] = [:]
    private var codexFilesByWorkingDirectory: [String: [URL]] = [:]
    private var codexCacheDate: Date?

    public init(
        fileManager: FileManager = .default,
        claudeProjectsDirectory: URL? = nil,
        codexSessionsDirectory: URL? = nil,
        calendar: Calendar = .current,
        codexScanCacheInterval: TimeInterval = 60,
        codexRecentFileInterval: TimeInterval = 24 * 60 * 60
    ) {
        self.fileManager = fileManager
        let home = fileManager.homeDirectoryForCurrentUser
        self.claudeProjectsDirectory = claudeProjectsDirectory
            ?? home.appendingPathComponent(".claude/projects", isDirectory: true)
        self.codexSessionsDirectory = codexSessionsDirectory
            ?? home.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.calendar = calendar
        self.codexScanCacheInterval = codexScanCacheInterval
        self.codexRecentFileInterval = codexRecentFileInterval
    }

    public mutating func observe(
        candidates: [SessionCandidate],
        at date: Date,
        idleInterval: TimeInterval
    ) -> SessionActivityObservation {
        var events: [SessionIdleEvent] = []
        var matchedAgents: Set<AgentID> = []
        var observedKeys: Set<SessionKey> = []

        for candidate in candidates {
            let workingDirectory = Self.normalized(candidate.workingDirectory)
            let key = SessionKey(agent: candidate.agent, workingDirectory: workingDirectory)
            // A transcript can only identify a cwd, not one of several tabs
            // sharing it. Keep the first Ghostty tab, matching focus behavior.
            guard observedKeys.insert(key).inserted,
                  let modificationDate = latestActivityDate(
                    for: candidate.agent,
                    workingDirectory: workingDirectory,
                    at: date
                  ) else { continue }

            matchedAgents.insert(candidate.agent)

            guard var state = states[key] else {
                states[key] = State(
                    modificationDate: modificationDate,
                    lastActivity: nil,
                    isActive: false
                )
                continue
            }

            let increased = modificationDate > state.modificationDate
            let reset = modificationDate < state.modificationDate

            if increased {
                state.lastActivity = modificationDate
                state.isActive = true
            } else if reset {
                state.lastActivity = nil
                state.isActive = false
            } else if state.isActive,
                      let lastActivity = state.lastActivity,
                      date.timeIntervalSince(lastActivity) >= max(0, idleInterval) {
                events.append(SessionIdleEvent(
                    agent: candidate.agent,
                    workingDirectory: workingDirectory,
                    tabTitle: candidate.tabTitle,
                    idleSince: lastActivity
                ))
                state.isActive = false
            }

            state.modificationDate = modificationDate
            states[key] = state
        }

        return SessionActivityObservation(idleEvents: events, matchedAgents: matchedAgents)
    }

    private mutating func latestActivityDate(
        for agent: AgentID,
        workingDirectory: String,
        at date: Date
    ) -> Date? {
        switch agent {
        case .claude:
            return latestClaudeActivityDate(workingDirectory: workingDirectory)
        case .codex:
            return latestCodexActivityDate(workingDirectory: workingDirectory, at: date)
        }
    }

    private func latestClaudeActivityDate(workingDirectory: String) -> Date? {
        let encodedDirectory = workingDirectory.replacingOccurrences(of: "/", with: "-")
        let projectDirectory = claudeProjectsDirectory
            .appendingPathComponent(encodedDirectory, isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return files.lazy
            .filter { $0.pathExtension == "jsonl" }
            .compactMap(modificationDate(of:))
            .max()
    }

    private mutating func latestCodexActivityDate(workingDirectory: String, at date: Date) -> Date? {
        refreshCodexCacheIfNeeded(at: date)
        let cutoff = date.addingTimeInterval(-max(0, codexRecentFileInterval))
        return codexFilesByWorkingDirectory[workingDirectory, default: []].lazy
            .compactMap(modificationDate(of:))
            .filter { $0 >= cutoff }
            .max()
    }

    private mutating func refreshCodexCacheIfNeeded(at date: Date) {
        if let codexCacheDate,
           date >= codexCacheDate,
           date.timeIntervalSince(codexCacheDate) < max(0, codexScanCacheInterval) {
            return
        }

        let cutoff = date.addingTimeInterval(-max(0, codexRecentFileInterval))
        var discovered: [String: [URL]] = [:]
        var visitedDirectories: Set<String> = []

        for dayOffset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = components.year, let month = components.month, let day = components.day else { continue }
            let directory = codexSessionsDirectory
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
            guard visitedDirectories.insert(directory.path).inserted,
                  let files = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let modificationDate = modificationDate(of: file), modificationDate >= cutoff,
                      let workingDirectory = codexWorkingDirectory(in: file) else { continue }
                discovered[Self.normalized(workingDirectory), default: []].append(file)
            }
        }

        codexFilesByWorkingDirectory = discovered
        codexCacheDate = date
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func codexWorkingDirectory(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else { return nil }
        let firstLine = data[..<(data.firstIndex(of: 0x0A) ?? data.endIndex)]
        guard let object = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else { return nil }
        return payload["cwd"] as? String
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
