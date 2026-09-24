import Darwin
import AppKit
import Foundation
import SwiftUI
import WidgetKit
import ServiceManagement

@main
struct CodexLimitsHostApp: App {
    @StateObject private var refresh = UsageRefreshController()

    init() {
        if CommandLine.arguments.contains("--reload-widgets") {
            WidgetCenter.shared.reloadAllTimelines()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--prepare-update") {
            let service = SMAppService.agent(plistName: "com.pugalol.aiusage.refresh.plist")
            if service.status == .notRegistered || service.status == .notFound { exit(0) }
            service.unregister { error in exit(error == nil ? 0 : 1) }
            dispatchMain()
        }
    }

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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Usage")
                        .font(.title2.weight(.semibold))
                    Text(refresh.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Connect Codex") { refresh.perform("connect") }
                    .buttonStyle(.borderedProminent)
                Button("Refresh") { refresh.perform("refresh") }
                Button("Disconnect") { refresh.disconnect() }
            }
            .disabled(refresh.isRefreshing)
            Toggle("Update in the background", isOn: Binding(
                get: { refresh.backgroundEnabled },
                set: { refresh.setBackground($0) }
            ))
            .disabled(refresh.isRefreshing || !refresh.backgroundAvailable)
            Text(refresh.backgroundStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if refresh.backgroundNeedsApproval {
                Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
            }
            Text("Claude usage refreshes through Claude Code’s /usage command. Sign in to Claude Code first. No model prompt is sent. Both services refresh when background updates are enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}

@MainActor
final class UsageRefreshController: ObservableObject {
    @Published var status = "Connect Codex to get started."
    @Published var isRefreshing = false
    @Published var backgroundEnabled = false
    @Published var backgroundNeedsApproval = false
    @Published var backgroundStatus = ""
    let backgroundAvailable = Bundle.main.object(forInfoDictionaryKey: "AIUsageBackgroundEnabledBuild") as? Bool == true
    private let service = SMAppService.agent(plistName: "com.pugalol.aiusage.refresh.plist")
    private var timer: Timer?

    init() {
        updateStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRefreshing else { return }
                self.updateBackgroundStatus()
            }
        }
    }

    private func updateStatus() {
        if let paths = try? UsagePaths(appURL: Bundle.main.bundleURL) {
            let snapshot = UsageSnapshot.read(from: paths.snapshot)
            status = snapshot.state == .disconnected ? "Connect Codex to get started."
                : snapshot.displayLimits().error ?? "Codex usage updated."
        }
        updateBackgroundStatus()
    }

    private func updateBackgroundStatus() {
        backgroundEnabled = service.status == .enabled || service.status == .requiresApproval
        backgroundNeedsApproval = service.status == .requiresApproval
        if !backgroundAvailable {
            backgroundStatus = "Automatic updates require a Developer ID-signed build. You can connect and refresh manually."
        } else if backgroundNeedsApproval {
            backgroundStatus = "Allow AI Usage in Login Items Settings to enable background updates."
        } else if backgroundEnabled {
            backgroundStatus = "The helper checks about every 5 minutes, even with this app closed. macOS controls widget refresh timing."
        } else {
            backgroundStatus = "Enable background updates to keep usage current when this app is closed."
        }
    }

    func setBackground(_ enabled: Bool) {
        guard backgroundAvailable, !isRefreshing else { return }
        isRefreshing = true
        Task {
            do {
                if enabled { try service.register() } else { try await service.unregister() }
                updateBackgroundStatus()
            } catch {
                status = "Could not change background updates. Check Login Items Settings."
            }
            isRefreshing = false
        }
    }

    func disconnect() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            do {
                if service.status != .notRegistered { try await service.unregister() }
                isRefreshing = false
                perform("disconnect")
            } catch {
                status = "Disable background updates in Login Items Settings before disconnecting."
                isRefreshing = false
            }
        }
    }

    func perform(_ action: String) {
        guard !isRefreshing else { return }
        isRefreshing = true
        status = action == "connect" ? "Complete sign-in in your browser…" : "Updating Codex…"
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AIUsageHelper")
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = helper
                process.arguments = [action]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    return (process.terminationStatus, String(decoding: data.prefix(2048), as: UTF8.self))
                } catch { return (Int32(1), "Could not start the AI Usage helper.") }
            }.value
            isRefreshing = false
            if result.0 == 0 { updateStatus() }
            else {
                let message = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
                status = message.isEmpty ? "The Codex helper stopped unexpectedly. Try again." : message
            }
        }
    }
}
