//
//  AutoSwitchDaemonServiceTests.swift
//  ClaudeSwapTests
//
//  Uses a fake launchctl and temp directories only; never touches the real
//  launchd or ~/Library.
//

import Foundation
import Testing
@testable import ClaudeSwap

/// Simulates launchd registration state and records every call.
final class FakeLaunchctl: LaunchctlRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _registered = false
    private var _printOutput = ""
    private var _bootstrapExit: Int32 = 0
    private var _loadExit: Int32 = 0
    private var _canUnregister = true

    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    var registered: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _registered }
        set { lock.lock(); _registered = newValue; lock.unlock() }
    }
    var printOutput: String {
        get { lock.lock(); defer { lock.unlock() }; return _printOutput }
        set { lock.lock(); _printOutput = newValue; lock.unlock() }
    }
    var bootstrapExit: Int32 {
        get { lock.lock(); defer { lock.unlock() }; return _bootstrapExit }
        set { lock.lock(); _bootstrapExit = newValue; lock.unlock() }
    }
    var loadExit: Int32 {
        get { lock.lock(); defer { lock.unlock() }; return _loadExit }
        set { lock.lock(); _loadExit = newValue; lock.unlock() }
    }
    var canUnregister: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _canUnregister }
        set { lock.lock(); _canUnregister = newValue; lock.unlock() }
    }

    func run(_ arguments: [String]) -> LaunchctlResult {
        lock.lock(); defer { lock.unlock() }
        _calls.append(arguments)
        switch arguments.first {
        case "print":
            return _registered
                ? LaunchctlResult(exitCode: 0, stdout: _printOutput, stderr: "")
                : LaunchctlResult(exitCode: 113, stdout: "", stderr: "Could not find service")
        case "bootout", "unload":
            guard _registered else { return LaunchctlResult(exitCode: 3, stdout: "", stderr: "No such process") }
            if _canUnregister { _registered = false }
            return LaunchctlResult(exitCode: 0, stdout: "", stderr: "")
        case "bootstrap":
            if _bootstrapExit == 0 { _registered = true }
            return LaunchctlResult(exitCode: _bootstrapExit, stdout: "", stderr: _bootstrapExit == 0 ? "" : "bootstrap failed")
        case "load":
            if _loadExit == 0 { _registered = true }
            return LaunchctlResult(exitCode: _loadExit, stdout: "", stderr: _loadExit == 0 ? "" : "load failed")
        default:
            return LaunchctlResult(exitCode: 1, stdout: "", stderr: "unexpected")
        }
    }
}

@Suite struct AutoSwitchDaemonServiceTests {
    struct Fixture {
        let root: URL
        let agents: URL
        let logs: URL
        let fake: FakeLaunchctl
        let service: AutoSwitchDaemonService
        let cswap: String
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoswitch-tests-\(UUID().uuidString)", isDirectory: true)
        let agents = root.appendingPathComponent("LaunchAgents", isDirectory: true)
        let logs = root.appendingPathComponent("Logs", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cswap = bin.appendingPathComponent("cswap")
        try "#!/bin/sh\nexit 0\n".write(to: cswap, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cswap.path)
        let fake = FakeLaunchctl()
        let env = AutoSwitchServiceEnvironment(
            launchAgentsDirectory: agents, logDirectory: logs, userID: 501,
            launchctl: fake, sleep: { _ in }
        )
        return Fixture(root: root, agents: agents, logs: logs, fake: fake,
                       service: AutoSwitchDaemonService(environment: env), cswap: cswap.path)
    }

    private func readPlist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func enableWritesPlistAndBootstraps() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.service.enable(cswapPath: f.cswap)

        let plist = try readPlist(f.service.plistURL)
        #expect(plist["Label"] as? String == AutoSwitchDaemonService.label)
        #expect(plist["ProgramArguments"] as? [String] == [f.cswap, "auto", "--json"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect((plist["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false])
        #expect(plist["ThrottleInterval"] as? Int == 30)
        let env = plist["EnvironmentVariables"] as? [String: String]
        #expect(env?["PATH"]?.hasSuffix("/usr/bin:/bin:/usr/sbin:/sbin") == true)
        #expect(env?.count == 1)
        #expect((plist["StandardOutPath"] as? String)?.hasPrefix(f.logs.path) == true)
        #expect(f.fake.calls.contains(["bootstrap", "gui/501", f.service.plistURL.path]))
        #expect(f.fake.registered)
    }

    @Test func enableFallsBackToLoad() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.fake.bootstrapExit = 5
        try f.service.enable(cswapPath: f.cswap)
        #expect(f.fake.calls.contains(["load", "-w", f.service.plistURL.path]))
    }

    @Test func enableThrowsWhenLaunchctlFailsEntirely() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.fake.bootstrapExit = 5
        f.fake.loadExit = 1
        #expect(throws: AutoSwitchDaemonError.launchctlFailed("bootstrap failed")) {
            try f.service.enable(cswapPath: f.cswap)
        }
    }

    @Test func enableRejectsNonExecutableLauncher() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let plain = f.root.appendingPathComponent("plain")
        try "x".write(to: plain, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        #expect(throws: AutoSwitchDaemonError.launcherNotExecutable(plain.path)) {
            try f.service.enable(cswapPath: plain.path)
        }
        #expect(!FileManager.default.fileExists(atPath: f.service.plistURL.path))
        #expect(f.fake.calls.isEmpty)
    }

    @Test func disableBootsOutAndRemovesPlist() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.service.enable(cswapPath: f.cswap)
        try f.service.disable()
        #expect(!f.fake.registered)
        #expect(!FileManager.default.fileExists(atPath: f.service.plistURL.path))
        #expect(f.service.status().health == .disabled)
    }

    @Test func disableWhenNothingInstalledSucceeds() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.service.disable()
        #expect(f.fake.calls.allSatisfy { $0.first != "unload" })
    }

    @Test func disableThrowsWhenCannotUnregister() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.service.enable(cswapPath: f.cswap)
        f.fake.canUnregister = false
        #expect(throws: AutoSwitchDaemonError.self) { try f.service.disable() }
    }

    @Test func statusParsesRunning() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.service.enable(cswapPath: f.cswap)
        f.fake.printOutput = "gui/501/x = {\n\tstate = running\n\tpid = 4242\n\tlast exit code = 1\n}"
        let s = f.service.status()
        #expect(s.pid == 4242)
        #expect(s.isRunning)
        #expect(s.lastExitStatus == 1)
        #expect(s.health == .running)
        #expect(s.launcherPath == f.cswap)
        #expect(s.launcherExists)
    }

    @Test func statusFailingAndStarting() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.service.enable(cswapPath: f.cswap)
        f.fake.printOutput = "\tlast exit code = 78\n"
        #expect(f.service.status().health == .failing(lastExitStatus: 78))
        f.fake.printOutput = "\tlast exit code = (never exited)\n"
        let s = f.service.status()
        #expect(s.lastExitStatus == nil)
        #expect(s.health == .starting)
    }

    @Test func statusNotRegisteredAndOrphaned() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.service.enable(cswapPath: f.cswap)
        f.fake.registered = false
        #expect(f.service.status().health == .notLoaded)
        f.fake.registered = true
        try FileManager.default.removeItem(at: f.service.plistURL)
        let s = f.service.status()
        #expect(s.health == .orphanedRegistration)
        #expect(!s.plistInstalled)
    }

    @Test func statusLauncherMissing() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.service.enable(cswapPath: f.cswap)
        try FileManager.default.removeItem(atPath: f.cswap)
        let s = f.service.status()
        #expect(s.health == .launcherMissing)
        #expect(!s.launcherExists)
    }

    @Test func statusDetectsUpstreamMenuBarAgentAndDoesNotMutate() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.createDirectory(at: f.agents, withIntermediateDirectories: true)
        let upstream = f.agents.appendingPathComponent("com.cswap.menubar.plist")
        try "<plist/>".write(to: upstream, atomically: true, encoding: .utf8)
        let s = f.service.status()
        #expect(s.upstreamMenuBarAgentInstalled)
        #expect(s.health == .disabled)
        #expect(f.fake.calls.allSatisfy { $0.first == "print" })
        #expect(FileManager.default.fileExists(atPath: upstream.path))
    }

    @Test func restartIfInstalledNoOpWhenAbsent() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.service.restartIfInstalled(cswapPath: f.cswap)
        #expect(f.fake.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.service.plistURL.path))
    }

    @Test func restartIfInstalledReenablesWhenPresent() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.service.enable(cswapPath: f.cswap)
        try f.service.restartIfInstalled(cswapPath: f.cswap)
        #expect(f.fake.calls.filter { $0.first == "bootstrap" }.count == 2)
        #expect(f.fake.calls.contains { $0.first == "bootout" })
    }

    @Test func rotatesLargeLogs() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.createDirectory(at: f.logs, withIntermediateDirectories: true)
        let log = f.logs.appendingPathComponent("autoswitch.log")
        let small = f.logs.appendingPathComponent("autoswitch.err.log")
        try Data(count: 5 * 1024 * 1024 + 1).write(to: log)
        try "tiny".write(to: small, atomically: true, encoding: .utf8)
        try "stale".write(to: f.logs.appendingPathComponent("autoswitch.log.1"), atomically: true, encoding: .utf8)
        try f.service.enable(cswapPath: f.cswap)
        let rotated = f.logs.appendingPathComponent("autoswitch.log.1")
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(try Data(contentsOf: rotated).count == 5 * 1024 * 1024 + 1)
        #expect(FileManager.default.fileExists(atPath: small.path))
        #expect(!FileManager.default.fileExists(atPath: small.path + ".1"))
    }
}
