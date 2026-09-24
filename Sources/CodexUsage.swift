import Foundation
import CoreFoundation

struct LimitWindow: Codable {
    let name: String
    let usedPercent: Int?
    let resetDate: Date?
    let durationMinutes: Int?

    var remainingPercent: Int? {
        guard let usedPercent else {
            return nil
        }
        return max(0, 100 - usedPercent)
    }
}

struct ResetCreditSummary: Codable {
    let availableCount: Int
    let expirations: [Date]
}

struct CodexLimits: Codable {
    let plan: String?
    let windows: [LimitWindow]
    let resetCredits: ResetCreditSummary?
    let status: String?
    let updatedAt: Date
    let error: String?

    static let placeholder = CodexLimits(
        plan: "plus",
        windows: [
            LimitWindow(
                name: "5h",
                usedPercent: 24,
                resetDate: Date().addingTimeInterval(3 * 60 * 60 + 25 * 60),
                durationMinutes: 300
            ),
            LimitWindow(
                name: "Weekly Allotment",
                usedPercent: 10,
                resetDate: Date().addingTimeInterval(6 * 24 * 60 * 60 + 8 * 60 * 60),
                durationMinutes: 10_080
            )
        ],
        resetCredits: ResetCreditSummary(
            availableCount: 2,
            expirations: [
                Date().addingTimeInterval(8 * 24 * 60 * 60),
                Date().addingTimeInterval(9 * 24 * 60 * 60)
            ]
        ),
        status: nil,
        updatedAt: Date(),
        error: nil
    )
}

enum CodexLimitsParser {
    static func parseLimits(from result: [String: Any]) -> CodexLimits {
        let buckets = parsedBuckets(from: result)
        let codexBucket = buckets.first(where: { $0.id == "codex" })?.value
            ?? (result["rateLimits"] as? [String: Any])
            ?? result
        var windows: [LimitWindow] = []
        var statuses: [String] = []

        for bucket in buckets {
            let prefix = bucket.id == "codex" ? nil : compactBucketName(bucket.value, fallback: bucket.id)
            if let primary = parseWindow(bucket.value["primary"], fallbackName: "primary", prefix: prefix) {
                windows.append(primary)
            }
            if let secondary = parseWindow(bucket.value["secondary"], fallbackName: "secondary", prefix: prefix) {
                windows.append(secondary)
            }
            if let status = bucket.value["rateLimitReachedType"] as? String {
                statuses.append(status)
            }
        }

        return CodexLimits(
            plan: codexBucket["planType"] as? String,
            windows: windows,
            resetCredits: parseResetCredits(result["rateLimitResetCredits"]),
            status: statuses.first,
            updatedAt: Date(),
            error: nil
        )
    }

    private static func parsedBuckets(from result: [String: Any]) -> [(id: String, value: [String: Any])] {
        if let rawBuckets = result["rateLimitsByLimitId"] as? [String: Any] {
            return rawBuckets.compactMap { id, value in
                guard let bucket = value as? [String: Any] else {
                    return nil
                }
                return (id: id, value: bucket)
            }.sorted { left, right in
                if left.id == "codex" { return true }
                if right.id == "codex" { return false }
                return left.id.localizedCaseInsensitiveCompare(right.id) == .orderedAscending
            }
        }
        let fallback = (result["rateLimits"] as? [String: Any]) ?? result
        return [(id: "codex", value: fallback)]
    }

    private static func compactBucketName(_ bucket: [String: Any], fallback: String) -> String {
        let name = (bucket["limitName"] as? String) ?? fallback
        if name.localizedCaseInsensitiveContains("spark") {
            return "Spark"
        }
        return name
            .replacingOccurrences(of: "GPT-", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "Codex-", with: "", options: .caseInsensitive)
    }

    private static func parseWindow(_ value: Any?, fallbackName: String, prefix: String?) -> LimitWindow? {
        guard let dict = value as? [String: Any],
              let used = number(dict["usedPercent"]), (0...100).contains(used) else {
            return nil
        }
        let duration = number(dict["windowDurationMins"])
        let name: String
        switch duration {
        case 300:
            name = "5h"
        case 10080:
            name = "Weekly Allotment"
        case let minutes? where minutes % 1440 == 0:
            name = "\(minutes / 1440)d"
        case let minutes? where minutes % 60 == 0:
            name = "\(minutes / 60)h"
        case let minutes?:
            name = "\(minutes)m"
        default:
            name = fallbackName
        }
        let displayName: String
        if duration == 10_080, prefix?.localizedCaseInsensitiveCompare("Spark") == .orderedSame {
            displayName = "Spark Weekly"
        } else {
            displayName = prefix.map { "\($0) \(name)" } ?? name
        }
        let resetDate = number(dict["resetsAt"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return LimitWindow(
            name: displayName,
            usedPercent: used,
            resetDate: resetDate,
            durationMinutes: duration
        )
    }

    private static func parseResetCredits(_ value: Any?) -> ResetCreditSummary? {
        guard let dict = value as? [String: Any], let count = number(dict["availableCount"]) else {
            return nil
        }
        let expirations = (dict["credits"] as? [[String: Any]] ?? [])
            .compactMap { number($0["expiresAt"]) }
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
            .filter { $0 > Date() }
        return ResetCreditSummary(
            availableCount: count,
            expirations: expirations.sorted()
        )
    }

    static func number(_ value: Any?) -> Int? {
        if let value = value as? String {
            return Int(value)
        }
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let number = value.doubleValue
        guard number.isFinite, number.rounded() == number,
              number >= Double(Int.min), number < Double(Int.max) else { return nil }
        return Int(number)
    }
}
