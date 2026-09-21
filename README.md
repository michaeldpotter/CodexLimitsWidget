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

The Codex and Claude widgets include a usage pace bar comparing the
original daily budget with the daily budget still available until weekly reset.
The marker is `0.6 × fraction of week remaining / fraction of allotment remaining`,
capped at 100%. Balanced usage (for example, 50% used halfway through the week)
places the marker at 60% of the scale, within green. Yellow begins when the
remaining daily allowance is about 14% below the original daily budget; red
begins when it is one-third below. These are indicator thresholds, not service limits.

With 92% left and 6 days 19 hours until reset, about 13.6% per day remains
available versus the original 14.3% per day, so the marker stays green. With
only 5% left and a full day remaining, it reaches red. As time passes without
more usage, the marker moves back toward green. Exhausted allotments stay red
until reset; expired windows have no pace indicator until fresh data arrives.
The small gauge uses the same calculation around a three-quarter tachometer-style
arc. This measures remaining budget pressure, not recent activity or a prediction
of future usage.

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
