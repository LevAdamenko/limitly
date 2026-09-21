import XCTest
@testable import LimitlyCore

/// This installer edits the user's real `~/.claude/settings.json`, so the
/// interesting cases here are all about *not losing* what is already in it.
/// Every test runs entirely inside a temporary directory.
final class ClaudeStatusLineInstallerTests: XCTestCase {
    private var root: URL!
    private var settingsURL: URL!
    private var limitlyDir: URL!
    private var scriptURL: URL!
    private var chainURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("limitly-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        settingsURL = root.appendingPathComponent(".claude/settings.json")
        limitlyDir = root.appendingPathComponent(".limitly")
        scriptURL = limitlyDir.appendingPathComponent("statusline.sh")
        chainURL = limitlyDir.appendingPathComponent("statusline-chain")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeSettings(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: settingsURL)
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func install() throws { try ClaudeStatusLineInstaller.install(settingsURL: settingsURL, limitlyDir: limitlyDir) }
    private func uninstall() throws { try ClaudeStatusLineInstaller.uninstall(settingsURL: settingsURL, limitlyDir: limitlyDir) }
    private func state() -> ClaudeStatusLineInstaller.State {
        ClaudeStatusLineInstaller.state(settingsURL: settingsURL, chainURL: chainURL, scriptURL: scriptURL)
    }

    func testInstallLeavesEveryOtherSettingUntouched() throws {
        try writeSettings([
            "model": "opus",
            "theme": "light",
            "modelSettings": ["claude-opus-5": ["effortLevel": "high"]],
            "voice": ["enabled": true, "mode": "hold"]
        ])

        try install()

        let settings = try readSettings()
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertEqual(settings["theme"] as? String, "light")
        XCTAssertEqual((settings["voice"] as? [String: Any])?["mode"] as? String, "hold")
        XCTAssertEqual(
            ((settings["modelSettings"] as? [String: Any])?["claude-opus-5"] as? [String: Any])?["effortLevel"] as? String,
            "high"
        )
        XCTAssertEqual((settings["statusLine"] as? [String: Any])?["command"] as? String, scriptURL.path)
        XCTAssertEqual((settings["statusLine"] as? [String: Any])?["type"] as? String, "command")
    }

    /// The hard requirement: someone who already has a status line must not
    /// silently lose it.
    func testAnExistingStatusLineIsChainedNotDestroyed() throws {
        let existing = "~/bin/my-status-line.sh --fancy"
        try writeSettings(["statusLine": ["type": "command", "command": existing, "padding": 0]])

        try install()

        XCTAssertEqual(try String(contentsOf: chainURL, encoding: .utf8), existing)
        XCTAssertEqual(state(), .installedAlongside(existing: existing))
        XCTAssertEqual((try readSettings()["statusLine"] as? [String: Any])?["command"] as? String, scriptURL.path)
    }

    func testUninstallRestoresTheChainedCommand() throws {
        let existing = "~/bin/my-status-line.sh --fancy"
        try writeSettings(["model": "opus", "statusLine": ["type": "command", "command": existing]])

        try install()
        try uninstall()

        let settings = try readSettings()
        XCTAssertEqual((settings["statusLine"] as? [String: Any])?["command"] as? String, existing)
        XCTAssertEqual(settings["model"] as? String, "opus")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptURL.path))
        XCTAssertEqual(state(), .notInstalled)
    }

    func testUninstallRemovesTheStatusLineKeyItCreatedItself() throws {
        try writeSettings(["model": "opus"])

        try install()
        try uninstall()

        let settings = try readSettings()
        XCTAssertNil(settings["statusLine"])
        XCTAssertEqual(settings["model"] as? String, "opus")
    }

    func testInstallIsIdempotentAndDoesNotChainToItself() throws {
        try writeSettings(["model": "opus"])

        try install()
        try install()
        try install()

        XCTAssertFalse(FileManager.default.fileExists(atPath: chainURL.path), "chaining to our own script would recurse")
        XCTAssertEqual(state(), .installed)
    }

    func testInstallBacksUpTheSettingsFileBeforeTouchingIt() throws {
        try writeSettings(["model": "opus", "theme": "light"])
        let before = try Data(contentsOf: settingsURL)

        try install()

        let backups = try FileManager.default
            .contentsOfDirectory(atPath: settingsURL.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("settings.json.backup-") }
        XCTAssertEqual(backups.count, 1)
        let backup = settingsURL.deletingLastPathComponent().appendingPathComponent(backups[0])
        XCTAssertEqual(try Data(contentsOf: backup), before)
    }

    func testInstallCreatesAnExecutableScript() throws {
        try install()

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scriptURL.path))
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
    }

    func testMissingSettingsFileIsCreatedRatherThanRefused() throws {
        try install()

        XCTAssertEqual((try readSettings()["statusLine"] as? [String: Any])?["command"] as? String, scriptURL.path)
    }

    /// Better to stop than to overwrite a file we could not understand.
    func testMalformedSettingsAreRefusedNotOverwritten() throws {
        try "{ this is not json".write(to: settingsURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try install())
        XCTAssertEqual(try String(contentsOf: settingsURL, encoding: .utf8), "{ this is not json")
        guard case .claudeSettingsUnreadable = state() else {
            return XCTFail("expected the unreadable state, got \(state())")
        }
    }

    func testUninstallLeavesSomebodyElsesStatusLineAlone() throws {
        let other = "~/bin/somebody-elses.sh"
        try writeSettings(["statusLine": ["type": "command", "command": other]])

        try uninstall()

        XCTAssertEqual((try readSettings()["statusLine"] as? [String: Any])?["command"] as? String, other)
    }
}
