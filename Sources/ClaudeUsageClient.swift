import Foundation

enum ClaudeUsageClient {
    static func fetch() async throws -> ClaudeUsageSnapshot {
        let auth = try await Task.detached(priority: .utility) {
            try credentials()
        }.value
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Ephemeral sessions prevent authenticated requests from entering the disk cache.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeUsageError.network
        }
        guard let response = response as? HTTPURLResponse else { throw ClaudeUsageError.invalidResponse }
        if response.statusCode == 429 {
            let now = Date()
            var retry = now.addingTimeInterval(15 * 60)
            if let header = response.value(forHTTPHeaderField: "Retry-After") {
                if let seconds = Double(header), seconds.isFinite, seconds > 0 {
                    retry = max(retry, now.addingTimeInterval(seconds))
                } else {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    if let date = formatter.date(from: header) { retry = max(retry, date) }
                }
            }
            throw ClaudeUsageError.rateLimited(until: retry)
        }
        guard response.statusCode == 200 else { throw ClaudeUsageError.http(response.statusCode) }
        return try ClaudeUsageSnapshot.parse(data, plan: auth.plan)
    }

    private struct Credentials {
        let accessToken: String
        let plan: String?
    }

    private static func credentials() throws -> Credentials {
        // Capture Keychain output in memory, never in arguments, files, or logs.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ClaudeUsageError.credentialsUnavailable }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw ClaudeUsageError.credentialsUnavailable }
        return Credentials(accessToken: token, plan: oauth["subscriptionType"] as? String)
    }
}
