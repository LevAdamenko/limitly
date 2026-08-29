# Limitly

Native macOS menu-bar app that shows live Claude Code and Codex CLI usage,
with alerts on current-session thresholds, weekly thresholds, and idle
periods.

## Where the numbers come from

- **Claude** — Anthropic's own real "five hour" and "seven day" usage
  percentages, read from the Claude desktop app's local cache
  (`~/Library/Application Support/Claude/plan-usage-history.json`). That file
  is only refreshed by the app every ~15 minutes, so the current value is
  linearly extrapolated forward from the last two samples to stay accurate
  between refreshes.
- **Codex** — OpenAI's own real rate-limit usage, read live from the `codex`
  CLI's local app-server (`codex app-server`, JSON-RPC method
  `account/rateLimits/read`) — the same figures the CLI's own status line
  uses.
- Token/dollar totals shown alongside the percentages come from
  [`ccusage`](https://github.com/ryoppippi/ccusage), invoked via `npx` against
  each tool's local usage logs.

If either real source is unavailable (e.g. `codex` isn't installed, or
Claude.app has never run), Limitly falls back to a percentage estimated
against a user-configured budget instead of failing outright.

## Requirements

- macOS 14+
- [Node.js](https://nodejs.org) (`npx`) on `PATH`, for `ccusage`
- For accurate Claude %: the Claude desktop app, installed and signed in
- For accurate Codex %: the [`codex`](https://github.com/openai/codex) CLI,
  installed and authenticated

## Features

- Menu-bar percentage for both agents, with a real system-level alert banner
  (or native macOS notification) on threshold/weekly/idle events
- Settings: per-agent budget & thresholds, alert delivery mode, idle timeout,
  and a "Used" vs "Remaining" percentage display toggle
- A "Send test alert" button in Settings to preview banner placement and
  sound without waiting for a real threshold

## Running

```
swift run LimitlyApp
```

The embedded Info.plist sets `LSUIElement`, so the app is menu-bar-only and
has no Dock icon.

## Tests

```
swift test
```
