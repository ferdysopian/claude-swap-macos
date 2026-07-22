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
    /// A bundled, signed-or-not helper binary shipped inside the app.
    case bundled(URL)
    /// A standalone `cswap-bridge` executable on PATH (or next to `cswap`).
    case bridgeExecutable(URL)
    /// A dev-mode / tool-install: run `python -m claude_swap.bridge`.
    case pythonModule(interpreter: URL, workingDirectory: URL?)

    var launchDescription: String {
        switch self {
        case .bundled(let url), .bridgeExecutable(let url):
            return url.path
        case .pythonModule(let interpreter, let workingDirectory):
            let cwd = workingDirectory.map { " (cwd: \($0.path))" } ?? ""
            return "\(interpreter.path) -m claude_swap.bridge\(cwd)"
        }
    }
}

/// How the app should talk to an installed Claude Swap installation.
enum CoreBackend: Sendable, Equatable {
    /// NDJSON bridge helper (preferred when available).
    case bridge(HelperLocation)
    /// Shell out to an installed `cswap` CLI (live accounts, no bridge module).
    case cli(cswapURL: URL)
    /// No install found — use in-app fixture/preview data.
    case fixture
}

/// Resolves how to reach Claude Swap, in priority order:
/// 1. `CLAUDE_SWAP_CORE_PATH` / Settings override (checkout with bridge)
/// 2. Bundled `claude-swap-helper`
/// 3. Installed `cswap-bridge` or `cswap`'s Python **with** `claude_swap.bridge`
/// 4. Installed `cswap` on PATH (CLI live mode — even without bridge)
/// 5. Sibling `claude-swap` checkout with a venv + bridge (dev)
/// 6. Fixture
enum HelperLocator {
    static let userDefaultsKey = "coreOverridePath"

    static func resolveBackend(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> CoreBackend {
        if let overridePath = environment["CLAUDE_SWAP_CORE_PATH"],
           let location = pythonLocation(atRepoRoot: overridePath, fileManager: fileManager),
           bridgeImportable(location) {
            return .bridge(location)
        }
        if let overridePath = userDefaults.string(forKey: userDefaultsKey),
           let location = pythonLocation(atRepoRoot: overridePath, fileManager: fileManager),
           bridgeImportable(location) {
            return .bridge(location)
        }
        if let bundled = bundle.url(forAuxiliaryExecutable: "claude-swap-helper"),
           fileManager.isExecutableFile(atPath: bundled.path) {
            return .bridge(.bundled(bundled))
        }
        if let bridge = findExecutable(named: "cswap-bridge", environment: environment, fileManager: fileManager) {
            return .bridge(.bridgeExecutable(bridge))
        }
        if let cswap = findExecutable(named: "cswap", environment: environment, fileManager: fileManager) {
            if let location = pythonFromCswapLauncher(cswap, fileManager: fileManager),
               bridgeImportable(location) {
                return .bridge(location)
            }
            // Installed cswap without bridge → still use live CLI data.
            return .cli(cswapURL: cswap)
        }
        for candidate in siblingCheckoutCandidates() {
            if let location = pythonLocation(atRepoRoot: candidate, fileManager: fileManager),
               bridgeImportable(location) {
                return .bridge(location)
            }
        }
        return .fixture
    }

    /// Back-compat for call sites that only care about a bridge helper.
    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> HelperLocation? {
        if case .bridge(let location) = resolveBackend(
            environment: environment,
            userDefaults: userDefaults,
            bundle: bundle,
            fileManager: fileManager
        ) {
            return location
        }
        return nil
    }

    /// Given a checkout root (e.g. `.../projects/claude-swap`), find a
    /// usable Python interpreter in its virtualenv.
    private static func pythonLocation(atRepoRoot root: String, fileManager: FileManager) -> HelperLocation? {
        let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
        let candidates = [
            rootURL.appendingPathComponent(".venv/bin/python3"),
            rootURL.appendingPathComponent(".venv/bin/python"),
            rootURL.appendingPathComponent(".venv312/bin/python3"),
            rootURL.appendingPathComponent("venv/bin/python3"),
        ]
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return .pythonModule(interpreter: candidate, workingDirectory: rootURL)
        }
        return nil
    }

    private static func findExecutable(
        named name: String,
        environment: [String: String],
        fileManager: FileManager
    ) -> URL? {
        let pathEnv = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
        // GUI apps often inherit a minimal PATH — also check common user bins.
        let extra = [
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        var dirs = pathEnv.split(separator: ":").map(String.init)
        for dir in extra where !dirs.contains(dir) {
            dirs.append(dir)
        }
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url.resolvingSymlinksInPath()
            }
        }
        return nil
    }

    /// `cswap` is typically a uv/pip console_script with a shebang pointing
    /// at the tool env's python.
    private static func pythonFromCswapLauncher(_ cswap: URL, fileManager: FileManager) -> HelperLocation? {
        guard let shebang = readShebang(of: cswap) else {
            let siblingPython = cswap.deletingLastPathComponent().appendingPathComponent("python")
            if fileManager.isExecutableFile(atPath: siblingPython.path) {
                return .pythonModule(interpreter: siblingPython, workingDirectory: nil)
            }
            return nil
        }
        let interpreter = URL(fileURLWithPath: shebang)
        guard fileManager.isExecutableFile(atPath: interpreter.path) else { return nil }
        return .pythonModule(interpreter: interpreter, workingDirectory: nil)
    }

    private static func readShebang(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 512)
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#!") else { return nil }
        let line = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let path = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    private static func bridgeImportable(_ location: HelperLocation) -> Bool {
        switch location {
        case .bundled, .bridgeExecutable:
            return true
        case .pythonModule(let interpreter, _):
            let process = Process()
            process.executableURL = interpreter
            process.arguments = ["-c", "import importlib.util as u; raise SystemExit(0 if u.find_spec('claude_swap.bridge') else 1)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }
    }

    private static func siblingCheckoutCandidates() -> [String] {
        var paths: [String] = []
        // Common layout: .../projects/claude-swap-macos next to .../claude-swap
        let home = NSHomeDirectory()
        paths.append("\(home)/Developer/claude-swap")
        if let cwd = FileManager.default.currentDirectoryPath as String? {
            paths.append((cwd as NSString).appendingPathComponent("../claude-swap"))
            paths.append((cwd as NSString).deletingLastPathComponent + "/claude-swap")
        }
        // App bundle lives under build/... — walk up looking for a sibling.
        if let exe = Bundle.main.executableURL {
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<8 {
                let sibling = dir.appendingPathComponent("claude-swap")
                paths.append(sibling.path)
                let parentSibling = dir.deletingLastPathComponent().appendingPathComponent("claude-swap")
                paths.append(parentSibling.path)
                dir = dir.deletingLastPathComponent()
            }
        }
        return paths
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
        case .bundled(let url), .bridgeExecutable(let url):
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
