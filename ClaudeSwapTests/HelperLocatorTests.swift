//
//  HelperLocatorTests.swift
//  ClaudeSwapTests
//
//  Every call passes explicit environment / arguments / home / defaults so
//  the real machine is never consulted.
//

import Foundation
import Testing
@testable import ClaudeSwap

@Suite struct HelperLocatorTests {
    private func resolve(
        environment: [String: String] = [:],
        arguments: [String] = [],
        home: URL,
        defaults: UserDefaults
    ) -> CoreBackend {
        HelperLocator.resolveBackend(
            environment: environment, arguments: arguments, userDefaults: defaults, home: home
        )
    }

    @Test func xctestEnvironmentForcesFixture() throws {
        let t = try TempTree()
        let cswap = try t.executable("bin/cswap")
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let backend = resolve(
            environment: ["XCTestConfigurationFilePath": "/x", "PATH": cswap.deletingLastPathComponent().path],
            home: try t.dir("home"), defaults: defaults)
        #expect(backend == .fixture)
    }

    @Test func backendFixtureEnvironment() throws {
        let t = try TempTree()
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        #expect(resolve(environment: ["CLAUDE_SWAP_BACKEND": "fixture"], home: try t.dir("home"), defaults: defaults) == .fixture)
    }

    @Test func demoModeArgument() throws {
        let t = try TempTree()
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        #expect(resolve(arguments: ["App", "-demoMode"], home: try t.dir("home"), defaults: defaults) == .fixture)
    }

    @Test func bridgeWithoutCorePathIsUnavailable() throws {
        let t = try TempTree()
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let backend = resolve(environment: ["CLAUDE_SWAP_BACKEND": "bridge"], home: try t.dir("home"), defaults: defaults)
        #expect(backend == .unavailable(configuredPath: nil))
    }

    @Test func bridgeWithBadCorePathReportsIt() throws {
        let t = try TempTree()
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let backend = resolve(
            environment: ["CLAUDE_SWAP_BACKEND": "bridge", "CLAUDE_SWAP_CORE_PATH": "/nonexistent/core"],
            home: try t.dir("home"), defaults: defaults)
        #expect(backend == .unavailable(configuredPath: "/nonexistent/core"))
    }

    @Test func bridgeWithVenvPython() throws {
        let t = try TempTree()
        let py = try t.executable("core/.venv/bin/python3")
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let backend = resolve(
            environment: ["CLAUDE_SWAP_BACKEND": "bridge", "CLAUDE_SWAP_CORE_PATH": t.root.appendingPathComponent("core").path],
            home: try t.dir("home"), defaults: defaults)
        guard case .bridge(.pythonModule(let interpreter, _)) = backend else {
            Issue.record("expected bridge, got \(backend)"); return
        }
        #expect(interpreter.path == py.path)
    }

    @Test func installedCLIIsUsed() throws {
        let t = try TempTree()
        let cswap = try t.executable("bin/cswap")
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let backend = resolve(
            environment: ["PATH": cswap.deletingLastPathComponent().path], home: try t.dir("home"), defaults: defaults)
        guard case .cli(let candidate) = backend else { Issue.record("expected cli, got \(backend)"); return }
        #expect(candidate.path == cswap.path)
    }

    @Test func invalidConfiguredPathIsUnavailableNotFallback() throws {
        let t = try TempTree()
        let cswap = try t.executable("bin/cswap")
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let bad = t.root.appendingPathComponent("missing/cswap").path
        let backend = resolve(
            environment: [CLIDiscovery.environmentKey: bad, "PATH": cswap.deletingLastPathComponent().path],
            home: try t.dir("home"), defaults: defaults)
        #expect(backend == .unavailable(configuredPath: bad))
    }

    @Test(.enabled(if: !systemCswapPresent, "a real cswap is installed in a system bin directory"))
    func nothingFoundIsUnavailableNeverFixture() throws {
        let t = try TempTree()
        let (defaults, cleanup) = isolatedDefaults()
        defer { cleanup() }
        let backend = resolve(environment: ["PATH": ""], home: try t.dir("home"), defaults: defaults)
        #expect(backend == .unavailable(configuredPath: nil))
        #expect(backend != .fixture)
    }
}
