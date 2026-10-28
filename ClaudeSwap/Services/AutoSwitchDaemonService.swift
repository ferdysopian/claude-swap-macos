//
//  AutoSwitchDaemonService.swift
//  ClaudeSwap
//
//  `cswap auto` is a foreground polling loop — it does nothing unless
//  something keeps a process alive running it. This service installs a
//  per-user LaunchAgent that runs plain `cswap auto --json`, with no
//  threshold/interval/strategy flags: upstream's settings.json (managed via
//  `cswap config set autoswitch.*`) is the single source of configuration,
//  so after a settings change the caller restarts the service.
//
//  Upstream also ships an optional menu bar agent (`com.cswap.menubar`) that
//  can run the same engine. We only detect it as a possible conflict and
//  never stop or modify it.
//
//  Everything goes through `AutoSwitchServiceEnvironment` so tests can use
//  temp directories and a fake launchctl. The live environment is for the
//  app only.
//

import Foundation
import os.log

// MARK: - launchctl abstraction

struct LaunchctlResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

protocol LaunchctlRunning: Sendable {
    func run(_ arguments: [String]) -> LaunchctlResult
}

/// Runs the real `/bin/launchctl` synchronously.
struct LiveLaunchctl: LaunchctlRunning {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    func run(_ arguments: [String]) -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return LaunchctlResult(exitCode: -1, stdout: "", stderr: "\(error)")
        }
        // Drain both pipes concurrently so a chatty `print` can't fill a
        // pipe buffer and deadlock waitUntilExit.
        let errBox = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.set(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return LaunchctlResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errBox.get(), encoding: .utf8) ?? ""
        )
    }
}

// MARK: - Environment

struct AutoSwitchServiceEnvironment: Sendable {
    var launchAgentsDirectory: URL
    var logDirectory: URL
    var userID: uid_t
    var launchctl: any LaunchctlRunning
    var sleep: @Sendable (Duration) -> Void

    static var live: AutoSwitchServiceEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AutoSwitchServiceEnvironment(
            launchAgentsDirectory: home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            logDirectory: home.appendingPathComponent("Library/Logs/ClaudeSwap", isDirectory: true),
            userID: getuid(),
            launchctl: LiveLaunchctl(),
            sleep: { duration in
                let c = duration.components
                Thread.sleep(forTimeInterval: Double(c.seconds) + Double(c.attoseconds) / 1e18)
            }
        )
    }
}

// MARK: - Status

struct AutoSwitchServiceStatus: Sendable, Equatable {
    enum Health: Sendable, Equatable {
        case disabled
        case running
        /// Registered, but no pid yet or between KeepAlive restarts.
        case starting
        case failing(lastExitStatus: Int32)
        case launcherMissing
        /// Registered in launchd but our plist is gone.
        case orphanedRegistration
        /// Plist present but not registered.
        case notLoaded
    }

    var plistInstalled: Bool
    /// `launchctl print gui/<uid>/<label>` exited 0.
    var registered: Bool
    var pid: Int32?
    var lastExitStatus: Int32?
    /// ProgramArguments[0] read back from our plist.
    var launcherPath: String?
    var launcherExists: Bool
    var upstreamMenuBarAgentInstalled: Bool
    var health: Health

    var isRunning: Bool { pid != nil }
}

enum AutoSwitchDaemonError: LocalizedError, Equatable {
    case launcherNotExecutable(String)
    case launchctlFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .launcherNotExecutable(let path):
            return "cswap is not an executable file at \(path); cannot set up the auto-switch service."
        case .launchctlFailed(let message):
            return "launchctl failed: \(message)"
        case .verificationFailed(let message):
            return "Auto-switch service verification failed: \(message)"
        }
    }
}

// MARK: - Service

/// Manages the per-user LaunchAgent that keeps `cswap auto --json` running.
struct AutoSwitchDaemonService: Sendable {
    static let label = "app.claudeswap.autoswitch"
    static let upstreamMenuBarLabel = "com.cswap.menubar"
    static let maxLogBytes: UInt64 = 5 * 1024 * 1024

    let environment: AutoSwitchServiceEnvironment

    init(environment: AutoSwitchServiceEnvironment = .live) {
        self.environment = environment
    }

    private static let log = Logger(subsystem: "app.claudeswap.ClaudeSwap", category: "AutoSwitchDaemon")

    var plistURL: URL {
        environment.launchAgentsDirectory.appendingPathComponent("\(Self.label).plist")
    }

    private var upstreamPlistURL: URL {
        environment.launchAgentsDirectory.appendingPathComponent("\(Self.upstreamMenuBarLabel).plist")
    }

    private var serviceTarget: String { "gui/\(environment.userID)/\(Self.label)" }
    private var domainTarget: String { "gui/\(environment.userID)" }

    // MARK: Status

    /// Read-only snapshot of launchd + plist state.
    func status() -> AutoSwitchServiceStatus {
        let fm = FileManager.default
        let plistInstalled = fm.fileExists(atPath: plistURL.path)
        let print = environment.launchctl.run(["print", serviceTarget])
        let registered = print.exitCode == 0

        let pid = registered ? Self.parseInt(in: print.stdout, key: "pid") : nil
        let lastExit = registered ? Self.parseInt(in: print.stdout, key: "last exit code") : nil

        var launcherPath: String?
        if plistInstalled,
           let data = try? Data(contentsOf: plistURL),
           let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let args = obj["ProgramArguments"] as? [String],
           let first = args.first {
            launcherPath = first
        }
        let launcherExists = launcherPath.map { fm.isExecutableFile(atPath: $0) } ?? false
        let upstream = fm.fileExists(atPath: upstreamPlistURL.path)

        let health: AutoSwitchServiceStatus.Health
        if !plistInstalled {
            health = registered ? .orphanedRegistration : .disabled
        } else if launcherPath != nil && !launcherExists {
            health = .launcherMissing
        } else if !registered {
            health = .notLoaded
        } else if pid != nil {
            health = .running
        } else if let lastExit, lastExit != 0 {
            health = .failing(lastExitStatus: Int32(truncatingIfNeeded: lastExit))
        } else {
            health = .starting
        }

        return AutoSwitchServiceStatus(
            plistInstalled: plistInstalled,
            registered: registered,
            pid: pid.map { Int32(truncatingIfNeeded: $0) },
            lastExitStatus: lastExit.map { Int32(truncatingIfNeeded: $0) },
            launcherPath: launcherPath,
            launcherExists: launcherExists,
            upstreamMenuBarAgentInstalled: upstream,
            health: health
        )
    }

    /// Parses `key = N` (possibly negative) from `launchctl print` output.
    /// Ignores values like "(never exited)".
    private static func parseInt(in text: String, key: String) -> Int? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(key) else { continue }
            let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            if let n = Int(value) { return n }
        }
        return nil
    }

    // MARK: Enable / disable

    /// Installs (or refreshes) the LaunchAgent and starts it.
    /// `cswapPath` is stored as given (symlinks are not resolved) so CLI
    /// upgrades that replace the target don't break the plist.
    func enable(cswapPath: String) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: cswapPath, isDirectory: &isDir), !isDir.boolValue,
              fm.isExecutableFile(atPath: cswapPath) else {
            throw AutoSwitchDaemonError.launcherNotExecutable(cswapPath)
        }

        try fm.createDirectory(at: environment.launchAgentsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: environment.logDirectory, withIntermediateDirectories: true)

        bootoutAndWait()

        let outLog = environment.logDirectory.appendingPathComponent("autoswitch.log")
        let errLog = environment.logDirectory.appendingPathComponent("autoswitch.err.log")
        rotateIfNeeded(outLog)
        rotateIfNeeded(errLog)

        let launcherDir = (cswapPath as NSString).deletingLastPathComponent
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [cswapPath, "auto", "--json"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 30,
            "ProcessType": "Background",
            "StandardOutPath": outLog.path,
            "StandardErrorPath": errLog.path,
            "EnvironmentVariables": ["PATH": "\(launcherDir):/usr/bin:/bin:/usr/sbin:/sbin"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        let boot = environment.launchctl.run(["bootstrap", domainTarget, plistURL.path])
        if boot.exitCode != 0 {
            let legacy = environment.launchctl.run(["load", "-w", plistURL.path])
            if legacy.exitCode != 0 {
                throw AutoSwitchDaemonError.launchctlFailed(boot.stderr.isEmpty ? legacy.stderr : boot.stderr)
            }
        }

        guard environment.launchctl.run(["print", serviceTarget]).exitCode == 0 else {
            throw AutoSwitchDaemonError.verificationFailed("service is not registered after start")
        }
        Self.log.info("auto-switch service enabled")
    }

    /// Persistently disables: unregisters and removes our plist so nothing
    /// re-enables at next login. Touches no other label.
    func disable() throws {
        bootoutAndWait()
        let fm = FileManager.default
        if fm.fileExists(atPath: plistURL.path) {
            try? fm.removeItem(at: plistURL)
        }
        if environment.launchctl.run(["print", serviceTarget]).exitCode == 0 {
            throw AutoSwitchDaemonError.verificationFailed("service is still registered after bootout")
        }
        if fm.fileExists(atPath: plistURL.path) {
            throw AutoSwitchDaemonError.verificationFailed("could not remove \(plistURL.path)")
        }
        Self.log.info("auto-switch service disabled")
    }

    /// Re-applies the service after a `cswap config` change. No-op when our
    /// plist isn't installed.
    func restartIfInstalled(cswapPath: String) throws {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try enable(cswapPath: cswapPath)
    }

    // MARK: Migration

    /// Earlier builds installed this same service under a different label
    /// (any `*.claudeswap.autoswitch` agent running `cswap auto`). Unregisters
    /// and deletes those, then re-enables the service under the current label
    /// so a user who had automation on keeps it on. Returns true if a legacy
    /// agent was found. Touches nothing that doesn't match that shape.
    @discardableResult
    func migrateLegacyAgents(cswapPath: String) throws -> Bool {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: environment.launchAgentsDirectory.path)) ?? []
        var found = false
        for name in files where name.hasSuffix(".claudeswap.autoswitch.plist") && name != "\(Self.label).plist" {
            let url = environment.launchAgentsDirectory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let legacyLabel = plist["Label"] as? String,
                  legacyLabel.hasSuffix(".claudeswap.autoswitch"),
                  let args = plist["ProgramArguments"] as? [String],
                  args.count >= 2, args[1] == "auto" else { continue }
            let target = "gui/\(environment.userID)/\(legacyLabel)"
            if environment.launchctl.run(["bootout", target]).exitCode != 0 {
                _ = environment.launchctl.run(["unload", url.path])
            }
            try fm.removeItem(at: url)
            found = true
            Self.log.info("removed legacy auto-switch agent")
        }
        if found, !fm.fileExists(atPath: plistURL.path) {
            try enable(cswapPath: cswapPath)
        }
        return found
    }

    // MARK: Helpers

    /// bootout (fallback unload when plist exists), then wait up to ~2 s for
    /// launchd to drop the registration. "Not loaded" is success.
    private func bootoutAndWait() {
        let res = environment.launchctl.run(["bootout", serviceTarget])
        if res.exitCode != 0, FileManager.default.fileExists(atPath: plistURL.path) {
            _ = environment.launchctl.run(["unload", plistURL.path])
        }
        for _ in 0..<20 {
            if environment.launchctl.run(["print", serviceTarget]).exitCode != 0 { return }
            environment.sleep(.milliseconds(100))
        }
    }

    /// One-generation rotation: a log over the cap becomes `<name>.1`.
    private func rotateIfNeeded(_ url: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.uint64Value > Self.maxLogBytes else { return }
        let old = url.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
    }
}
