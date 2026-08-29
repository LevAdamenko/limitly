# Limitly

Native macOS menu-bar app that shows live Claude Code and Codex CLI usage against
user-defined budgets. It polls read-only local data through ccusage every five
seconds and alerts on current-day thresholds, weekly thresholds, and an
active-to-idle polling proxy.

The app invokes:

```
npx --yes ccusage@latest daily --json --by-agent --since YYYY-MM-DD --offline
npx --yes ccusage@latest blocks --json --active --offline
```

The daily report supplies current-day and trailing-seven-day usage. `blocks` is
currently emitted by ccusage for Claude billing blocks, so Limitly displays its
"resets in" line for Claude only; it does not invent a Codex reset time.

Run locally with `swift run LimitlyApp`. The embedded Info.plist uses
`LSUIElement`, so the app is menu-bar-only and has no Dock icon.
