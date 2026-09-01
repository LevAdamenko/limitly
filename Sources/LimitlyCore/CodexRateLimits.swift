import Foundation

/// OpenAI's own real Codex usage figures, as reported by the `codex` CLI's
/// local app-server (`account/rateLimits/read`) — the same numbers the CLI's
/// own status line uses, not a locally-derived approximation. `primary` is
/// the ~5-hour session window (mirrors Claude's "five hour" figure);
/// `secondary` is the ~7-day weekly window.
public struct CodexRateLimitSnapshot: Equatable, Sendable {
    public let fiveHourPercent: Double
    public let weeklyPercent: Double?
    public let sessionResetTime: Date?
    public let weeklyResetTime: Date?

    public init(fiveHourPercent: Double, weeklyPercent: Double?, sessionResetTime: Date?, weeklyResetTime: Date?) {
        self.fiveHourPercent = fiveHourPercent
        self.weeklyPercent = weeklyPercent
        self.sessionResetTime = sessionResetTime
        self.weeklyResetTime = weeklyResetTime
    }
}

public enum CodexRateLimitParser {
    /// `rpcOutput` is the app-server's newline-delimited JSON-RPC stdout.
    /// The caller always sends the `account/rateLimits/read` request as id
    /// 2, so this scans for that response line and ignores everything else,
    /// including the `initialize` reply and any notifications the server
    /// interleaves ahead of it.
    public static func parse(_ rpcOutput: String) -> CodexRateLimitSnapshot? {
        for line in rpcOutput.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let response = try? JSONDecoder().decode(RPCResponse.self, from: data),
                  response.id == 2,
                  let limits = response.result?.rateLimits,
                  // A `null` primary window means the app-server has no real
                  // data yet (e.g. right after wake, before it's reconnected)
                  // — treat that as "no update" rather than defaulting to a
                  // false 0%, which would otherwise get cached for
                  // `refreshInterval` and clobber the last known-good value.
                  let primary = limits.primary else { continue }
            return CodexRateLimitSnapshot(
                fiveHourPercent: primary.usedPercent,
                // Missing `secondary` (e.g. a plan without a weekly window,
                // or a transient partial response) means "no data" — same
                // reasoning as the `primary` guard above. Defaulting to 0
                // here would mask a real near-threshold weekly usage.
                weeklyPercent: limits.secondary?.usedPercent,
                sessionResetTime: primary.resetsAt.map { Date(timeIntervalSince1970: Double($0)) },
                weeklyResetTime: limits.secondary?.resetsAt.map { Date(timeIntervalSince1970: Double($0)) }
            )
        }
        return nil
    }

    private struct RPCResponse: Decodable { let id: Int?; let result: RPCResult? }
    private struct RPCResult: Decodable { let rateLimits: RateLimits? }
    private struct RateLimits: Decodable { let primary: Window?; let secondary: Window? }
    private struct Window: Decodable { let usedPercent: Double; let resetsAt: Int64? }
}
