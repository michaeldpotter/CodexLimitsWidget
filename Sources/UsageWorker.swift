import Foundation
import Darwin

// One owner for connect/disconnect/refresh, including concurrent launchd invocations.
enum UsageWorker {
    static func run(action: String, paths: UsagePaths, executable: URL? = nil,
                    openURL: (URL) -> Void = { _ in }) throws {
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(paths.codexHome.appendingPathComponent("usage.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw UsageFailure.configuration }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw UsageFailure.busy }
        defer { flock(fd, LOCK_UN) }
        let previous = UsageSnapshot.read(from: paths.snapshot)
        if action == "poll" {
            guard previous.state != .disconnected, previous.state != .needsSignIn else { return }
            if let next = previous.nextAttempt, next > Date() { return }
        }
        do {
            let session = try CodexSession(home: paths.codexHome, executable: executable)
            defer { session.stop() }
            if action == "connect" { try session.connect(openURL: openURL) }
            if action == "disconnect" {
                try session.disconnect()
                try UsageSnapshot.disconnected.write(to: paths.snapshot)
                do { try paths.removeLegacyAuth() } catch { throw UsageFailure.migration }
                return
            }
            let limits = try session.fetch()
            // Do not declare migration complete while the old token copy remains.
            do { try paths.removeLegacyAuth() } catch { throw UsageFailure.migration }
            try UsageSnapshot(state: .ready, limits: limits, attemptedAt: Date(),
                              nextAttempt: nil).write(to: paths.snapshot)
        } catch {
            let needsSignIn: Bool
            if case UsageFailure.signIn = error { needsSignIn = true } else { needsSignIn = false }
            // Back off failed background attempts across process restarts. Foreground
            // refresh may retry, but never mark old data as newly fetched.
            try UsageSnapshot(state: needsSignIn ? .needsSignIn : .unavailable,
                              limits: previous.limits, attemptedAt: Date(),
                              nextAttempt: Date().addingTimeInterval(900)).write(to: paths.snapshot)
            throw error
        }
    }
}
