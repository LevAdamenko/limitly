import Foundation

/// Decides when the Codex rate-limit probe is worth paying for.
///
/// Each probe starts a process and makes an HTTPS request, so the network
/// radio wakes along with the CPU. Codex's figure only moves while Codex is
/// in use, so a quiet machine needs only a slow check — which still catches
/// usage on another device, since those write no local logs.
public struct CodexProbePolicy: Sendable {
    public struct State: Equatable, Sendable {
        public var lastAttempt: Date?
        public var logsChangedSinceProbe: Bool
        public var lastAttemptFailed: Bool
        /// The popover is open, so somebody is reading the number right now.
        public var isForeground: Bool

        public init(lastAttempt: Date? = nil, logsChangedSinceProbe: Bool = false, lastAttemptFailed: Bool = false, isForeground: Bool = false) {
            self.lastAttempt = lastAttempt
            self.logsChangedSinceProbe = logsChangedSinceProbe
            self.lastAttemptFailed = lastAttemptFailed
            self.isForeground = isForeground
        }
    }

    public var foregroundInterval: TimeInterval
    public var activeInterval: TimeInterval
    public var idleInterval: TimeInterval

    public init(foregroundInterval: TimeInterval = 30, activeInterval: TimeInterval = 60, idleInterval: TimeInterval = 5 * 60) {
        self.foregroundInterval = foregroundInterval
        self.activeInterval = activeInterval
        self.idleInterval = idleInterval
    }

    public func isDue(now: Date, state: State) -> Bool {
        guard let last = state.lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(last)
        if elapsed < 0 { return true }
        if state.isForeground { return elapsed >= foregroundInterval }
        if state.logsChangedSinceProbe || state.lastAttemptFailed { return elapsed >= activeInterval }
        return elapsed >= idleInterval
    }
}
