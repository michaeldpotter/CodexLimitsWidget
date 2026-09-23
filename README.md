# AI Usage[^vibe]

![preview](Resources/preview.jpeg)

Native macOS widgets for Codex and Claude usage, with weekly pace indicators,
reset times, and a combined side-by-side view. Formerly named Codex Limits.

The widget uses `codex app-server` and the `account/rateLimits/read` method, so
it reads the same source of data that backs `/status` in the Codex CLI.

**AI Usage is an independent project and is not affiliated with,
endorsed by, or sponsored by OpenAI or Anthropic.**

## Contents

- `Sources/CodexLimitsHost.swift` - a small host app that syncs an auth snapshot.
- `Sources/CodexLimitsWidget.swift` - the WidgetKit extension that reads and renders limits.
- `Sources/MediumLimitsView.swift` - the side-by-side Codex and Claude layout.
- `Sources/ClaudeUsage.swift` / `ClaudeUsageClient.swift` - Claude usage snapshots and host-side fetching.
- `Resources` - `Info.plist`, entitlements, and the app/widget icon.
- `codex-limits` - a CLI script for printing limits without the interactive TUI.
- `build-widget.sh` - builds the `.app` bundle.
- `install-widget.sh` - builds, installs into `/Applications`, and registers the widget.

## Requirements

- macOS with WidgetKit desktop widget support.
- Apple Silicon target (`arm64-apple-macosx14.0` in `build-widget.sh`).
- Installed `swiftc` / `Xcode Command Line Tools`.
- Installed and authenticated [`Codex CLI`](https://developers.openai.com/codex/cli).

## Build

```sh
./build-widget.sh
```

The app bundle is created at:

```text
build/AI Usage.app
```

## Install

```sh
./install-widget.sh
```

The script:

- rebuilds the app;
- installs it to `/Applications/AI Usage.app`;
- removes the old `/Applications/Codex Limits.app` and `/Applications/CodexLimits.app` bundles if present;
- registers the app through Launch Services;
- opens the host app.

After installation, open the macOS widget gallery and search for `AI Usage`.
The app provides a combined `AI Usage` widget, individual small `Codex Limits`
and `Claude Limits` widgets, and the small `Usage Pace` gauge. Existing widgets
and saved data remain connected: bundle identifiers, widget kinds, and storage
paths are unchanged. The original combined entry also keeps its small size for
compatibility with existing Codex widgets.

The Claude widget uses the existing host refresh and does not need a Codex
connection. Small widgets focus on the standard weekly allotment
and usage pace. The medium widget shows Codex weekly usage, pace, and Full Reset
count and expiration dates on the left, with Claude five-hour and weekly usage
on the right. Both columns show the percentage remaining and reset times. A
single update time sits at the lower right and uses the older provider timestamp
when both are available.[^gatekeeper]

The Codex and Claude widgets include a usage pace bar comparing the fraction of
allotment used with the fraction of the weekly window elapsed. A fresh allotment
starts at the far left. After a six-hour startup grace period, balanced usage
(for example, 50% used halfway through the week) puts the marker at the
green/yellow boundary, 70% across the scale. Slower usage stays green; faster
usage moves through yellow into red at about 1.29 times the even weekly pace.
These are indicator thresholds, not service limits.

The marker is `0.7 × used fraction / max(elapsed fraction, six hours / window duration)`,
capped at 100%. During the first six hours, the denominator stays at six hours'
normal allowance to soften small early bursts. This is a startup allowance,
not a rolling measurement of recent activity. With 1% used just after a weekly
reset, the marker is about 20% across the bar; with no usage, it remains at zero.
As time passes without more usage, the marker moves left after the grace period.
Exhausted allotments stay at the far right until reset; expired windows have no
pace indicator until fresh data arrives. The small gauge uses the same calculation
around a three-quarter tachometer-style arc. The bar reflects average usage since
the current window began, not a prediction of future activity.

## Authentication

The WidgetKit extension runs in a sandbox and does not read the user's
`~/.codex/auth.json` directly. Instead, the host app copies a short auth snapshot
into the widget extension's Application Support directory on launch, every five
minutes while running, and when the `Refresh Widget` button is pressed. The container location is resolved at runtime
from the bundled widget extension.

The snapshot stores only:

- access token;
- account id;
- plan type;
- update timestamp.

The refresh token is not copied.

### Claude usage

Sign in to Claude Code with your Claude subscription, then open the host app or
press `Refresh Widget`. The host reads the default macOS `Claude Code-credentials`
Keychain entry and calls Claude's OAuth usage endpoint. It reads the current
access token on each refresh; it does not refresh tokens or modify Claude Code's
credentials. API-key billing, custom Claude config directories, and alternate
credential stores are not supported.

Only the subscription tier, five-hour and weekly usage percentages, reset times, update time, and
safe error messages are written to `claude-usage.json` in the widget container.
Claude credentials stay in memory and are never copied to the widget. Claude's
OAuth usage endpoint is an internal interface and may change independently of
this app.

The host refreshes every five minutes while running. Closing its window keeps
updates running; quitting the app or restarting the Mac requires reopening it.
The widget marks Claude data **Stale** after 15 minutes without a successful
update, and hides expired-window percentages until fresh data arrives. Each
provider has its own error display. Authentication failures pause Claude checks
until you sign in through Claude Code and press `Refresh Widget`; rate limiting
backs off for at least 15 minutes and respects longer `Retry-After` responses.

## Refresh cadence

The widget asks WidgetKit to refresh its timeline every 5 minutes. macOS may
delay or throttle widget updates, so this is a requested cadence rather than a
strict timer. Opening the host app and pressing `Refresh Widget` forces an
earlier timeline reload.

## Verification

```sh
python3 Tests/test_claude_usage.py
python3 Tests/test_weekly_pace.py
./build-widget.sh
```

## CLI

Print limits in the terminal:

```sh
./codex-limits
```

Print the raw JSON response:

```sh
./codex-limits --json
```

Show all buckets if the Codex CLI returns more than one:

```sh
./codex-limits --all
```

## Troubleshooting

If the widget appears but does not show limits:

1. Open `/Applications/AI Usage.app`.
2. Press `Refresh Widget`.
3. Make sure the `codex` CLI is authenticated and available from `PATH`.
4. Rebuild and reinstall:

```sh
./install-widget.sh
```

## License

The source code is licensed under the MIT License. See [LICENSE](LICENSE).
This license does not apply to `Resources/CodexLimits.icns`, which is a
third-party brand asset and is not sublicensed under MIT.

[^vibe]: This project is fully vibe-coded, from development to publication.
[^gatekeeper]: Release builds are ad-hoc signed and not Apple-notarized, so macOS Gatekeeper may show a warning the first time the downloaded app is opened.
