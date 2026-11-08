import Foundation

enum ConnectionState: String, Codable {
    case disconnected, ready, needsSignIn, unavailable

    var message: String {
        switch self {
        case .disconnected: return "Connect Codex in AI Usage."
        case .ready: return "Codex usage updated."
        case .needsSignIn: return "Reconnect Codex in AI Usage."
        case .unavailable: return "Could not update Codex. Check the connection and try again."
        }
    }
}

// An allowlist of display data. Never persist RPC responses or credentials here.
struct UsageSnapshot: Codable {
    var version = 1
    let state: ConnectionState
    let limits: CodexLimits?
    let attemptedAt: Date
    let nextAttempt: Date?

    static let disconnected = UsageSnapshot(state: .disconnected, limits: nil, attemptedAt: .distantPast, nextAttempt: nil)

    static func read(from url: URL) -> UsageSnapshot {
        guard let data = try? Data(contentsOf: url), data.count <= 1_048_576,
              let snapshot = try? JSONDecoder().decode(Self.self, from: data), snapshot.version == 1
        else { return .disconnected }
        return snapshot
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    func displayLimits(at now: Date = Date()) -> CodexLimits {
        if state == .ready, let limits, now.timeIntervalSince(limits.updatedAt) <= 900 {
            return limits
        }
        return CodexLimits(plan: nil, windows: [], resetCredits: nil, status: nil,
                           updatedAt: limits?.updatedAt ?? attemptedAt,
                           error: state == .ready ? "Usage is stale. Open AI Usage to check background updates." : state.message)
    }
}

struct UsagePaths {
    let codexHome: URL
    let snapshot: URL
    var executableSettings: URL { codexHome.deletingLastPathComponent().appendingPathComponent("codex-cli.json") }
    var legacyAuth: URL { snapshot.deletingLastPathComponent().appendingPathComponent("external-auth.json") }

    init(appURL: URL) throws {
        let extensionURL = appURL.appendingPathComponent("Contents/PlugIns/CodexLimitsWidgetExtension.appex")
        guard let identifier = Bundle(url: extensionURL)?.bundleIdentifier,
              identifier == "com.pugalol.codexlimits.widget" else { throw UsageFailure.configuration }
        let home = FileManager.default.homeDirectoryForCurrentUser
        codexHome = home.appendingPathComponent("Library/Application Support/AI Usage/Codex", isDirectory: true)
        snapshot = home.appendingPathComponent("Library/Containers/\(identifier)/Data/Library/Application Support/CodexLimits/codex-usage.json")
    }

    init(codexHome: URL, snapshot: URL) {
        self.codexHome = codexHome
        self.snapshot = snapshot
    }

    func removeLegacyAuth() throws {
        if FileManager.default.fileExists(atPath: legacyAuth.path) {
            try FileManager.default.removeItem(at: legacyAuth)
        }
    }
}

enum UsageFailure: Error {
    case configuration, missingCodex, busy, timeout, protocolError, signIn, service, migration
}

enum CodexLimitsReader {
    static func read() -> CodexLimits {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return UsageSnapshot.read(from: directory.appendingPathComponent("CodexLimits/codex-usage.json")).displayLimits()
    }
}

// Shared by the host and helper; discovery never executes shell startup files.
enum CodexExecutable {
    static let systemPaths = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]

    static func savedPath(at settings: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: settings.path) else { return nil }
        let data = try Data(contentsOf: settings)
        guard data.count <= 16_384 else { throw UsageFailure.configuration }
        return try JSONDecoder().decode(String.self, from: data)
    }

    static func save(_ executable: URL?, to settings: URL) throws {
        guard let executable else {
            if FileManager.default.fileExists(atPath: settings.path) {
                try FileManager.default.removeItem(at: settings)
            }
            return
        }
        guard isExecutable(executable.path) else { throw UsageFailure.missingCodex }
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(executable.path).write(to: settings, options: .atomic)
    }

    static func resolve(settings: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        systemPaths: [String] = systemPaths) throws -> URL {
        if let selected = try savedPath(at: settings) {
            guard selected.hasPrefix("/"), isExecutable(selected) else { throw UsageFailure.missingCodex }
            return URL(fileURLWithPath: selected)
        }
        var candidates = systemPaths + [home.appendingPathComponent(".local/bin/codex").path]
        let versions = home.appendingPathComponent(".nvm/versions/node")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: versions.path)) ?? []
        // Prefer the newest installed release; NVM's shell aliases are not sourced.
        let releases = names.filter { $0.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        candidates += releases.map { versions.appendingPathComponent("\($0)/bin/codex").path }
        guard let path = candidates.first(where: isExecutable) else { throw UsageFailure.missingCodex }
        return URL(fileURLWithPath: path)
    }

    private static func isExecutable(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
