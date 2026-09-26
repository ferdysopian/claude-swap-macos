//
//  AutoSwitchDaemonService.swift
//  ClaudeSwap
//
//  `cswap auto` is a foreground polling loop (see `cswap auto --help`) — it
//  does nothing unless something keeps a process alive running it. The app's
//  Automation toggle used to only try to flip `autoswitch.enabled` in
//  settings.json — not even a valid key — so nothing ever polled. This
//  service makes the toggle real by installing
//  a per-user LaunchAgent that runs `cswap auto --json` continuously,
//  restarts it if it dies, and logs to ~/Library/Logs/ClaudeSwap/.
//
//  Uses `launchctl bootstrap`/`bootout` (modern, per-user domain) with a
//  fallback to `load`/`unload` for older macOS.
//

import Foundation
import os.log

enum AutoSwitchDaemonError: LocalizedError {
    case cswapNotFound
    case launchctlFailed(String)

    var errorDescription: String? {
        switch self {
        case .cswapNotFound:
            return "cswap executable not found; cannot start the auto-switch daemon."
        case .launchctlFailed(let message):
            return "launchctl failed: \(message)"
        }
    }
}

/// Manages a per-user LaunchAgent that runs `cswap auto --json` in the
/// background so auto-switch actually takes effect 24/7, independent of
/// whether the app itself is running.
enum AutoSwitchDaemonService {
    static let label = "app.claudeswap.autoswitch"

    private static var log: Logger { Logger(subsystem: "app.claudeswap.ClaudeSwap", category: "AutoSwitchDaemon") }

    private static var agentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private static var plistURL: URL {
        agentsDir.appendingPathComponent("\(label).plist")
    }

    private static var logDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeSwap", isDirectory: true)
    }

    /// True if the LaunchAgent is currently loaded (running or scheduled to
    /// keep running) in the user's launchd domain — the ground truth for
    /// "is auto-switch actually active".
    static func isRunning() -> Bool {
        let uid = getuid()
        let result = runProcess("/bin/launchctl", ["print", "gui/\(uid)/\(label)"])
        return result.exitCode == 0
    }

    /// Installs (or refreshes) the LaunchAgent and starts it immediately.
    /// Idempotent: safe to call when it's already running (e.g. to apply
    /// updated threshold/interval settings — bootout+bootstrap picks them up
    /// since they're passed as CLI arguments, not re-read at runtime).
    static func start(
        cswapPath: String,
        thresholdPct: Double,
        intervalSeconds: Double,
        cooldownSeconds: Double,
        strategy: String,
        includeAPIKeyAccounts: Bool
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: cswapPath) else {
            throw AutoSwitchDaemonError.cswapNotFound
        }

        try? FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        // Stop any existing instance first so argument changes (threshold,
        // interval, strategy) actually take effect on reload.
        stopQuietly()

        // Clamp to the ranges `cswap auto` accepts (threshold 50-99.9,
        // interval >= 15) — an out-of-range flag makes argparse exit
        // non-zero, which KeepAlive would turn into a crash loop.
        let threshold = min(max(thresholdPct, 50), 99.9)
        let interval = max(Int(intervalSeconds), 15)
        let cooldown = max(Int(cooldownSeconds), 0)
        // argparse choices are {best,consume-first}.
        let strategyArg = (strategy == "consumeFirst" || strategy == "consume-first") ? "consume-first" : "best"

        var args = [
            cswapPath, "auto", "--json",
            "--threshold", String(format: "%.1f", threshold),
            "--interval", String(interval),
            "--cooldown", String(cooldown),
            "--strategy", strategyArg,
        ]
        args.append(includeAPIKeyAccounts ? "--include-api-key-accounts" : "--no-include-api-key-accounts")

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": args,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false, "Crashed": true],
            "ProcessType": "Background",
            "StandardOutPath": logDir.appendingPathComponent("autoswitch.log").path,
            "StandardErrorPath": logDir.appendingPathComponent("autoswitch.err.log").path,
            "ThrottleInterval": 10,
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        try bootstrap()
        log.info("auto-switch daemon started: threshold=\(thresholdPct, privacy: .public)%")
    }

    /// Stops and unloads the LaunchAgent. Leaves the plist in place (harmless;
    /// `start()` overwrites it) so re-enabling doesn't need to recreate the
    /// directory dance.
    static func stop() {
        stopQuietly()
        log.info("auto-switch daemon stopped")
    }

    private static func stopQuietly() {
        let uid = getuid()
        _ = runProcess("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        // Fallback for older macOS where bootout on a not-yet-bootstrapped
        // label can behave inconsistently; unload is a harmless no-op if
        // nothing is loaded.
        if FileManager.default.fileExists(atPath: plistURL.path) {
            _ = runProcess("/bin/launchctl", ["unload", plistURL.path])
        }
        // bootout returns before launchd has fully torn the job down; an
        // immediate bootstrap of the same label then fails with EIO (5).
        for _ in 0..<20 where isRunning() {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func bootstrap() throws {
        let uid = getuid()
        let result = runProcess("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistURL.path])
        if result.exitCode != 0 {
            // Fallback for older macOS / edge cases.
            let legacy = runProcess("/bin/launchctl", ["load", "-w", plistURL.path])
            if legacy.exitCode != 0 {
                throw AutoSwitchDaemonError.launchctlFailed(
                    result.stderr.isEmpty ? legacy.stderr : result.stderr
                )
            }
        }
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    @discardableResult
    private static func runProcess(_ launchPath: String, _ arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: "\(error)")
        }
        // Drain before waiting so a chatty `launchctl print` can't fill the
        // pipe buffer and deadlock waitUntilExit.
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
