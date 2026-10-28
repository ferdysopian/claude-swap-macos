//
//  BridgeProcess.swift
//  ClaudeSwap
//
//  Thin wrapper around `Foundation.Process` that owns the helper's
//  lifecycle: locating the executable, launching it with the right
//  environment, and exposing line-based async sequences over its pipes.
//  `CoreBridgeClient` is the only intended caller.
//

import Foundation

/// Where to find the core helper executable / interpreter.
enum HelperLocation: Sendable, Equatable {
    /// A standalone bridge executable (development only).
    case bridgeExecutable(URL)
    /// Development checkout: run `python -m claude_swap.bridge`.
    case pythonModule(interpreter: URL, workingDirectory: URL?)

    var launchDescription: String {
        switch self {
        case .bridgeExecutable(let url):
            return url.path
        case .pythonModule(let interpreter, let workingDirectory):
            let cwd = workingDirectory.map { " (cwd: \($0.path))" } ?? ""
            return "\(interpreter.path) -m claude_swap.bridge\(cwd)"
        }
    }
}

/// How the app should talk to Claude Swap.
enum CoreBackend: Sendable, Equatable {
    /// Development only: NDJSON bridge from a local checkout, selected with
    /// `CLAUDE_SWAP_BACKEND=bridge` + `CLAUDE_SWAP_CORE_PATH`. Released
    /// upstream versions ship no bridge module.
    case bridge(HelperLocation)
    /// Production: the separately installed `cswap` CLI.
    case cli(CLICandidate)
    /// Explicit demo data (previews, tests, `-demoMode`).
    case fixture
    /// No usable CLI. `configuredPath` is set when an explicit path was
    /// given but isn't executable.
    case unavailable(configuredPath: String?)
}

/// Picks the backend. Production builds only ever use the installed CLI;
/// demo data and the dev bridge must be asked for explicitly, and nothing
/// falls back to a sibling checkout or to demo data on its own.
enum HelperLocator {
    static let backendEnvironmentKey = "CLAUDE_SWAP_BACKEND"
    static let devCorePathEnvironmentKey = "CLAUDE_SWAP_CORE_PATH"
    static let demoLaunchArgument = "-demoMode"

    static func resolveBackend(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        userDefaults: UserDefaults = .standard,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> CoreBackend {
        // Hosted unit tests launch the app itself; never let that touch the
        // developer's real CLI, accounts or Keychain.
        if environment["XCTestConfigurationFilePath"] != nil
            || environment[backendEnvironmentKey] == "fixture"
            || arguments.contains(demoLaunchArgument) {
            return .fixture
        }
        if environment[backendEnvironmentKey] == "bridge" {
            guard let root = environment[devCorePathEnvironmentKey],
                  let location = pythonLocation(atRepoRoot: root, fileManager: fileManager) else {
                return .unavailable(configuredPath: environment[devCorePathEnvironmentKey])
            }
            return .bridge(location)
        }
        switch CLIDiscovery.resolve(environment: environment, userDefaults: userDefaults, home: home, fileManager: fileManager) {
        case .found(let candidate):
            return .cli(candidate)
        case .configuredPathInvalid(let path):
            return .unavailable(configuredPath: path)
        case .notFound:
            return .unavailable(configuredPath: nil)
        }
    }

    /// The dev bridge location, if (and only if) it was explicitly selected.
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> HelperLocation? {
        if case .bridge(let location) = resolveBackend(environment: environment) {
            return location
        }
        return nil
    }

    /// Given a checkout root, find a Python interpreter in its virtualenv.
    private static func pythonLocation(atRepoRoot root: String, fileManager: FileManager) -> HelperLocation? {
        let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
        let candidates = [
            rootURL.appendingPathComponent(".venv/bin/python3"),
            rootURL.appendingPathComponent(".venv/bin/python"),
            rootURL.appendingPathComponent("venv/bin/python3"),
        ]
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return .pythonModule(interpreter: candidate, workingDirectory: rootURL)
        }
        return nil
    }
}

/// Owns a single helper subprocess and its pipes. Not thread-safe on its
/// own — always accessed from within the `CoreBridgeClient` actor.
final class BridgeProcess {
    private(set) var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    var isRunning: Bool { process?.isRunning ?? false }
    var processIdentifier: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    /// Launches the helper described by `location`. Throws `.launchFailed`
    /// if `Process.run()` itself throws (e.g. file missing, not executable).
    func launch(_ location: HelperLocation) throws -> AsyncStream<String> {
        let process = Process()
        switch location {
        case .bridgeExecutable(let url):
            process.executableURL = url
            process.arguments = []
        case .pythonModule(let interpreter, let workingDirectory):
            process.executableURL = interpreter
            process.arguments = ["-m", "claude_swap.bridge"]
            process.currentDirectoryURL = workingDirectory
        }

        // Never pass secrets via argv/env; only non-sensitive plumbing.
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_SWAP_BRIDGE_PROTOCOL_VERSION"] = String(BridgeProtocolVersion.current)
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.process = process

        let lineStream = Self.lineStream(from: stdout.fileHandleForReading)

        do {
            try process.run()
        } catch {
            self.process = nil
            throw BridgeError.launchFailed(error.localizedDescription)
        }
        return lineStream
    }

    /// Writes one NDJSON line (a trailing newline is appended) to the
    /// helper's stdin. No-ops if the process isn't running.
    func writeLine(_ line: String) throws {
        guard let stdinPipe, isRunning else { throw BridgeError.notConnected }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func terminate() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    /// Force-kills if still alive after `terminate()` didn't converge.
    func forceKillIfNeeded() {
        guard let process, process.isRunning else { return }
        process.interrupt()
        kill(process.processIdentifier, SIGKILL)
    }

    /// Adapts a pipe's raw bytes into an async sequence of complete lines,
    /// splitting on `\n`. Terminates the stream when the pipe closes (EOF).
    private static func lineStream(from handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "app.claudeswap.ClaudeSwap.bridge.stdout")
            handle.readabilityHandler = nil

            queue.async {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        break // EOF: helper closed stdout
                    }
                    buffer.append(chunk)
                    while let newlineRange = buffer.range(of: Data([0x0A])) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                        buffer.removeSubrange(buffer.startIndex..<newlineRange.upperBound)
                        if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                            continuation.yield(line)
                        }
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }
}
