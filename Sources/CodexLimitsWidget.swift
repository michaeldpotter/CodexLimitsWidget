import Foundation
import SwiftUI
import WidgetKit

struct LimitWindow {
    let name: String
    let usedPercent: Int?
    let resetDate: Date?

    var remainingPercent: Int? {
        guard let usedPercent else {
            return nil
        }
        return max(0, 100 - usedPercent)
    }
}

struct ResetCreditSummary {
    let availableCount: Int
    let expirations: [Date]
}

struct CodexLimits {
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
                resetDate: Date().addingTimeInterval(3 * 60 * 60 + 25 * 60)
            ),
            LimitWindow(
                name: "Weekly",
                usedPercent: 10,
                resetDate: Date().addingTimeInterval(6 * 24 * 60 * 60 + 8 * 60 * 60)
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

struct CodexLimitsEntry: TimelineEntry {
    let date: Date
    let limits: CodexLimits
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
        completion(CodexLimitsEntry(date: Date(), limits: CodexLimitsReader.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexLimitsEntry>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let now = Date()
            let entry = CodexLimitsEntry(date: now, limits: CodexLimitsReader.read())
            let nextRefresh = Calendar.current.date(byAdding: .minute, value: 5, to: now) ?? now.addingTimeInterval(300)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }
}

struct CodexLimitsReader {
    static func read() -> CodexLimits {
        do {
            let codexPath = try findCodex()
            let result = try callCodexAppServer(codexPath: codexPath)
            return parseLimits(from: result)
        } catch {
            return CodexLimits(
                plan: nil,
                windows: [],
                resetCredits: nil,
                status: nil,
                updatedAt: Date(),
                error: String(describing: error)
            )
        }
    }

    private static func findCodex() throws -> String {
        let envPath = ProcessInfo.processInfo.environment["CODEX_BIN"]
        let candidates = [
            envPath,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ].compactMap { $0 }
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw WidgetError.codexNotFound
    }

    private static func callCodexAppServer(codexPath: String) throws -> [String: Any] {
        let codexHomeURL = try makeRuntimeCodexHome()
        let process = Process()
        let environment = codexEnvironment(codexHome: codexHomeURL.path)
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let reader = JSONLineReader(
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading
        )
        defer {
            try? stdin.fileHandleForWriting.close()
            reader.stop()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: codexHomeURL.deletingLastPathComponent())
        }
        try writeJSON([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codex-limits-widget",
                    "version": "0.3.7"
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ]
        ], to: stdin.fileHandleForWriting)
        _ = try reader.waitForMessage(id: 1, process: process, deadline: Date().addingTimeInterval(15))
        try writeJSON([
            "id": 2,
            "method": "account/rateLimits/read"
        ], to: stdin.fileHandleForWriting)
        var message = try reader.waitForMessage(id: 2, process: process, deadline: Date().addingTimeInterval(15))
        if let error = message["error"], isCodexAccountAuthRequired(error) {
            let auth = try readChatGPTAuthTokens()
            try writeJSON([
                "id": 3,
                "method": "account/login/start",
                "params": [
                    "type": "chatgptAuthTokens",
                    "accessToken": auth.accessToken,
                    "chatgptAccountId": auth.accountId,
                    "chatgptPlanType": auth.planType
                ]
            ], to: stdin.fileHandleForWriting)
            let loginMessage = try reader.waitForMessage(
                id: 3,
                process: process,
                deadline: Date().addingTimeInterval(15)
            )
            if let loginError = loginMessage["error"] {
                throw WidgetError.serverError(serverErrorDescription(loginError))
            }
            try writeJSON([
                "id": 4,
                "method": "account/rateLimits/read"
            ], to: stdin.fileHandleForWriting)
            message = try reader.waitForMessage(id: 4, process: process, deadline: Date().addingTimeInterval(15))
        }
        if let error = message["error"] {
            throw WidgetError.serverError(serverErrorDescription(error))
        }
        if let result = message["result"] as? [String: Any] {
            return result
        }
        throw WidgetError.missingRateLimits
    }

    private static func makeRuntimeCodexHome() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexLimits", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codexHomeURL = rootURL.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexHomeURL,
            withIntermediateDirectories: true
        )
        return codexHomeURL
    }

    private static func codexEnvironment(codexHome: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        environment["HOME"] = home
        environment["CODEX_HOME"] = codexHome
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if environment["USER"] == nil {
            environment["USER"] = NSUserName()
        }
        if environment["LOGNAME"] == nil {
            environment["LOGNAME"] = NSUserName()
        }
        return environment
    }

    private static func isCodexAccountAuthRequired(_ error: Any) -> Bool {
        serverErrorDescription(error).localizedCaseInsensitiveContains(
            "codex account authentication required to read rate limits"
        )
    }

    private static func serverErrorDescription(_ error: Any) -> String {
        if
            let dict = error as? [String: Any],
            let message = dict["message"] as? String
        {
            return message
        }
        return String(describing: error)
    }

    private static func readChatGPTAuthTokens() throws -> ChatGPTAuthTokens {
        let authURL = authSnapshotURL()
        guard let data = try? Data(contentsOf: authURL) else {
            throw WidgetError.authUnavailable
        }
        guard
            let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = auth["accessToken"] as? String,
            let accountId = auth["accountId"] as? String,
            let planType = auth["planType"] as? String
        else {
            throw WidgetError.authUnavailable
        }
        return ChatGPTAuthTokens(
            accessToken: accessToken,
            accountId: accountId,
            planType: planType
        )
    }

    private static func authSnapshotURL() -> URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return applicationSupportURL
            .appendingPathComponent("CodexLimits", isDirectory: true)
            .appendingPathComponent("external-auth.json")
    }

    private static func writeJSON(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw WidgetError.invalidOutput
        }
        handle.write(Data((string + "\n").utf8))
    }

    private static func parseLimits(from result: [String: Any]) -> CodexLimits {
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
        guard let dict = value as? [String: Any] else {
            return nil
        }
        let duration = number(dict["windowDurationMins"])
        let name: String
        switch duration {
        case 300:
            name = "5h"
        case 10080:
            name = "Weekly"
        case let minutes? where minutes % 1440 == 0:
            name = "\(minutes / 1440)d"
        case let minutes? where minutes % 60 == 0:
            name = "\(minutes / 60)h"
        case let minutes?:
            name = "\(minutes)m"
        default:
            name = fallbackName
        }
        let displayName = prefix.map { "\($0) \(name)" } ?? name
        let resetDate = number(dict["resetsAt"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return LimitWindow(
            name: displayName,
            usedPercent: number(dict["usedPercent"]),
            resetDate: resetDate
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
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }
}

struct ChatGPTAuthTokens {
    let accessToken: String
    let accountId: String
    let planType: String
}

final class JSONLineReader {
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var stdoutBuffer = Data()
    private var messages: [[String: Any]] = []
    private var stderrText = ""

    init(stdout: FileHandle, stderr: FileHandle) {
        self.stdout = stdout
        self.stderr = stderr
        stdout.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            self?.appendStdout(data)
        }
        stderr.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            self?.appendStderr(data)
        }
    }

    func stop() {
        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil
    }

    func waitForMessage(id: Int, process: Process, deadline: Date) throws -> [String: Any] {
        while Date() < deadline {
            if let message = takeMessage(id: id) {
                return message
            }
            if !process.isRunning {
                if let message = takeMessage(id: id) {
                    return message
                }
                throw WidgetError.missingRateLimits
            }
            let milliseconds = max(1, min(200, Int(deadline.timeIntervalSinceNow * 1000)))
            _ = signal.wait(timeout: .now() + .milliseconds(milliseconds))
        }
        if process.isRunning {
            process.terminate()
        }
        throw WidgetError.timeout
    }

    private func appendStdout(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stdoutBuffer.append(data)
        let newline = Data([0x0A])
        while let range = stdoutBuffer.range(of: newline) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
            guard
                !lineData.isEmpty,
                let message = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                continue
            }
            messages.append(message)
            signal.signal()
        }
    }

    private func appendStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if let text = String(data: data, encoding: .utf8) {
            stderrText += text
        }
    }

    private func takeMessage(id: Int) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = messages.firstIndex(where: { CodexLimitsReader.number($0["id"]) == id }) else {
            return nil
        }
        return messages.remove(at: index)
    }
}

enum WidgetError: Error, CustomStringConvertible {
    case authUnavailable
    case codexNotFound
    case invalidAuthToken
    case invalidOutput
    case missingRateLimits
    case serverError(String)
    case timeout

    var description: String {
        switch self {
        case .authUnavailable:
            return "open Codex Limits to sync auth"
        case .codexNotFound:
            return "codex was not found"
        case .invalidAuthToken:
            return "codex auth token is invalid"
        case .invalidOutput:
            return "invalid codex output"
        case .missingRateLimits:
            return "rate limits were not returned"
        case .serverError(let message):
            return message
        case .timeout:
            return "codex request timed out"
        }
    }
}

struct CodexLimitsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CodexLimitsEntry
    let resetDisplayStyle: ResetDisplayStyle

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
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
                if let credits = entry.limits.resetCredits {
                    ResetCreditRow(summary: credits)
                }
                if let status = entry.limits.status {
                    Text(status.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("Updated \(entry.limits.updatedAt, style: .time)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 2)
        .containerBackground(.background, for: .widget)
    }

    @ViewBuilder
    private var windowsView: some View {
        if family == .systemMedium {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(visibleWindows.enumerated()), id: \.offset) { _, window in
                    LimitRow(window: window, resetDisplayStyle: resetDisplayStyle)
                }
            }
        } else {
            ForEach(Array(visibleWindows.enumerated()), id: \.offset) { _, window in
                LimitRow(window: window, resetDisplayStyle: resetDisplayStyle)
            }
        }
    }

    private var visibleWindows: [LimitWindow] {
        let maximum: Int
        if family == .systemSmall {
            maximum = entry.limits.resetCredits == nil ? 2 : 1
        } else {
            maximum = 4
        }
        return Array(entry.limits.windows.prefix(maximum))
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
        .configurationDisplayName("Codex Limits")
        .description("Shows Codex usage buckets and available Full Reset credits.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct CodexLimitsResetTimesWidget: Widget {
    let kind = "CodexLimitsResetTimesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodexLimitsProvider()) { entry in
            CodexLimitsWidgetView(entry: entry, resetDisplayStyle: .absolute)
        }
        .configurationDisplayName("Codex Reset Times")
        .description("Shows Codex usage reset times and available Full Reset credits.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct CodexLimitsWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexLimitsWidget()
        CodexLimitsResetTimesWidget()
    }
}
