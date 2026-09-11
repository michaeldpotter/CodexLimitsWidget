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
near(pace(50, 3.5)!.markerFraction, 0.6)
near(pace(25, 3.5)!.markerFraction, 0.3)
near(pace(65, 3.5)!.markerFraction, 0.78) // yellow
near(pace(75, 3.5)!.markerFraction, 0.9) // red
let screenshot = pace(72, 3.875)!
near(screenshot.markerFraction, 0.96768)
precondition(screenshot.markerFraction >= WeeklyPaceScale.greenFraction + WeeklyPaceScale.yellowFraction)
precondition(pace(72, 3)!.markerFraction < screenshot.markerFraction)
precondition(pace(80, 3.875)!.markerFraction > screenshot.markerFraction)
near(pace(0, 7)!.markerFraction, 0)
near(pace(1, 7)!.markerFraction, 1)
near(pace(0, 8)!.markerFraction, 0)
near(pace(100, 0)!.markerFraction, 0.6)
near(pace(100, -1)!.markerFraction, 0.6)
near(pace(-10, 3.5)!.markerFraction, 0)
near(pace(120, 3.5)!.markerFraction, 1)
precondition(pace(nil, 4) == nil)
precondition(pace(72, 4, duration: nil) == nil)
precondition(pace(72, 4, duration: 0) == nil)
precondition(WeeklyPace(window: LimitWindow(name: "Weekly", usedPercent: 72,
    resetDate: nil, durationMinutes: 10080), now: now) == nil)
near(WeeklyPaceScale.markerFraction(for: screenshot), 0.9489728)
near(WeeklyPaceScale.gaugeMarkerFraction(for: screenshot), 0.7117296)
print("Weekly pace regression checks passed")
'''
with tempfile.TemporaryDirectory(prefix="weekly-pace-") as directory:
    script = Path(directory) / "main.swift"
    script.write_text("import Foundation\nimport SwiftUI\n" + window + pace + checks)
    subprocess.run(["swift", "-module-cache-path", str(Path(directory) / "cache"), str(script)], check=True)
