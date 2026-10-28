//
//  CLIDiscoveryTests.swift
//  ClaudeSwapTests
//
//  Temp directories with throwaway executables only.
//

import Foundation
import Testing
@testable import ClaudeSwap

/// The search always appends /opt/homebrew/bin and /usr/local/bin. A machine
/// that really has cswap there can't run the "nothing found" cases.
let systemCswapPresent: Bool = ["/opt/homebrew/bin/cswap", "/usr/local/bin/cswap"]
    .contains { FileManager.default.fileExists(atPath: $0) }

final class TempTree: @unchecked Sendable {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func dir(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func executable(_ relative: String, mode: Int = 0o755) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }
}

func isolatedDefaults() -> (UserDefaults, () -> Void) {
    let name = "ClaudeSwapTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (defaults, { defaults.removePersistentDomain(forName: name) })
}

@Suite struct CLIDiscoveryTests {
    @Test func pathOrderIsRespected() throws {
        let t = try TempTree()
        let a = try t.executable("a/cswap")
        let b = try t.executable("b/cswap")
        let home = try t.dir("home")
        let env = ["PATH": "\(a.deletingLastPathComponent().path):\(b.deletingLastPathComponent().path)"]
        let found = CLIDiscovery.candidates(environment: env, home: home)
        #expect(found.prefix(2).map(\.path) == [a.path, b.path])
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        #expect(CLIDiscovery.resolve(environment: env, userDefaults: defaults, home: home)
            == .found(CLICandidate(path: a.path, resolvedPath: a.resolvingSymlinksInPath().path, source: .searchPath)))
        // Reversed PATH flips the winner.
        let reversed = ["PATH": "\(b.deletingLastPathComponent().path):\(a.deletingLastPathComponent().path)"]
        guard case .found(let c) = CLIDiscovery.resolve(environment: reversed, userDefaults: defaults, home: home) else {
            Issue.record("expected found"); return
        }
        #expect(c.path == b.path)
    }

    @Test func wellKnownLocalBinFallback() throws {
        let t = try TempTree()
        let home = try t.dir("home")
        let cswap = try t.executable("home/.local/bin/cswap")
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        guard case .found(let c) = CLIDiscovery.resolve(environment: ["PATH": ""], userDefaults: defaults, home: home) else {
            Issue.record("expected found"); return
        }
        #expect(c.path == cswap.path)
        #expect(c.source == .searchPath)
    }

    @Test func searchDirectoriesDedupeAndAppendWellKnown() throws {
        let home = URL(fileURLWithPath: "/tmp/h")
        let dirs = CLIDiscovery.searchDirectories(
            environment: ["PATH": "/opt/homebrew/bin::/x"], home: home)
        #expect(dirs == ["/opt/homebrew/bin", "/x", "/tmp/h/.local/bin", "/usr/local/bin"])
    }

    @Test func symlinksAreDedupedAndLauncherPathIsKept() throws {
        let t = try TempTree()
        let home = try t.dir("home")
        let target = try t.executable("venv/bin/cswap")
        let binA = try t.dir("binA")
        let binB = try t.dir("binB")
        let linkA = binA.appendingPathComponent("cswap")
        let linkB = binB.appendingPathComponent("cswap")
        try FileManager.default.createSymbolicLink(at: linkA, withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: linkB, withDestinationURL: target)
        let env = ["PATH": "\(binA.path):\(binB.path)"]
        let found = CLIDiscovery.candidates(environment: env, home: home)
            .filter { $0.path.hasPrefix(t.root.path) }
        #expect(found.count == 1)
        #expect(found.first?.path == linkA.path)
        #expect(found.first?.path != target.path)
        #expect(found.first?.resolvedPath == target.resolvingSymlinksInPath().path)
    }

    @Test func environmentPathWinsAndInvalidIsNotSecondGuessed() throws {
        let t = try TempTree()
        let home = try t.dir("home")
        let good = try t.executable("good/cswap")
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        defaults.set(good.path, forKey: CLIDiscovery.executablePathDefaultsKey)
        let missing = t.root.appendingPathComponent("nope/cswap").path
        let env = [CLIDiscovery.environmentKey: missing, "PATH": good.deletingLastPathComponent().path]
        #expect(CLIDiscovery.resolve(environment: env, userDefaults: defaults, home: home) == .configuredPathInvalid(missing))

        let env2 = [CLIDiscovery.environmentKey: good.path]
        guard case .found(let c) = CLIDiscovery.resolve(environment: env2, userDefaults: defaults, home: home) else {
            Issue.record("expected found"); return
        }
        #expect(c.source == .environment)
        #expect(c.path == good.path)
    }

    @Test func invalidUserDefaultsPathDoesNotFallBack() throws {
        let t = try TempTree()
        let home = try t.dir("home")
        let good = try t.executable("good/cswap")
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let bad = t.root.appendingPathComponent("gone/cswap").path
        defaults.set(bad, forKey: CLIDiscovery.executablePathDefaultsKey)
        let env = ["PATH": good.deletingLastPathComponent().path]
        #expect(CLIDiscovery.resolve(environment: env, userDefaults: defaults, home: home) == .configuredPathInvalid(bad))
        defaults.set(good.path, forKey: CLIDiscovery.executablePathDefaultsKey)
        guard case .found(let c) = CLIDiscovery.resolve(environment: [:], userDefaults: defaults, home: home) else {
            Issue.record("expected found"); return
        }
        #expect(c.source == .settings)
    }

    @Test func emptyExplicitValuesAreIgnored() throws {
        let t = try TempTree()
        let home = try t.dir("home")
        let good = try t.executable("good/cswap")
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        defaults.set("", forKey: CLIDiscovery.executablePathDefaultsKey)
        let env = [CLIDiscovery.environmentKey: "", "PATH": good.deletingLastPathComponent().path]
        guard case .found(let c) = CLIDiscovery.resolve(environment: env, userDefaults: defaults, home: home) else {
            Issue.record("expected found"); return
        }
        #expect(c.path == good.path)
    }

    @Test func directoryNamedCswapIsIgnored() throws {
        let t = try TempTree()
        let home = try t.dir("home")
        try t.dir("bin/cswap")
        let bin = t.root.appendingPathComponent("bin").path
        let found = CLIDiscovery.candidates(environment: ["PATH": bin], home: home)
            .filter { $0.path.hasPrefix(t.root.path) }
        #expect(found.isEmpty)
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let explicit = t.root.appendingPathComponent("bin/cswap").path
        #expect(CLIDiscovery.resolve(environment: [CLIDiscovery.environmentKey: explicit], userDefaults: defaults, home: home)
            == .configuredPathInvalid(explicit))
    }

    @Test func nonExecutableIsIgnored() throws {
        let t = try TempTree()
        let home = try t.dir("home")
        try t.executable("bin/cswap", mode: 0o644)
        let bin = t.root.appendingPathComponent("bin").path
        let found = CLIDiscovery.candidates(environment: ["PATH": bin], home: home)
            .filter { $0.path.hasPrefix(t.root.path) }
        #expect(found.isEmpty)
    }

    @Test func tildeExpansion() throws {
        let t = try TempTree()
        let home = try t.dir("home")
        let cswap = try t.executable("home/tools/cswap")
        #expect(CLIDiscovery.expandTilde("~", home: home) == home.path)
        #expect(CLIDiscovery.expandTilde("~/tools/cswap", home: home) == cswap.path)
        #expect(CLIDiscovery.expandTilde("/abs/~x", home: home) == "/abs/~x")
        #expect(CLIDiscovery.expandTilde("~other/x", home: home) == "~other/x")
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        guard case .found(let c) = CLIDiscovery.resolve(
            environment: [CLIDiscovery.environmentKey: "~/tools/cswap"], userDefaults: defaults, home: home
        ) else { Issue.record("expected found"); return }
        #expect(c.path == cswap.path)
    }

    @Test(.enabled(if: !systemCswapPresent, "a real cswap is installed in a system bin directory"))
    func notFoundWhenNothingExists() throws {
        let t = try TempTree()
        let home = try t.dir("home")
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        #expect(CLIDiscovery.resolve(environment: ["PATH": ""], userDefaults: defaults, home: home) == .notFound)
    }

    @Test func childEnvironmentWidensPathAndDropsBackendOverride() {
        let exe = URL(fileURLWithPath: "/tmp/tools/cswap")
        let env = CLIDiscovery.childEnvironment(for: exe, base: [
            "PATH": "/custom/bin:/usr/bin", "CLAUDE_SWAP_BACKEND": "fixture", "KEEP": "1",
        ])
        let parts = env["PATH"]!.split(separator: ":").map(String.init)
        #expect(parts.first == "/tmp/tools")
        #expect(parts.contains("/custom/bin"))
        #expect(parts.filter { $0 == "/usr/bin" }.count == 1)
        #expect(parts.contains("/bin") && parts.contains("/usr/sbin") && parts.contains("/sbin"))
        #expect(env["NO_COLOR"] == "1")
        #expect(env["CLAUDE_SWAP_BACKEND"] == nil)
        #expect(env["KEEP"] == "1")
    }
}
