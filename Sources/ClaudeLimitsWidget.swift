import SwiftUI
import WidgetKit

struct ClaudeLimitsEntry: TimelineEntry {
    let date: Date
    let usage: ClaudeUsageSnapshot
}

struct ClaudeLimitsProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClaudeLimitsEntry {
        let now = Date()
        return ClaudeLimitsEntry(date: now, usage: ClaudeUsageSnapshot(
            fiveHour: .init(utilization: 25, resetsAt: now.addingTimeInterval(7200)),
            sevenDay: .init(utilization: 40, resetsAt: now.addingTimeInterval(3 * 86400)),
            updatedAt: now, error: nil, plan: "pro"
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (ClaudeLimitsEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeLimitsEntry>) -> Void) {
        let entry = currentEntry()
        completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(300))))
    }

    private func currentEntry() -> ClaudeLimitsEntry {
        ClaudeLimitsEntry(date: Date(), usage: .readForWidget())
    }
}

struct ClaudeLimitsWidget: Widget {
    let kind = "ClaudeLimitsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClaudeLimitsProvider()) { entry in
            ClaudeLimitsWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Claude Limits")
        .description("Shows Claude weekly usage, reset time, and usage pace.")
        .supportedFamilies([.systemSmall])
    }
}

struct ClaudeLimitsWidgetView: View {
    let entry: ClaudeLimitsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Claude").font(.headline.weight(.semibold))
                if let plan = entry.usage.planLabel {
                    Text(plan).font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                }
                Spacer(minLength: 0)
            }
            if let error = entry.usage.error {
                Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(4)
            } else if let window = weeklyWindow {
                MediumUsageRow(title: "Weekly", remaining: window.remainingPercent,
                               reset: window.resetDate, now: entry.date, style: .relative)
                if let pace = WeeklyPace(window: window, now: entry.date) {
                    WeeklyPaceBar(pace: pace, compact: true)
                }
            } else {
                Text("Weekly usage unavailable").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let date = entry.usage.updatedAt {
                let stale = entry.usage.isStale(at: entry.date)
                HStack(spacing: 2) {
                    Text(stale ? "Stale ·" : "Updated")
                    Text(date, style: .time)
                }
                .font(.system(size: 8))
                .foregroundStyle(stale ? .orange : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel(stale ? "Claude usage is stale. Open AI Usage to refresh." : "Updated \(date.formatted())")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    private var weeklyWindow: LimitWindow? {
        guard let weekly = entry.usage.sevenDay else { return nil }
        return LimitWindow(name: "Weekly", usedPercent: Int(weekly.utilization.rounded(.up)),
                           resetDate: weekly.resetsAt, durationMinutes: 10_080)
    }
}
