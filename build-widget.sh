#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
SIGNING_IDENTITY="${AI_USAGE_SIGNING_IDENTITY:--}"
BACKGROUND_ENABLED=false
if [[ "$SIGNING_IDENTITY" == "Developer ID Application:"* || "${AI_USAGE_EXPERIMENTAL_BACKGROUND:-0}" == "1" ]]; then
  BACKGROUND_ENABLED=true
fi
APP="$BUILD_DIR/AI Usage.app"
APP_CONTENTS="$APP/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_PLUGINS="$APP_CONTENTS/PlugIns"
EXT="$APP_PLUGINS/CodexLimitsWidgetExtension.appex"
EXT_CONTENTS="$EXT/Contents"
EXT_MACOS="$EXT_CONTENTS/MacOS"
EXT_RESOURCES="$EXT_CONTENTS/Resources"
rm -rf "$APP"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_PLUGINS" "$EXT_MACOS" "$EXT_RESOURCES"
mkdir -p "$APP_CONTENTS/Helpers" "$APP_CONTENTS/Library/LaunchAgents"
cp "$ROOT/Resources/com.pugalol.aiusage.refresh.plist" "$APP_CONTENTS/Library/LaunchAgents/"
cp "$ROOT/Resources/AppInfo.plist" "$APP_CONTENTS/Info.plist"
cp "$ROOT/Resources/WidgetInfo.plist" "$EXT_CONTENTS/Info.plist"
cp "$ROOT/Resources/AIUsage.icns" "$APP_RESOURCES/AIUsage.icns"
cp "$ROOT/Scripts/claude-usage.py" "$APP_RESOURCES/claude-usage.py"
cp "$ROOT/Resources/AIUsage.icns" "$EXT_RESOURCES/AIUsage.icns"
/usr/libexec/PlistBuddy -c "Add :AIUsageBackgroundEnabledBuild bool $BACKGROUND_ENABLED" "$APP_CONTENTS/Info.plist"
printf "APPL????" > "$APP_CONTENTS/PkgInfo"
swiftc \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  -target arm64-apple-macosx14.0 \
  -parse-as-library \
  -O \
  -framework SwiftUI \
  -framework WidgetKit \
  "$ROOT/Sources/CodexLimitsHost.swift" \
  "$ROOT/Sources/CodexUsage.swift" \
  "$ROOT/Sources/UsageStore.swift" \
  -o "$APP_MACOS/CodexLimits"
swiftc \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  -target arm64-apple-macosx14.0 \
  -application-extension \
  -parse-as-library \
  -O \
  -framework SwiftUI \
  -framework WidgetKit \
  -Xlinker -e \
  -Xlinker _NSExtensionMain \
  "$ROOT/Sources/CodexUsage.swift" \
  "$ROOT/Sources/UsageStore.swift" \
  "$ROOT/Sources/CodexLimitsWidget.swift" \
  "$ROOT/Sources/MediumLimitsView.swift" \
  "$ROOT/Sources/ClaudeLimitsWidget.swift" \
  "$ROOT/Sources/ClaudeUsage.swift" \
  -o "$EXT_MACOS/CodexLimitsWidgetExtension"
swiftc \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  -target arm64-apple-macosx14.0 \
  -parse-as-library -O \
  "$ROOT/Sources/AIUsageHelper.swift" \
  "$ROOT/Sources/CodexSession.swift" \
  "$ROOT/Sources/CodexUsage.swift" \
  "$ROOT/Sources/UsageStore.swift" \
  "$ROOT/Sources/UsageWorker.swift" \
  -o "$APP_CONTENTS/Helpers/AIUsageHelper"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$APP_CONTENTS/Helpers/AIUsageHelper"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements "$ROOT/Resources/Widget.entitlements" "$EXT"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements "$ROOT/Resources/App.entitlements" "$APP"
echo "$APP"
