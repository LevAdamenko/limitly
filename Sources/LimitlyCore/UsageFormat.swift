import Foundation

/// Human-sized numbers for the popover. Claude Code counts cache reads as
/// tokens, so a normal week is hundreds of millions — "412,345,678 tokens"
/// is unreadable, "412M tokens" is not.
public enum UsageFormat {
    public static func compactTokens(_ tokens: UInt64) -> String {
        let value = Double(tokens)
        let (scaled, suffix): (Double, String) = switch value {
        case 1_000_000_000...: (value / 1_000_000_000, "B")
        case 1_000_000...: (value / 1_000_000, "M")
        case 1_000...: (value / 1_000, "K")
        default: (value, "")
        }
        let digits = suffix.isEmpty || scaled >= 100 ? 0 : 1
        let text = String(format: "%.\(digits)f", scaled)
            .replacingOccurrences(of: ".0", with: "")
        return "\(text)\(suffix) tokens"
    }

    /// Dollars at API list prices, as ccusage computes them — on a
    /// subscription this is what the same usage would have cost, not a bill.
    public static func dollars(_ amount: Double) -> String {
        guard amount.isFinite, amount >= 0 else { return "$0" }
        return amount >= 100 ? "$\(Int(amount.rounded()))" : String(format: "$%.2f", amount)
    }

    /// Percentages shown to the user are clamped: a provider never reports
    /// more than 100% of a window, and anything outside 0...100 is a bug
    /// upstream that must not reach the menu bar as "4,812,000%".
    public static func clampedPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 100)
    }
}
