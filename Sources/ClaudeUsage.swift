import Foundation
import CoreFoundation

// This is the only Claude data shared with the sandboxed widget. Never store tokens here.
struct ClaudeUsageSnapshot: Codable {
    struct Window: Codable {
        let utilization: Double
        let resetsAt: Date?

        func remainingPercent(at now: Date) -> Int? {
            guard resetsAt.map({ $0 > now }) ?? true else { return nil }
            return max(0, min(100, Int((100 - utilization).rounded(.down))))
        }
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let updatedAt: Date?
    let error: String?
    var plan: String? = nil

    var planLabel: String? {
        guard let plan, ["pro", "max", "team", "enterprise"].contains(plan.lowercased()) else { return nil }
        return plan.uppercased()
    }

    static let unavailable = ClaudeUsageSnapshot(
        fiveHour: nil, sevenDay: nil, updatedAt: nil,
        error: "Open Claude Code and sign in, then refresh AI Usage."
    )

    func isStale(at now: Date) -> Bool {
        guard let updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) > 15 * 60
    }

    static func read(from url: URL) -> ClaudeUsageSnapshot {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data)
        else { return .unavailable }
        return snapshot
    }

    static func readForWidget() -> ClaudeUsageSnapshot {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return read(from: directory.appendingPathComponent("CodexLimits/claude-cli-usage.json"))
    }

    static func parse(_ data: Data, now: Date = Date(), plan: String? = nil) throws -> ClaudeUsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageError.invalidResponse
        }
        func window(_ key: String) throws -> Window? {
            guard let value = json[key], !(value is NSNull) else { return nil }
            guard let fields = value as? [String: Any],
                  let percent = fields["utilization"] as? NSNumber,
                  CFGetTypeID(percent) != CFBooleanGetTypeID(),
                  percent.doubleValue.isFinite, (0...100).contains(percent.doubleValue)
            else { throw ClaudeUsageError.invalidResponse }
            var reset: Date?
            if let value = fields["resets_at"], !(value is NSNull) {
                guard let text = value as? String else { throw ClaudeUsageError.invalidResponse }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = formatter.date(from: text)
                if reset == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    reset = formatter.date(from: text)
                }
                guard reset != nil else { throw ClaudeUsageError.invalidResponse }
            }
            return Window(utilization: percent.doubleValue, resetsAt: reset)
        }
        let fiveHour = try window("five_hour")
        let sevenDay = try window("seven_day")
        guard fiveHour != nil || sevenDay != nil else { throw ClaudeUsageError.noWindows }
        return Self(fiveHour: fiveHour, sevenDay: sevenDay, updatedAt: now, error: nil, plan: plan)
    }
}

enum ClaudeUsageError: Error, CustomStringConvertible {
    case credentialsUnavailable, invalidResponse, noWindows, network, http(Int), rateLimited(until: Date)

    var description: String {
        switch self {
        case .credentialsUnavailable: return "Sign in to Claude Code, then refresh here."
        case .invalidResponse: return "Claude returned unreadable usage data."
        case .noWindows: return "Claude returned no usage windows."
        case .network: return "Could not reach Claude. Try Refresh Widget."
        case .http(401), .http(403): return "Open Claude Code to renew sign-in, then refresh here."
        case .http(429), .rateLimited: return "Claude is rate limiting usage checks. Try again later."
        case .http: return "Claude usage is temporarily unavailable."
        }
    }
}
