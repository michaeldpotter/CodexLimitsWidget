# AI Usage[^vibe]

![preview](Resources/preview.jpeg)

Native macOS widgets for Codex and Claude usage, with weekly pace indicators and
reset times. Formerly named Codex Limits. Claude uses an experimental Claude Code
terminal integration.

The helper uses `codex app-server` and the `account/rateLimits/read` method, so
it reads the same source of data that backs `/status` in the Codex CLI.

**AI Usage is an independent project and is not affiliated with,
endorsed by, or sponsored by OpenAI or Anthropic.**

## Contents

- `Sources/CodexLimitsHost.swift` - sign-in, manual refresh, and background-service controls.
- `Sources/AIUsageHelper.swift` / `UsageWorker.swift` - isolated managed Codex sessions and background refresh.
- `Sources/CodexSession.swift` - bounded app-server client with strict Keychain storage.
- `Sources/CodexUsage.swift` / `UsageStore.swift` - usage parsing and nonsecret snapshots.
- `Sources/CodexLimitsWidget.swift` - the WidgetKit extension that reads and renders limits.
- `Sources/MediumLimitsView.swift` - the side-by-side Codex and Claude layout.
- `Sources/ClaudeUsage.swift` - Claude display models and snapshot loading.
- `Scripts/claude-usage.py` - bounded Claude Code `/usage` collector.
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

Claude widgets read the snapshot produced by Claude Code’s built-in `/usage`
command. This build does not read Claude Code credentials or call its internal
usage endpoint directly. Both providers refresh through the background helper.

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

Choose **Connect Codex** in AI Usage and complete the official browser sign-in.
The helper uses Codex's managed ChatGPT login with
`cli_auth_credentials_store = "keyring"`; it checks the effective configuration
and fails if strict Keychain storage is not active. Codex owns token renewal.
AI Usage does not read your existing `~/.codex/auth.json` or copy tokens.

The app uses its own persistent Codex home at
`~/Library/Application Support/AI Usage/Codex`, so this sign-in is separate from
your normal CLI login. **Disconnect** stops the registered background service,
logs out that dedicated profile, and clears its displayed usage. It does not log
out your usual Codex CLI account.

Only parsed usage data, safe status values, timestamps, and retry timing are
written to `codex-usage.json` in the widget container. The widget has no network
or external executable permissions. Missing or expired credentials require
reconnecting; data older than 15 minutes is marked stale rather than displayed
as current. Failed background attempts back off for 15 minutes across restarts.

On the first successful fetch, the helper removes the old widget-local
`external-auth.json` credential copy. Failure to remove it is reported as a
migration error. This cleanup does not touch provider-owned credential files.
Until a successful connection, the old copy may still exist, but this build never
reads it. Disconnect also attempts this cleanup.

### Background updates and signing

An ad-hoc development build supports sign-in and manual refresh. Background
registration is disabled because ad-hoc helper upgrades failed in integration
testing. Build with a stable Developer ID identity to enable the opt-in toggle:

```sh
AI_USAGE_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./build-widget.sh
```

For local testing with ad hoc signing, run
`AI_USAGE_EXPERIMENTAL_BACKGROUND=1 ./install-widget.sh`, then enable the toggle.
This explicitly bypasses the development-build restriction; helper registration
and Keychain access may need recovery after rebuilding or replacing the app.

With a signed build installed, turn on **Update in the background**. macOS may
require approval in Login Items Settings; the app provides a button to open it.
Registration is never automatic. The per-user helper checks approximately every
five minutes even when the main app is quit. Sleep, login state, system scheduling,
and WidgetKit determine actual update timing.

Turn off background updates before removing the application. The install script
unregisters an existing new-style service before replacing its executable; turn
background updates back on after an upgrade. Developer ID registration, upgrade,
and real-account renewal still require integration validation with that signing
identity; the default ad-hoc build is not proof of those paths.

### Claude

The helper runs the installed Claude Code in a private PTY and invokes its built-in
`/usage` command. Claude Code owns authentication; AI Usage never reads its
credentials and sends no model prompt. Sign in to Claude Code once before using
**Refresh** or enabling background updates. The collector requires `/usr/bin/python3`
(available with Xcode Command Line Tools) and Claude Code's `--safe-mode` and
`--ax-screen-reader` options.

This is an experimental terminal integration, not a stable usage API. It waits
for the cached display's refresh to complete before saving percentages and reset
times to `claude-cli-usage.json` in the widget container. Unsupported output,
sign-in problems, and timeouts preserve the previous timestamp and show an error;
background failures back off for 15 minutes. CLI layout changes may require a
parser update. Reset times have the precision shown by Claude Code. The collector
uses a dedicated empty directory, disables customizations/tools and auto-updates,
and bounds each session to 50 seconds plus termination cleanup. Claude and Codex
fail independently. No raw terminal output is saved.

## Verification

```sh
python3 Tests/test_claude_cli.py
python3 Tests/test_claude_usage.py
python3 Tests/test_weekly_pace.py
python3 Tests/test_managed_usage.py
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
2. Choose `Connect Codex` and complete sign-in, then press `Refresh`.
3. Make sure Codex CLI is installed in `/opt/homebrew/bin` or `/usr/local/bin`.
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
