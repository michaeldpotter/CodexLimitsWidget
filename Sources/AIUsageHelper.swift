import AppKit
import Foundation
import WidgetKit
import MachO

@main
struct AIUsageHelper {
    static func main() {
        let action = CommandLine.arguments.dropFirst().first ?? "poll"
        guard ["poll", "refresh", "connect", "disconnect"].contains(action) else { exit(2) }
        // launchd may supply a short argv[0]. Resolve the actual executable via
        // dyld rather than treating that argument as an absolute path.
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { exit(2) }
        let appURL = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if ["poll", "refresh"].contains(action), let paths = try? UsagePaths(appURL: appURL) {
            let claude = Process()
            claude.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            claude.arguments = [appURL.appendingPathComponent("Contents/Resources/claude-usage.py").path,
                               paths.snapshot.deletingLastPathComponent().appendingPathComponent("claude-cli-usage.json").path,
                               action]
            claude.standardOutput = FileHandle.nullDevice
            claude.standardError = FileHandle.nullDevice
            if (try? claude.run()) != nil { claude.waitUntilExit() }
        }
        do {
            let paths = try UsagePaths(appURL: appURL)
            try UsageWorker.run(action: action, paths: paths) { NSWorkspace.shared.open($0) }
            reloadWidgets()
            exit(0)
        } catch UsageFailure.busy {
            print("Another Codex operation is in progress.")
            exit(3)
        } catch UsageFailure.missingCodex {
            print("Install Codex CLI to connect your account.")
        } catch UsageFailure.migration {
            print("Could not remove the old credential copy. Check AI Usage's file access.")
        } catch UsageFailure.timeout {
            print("Codex timed out. Try connecting or refreshing again.")
        } catch UsageFailure.signIn {
            print("Connect Codex in AI Usage.")
        } catch {
            // Never print raw provider responses, auth URLs, or credentials.
            print("Codex could not complete the request. Check sign-in and Keychain access.")
        }
        reloadWidgets()
        exit(1)
    }

    private static func reloadWidgets() {
        // WidgetCenter needs the containing application's bundle identity.
        // Run its headless reload command instead of calling from this bare helper.
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return }
        let contents = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = contents.appendingPathComponent("MacOS/CodexLimits")
        process.arguments = ["--reload-widgets"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil { process.waitUntilExit() }
    }
}
