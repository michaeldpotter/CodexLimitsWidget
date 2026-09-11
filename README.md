# CodexLimitsWidget[^vibe]

![preview](Resources/preview.jpeg)

A native macOS app with a WidgetKit desktop widget that shows the remaining
Codex limits without opening an interactive Codex CLI session.

The widget uses `codex app-server` and the `account/rateLimits/read` method, so
it reads the same source of data that backs `/status` in the Codex CLI.

**CodexLimitsWidget is an independent project and is not affiliated with,
endorsed by, or sponsored by OpenAI.**

## Contents

- `Sources/CodexLimitsHost.swift` - a small host app that syncs an auth snapshot.
- `Sources/CodexLimitsWidget.swift` - the WidgetKit extension that reads and renders limits.
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
build/Codex Limits.app
```

## Install

```sh
./install-widget.sh
```

The script:

- rebuilds the app;
- installs it to `/Applications/Codex Limits.app`;
- removes the old `/Applications/CodexLimits.app` bundle if it is still present;
- registers the app through Launch Services;
- opens the host app.

After installation, open the macOS widget gallery and search for `Codex Limits`.
The app provides small and medium versions of `Codex Limits` and a small
`Usage Pace` gauge. Small widgets focus on the standard weekly allotment
and usage pace; Spark buckets are reserved for the detailed medium widget. When
available, the widgets also show Full Reset credits and their
expirations.[^gatekeeper]

Small and medium `Codex Limits` widgets include a usage pace bar comparing the
fraction of the weekly allotment used with the fraction of the week elapsed.
A sustainable pace (for example, 50% used halfway through the week) places the
marker at 60% of the scale, within green. Yellow begins around 1.17× sustainable
pace; red begins at 1.5×. With 28% left and nearly four days until reset, the
marker is in red because usage is running about 1.6× sustainable pace.
As time passes without more usage, the marker moves back toward green.
The gauge uses the same scale and marker calculation around a three-quarter
tachometer-style arc. This is an average since the start of the weekly window,
not a measurement of recent activity.

## Authentication

The WidgetKit extension runs in a sandbox and does not read the user's
`~/.codex/auth.json` directly. Instead, the host app copies a short auth snapshot
into the widget extension's Application Support directory on launch and when the
`Refresh Widget` button is pressed. The container location is resolved at runtime
from the bundled widget extension.

The snapshot stores only:

- access token;
- account id;
- plan type;
- update timestamp.

The refresh token is not copied.

## Refresh cadence

The widget asks WidgetKit to refresh its timeline every 5 minutes. macOS may
delay or throttle widget updates, so this is a requested cadence rather than a
strict timer. Opening the host app and pressing `Refresh Widget` forces an
earlier timeline reload.

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

1. Open `/Applications/Codex Limits.app`.
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
