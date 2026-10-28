//
//  CLICompatibilityTests.swift
//  ClaudeSwapTests
//

import Foundation
import Testing
@testable import ClaudeSwap

@Suite struct CLICompatibilityTests {
    @Test func parsesVersionOutputs() throws {
        #expect(CLIVersion("cswap 0.26.0")?.components == [0, 26, 0])
        #expect(CLIVersion("0.26.0")?.components == [0, 26, 0])
        #expect(CLIVersion("claude-swap 1.2.3\n")?.components == [1, 2, 3])
        let pre = try #require(CLIVersion("0.27.0b1"))
        #expect(pre.components == [0, 27, 0])
        #expect(pre.prerelease == "b1")
        #expect(pre.description == "0.27.0b1")
    }

    @Test func garbageIsNil() {
        #expect(CLIVersion("") == nil)
        #expect(CLIVersion("garbage") == nil)
        #expect(CLIVersion("cswap") == nil)
        #expect(CLIVersion("usage: cswap [-h]") == nil)
    }

    @Test func ordersVersions() throws {
        let a = try #require(CLIVersion("0.25.9"))
        let b = try #require(CLIVersion("0.26.0"))
        let c = try #require(CLIVersion("0.26.1"))
        let d = try #require(CLIVersion("0.100.0"))
        #expect(a < b)
        #expect(b < c)
        #expect(c < d)
        #expect(!(b < b))
    }

    @Test func prereleaseSortsBeforeRelease() throws {
        let beta = try #require(CLIVersion("0.27.0b1"))
        let release = try #require(CLIVersion("0.27.0"))
        let beta2 = try #require(CLIVersion("0.27.0b2"))
        #expect(beta < release)
        #expect(!(release < beta))
        #expect(beta < beta2)
    }

    @Test func policyVerdicts() {
        let policy = CLICompatibilityPolicy(
            minimumVersion: "0.26.0",
            baselineVersion: "0.26.0",
            verifiedVersions: ["0.26.1"],
            jsonSchemaVersions: [1],
            upstream: "https://example.com/cswap"
        )
        #expect(policy.evaluate(versionOutput: "cswap 0.25.0") == .tooOld(minimum: "0.26.0"))
        #expect(policy.evaluate(versionOutput: "cswap 0.26.0") == .unverified)
        #expect(policy.evaluate(versionOutput: "cswap 0.26.1") == .verified)
        #expect(policy.evaluate(versionOutput: "cswap 0.27.0") == .unverified)
        #expect(policy.evaluate(versionOutput: "not a version") == .unknownVersion)
        #expect(policy.evaluate(versionOutput: "") == .unknownVersion)
    }

    @Test func schemaSupport() {
        let policy = CLICompatibilityPolicy.builtIn
        #expect(policy.supportsSchema(1))
        #expect(!policy.supportsSchema(2))
        #expect(!policy.supportsSchema(nil))
    }

    @Test func bundledPolicyDecodesAndMatchesExpectations() throws {
        // The test host is the app, so its main bundle carries the resource.
        let url = try #require(Bundle.main.url(forResource: "CLICompatibility", withExtension: "json"))
        let policy = try JSONDecoder().decode(CLICompatibilityPolicy.self, from: Data(contentsOf: url))
        #expect(policy.minimumVersion == "0.26.0")
        #expect(policy.baselineVersion == "0.26.0")
        #expect(policy.verifiedVersions.isEmpty)
        #expect(policy.jsonSchemaVersions == [1])
        #expect(CLICompatibilityPolicy.load() == policy)
    }

    @Test func bundleWithoutResourceFallsBackToBuiltIn() {
        // The xctest bundle itself carries no CLICompatibility.json.
        let bundle = Bundle(for: FakeBundleAnchor.self)
        #expect(bundle.url(forResource: "CLICompatibility", withExtension: "json") == nil)
        #expect(CLICompatibilityPolicy.load(bundle: bundle) == .builtIn)
        #expect(CLICompatibilityPolicy.builtIn.minimumVersion == "0.26.0")
        #expect(CLICompatibilityPolicy.builtIn.verifiedVersions.isEmpty)
    }
}

private final class FakeBundleAnchor {}
