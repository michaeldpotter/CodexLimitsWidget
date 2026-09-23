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
// Fresh resets start at the far left, including an out-of-range future reset.
near(pace(0, 7)!.markerFraction, 0)
near(pace(0, 6 + 23.0 / 24)!.markerFraction, 0)
near(pace(0, 8)!.markerFraction, 0)
// Six hours of normal allowance softens small early bursts.
near(pace(1, 7)!.markerFraction, 0.196)
near(pace(1, 7 - 3.0 / 24)!.markerFraction, 0.196)
near(pace(1, 7 - 6.0 / 24)!.markerFraction, 0.196)
precondition(pace(1, 7 - 6.01 / 24)!.markerFraction < 0.196)
// Balanced usage reaches the green/yellow boundary after the grace period.
for used in [5, 10, 25, 50, 75, 90, 99] {
    near(pace(used, 7 * (1 - Double(used) / 100))!.markerFraction,
         WeeklyPaceScale.greenFraction)
}
near(pace(25, 3.5)!.markerFraction, 0.35) // below pace: green
near(pace(60, 3.5)!.markerFraction, 0.84) // 20% above pace: yellow
near(pace(65, 3.5)!.markerFraction, 0.91) // 30% above pace: red
near(pace(80, 3.5)!.markerFraction, 1)
// Average pace deliberately differs from remaining-budget pressure.
near(pace(95, 1)!.markerFraction, 0.7 * 0.95 / (6.0 / 7))
// More usage never moves left; idle time never moves right.
for daysLeft in [0.25, 1.0, 3.5, 6.0, 6.9, 7.0] {
    var previous = 0.0
    for used in 0...100 {
        let current = pace(used, daysLeft)!.markerFraction
        precondition(current >= previous && current <= 1)
        precondition(pace(used, daysLeft / 2)!.markerFraction <= current)
        previous = current
    }
}
near(pace(-10, 3.5)!.markerFraction, 0)
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
// Respect supplied window length, including windows shorter than the grace period.
near(pace(50, 0.5, duration: 1440)!.markerFraction, 0.7)
near(pace(1, 1, duration: 1440)!.markerFraction, 0.028)
near(pace(50, 1.0 / 24, duration: 60)!.markerFraction, 0.35)
// Both renderers share the same model; the gauge keeps its visual end inset.
let fresh = pace(0, 7)!
near(WeeklyPaceScale.markerFraction(for: fresh), 0.02)
near(WeeklyPaceScale.gaugeMarkerFraction(for: fresh), 0.015)
let balanced = pace(50, 3.5)!
near(WeeklyPaceScale.markerFraction(for: balanced), 0.692)
near(WeeklyPaceScale.gaugeMarkerFraction(for: balanced), 0.519)
print("Weekly pace regression checks passed")
'''
with tempfile.TemporaryDirectory(prefix="weekly-pace-") as directory:
    script = Path(directory) / "main.swift"
    script.write_text("import Foundation\nimport SwiftUI\n" + window + pace + checks)
    subprocess.run(["swift", "-module-cache-path", str(Path(directory) / "cache"), str(script)], check=True)
