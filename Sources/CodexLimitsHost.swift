import Darwin
import AppKit
import Foundation
import SwiftUI
import WidgetKit

@main
struct CodexLimitsHostApp: App {
    @StateObject private var refresh = UsageRefreshController()

    var body: some Scene {
        WindowGroup {
            HostView(refresh: refresh)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About AI Usage") {
                    AboutPanel.show()
                }
            }
        }
    }
}

@MainActor
enum AboutPanel {
    private static let repositoryURL = URL(string: "https://github.com/michaeldpotter/CodexLimitsWidget")!

    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "AI Usage",
            .applicationVersion: appVersion,
            .version: buildVersion,
            .credits: credits
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.8"
    }

    private static var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "27"
    }

    private static var credits: NSAttributedString {
        let body = NSMutableAttributedString(
            string: "Native macOS widgets for Codex and Claude usage.\n\nGitHub Repository",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        let repositoryRange = (body.string as NSString).range(of: "GitHub Repository")
        body.addAttributes(
            [
                .link: repositoryURL,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ],
            range: repositoryRange
        )
        return body
    }
}

struct HostView: View {
    @ObservedObject var refresh: UsageRefreshController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI Usage")
                .font(.title2.weight(.semibold))
            Text(refresh.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Refresh Widget") {
                refresh.refreshWidget()
            }
            .buttonStyle(.borderedProminent)
            .disabled(refresh.isRefreshing)
            Text("Claude usage refreshes every 5 minutes while this app is running. You can close this window; quitting the app stops Claude updates.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
    }
}

@MainActor
final class UsageRefreshController: ObservableObject {
    @Published var status = "Preparing widget..."
    @Published var isRefreshing = false
    private var timer: Timer?
    private var claudePaused = false
    private var nextClaudeAttempt = Date.distantPast

    init() {
        refreshWidget()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWidget(automatic: true) }
        }
    }

    func refreshWidget(automatic: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        if !automatic { claudePaused = false }
        Task {
            var messages: [String] = []
            do {
                _ = try AuthSnapshotWriter.write()
                messages.append("Codex auth synced.")
            } catch {
                messages.append(String(describing: error))
            }
            if !claudePaused && Date() >= nextClaudeAttempt {
                do {
                    let snapshot: ClaudeUsageSnapshot
                    do {
                        snapshot = try await ClaudeUsageClient.fetch()
                        messages.append("Claude usage updated.")
                    } catch {
                        let failure = (error as? ClaudeUsageError) ?? .invalidResponse
                        switch failure {
                        case .credentialsUnavailable, .http(401), .http(403): claudePaused = true
                        case .http(429): nextClaudeAttempt = Date().addingTimeInterval(15 * 60)
                        case .rateLimited(let until): nextClaudeAttempt = until
                        default: break
                        }
                        snapshot = ClaudeUsageSnapshot(fiveHour: nil, sevenDay: nil, updatedAt: nil,
                                                       error: failure.description)
                        messages.append(failure.description)
                    }
                    let url = try AuthSnapshotWriter.authSnapshotURL()
                        .deletingLastPathComponent().appendingPathComponent("claude-usage.json")
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
                } catch {
                    messages.append("Could not save Claude usage for the widget.")
                }
            } else {
                messages.append(claudePaused ? "Claude sign-in needs attention. Refresh after signing in."
                                : "Claude usage checks are cooling down; retrying automatically.")
            }
            WidgetCenter.shared.reloadAllTimelines()
            status = messages.joined(separator: "\n")
            isRefreshing = false
        }
    }
}

enum AuthSnapshotWriter {
    static func write() throws -> Date {
        let auth = try readCodexAuth()
        let updatedAt = Date()
        let destination = try authSnapshotURL()
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let payload: [String: Any] = [
            "accessToken": auth.accessToken,
            "accountId": auth.accountId,
            "planType": auth.planType,
            "updatedAt": Int(updatedAt.timeIntervalSince1970)
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: destination, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
        return updatedAt
    }

    private static func readCodexAuth() throws -> ChatGPTAuthTokens {
        let authURL = URL(fileURLWithPath: realHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        let data = try Data(contentsOf: authURL)
        guard
            let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = auth["tokens"] as? [String: Any],
            let accessToken = tokens["access_token"] as? String,
            let accountId = tokens["account_id"] as? String
        else {
            throw HostError.authUnavailable
        }
        guard let planType = chatGPTPlanType(from: accessToken)
            ?? (tokens["id_token"] as? String).flatMap(chatGPTPlanType(from:))
        else {
            throw HostError.invalidAuthToken
        }
        return ChatGPTAuthTokens(
            accessToken: accessToken,
            accountId: accountId,
            planType: planType
        )
    }

    static func authSnapshotURL() throws -> URL {
        let widgetIdentifier = try widgetExtensionBundleIdentifier()
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: realHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
        return libraryURL
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(widgetIdentifier, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CodexLimits", isDirectory: true)
            .appendingPathComponent("external-auth.json")
    }

    private static func widgetExtensionBundleIdentifier() throws -> String {
        let extensionURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("PlugIns", isDirectory: true)
            .appendingPathComponent("CodexLimitsWidgetExtension.appex", isDirectory: true)
        guard
            let bundle = Bundle(url: extensionURL),
            let identifier = bundle.bundleIdentifier,
            !identifier.isEmpty
        else {
            throw HostError.widgetExtensionUnavailable
        }
        return identifier
    }

    private static func realHomeDirectory() -> String {
        if
            let passwd = getpwuid(getuid()),
            let directory = passwd.pointee.pw_dir
        {
            let path = String(cString: directory)
            if !path.isEmpty {
                return path
            }
        }
        return NSHomeDirectory()
    }

    private static func chatGPTPlanType(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard
            let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let auth = json["https://api.openai.com/auth"] as? [String: Any],
            let planType = auth["chatgpt_plan_type"] as? String
        else {
            return nil
        }
        return planType
    }
}

struct ChatGPTAuthTokens {
    let accessToken: String
    let accountId: String
    let planType: String
}

enum HostError: Error, CustomStringConvertible {
    case authUnavailable
    case invalidAuthToken
    case widgetExtensionUnavailable

    var description: String {
        switch self {
        case .authUnavailable:
            return "Codex auth is unavailable. Run `codex login` first."
        case .invalidAuthToken:
            return "Codex auth token is invalid. Run `codex login` again."
        case .widgetExtensionUnavailable:
            return "AI Usage widget extension is unavailable. Reinstall the app."
        }
    }
}
