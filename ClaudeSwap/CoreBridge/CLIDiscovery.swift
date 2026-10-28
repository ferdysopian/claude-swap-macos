//
//  CLIDiscovery.swift
//  ClaudeSwap
//
//  Finds the user's separately installed `cswap` launcher. Apps opened from
//  Finder inherit a minimal PATH, so the usual uv / pipx / Homebrew bin
//  directories are searched too. Paths are kept as the launcher the user
//  sees (e.g. `~/.local/bin/cswap`), not the symlink target inside a tool
//  venv, because the target moves when the CLI is upgraded.
//

import Foundation

struct CLICandidate: Sendable, Equatable, Identifiable {
    enum Source: String, Sendable, Equatable {
        case environment   // CLAUDE_SWAP_CLI_PATH
        case settings      // Settings > Command-Line Tool
        case searchPath    // PATH or a well-known bin directory
    }

    /// Stable launcher path (what LaunchAgents and Settings store).
    let path: String
    /// Symlink-resolved target, for display and de-duplication only.
    let resolvedPath: String
    let source: Source

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

enum CLIResolution: Sendable, Equatable {
    case found(CLICandidate)
    /// The user (or environment) pointed at a path that isn't an executable
    /// file. Reported as-is instead of silently falling back to another CLI.
    case configuredPathInvalid(String)
    case notFound
}

enum CLIDiscovery {
    static let executablePathDefaultsKey = "cswapExecutablePath"
    static let environmentKey = "CLAUDE_SWAP_CLI_PATH"
    static let executableName = "cswap"

    /// PATH entries first, then the bin directories uv, pipx and Homebrew
    /// install into, de-duplicated in order.
    static func searchDirectories(environment: [String: String], home: URL) -> [String] {
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let wellKnown = [
            home.appendingPathComponent(".local/bin").path,   // uv tool / pipx default
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        for dir in wellKnown where !dirs.contains(dir) {
            dirs.append(dir)
        }
        return dirs.filter { !$0.isEmpty }
    }

    /// Every distinct `cswap` reachable from the search directories.
    static func candidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [CLICandidate] {
        var seen = Set<String>()
        var result: [CLICandidate] = []
        for dir in searchDirectories(environment: environment, home: home) {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(executableName)
            guard isExecutableFile(url.path, fileManager: fileManager) else { continue }
            let resolved = url.resolvingSymlinksInPath().path
            guard seen.insert(resolved).inserted else { continue }
            result.append(CLICandidate(path: url.path, resolvedPath: resolved, source: .searchPath))
        }
        return result
    }

    /// Explicit choices win and are never second-guessed: environment, then
    /// the path saved in Settings, then the first `cswap` on the search path.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> CLIResolution {
        if let explicit = environment[environmentKey], !explicit.isEmpty {
            return explicitCandidate(explicit, source: .environment, home: home, fileManager: fileManager)
        }
        if let saved = userDefaults.string(forKey: executablePathDefaultsKey), !saved.isEmpty {
            return explicitCandidate(saved, source: .settings, home: home, fileManager: fileManager)
        }
        if let first = candidates(environment: environment, home: home, fileManager: fileManager).first {
            return .found(first)
        }
        return .notFound
    }

    private static func explicitCandidate(
        _ rawPath: String,
        source: CLICandidate.Source,
        home: URL,
        fileManager: FileManager
    ) -> CLIResolution {
        let path = expandTilde(rawPath, home: home)
        guard isExecutableFile(path, fileManager: fileManager) else {
            return .configuredPathInvalid(path)
        }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return .found(CLICandidate(path: path, resolvedPath: resolved, source: source))
    }

    static func expandTilde(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).path }
        return path
    }

    static func isExecutableFile(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }

    /// Environment for CLI child processes: the app's own environment with
    /// PATH widened to the launcher's directory and standard system dirs, so
    /// a Finder-launched app behaves like a terminal. Colour is turned off so
    /// stderr stays parseable. Nothing secret is added.
    static func childEnvironment(
        for executable: URL,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        var dirs = [executable.deletingLastPathComponent().path]
        dirs += (base["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !dirs.contains(dir) {
            dirs.append(dir)
        }
        var unique: [String] = []
        for dir in dirs where !dir.isEmpty && !unique.contains(dir) { unique.append(dir) }
        environment["PATH"] = unique.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment.removeValue(forKey: "CLAUDE_SWAP_BACKEND")
        return environment
    }
}
