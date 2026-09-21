import SwiftUI

struct MediumLimitsView: View {
    let entry: CodexLimitsEntry
    let resetDisplayStyle: ResetDisplayStyle

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geometry in
                let columnWidth = max(0, (geometry.size.width - 25) / 2)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        heading("Codex", detail: entry.limits.plan?.uppercased(), color: .blue)
                        if let error = entry.limits.error {
                            message(error)
                        } else if let weekly = entry.limits.windows.first(where: {
                            $0.durationMinutes == 10_080 && !$0.name.localizedCaseInsensitiveContains("spark")
                        }) {
                            MediumUsageRow(title: "Weekly", remaining: weekly.remainingPercent,
                                           reset: weekly.resetDate, now: entry.date, style: resetDisplayStyle)
                            if let pace = WeeklyPace(window: weekly, now: entry.date) {
                                WeeklyPaceBar(pace: pace, compact: true)
                            }
                            if let status = entry.limits.status {
                                Text(status.replacingOccurrences(of: "_", with: " "))
                                    .font(.system(size: 9)).foregroundStyle(.red).lineLimit(1)
                            }
                        } else {
                            message("No weekly usage returned.")
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: columnWidth, height: geometry.size.height, alignment: .topLeading)

                    Rectangle().fill(.secondary.opacity(0.2)).frame(width: 1)

                    VStack(alignment: .leading, spacing: 4) {
                        heading("Claude", detail: entry.claude.planLabel,
                                color: Color(red: 0.85, green: 0.47, blue: 0.34))
                        if let error = entry.claude.error {
                            message(error)
                        } else {
                            claudeRow("5-hour", window: entry.claude.fiveHour)
                            claudeRow("Weekly", window: entry.claude.sevenDay)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: columnWidth, height: geometry.size.height, alignment: .topLeading)
                }
            }
            HStack(alignment: .lastTextBaseline, spacing: 25) {
                Group {
                    if entry.limits.error == nil, let credits = entry.limits.resetCredits {
                        resetCredits(credits)
                    } else {
                        Color.clear.frame(height: 0).accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                updated
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }

    private func heading(_ title: String, detail: String?, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title).font(.headline.weight(.semibold))
            if let detail {
                Text(detail).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
            }
            Spacer(minLength: 0)
        }
    }

    private func claudeRow(_ title: String, window: ClaudeUsageSnapshot.Window?) -> some View {
        MediumUsageRow(title: title, remaining: window?.remainingPercent(at: entry.date),
                       reset: window?.resetsAt, now: entry.date, style: resetDisplayStyle)
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(4)
    }

    private func resetCredits(_ credits: ResetCreditSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(credits.availableCount) full \(credits.availableCount == 1 ? "reset" : "resets")")
                .font(.system(size: 9))
            if !credits.expirations.isEmpty {
                let dates = credits.expirations.map { date in
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "MM/dd"
                    return formatter.string(from: date)
                }.joined(separator: ", ")
                Text("Exp \(dates)")
                    .font(.system(size: 8)).monospacedDigit().lineLimit(1)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var updated: some View {
        // A shared timestamp must not make older Claude data look freshly fetched.
        let date = entry.claude.updatedAt.map { min($0, entry.limits.updatedAt) }
            ?? entry.limits.updatedAt
        let stale = entry.claude.updatedAt != nil && entry.claude.isStale(at: entry.date)
        return HStack(spacing: 2) {
            Text(stale ? "Claude stale · Updated" : "Updated")
            Text(date, style: .time)
        }
        .font(.system(size: 8)).foregroundStyle(stale ? .orange : .secondary)
        .lineLimit(1)
        .accessibilityLabel(stale ? "Claude usage is stale. Open AI Usage to refresh." : "Updated \(date.formatted())")
    }

}

struct MediumUsageRow: View {
    let title: String
    let remaining: Int?
    let reset: Date?
    let now: Date
    let style: ResetDisplayStyle

    private var expired: Bool { reset.map { $0 <= now } ?? false }
    private var value: Int? { expired ? nil : remaining }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title).fontWeight(.semibold)
                Spacer(minLength: 0)
                Text(value.map { "\($0)% left" } ?? "—").monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.15))
                    Capsule().fill(tint).frame(width: geometry.size.width * Double(value ?? 0) / 100)
                }
            }
            .frame(height: 4)
            Text(resetText).font(.system(size: 8)).monospacedDigit()
                .foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        guard let value else { return .gray }
        if value <= 15 { return .red }
        if value <= 35 { return .orange }
        return .green
    }

    private var resetText: String {
        if expired { return "Awaiting refresh" }
        guard let reset else { return remaining == nil ? "Not available" : "Reset not reported" }
        if style == .absolute {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM/dd HH:mm"
            return "Resets \(formatter.string(from: reset))"
        }
        let minutes = max(0, Int(reset.timeIntervalSince(now) / 60))
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        if days > 0 { return "Resets in \(days)d \(hours)h" }
        if hours > 0 { return "Resets in \(hours)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }
}
