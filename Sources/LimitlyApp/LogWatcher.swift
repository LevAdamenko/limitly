import CoreServices
import Foundation
import LimitlyCore

/// Watches the directories each agent writes its usage logs to, so Limitly
/// can re-run `ccusage` only when there is something new to count. FSEvents
/// costs nothing while those directories are quiet, unlike polling them.
final class LogWatcher: @unchecked Sendable {
    /// Agents whose log directory existed and is being watched. Any agent
    /// missing from this set has to be treated as "may have changed" on
    /// every check, since nothing will report when it does.
    let watchedAgents: Set<AgentID>

    private let roots: [(agent: AgentID, path: String)]
    private let onChange: @Sendable (Set<AgentID>) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "limitly.log-watcher", qos: .utility)

    init(onChange: @escaping @Sendable (Set<AgentID>) -> Void) {
        self.onChange = onChange
        let fileManager = FileManager.default
        // FSEvents reports real paths, so roots are resolved up front for the
        // prefix match below to hold when e.g. ~/.claude is a symlink.
        var roots: [(agent: AgentID, path: String)] = []
        for (agent, url) in Self.candidateRoots() {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue,
                  !roots.contains(where: { $0.path == resolved }) else { continue }
            roots.append((agent, resolved))
        }
        self.roots = roots
        self.watchedAgents = Set(roots.map(\.agent))
        start()
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// The same places `ccusage` and `SessionActivityTracker` read from.
    private static func candidateRoots() -> [(AgentID, URL)] {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        var claudeDirectories = [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".config/claude/projects", isDirectory: true)
        ]
        if let configured = environment["CLAUDE_CONFIG_DIR"] {
            claudeDirectories += configured.split(separator: ",").map {
                URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces), isDirectory: true)
                    .appendingPathComponent("projects", isDirectory: true)
            }
        }
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        return claudeDirectories.map { (AgentID.claude, $0) }
            + [(AgentID.codex, codexHome.appendingPathComponent("sessions", isDirectory: true))]
    }

    private func start() {
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<LogWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handle(paths: paths.prefix(count))
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            roots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            // Coalesces a burst of appends (a streaming reply writes many
            // lines) into one wake-up.
            2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func handle<Paths: Sequence<String>>(paths: Paths) {
        var agents: Set<AgentID> = []
        for path in paths {
            for root in roots where path == root.path || path.hasPrefix(root.path + "/") {
                agents.insert(root.agent)
            }
        }
        if !agents.isEmpty { onChange(agents) }
    }
}
