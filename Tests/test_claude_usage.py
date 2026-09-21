"""Compile and exercise the production Claude parser and snapshot model."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
checks = r'''
import Foundation

@main
struct Checks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_789_947_600)
        func parse(_ json: String) throws -> ClaudeUsageSnapshot {
            try .parse(Data(json.utf8), now: now)
        }
        let sample = try parse(#"{"five_hour":{"utilization":73.0,"resets_at":"2026-09-21T04:00:00.116266+00:00"},"seven_day":{"utilization":40,"resets_at":"2026-09-22T06:59:59Z"},"seven_day_sonnet":null,"unknown_field":42}"#)
        precondition(sample.fiveHour!.remainingPercent(at: now) == 27)
        precondition(sample.sevenDay!.remainingPercent(at: now) == 60)
        precondition(sample.fiveHour!.resetsAt != nil)
        precondition(sample.sevenDay!.resetsAt != nil)
        precondition(sample.updatedAt == now && sample.error == nil)
        precondition(!sample.isStale(at: now.addingTimeInterval(900)))
        precondition(sample.isStale(at: now.addingTimeInterval(901)))
        let reset = sample.fiveHour!.resetsAt!
        precondition(sample.fiveHour!.remainingPercent(at: reset) == nil)
        precondition(sample.fiveHour!.remainingPercent(at: reset.addingTimeInterval(1)) == nil)
        for (used, expected) in [(0.0, 100), (0.1, 99), (99.9, 0), (100.0, 0)] {
            let result = try parse("{\"five_hour\":{\"utilization\":\(used),\"resets_at\":null}}")
            precondition(result.fiveHour!.remainingPercent(at: now) == expected)
            precondition(result.sevenDay == nil)
        }
        let weeklyOnly = try parse(#"{"five_hour":null,"seven_day":{"utilization":1}}"#)
        precondition(weeklyOnly.fiveHour == nil && weeklyOnly.sevenDay != nil)
        for bad in [
            "{}", "[]", "not json", #"{"five_hour":null,"seven_day":null}"#,
            #"{"five_hour":{"utilization":true}}"#,
            #"{"five_hour":{"utilization":-1}}"#,
            #"{"five_hour":{"utilization":101}}"#,
            #"{"five_hour":{"utilization":"73"}}"#,
            #"{"five_hour":{"resets_at":null}}"#,
            #"{"five_hour":{"utilization":73,"resets_at":"bad date"}}"#,
            #"{"five_hour":{"utilization":73,"resets_at":42}}"#
        ] {
            do { _ = try parse(bad); fatalError("Accepted invalid usage: \(bad)") }
            catch { }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("claude-usage.json")
        precondition(ClaudeUsageSnapshot.read(from: url).error != nil)
        let encoded = try JSONEncoder().encode(sample)
        try encoded.write(to: url, options: .atomic)
        let restored = ClaudeUsageSnapshot.read(from: url)
        precondition(restored.fiveHour!.utilization == 73)
        precondition(restored.updatedAt == now)
        precondition(restored.plan == nil) // Existing snapshots remain readable.
        let withPlan = try ClaudeUsageSnapshot.parse(Data(#"{"five_hour":{"utilization":73}}"#.utf8), now: now, plan: "pro")
        try JSONEncoder().encode(withPlan).write(to: url)
        precondition(ClaudeUsageSnapshot.read(from: url).planLabel == "PRO")
        var otherPlan = withPlan
        otherPlan.plan = "max"
        precondition(otherPlan.planLabel == "MAX")
        otherPlan.plan = "unknown"
        precondition(otherPlan.planLabel == nil)
        let fields = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        precondition(Set(fields.keys) == Set(["fiveHour", "sevenDay", "updatedAt"]))
        try Data("corrupted".utf8).write(to: url)
        precondition(ClaudeUsageSnapshot.read(from: url).error != nil)
        precondition(ClaudeUsageSnapshot.unavailable.isStale(at: now))
        precondition(ClaudeUsageError.http(401).description.contains("sign-in"))
        precondition(ClaudeUsageError.http(429).description.contains("rate limiting"))
        print("Claude usage parsing, expiry, stale data, and snapshot checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="claude-usage-test-") as directory:
    script = Path(directory) / "Checks.swift"
    script.write_text(checks)
    binary = Path(directory) / "checks"
    subprocess.run(["swiftc", "-module-cache-path", str(root / "build/ModuleCache"),
                    str(root / "Sources/ClaudeUsage.swift"), str(script), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
