import Foundation
import SwiftUI
import WidgetKit

struct CodexLimitsEntry: TimelineEntry {
    let date: Date
    let limits: CodexLimits
    var claude: ClaudeUsageSnapshot = .unavailable
}

enum ResetDisplayStyle {
    case relative
    case absolute
}

private enum ResetDateFormat {
    static let date = "MM/dd"
    static let dateAndTime = "\(date) HH:mm"
}

struct CodexLimitsProvider: TimelineProvider {
    func placeholder(in context: Context) -> CodexLimitsEntry {
        CodexLimitsEntry(date: Date(), limits: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (CodexLimitsEntry) -> Void) {
        completion(CodexLimitsEntry(date: Date(), limits: CodexLimitsReader.read(), claude: claudeUsage()))
    }

    private func claudeUsage() -> ClaudeUsageSnapshot {
        .readForWidget()
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexLimitsEntry>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let now = Date()
            let entry = CodexLimitsEntry(date: now, limits: CodexLimitsReader.read(), claude: claudeUsage())
            let nextRefresh = Calendar.current.date(byAdding: .minute, value: 5, to: now) ?? now.addingTimeInterval(300)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }
}

struct CodexLimitsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CodexLimitsEntry
    let resetDisplayStyle: ResetDisplayStyle

    var body: some View {
        if family == .systemMedium {
            MediumLimitsView(entry: entry, resetDisplayStyle: resetDisplayStyle)
                .containerBackground(.background, for: .widget)
        } else {
            smallBody
        }
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 6) {
            header
            if let error = entry.limits.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            } else {
                windowsView
                if visibleWindows.isEmpty {
                    Text("No usage windows returned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if family != .systemMedium, weeklyPace == nil, let credits = entry.limits.resetCredits {
                    ResetCreditRow(summary: credits)
                }
                if let status = entry.limits.status {
                    Text(status.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                if family != .systemMedium {
                    Spacer(minLength: 0)
                    Text("Updated \(entry.limits.updatedAt, style: .time)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .frame(
                            maxWidth: .infinity,
                            alignment: family == .systemSmall ? .center : .leading
                        )
                }
            }
        }
        .padding(.vertical, family == .systemSmall ? 12 : 6)
        .padding(.horizontal, family == .systemSmall ? 8 : 2)
        .containerBackground(.background, for: .widget)
    }

    @ViewBuilder
    private var windowsView: some View {
        if let weeklyPace, let weeklyWindow {
            SmallWeeklyPaceRow(
                window: weeklyWindow,
                pace: weeklyPace,
                credits: entry.limits.resetCredits,
                resetDisplayStyle: resetDisplayStyle
            )
        } else {
            ForEach(Array(visibleWindows.enumerated()), id: \.offset) { _, window in
                LimitRow(window: window, resetDisplayStyle: resetDisplayStyle)
            }
        }
    }

    private var visibleWindows: [LimitWindow] {
        let candidates = family == .systemSmall
            ? entry.limits.windows.filter { !isSpark($0) }
            : entry.limits.windows
        let maximum: Int
        if family == .systemSmall {
            maximum = entry.limits.resetCredits == nil ? 2 : 1
        } else {
            maximum = 4
        }
        return Array(candidates.prefix(maximum))
    }

    private var weeklyWindow: LimitWindow? {
        entry.limits.windows.first(where: { $0.durationMinutes == 10_080 && !isSpark($0) })
    }

    private func isSpark(_ window: LimitWindow) -> Bool {
        window.name.localizedCaseInsensitiveContains("spark")
    }

    private var weeklyPace: WeeklyPace? {
        weeklyWindow.flatMap { WeeklyPace(window: $0, now: entry.date) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Codex")
                .font(.headline.weight(.semibold))
            Spacer(minLength: 6)
            if let plan = entry.limits.plan {
                Text(plan.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        }
    }
}

struct WeeklyPace {
    let usedFraction: Double
    let targetFraction: Double

    init?(window: LimitWindow, now: Date) {
        guard
            let usedPercent = window.usedPercent,
            let resetDate = window.resetDate,
            resetDate > now,
            let durationMinutes = window.durationMinutes,
            durationMinutes > 0
        else {
            return nil
        }
        let duration = TimeInterval(durationMinutes * 60)
        let remainingFraction = resetDate.timeIntervalSince(now) / duration
        usedFraction = min(1, max(0, Double(usedPercent) / 100))
        targetFraction = min(1, max(0, 1 - remainingFraction))
    }

    /// Compares the original daily budget with the daily budget still available.
    /// Balanced usage sits at 60%; needing a one-third reduction reaches red.
    var markerFraction: Double {
        let remainingUsage = 1 - usedFraction
        guard remainingUsage > 0 else { return 1 }
        return min(1, 0.6 * (1 - targetFraction) / remainingUsage)
    }
}

enum WeeklyPaceScale {
    static let greenFraction = 0.7
    static let yellowFraction = 0.2
    static let redFraction = 0.1
    static let circularMarkerInset = 0.02
    static let gaugeArcFraction = 0.75
    static let gaugeStartRotation = 135.0

    static func markerFraction(for pace: WeeklyPace) -> Double {
        circularMarkerInset
            + (1 - 2 * circularMarkerInset) * pace.markerFraction
    }

    static func gaugeMarkerFraction(for pace: WeeklyPace) -> Double {
        gaugeArcFraction * markerFraction(for: pace)
    }
}

struct WeeklyPaceGauge: View {
    let pace: WeeklyPace

    var body: some View {
        ZStack {
            Circle()
                .trim(
                    from: 0,
                    to: WeeklyPaceScale.gaugeArcFraction * WeeklyPaceScale.greenFraction
                )
                .stroke(.green.opacity(0.82), style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                .rotationEffect(.degrees(WeeklyPaceScale.gaugeStartRotation))
            Circle()
                .trim(
                    from: WeeklyPaceScale.gaugeArcFraction * WeeklyPaceScale.greenFraction,
                    to: WeeklyPaceScale.gaugeArcFraction
                        * (WeeklyPaceScale.greenFraction + WeeklyPaceScale.yellowFraction)
                )
                .stroke(.yellow.opacity(0.9), style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                .rotationEffect(.degrees(WeeklyPaceScale.gaugeStartRotation))
            Circle()
                .trim(
                    from: WeeklyPaceScale.gaugeArcFraction
                        * (WeeklyPaceScale.greenFraction + WeeklyPaceScale.yellowFraction),
                    to: WeeklyPaceScale.gaugeArcFraction
                )
                .stroke(.red.opacity(0.82), style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                .rotationEffect(.degrees(WeeklyPaceScale.gaugeStartRotation))
            Circle()
                .trim(
                    from: WeeklyPaceScale.gaugeMarkerFraction(for: pace) - 0.004,
                    to: WeeklyPaceScale.gaugeMarkerFraction(for: pace) + 0.004
                )
                .stroke(.primary, style: StrokeStyle(lineWidth: 12, lineCap: .butt))
                .rotationEffect(.degrees(WeeklyPaceScale.gaugeStartRotation))
        }
        .frame(width: 94, height: 94)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if pace.markerFraction < WeeklyPaceScale.greenFraction {
            return "Usage pace is in the green zone"
        }
        if pace.markerFraction
            < WeeklyPaceScale.greenFraction + WeeklyPaceScale.yellowFraction {
            return "Usage pace is in the yellow zone"
        }
        return "Usage pace is in the red zone"
    }
}

struct WeeklyPaceBar: View {
    private static let indicatorWidth: CGFloat = 8

    let pace: WeeklyPace
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Usage Pace")
                    .font(.caption2.weight(.semibold))
            }
            HStack(spacing: 6) {
                GeometryReader { geometry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 1) {
                            Rectangle()
                                .fill(.green.opacity(0.82))
                                .frame(width: zoneWidth(greenFraction, in: geometry.size.width))
                            Rectangle()
                                .fill(.yellow.opacity(0.9))
                                .frame(width: zoneWidth(yellowFraction, in: geometry.size.width))
                            Rectangle()
                                .fill(.red.opacity(0.82))
                                .frame(width: zoneWidth(redFraction, in: geometry.size.width))
                        }
                        .frame(height: 4)
                        .clipShape(Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.secondary.opacity(0.2), lineWidth: 0.5)
                        }
                        Path { path in
                            path.move(to: CGPoint(x: Self.indicatorWidth / 2, y: 0))
                            path.addLine(to: CGPoint(x: Self.indicatorWidth, y: 6))
                            path.addLine(to: CGPoint(x: 0, y: 6))
                            path.closeSubpath()
                        }
                        .fill(.primary)
                        .frame(width: Self.indicatorWidth, height: 6)
                        .offset(x: indicatorOffset(in: geometry.size.width))
                    }
                }
                .frame(height: 12)
                if !compact {
                    Color.clear
                        .frame(width: 44)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if pace.markerFraction < WeeklyPaceScale.greenFraction {
            return "Usage pace is in the green zone"
        }
        if pace.markerFraction
            < WeeklyPaceScale.greenFraction + WeeklyPaceScale.yellowFraction {
            return "Usage pace is in the yellow zone"
        }
        return "Usage pace is in the red zone"
    }

    private var greenFraction: Double {
        WeeklyPaceScale.greenFraction
    }

    private var yellowFraction: Double {
        WeeklyPaceScale.yellowFraction
    }

    private var redFraction: Double {
        WeeklyPaceScale.redFraction
    }

    private func zoneWidth(_ fraction: Double, in width: CGFloat) -> CGFloat {
        let spacing = CGFloat(2)
        return max(0, (width - spacing) * fraction)
    }

    private func indicatorOffset(in width: CGFloat) -> CGFloat {
        let maximum = max(0, width - Self.indicatorWidth)
        return maximum * pace.markerFraction
    }
}

struct SmallWeeklyPaceRow: View {
    let window: LimitWindow
    let pace: WeeklyPace
    let credits: ResetCreditSummary?
    let resetDisplayStyle: ResetDisplayStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Weekly")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text(percentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ProgressView(value: Double(window.remainingPercent ?? 0), total: 100)
                .tint(usageTint)
            if let resetDate = window.resetDate {
                Text(resetText(for: resetDate))
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            WeeklyPaceBar(pace: pace, compact: true)
            if let credits {
                Text(creditText(credits))
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var percentText: String {
        window.remainingPercent.map { "\($0)% left" } ?? "unknown"
    }

    private var usageTint: Color {
        guard let remaining = window.remainingPercent else { return .gray }
        if remaining <= 15 { return .red }
        if remaining <= 35 { return .orange }
        return .green
    }

    private func resetText(for date: Date) -> String {
        if resetDisplayStyle == .relative {
            let seconds = max(0, Int(date.timeIntervalSinceNow))
            let days = seconds / 86_400
            let hours = (seconds % 86_400) / 3_600
            return days > 0 ? "resets in \(days)d \(hours)h" : "resets in \(hours)h"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = ResetDateFormat.dateAndTime
        return "resets \(formatter.string(from: date))"
    }

    private func creditText(_ summary: ResetCreditSummary) -> String {
        let noun = summary.availableCount == 1 ? "reset" : "resets"
        return "\(summary.availableCount) full \(noun)"
    }
}

struct ResetCreditRow: View {
    let summary: ResetCreditSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Full Resets")
                .font(.caption.weight(.semibold))
            ForEach(Array(resetLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var resetLines: [String] {
        guard summary.availableCount > 0 else {
            return ["0 Available"]
        }
        return (0..<summary.availableCount).map { index in
            guard summary.expirations.indices.contains(index) else {
                return "1 Available - Exp unknown"
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = ResetDateFormat.date
            return "1 Available - Exp \(formatter.string(from: summary.expirations[index]))"
        }
    }
}

struct CompactLimitRow: View {
    let window: LimitWindow
    let resetDisplayStyle: ResetDisplayStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(percentText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                ProgressView(value: Double(window.remainingPercent ?? 0), total: 100)
                    .tint(tint)
                if let resetDate = window.resetDate {
                    Text(resetText(for: resetDate))
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    private var percentText: String {
        window.remainingPercent.map { "\($0)% left" } ?? "unknown"
    }

    private var tint: Color {
        guard let remaining = window.remainingPercent else { return .gray }
        if remaining <= 15 { return .red }
        if remaining <= 35 { return .orange }
        return .green
    }

    private func resetText(for date: Date) -> String {
        switch resetDisplayStyle {
        case .relative:
            let seconds = max(0, Int(date.timeIntervalSinceNow))
            let days = seconds / 86_400
            let hours = (seconds % 86_400) / 3_600
            let minutes = (seconds % 3_600) / 60
            if days > 0 { return "\(days)d \(hours)h" }
            if hours > 0 { return "\(hours)h \(minutes)m" }
            return "\(minutes)m"
        case .absolute:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: Date())
                ? "HH:mm"
                : ResetDateFormat.dateAndTime
            return formatter.string(from: date)
        }
    }
}

struct LimitRow: View {
    let window: LimitWindow
    let resetDisplayStyle: ResetDisplayStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.name)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text(percentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progressValue, total: 100)
                .tint(tint)
            if let resetDate = window.resetDate {
                Text(resetText(for: resetDate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var percentText: String {
        if let remaining = window.remainingPercent {
            return "\(remaining)% left"
        }
        return "unknown"
    }

    private var progressValue: Double {
        Double(window.remainingPercent ?? 0)
    }

    private var tint: Color {
        guard let remaining = window.remainingPercent else {
            return .gray
        }
        if remaining <= 15 {
            return .red
        }
        if remaining <= 35 {
            return .orange
        }
        return .green
    }

    private func resetText(for date: Date) -> String {
        switch resetDisplayStyle {
        case .relative:
            return "resets in \(relativeResetText(until: date))"
        case .absolute:
            let formatter = DateFormatter()
            if Calendar.current.isDate(date, inSameDayAs: Date()) {
                formatter.setLocalizedDateFormatFromTemplate("HH:mm")
                return "resets at \(formatter.string(from: date))"
            }
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = ResetDateFormat.dateAndTime
            return "resets \(formatter.string(from: date))"
        }
    }

    private func relativeResetText(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(Date())))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            if hours > 0 {
                return "\(days)d \(hours)h"
            }
            return "\(days)d"
        }
        if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(hours)h"
        }
        return "\(minutes)m"
    }
}

struct CodexLimitsWidget: Widget {
    let kind = "CodexLimitsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodexLimitsProvider()) { entry in
            CodexLimitsWidgetView(entry: entry, resetDisplayStyle: .relative)
        }
        .configurationDisplayName("AI Usage")
        .description("Shows Codex limits and, in the medium widget, Claude usage.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// The original kind retains small support so existing desktop widgets survive the rename.
// A separate gallery entry keeps the individual Codex widget's descriptive name.
struct CodexSmallLimitsWidget: Widget {
    let kind = "CodexSmallLimitsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodexLimitsProvider()) { entry in
            CodexLimitsWidgetView(entry: entry, resetDisplayStyle: .relative)
        }
        .configurationDisplayName("Codex Limits")
        .description("Shows Codex weekly usage, reset time, and usage pace.")
        .supportedFamilies([.systemSmall])
    }
}

struct CodexCircularLimitsWidget: Widget {
    let kind = "CodexCircularLimitsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodexLimitsProvider()) { entry in
            CodexCircularLimitsWidgetView(entry: entry)
        }
        .configurationDisplayName("Usage Pace")
        .description("Shows weekly usage relative to the time elapsed before reset.")
        .supportedFamilies([.systemSmall])
    }
}

struct CodexCircularLimitsWidgetView: View {
    let entry: CodexLimitsEntry

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Codex")
                    .font(.headline.weight(.semibold))
                Spacer(minLength: 6)
                if let plan = entry.limits.plan {
                    Text(plan.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            if let error = entry.limits.error {
                Spacer()
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                Spacer()
            } else if let window = weeklyWindow, let pace {
                Text("Usage Pace")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, -1)
                    .padding(.bottom, 8)
                ZStack {
                    WeeklyPaceGauge(pace: pace)
                    VStack(spacing: -1) {
                        Text("\(window.remainingPercent ?? 0)%")
                            .font(.title3.weight(.bold).monospacedDigit())
                        Text("Allotment")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Left")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if let resetDate = window.resetDate {
                    Text("resets in \(relativeTime(until: resetDate))")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 5)
                }
            } else {
                Spacer()
                Text("Weekly allotment unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .containerBackground(.background, for: .widget)
    }

    private var weeklyWindow: LimitWindow? {
        entry.limits.windows.first(where: {
            $0.durationMinutes == 10_080
                && !$0.name.localizedCaseInsensitiveContains("spark")
        })
    }

    private var pace: WeeklyPace? {
        weeklyWindow.flatMap { WeeklyPace(window: $0, now: entry.date) }
    }

    private func relativeTime(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        if days > 0 { return "\(days)d \(hours)h" }
        return "\(hours)h"
    }
}

@main
struct CodexLimitsWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexLimitsWidget()
        CodexSmallLimitsWidget()
        CodexCircularLimitsWidget()
        ClaudeLimitsWidget()
    }
}
