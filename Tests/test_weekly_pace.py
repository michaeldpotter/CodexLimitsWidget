"""Run the widget's actual pace model against fixed usage/reset scenarios."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/CodexLimitsWidget.swift").read_text()
window = source[source.index("struct LimitWindow {"):source.index("struct ResetCreditSummary {")]
pace = source[source.index("struct WeeklyPace {"):source.index("struct WeeklyPaceGauge: View {")]
checks = r'''
let now = Date(timeIntervalSince1970: 1_000_000)
func pace(_ used: Int?, _ daysLeft: Double, duration: Int? = 10080) -> WeeklyPace? {
    WeeklyPace(window: LimitWindow(name: "Weekly", usedPercent: used,
        resetDate: now.addingTimeInterval(daysLeft * 86400),
        durationMinutes: duration), now: now)
}
func near(_ actual: Double, _ expected: Double) {
    precondition(abs(actual - expected) < 0.000001, "\(actual) != \(expected)")
}
// Balanced usage stays at 60% throughout the week.
for used in [0, 10, 25, 50, 75, 90, 99] {
    near(pace(used, 7 * (1 - Double(used) / 100))!.markerFraction, 0.6)
}
near(pace(25, 3.5)!.markerFraction, 0.4)
near(pace(60, 3.5)!.markerFraction, 0.75) // yellow
near(pace(70, 3.5)!.markerFraction, 1) // red
// User screenshot: 92% left, 6d 19h remaining; an early burst stays green.
let screenshot = pace(8, 6 + 19.0 / 24)!
near(screenshot.markerFraction, 0.6327639751552795)
precondition(screenshot.markerFraction < WeeklyPaceScale.greenFraction)
near(pace(8, 6)!.markerFraction, 0.5590062111801242)
near(pace(8, 4)!.markerFraction, 0.3726708074534161)
// Late-week scarcity must show red even when average burn is near balanced.
near(pace(95, 1)!.markerFraction, 1)
near(pace(72, 3.875)!.markerFraction, 1)
// More usage increases pressure; idle time reduces it, across the week.
for daysLeft in [0.25, 1.0, 3.5, 6.0, 7.0] {
    var previous = 0.0
    for used in 0...100 {
        let current = pace(used, daysLeft)!.markerFraction
        precondition(current >= previous && current <= 1)
        precondition(pace(used, daysLeft / 2)!.markerFraction <= current)
        previous = current
    }
}
near(pace(1, 7)!.markerFraction, 0.6060606060606061)
near(pace(0, 8)!.markerFraction, 0.6)
near(pace(-10, 3.5)!.markerFraction, 0.3)
near(pace(120, 3.5)!.markerFraction, 1)
near(pace(100, 0.001)!.markerFraction, 1)
// Expired data cannot describe the new week's budget.
precondition(pace(100, 0) == nil)
precondition(pace(100, -1) == nil)
precondition(pace(0, 0) == nil)
precondition(pace(nil, 4) == nil)
precondition(pace(72, 4, duration: nil) == nil)
precondition(pace(72, 4, duration: 0) == nil)
precondition(pace(72, 4, duration: -1) == nil)
precondition(WeeklyPace(window: LimitWindow(name: "Weekly", usedPercent: 72,
    resetDate: nil, durationMinutes: 10080), now: now) == nil)
// Respect supplied window length, and share the model with the circular gauge.
near(pace(50, 0.5, duration: 1440)!.markerFraction, 0.6)
near(WeeklyPaceScale.markerFraction(for: screenshot), 0.6274534161490684)
near(WeeklyPaceScale.gaugeMarkerFraction(for: screenshot), 0.4705900621118013)
print("Weekly pace regression checks passed")
'''
with tempfile.TemporaryDirectory(prefix="weekly-pace-") as directory:
    script = Path(directory) / "main.swift"
    script.write_text("import Foundation\nimport SwiftUI\n" + window + pace + checks)
    subprocess.run(["swift", "-module-cache-path", str(Path(directory) / "cache"), str(script)], check=True)
