import Foundation
import Darwin

// Owns one managed Codex app-server. The widget never compiles this file.
final class CodexSession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var messages: [[String: Any]] = []
    private var buffer = Data()
    private var ended = false
    private var nextID = 0

    init(home: URL, executable: URL? = nil) throws {
        Darwin.signal(SIGPIPE, SIG_IGN)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let path = executable?.path ?? candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw UsageFailure.missingCodex }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-c", "cli_auth_credentials_store=\"keyring\"", "app-server", "--listen", "stdio://"]
        // Do not inherit API keys, auth overrides, or the user's Codex configuration.
        var environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "CODEX_HOME": home.path,
                           "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        for key in ["USER", "LOGNAME", "TMPDIR"] { environment[key] = ProcessInfo.processInfo.environment[key] }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        do {
            _ = try request("initialize", params: ["clientInfo": ["name": "ai-usage", "version": "0.4.0"]])
            try send(["method": "initialized"])
            let config = try request("config/read", params: ["includeLayers": false])
            guard (config["config"] as? [String: Any])?["cli_auth_credentials_store"] as? String == "keyring"
            else { throw UsageFailure.configuration }
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? output.fileHandleForReading.close()
    }

    private func receive(_ data: Data) {
        lock.lock()
        defer { lock.unlock(); signal.signal() }
        guard !data.isEmpty else { ended = true; return }
        buffer.append(data)
        guard buffer.count <= 1_048_576 else { ended = true; buffer.removeAll(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], messages.count < 128
            else { ended = true; buffer.removeAll(); return }
            messages.append(object)
            buffer.removeSubrange(...newline)
        }
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func request(_ method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        try send(["id": id, "method": method, "params": params])
        let response = try wait(timeout: 30) { ($0["id"] as? Int) == id && $0["method"] == nil }
        guard response["error"] == nil, let result = response["result"] as? [String: Any]
        else { throw UsageFailure.service }
        return result
    }

    private func wait(timeout: TimeInterval, matching predicate: ([String: Any]) -> Bool) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            if let index = messages.firstIndex(where: predicate) {
                let result = messages.remove(at: index)
                lock.unlock()
                return result
            }
            let closed = ended
            lock.unlock()
            if closed { throw UsageFailure.protocolError }
            _ = signal.wait(timeout: .now() + min(0.25, max(0, deadline.timeIntervalSinceNow)))
        }
        throw UsageFailure.timeout
    }

    func connected() throws -> Bool {
        let result = try request("account/read", params: ["refreshToken": false])
        return (result["account"] as? [String: Any])?["type"] as? String == "chatgpt"
    }

    func connect(openURL: (URL) -> Void) throws {
        let result = try request("account/login/start", params: ["type": "chatgpt"])
        guard let loginID = result["loginId"] as? String,
              let text = result["authUrl"] as? String, let url = Self.loginURL(text) else { throw UsageFailure.protocolError }
        openURL(url)
        do {
            let message = try wait(timeout: 180) {
                $0["method"] as? String == "account/login/completed" &&
                ($0["params"] as? [String: Any])?["loginId"] as? String == loginID
            }
            guard (message["params"] as? [String: Any])?["success"] as? Bool == true,
                  try connected() else { throw UsageFailure.signIn }
        } catch {
            _ = try? request("account/login/cancel", params: ["loginId": loginID])
            throw error
        }
    }

    static func loginURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https",
              let host = url.host, ["auth.openai.com", "chatgpt.com", "auth0.openai.com"].contains(host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        return url
    }

    func fetch() throws -> CodexLimits {
        guard try connected() else { throw UsageFailure.signIn }
        let result = try request("account/rateLimits/read")
        let limits = CodexLimitsParser.parseLimits(from: result)
        guard !limits.windows.isEmpty else { throw UsageFailure.protocolError }
        return limits
    }

    func disconnect() throws { _ = try request("account/logout") }
}
