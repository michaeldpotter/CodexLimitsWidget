"""Exercise production managed-session and worker code against a local fake server.
No real credentials, browser, Keychain, or network access is used.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
server = r'''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
home = Path(os.environ['CODEX_HOME'])
scenario = (home / 'scenario').read_text()
assert 'OPENAI_API_KEY' not in os.environ
assert 'ANTHROPIC_API_KEY' not in os.environ
assert 'cli_auth_credentials_store="keyring"' in sys.argv
connected = scenario not in ('signed-out', 'connect')
def emit(value):
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    with (home / 'calls').open('a') as log: log.write(method + '\n')
    if 'id' not in request: continue
    result = {}
    if method == 'config/read':
        result = {'config': {'cli_auth_credentials_store': 'file' if scenario == 'file-storage' else 'keyring'}}
    elif method == 'account/read':
        result = {'account': {'type': 'chatgpt'} if connected else None}
    elif method == 'account/login/start':
        assert request['params'] == {'type': 'chatgpt'}
        result = {'loginId': 'test-login', 'authUrl': 'https://auth.openai.com/authorize?state=synthetic'}
        emit({'method': 'account/login/completed', 'params': {'loginId': 'unrelated', 'success': False}})
        emit({'method': 'account/login/completed', 'params': {'loginId': 'test-login', 'success': True}})
        connected = True
    elif method == 'account/logout':
        connected = False
    elif method == 'account/rateLimits/read':
        if scenario == 'remote-error':
            emit({'id': request['id'], 'error': {'message': 'SYNTHETIC_SECRET_SHOULD_NOT_ESCAPE'}})
            continue
        if scenario == 'eof': sys.exit(0)
        result = {'rateLimits': {'planType': 'plus', 'primary': {'usedPercent': 25, 'windowDurationMins': 300, 'resetsAt': 1999999999}},
                  'accessToken': 'SYNTHETIC_SECRET_SHOULD_NOT_ESCAPE', 'unknown': {'refreshToken': 'secret'}}
        if scenario == 'malformed': result = {'unexpected': 'data'}
    emit({'id': request['id'], 'result': result})
'''
checks = r'''
import Foundation
import Darwin

@main
struct Checks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let executable = URL(fileURLWithPath: CommandLine.arguments[2])
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); count += 1
        }
        func paths(_ scenario: String) throws -> UsagePaths {
            let home = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try Data(scenario.utf8).write(to: home.appendingPathComponent("scenario"))
            return UsagePaths(codexHome: home, snapshot: home.appendingPathComponent("widget/codex-usage.json"))
        }
        // Discovery must work with a GUI's minimal PATH, without running a shell.
        let discoveryHome = root.appendingPathComponent("discovery home")
        let settings = discoveryHome.appendingPathComponent("cli.json")
        func install(_ relative: String) throws -> URL {
            let url = discoveryHome.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: executable, to: url)
            return url
        }
        let older = try install(".nvm/versions/node/v9.9.0/bin/codex")
        let newer = try install(".nvm/versions/node/v26.12.1/bin/codex")
        check(try CodexExecutable.resolve(settings: settings, home: discoveryHome, systemPaths: []).path == newer.path,
              "GUI discovers newest NVM version numerically")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: newer.path)
        check(try CodexExecutable.resolve(settings: settings, home: discoveryHome, systemPaths: []).path == older.path,
              "nonexecutable candidates skipped")
        let local = try install(".local/bin/codex")
        check(try CodexExecutable.resolve(settings: settings, home: discoveryHome, systemPaths: []).path == local.path,
              "local install takes precedence over NVM fallback")
        let preferred = try install("custom bin/codex")
        try CodexExecutable.save(preferred, to: settings)
        check(try CodexExecutable.resolve(settings: settings, home: discoveryHome, systemPaths: []).path == preferred.path,
              "manual selection persists across resolver calls")
        // npm CLIs use /usr/bin/env: the selected bin directory must reach the child.
        let envServer = try String(contentsOf: preferred, encoding: .utf8)
            .replacingOccurrences(of: "#!/usr/bin/python3", with: "#!/usr/bin/env ai-usage-test-python")
        try envServer.write(to: preferred, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: preferred.path)
        let interpreter = preferred.deletingLastPathComponent().appendingPathComponent("ai-usage-test-python")
        try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: interpreter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: interpreter.path)
        let selected = try paths("ready")
        try CodexExecutable.save(preferred, to: selected.executableSettings)
        try UsageWorker.run(action: "refresh", paths: selected)
        check(UsageSnapshot.read(from: selected.snapshot).state == .ready, "worker uses saved CLI selection")
        try FileManager.default.removeItem(at: preferred)
        do {
            _ = try CodexExecutable.resolve(settings: settings, home: discoveryHome, systemPaths: [])
            fatalError("silently ignored missing manual executable")
        } catch UsageFailure.missingCodex { }
        try CodexExecutable.save(nil, to: settings)
        check(try CodexExecutable.resolve(settings: settings, home: discoveryHome, systemPaths: []).path == local.path,
              "automatic mode clears saved override")
        try FileManager.default.removeItem(at: local)
        try FileManager.default.removeItem(at: older)
        do {
            _ = try CodexExecutable.resolve(settings: settings, home: discoveryHome, systemPaths: [])
            fatalError("accepted missing CLI")
        } catch UsageFailure.missingCodex { }
        for value: Any in [true, -1, 101, 1e100, 1.5] {
            let parsed = CodexLimitsParser.parseLimits(from: ["rateLimits": ["primary": ["usedPercent": value]]])
            check(parsed.windows.isEmpty, "invalid percentages rejected")
        }
        let ready = try paths("ready")
        try FileManager.default.createDirectory(at: ready.legacyAuth.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic-old-token".utf8).write(to: ready.legacyAuth)
        try UsageWorker.run(action: "refresh", paths: ready, executable: executable)
        let snapshot = UsageSnapshot.read(from: ready.snapshot)
        check(snapshot.state == .ready, "ready state")
        check(snapshot.limits?.windows.first?.usedPercent == 25, "actual usage parsed")
        check(!FileManager.default.fileExists(atPath: ready.legacyAuth.path), "legacy copy removed")
        let stored = try String(contentsOf: ready.snapshot, encoding: .utf8)
        check(!stored.contains("Token") && !stored.contains("SECRET"), "snapshot excludes credentials")
        check(snapshot.displayLimits(at: snapshot.limits!.updatedAt.addingTimeInterval(901)).error != nil, "stale data is not current")

        let login = try paths("connect")
        var opened = false
        try UsageWorker.run(action: "connect", paths: login, executable: executable) { _ in opened = true }
        check(opened && UsageSnapshot.read(from: login.snapshot).state == .ready, "managed login notification")
        try UsageWorker.run(action: "disconnect", paths: login, executable: executable)
        check(UsageSnapshot.read(from: login.snapshot).state == .disconnected, "disconnect clears usage")
        let callsBefore = try Data(contentsOf: login.codexHome.appendingPathComponent("calls"))
        try UsageWorker.run(action: "poll", paths: login, executable: executable)
        check(try Data(contentsOf: login.codexHome.appendingPathComponent("calls")) == callsBefore, "disconnected background poll does not authenticate")

        for scenario in ["signed-out", "remote-error", "malformed", "file-storage", "eof"] {
            let location = try paths(scenario)
            do {
                try UsageWorker.run(action: "refresh", paths: location, executable: executable)
                fatalError("Accepted \(scenario)")
            } catch { }
            let failure = UsageSnapshot.read(from: location.snapshot)
            check(failure.state == (scenario == "signed-out" ? .needsSignIn : .unavailable), "safe failure state")
            let data = try String(contentsOf: location.snapshot, encoding: .utf8)
            check(!data.contains("SYNTHETIC_SECRET"), "raw error not persisted")
            let calls = try Data(contentsOf: location.codexHome.appendingPathComponent("calls"))
            try UsageWorker.run(action: "poll", paths: location, executable: executable)
            check(try Data(contentsOf: location.codexHome.appendingPathComponent("calls")) == calls, "cooldown survives worker restart")
            if scenario == "file-storage" {
                check(!String(decoding: calls, as: UTF8.self).contains("account/"), "fail closed before login with file storage")
            }
        }
        for url in ["http://auth.openai.com/authorize", "https://auth.openai.com.evil.example/", "https://user@auth.openai.com/", "file:///tmp/example", "https://auth.openai.com:8080/"] {
            check(CodexSession.loginURL(url) == nil, "reject unsafe browser destination")
        }
        check(CodexSession.loginURL("https://chatgpt.com/authorize") != nil, "allow documented host")
        let locked = try paths("ready")
        let fd = open(locked.codexHome.appendingPathComponent("usage.lock").path, O_CREAT | O_RDWR, 0o600)
        check(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0, "test lock")
        do { try UsageWorker.run(action: "refresh", paths: locked, executable: executable); fatalError("overlapping refresh") }
        catch UsageFailure.busy { }
        flock(fd, LOCK_UN); close(fd)
        check(!FileManager.default.fileExists(atPath: locked.codexHome.appendingPathComponent("calls").path), "busy worker does not start a server")
        print("Managed usage: \(count) checks passed (login, snapshots, migration, failure isolation, cooldown, URL validation, locking)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='managed-usage-tests-') as directory:
    work = Path(directory)
    fake = work / 'fake-codex'
    fake.write_text(server)
    fake.chmod(0o700)
    swift = work / 'Checks.swift'
    swift.write_text(checks)
    binary = work / 'checks'
    sources = ['CodexUsage.swift', 'UsageStore.swift', 'CodexSession.swift', 'UsageWorker.swift']
    subprocess.run(['swiftc', '-module-cache-path', str(root / 'build/ModuleCache'),
                    *[str(root / 'Sources' / name) for name in sources], str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(work), str(fake)], check=True, timeout=60)
