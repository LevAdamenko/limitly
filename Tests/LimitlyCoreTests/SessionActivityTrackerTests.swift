import XCTest
@testable import LimitlyCore

final class SessionActivityTrackerTests: XCTestCase {
    private let fileManager = FileManager.default
    private let start = Date(timeIntervalSince1970: 1_788_228_800) // 2026-09-01 12:00 UTC
    private var root: URL!
    private var claudeRoot: URL!
    private var codexRoot: URL!

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        claudeRoot = root.appendingPathComponent("claude", isDirectory: true)
        codexRoot = root.appendingPathComponent("codex", isDirectory: true)
        try fileManager.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: codexRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
    }

    func testClaudeActivityTransitionFiresOnceAndUsesTabMetadata() throws {
        let cwd = "/Users/lev/Projects/menu-bar"
        let transcript = try makeClaudeTranscript(cwd: cwd, modifiedAt: start)
        var tracker = makeTracker()
        let candidate = SessionCandidate(agent: .claude, workingDirectory: cwd, tabTitle: "Menu bar icon rendering")

        let baseline = tracker.observe(candidates: [candidate], at: start, idleInterval: 30)
        XCTAssertEqual(baseline.matchedAgents, [.claude])
        XCTAssertTrue(baseline.idleEvents.isEmpty)

        let activity = start.addingTimeInterval(5)
        try setModificationDate(activity, on: transcript)
        XCTAssertTrue(tracker.observe(candidates: [candidate], at: activity, idleInterval: 30).idleEvents.isEmpty)
        XCTAssertTrue(tracker.observe(candidates: [candidate], at: start.addingTimeInterval(34), idleInterval: 30).idleEvents.isEmpty)

        XCTAssertEqual(
            tracker.observe(candidates: [candidate], at: start.addingTimeInterval(35), idleInterval: 30).idleEvents,
            [SessionIdleEvent(agent: .claude, workingDirectory: cwd, tabTitle: "Menu bar icon rendering", idleSince: activity)]
        )
        XCTAssertTrue(tracker.observe(candidates: [candidate], at: start.addingTimeInterval(60), idleInterval: 30).idleEvents.isEmpty)
    }

    func testClaudeUsesForwardPathEncodingAndNewestTranscript() throws {
        let cwd = "/Users/lev/a-project/with-dashes"
        _ = try makeClaudeTranscript(cwd: cwd, name: "older.jsonl", modifiedAt: start)
        let newest = try makeClaudeTranscript(cwd: cwd, name: "newest.jsonl", modifiedAt: start.addingTimeInterval(7))
        var tracker = makeTracker()
        let candidate = SessionCandidate(agent: .claude, workingDirectory: cwd, tabTitle: "Claude tab")

        _ = tracker.observe(candidates: [candidate], at: start.addingTimeInterval(7), idleInterval: 10)
        let activity = start.addingTimeInterval(9)
        try setModificationDate(activity, on: newest)
        _ = tracker.observe(candidates: [candidate], at: activity, idleInterval: 10)

        XCTAssertEqual(
            tracker.observe(candidates: [candidate], at: start.addingTimeInterval(19), idleInterval: 10).idleEvents.first?.idleSince,
            activity
        )
    }

    func testCandidateWithoutTranscriptIsNotMatchedForFallbackDecision() {
        var tracker = makeTracker()
        let candidate = SessionCandidate(agent: .claude, workingDirectory: "/missing", tabTitle: "No session")

        let observation = tracker.observe(candidates: [candidate], at: start, idleInterval: 10)

        XCTAssertTrue(observation.matchedAgents.isEmpty)
        XCTAssertTrue(observation.idleEvents.isEmpty)
    }

    func testCodexMatchesFirstLineCwdAndIgnoresOldRollouts() throws {
        let calendar = utcCalendar()
        let cwd = "/Users/lev/Projects/limitly"
        let live = try makeCodexRollout(cwd: cwd, modifiedAt: start, calendar: calendar)
        _ = try makeCodexRollout(
            cwd: "/Users/lev/Projects/old",
            name: "rollout-old.jsonl",
            modifiedAt: start.addingTimeInterval(-(24 * 60 * 60 + 1)),
            calendar: calendar
        )
        var tracker = makeTracker(calendar: calendar)
        let candidates = [
            SessionCandidate(agent: .codex, workingDirectory: cwd, tabTitle: "Limitly"),
            SessionCandidate(agent: .codex, workingDirectory: "/Users/lev/Projects/old", tabTitle: "Old")
        ]

        XCTAssertEqual(tracker.observe(candidates: candidates, at: start, idleInterval: 20).matchedAgents, [.codex])
        let activity = start.addingTimeInterval(2)
        try setModificationDate(activity, on: live)
        _ = tracker.observe(candidates: candidates, at: activity, idleInterval: 20)

        XCTAssertEqual(
            tracker.observe(candidates: candidates, at: start.addingTimeInterval(22), idleInterval: 20).idleEvents,
            [SessionIdleEvent(agent: .codex, workingDirectory: cwd, tabTitle: "Limitly", idleSince: activity)]
        )
    }

    func testModificationDateMovingBackwardResetsWithoutIdleEvent() throws {
        let cwd = "/Users/lev/Projects/reset"
        let transcript = try makeClaudeTranscript(cwd: cwd, modifiedAt: start)
        var tracker = makeTracker()
        let candidate = SessionCandidate(agent: .claude, workingDirectory: cwd, tabTitle: "Reset")
        _ = tracker.observe(candidates: [candidate], at: start, idleInterval: 10)
        try setModificationDate(start.addingTimeInterval(2), on: transcript)
        _ = tracker.observe(candidates: [candidate], at: start.addingTimeInterval(2), idleInterval: 10)
        try setModificationDate(start.addingTimeInterval(-1), on: transcript)

        XCTAssertTrue(tracker.observe(candidates: [candidate], at: start.addingTimeInterval(20), idleInterval: 10).idleEvents.isEmpty)
        XCTAssertTrue(tracker.observe(candidates: [candidate], at: start.addingTimeInterval(40), idleInterval: 10).idleEvents.isEmpty)
    }

    private func makeTracker(calendar: Calendar = .current) -> SessionActivityTracker {
        SessionActivityTracker(
            fileManager: fileManager,
            claudeProjectsDirectory: claudeRoot,
            codexSessionsDirectory: codexRoot,
            calendar: calendar,
            codexScanCacheInterval: 60
        )
    }

    @discardableResult
    private func makeClaudeTranscript(
        cwd: String,
        name: String = "session.jsonl",
        modifiedAt date: Date
    ) throws -> URL {
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        let directory = claudeRoot.appendingPathComponent(encoded, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data("{}\n".utf8).write(to: file)
        try setModificationDate(date, on: file)
        return file
    }

    @discardableResult
    private func makeCodexRollout(
        cwd: String,
        name: String = "rollout-live.jsonl",
        modifiedAt date: Date,
        calendar: Calendar
    ) throws -> URL {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let directory = codexRoot
            .appendingPathComponent(String(format: "%04d", components.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day!), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        let line = #"{"type":"session_meta","payload":{"cwd":"\#(cwd)"}}"# + "\n{}\n"
        try Data(line.utf8).write(to: file)
        try setModificationDate(date, on: file)
        return file
    }

    private func setModificationDate(_ date: Date, on file: URL) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
