//
//  BridgeModelDecodingTests.swift
//  ClaudeSwapTests
//
//  Decodes the golden fixture snapshots and asserts on the shapes the rest
//  of the app depends on (binding window selection, status thresholds,
//  optional fields round-tripping through `nil`).
//

import Testing
import Foundation
@testable import ClaudeSwap

struct BridgeModelDecodingTests {
    @Test func decodesBasicSnapshot() throws {
        let snapshot = try Self.loadFixture("snapshot_basic")

        #expect(snapshot.protocolVersion == 1)
        #expect(snapshot.activeAccountId == "1")
        #expect(snapshot.accounts.count == 2)

        let primary = try #require(snapshot.accounts.first(where: { $0.id == "1" }))
        #expect(primary.displayName == "Primary")
        #expect(primary.isActive == true)
        #expect(primary.usage.windows.count == 2)
        #expect(primary.usage.bindingWindow?.id == "5h")
        #expect(primary.usage.bindingWindow?.status == .normal)

        let secondary = try #require(snapshot.accounts.first(where: { $0.id == "2" }))
        #expect(secondary.displayName == "Acme Corp", "no alias -> organization name")
        #expect(secondary.kind == .apiKey)
        #expect(secondary.quarantined == true)
        #expect(secondary.quarantineReason == "invalid_grant")
        #expect(secondary.usage.unknown == true)
        #expect(secondary.usage.bindingWindow == nil)

        #expect(snapshot.autoSwitch.strategy == .consumeFirst)
        #expect(snapshot.autoSwitch.lastSwitchAt == nil)
        #expect(snapshot.capabilities.supportsExportImport == false)
        #expect(snapshot.diagnostics.warnings.count == 1)
    }

    @Test func decodesExhaustedSnapshot() throws {
        let snapshot = try Self.loadFixture("snapshot_exhausted")
        let account = try #require(snapshot.accounts.first)
        #expect(account.usage.bindingWindow?.utilizationPct == 100)
        #expect(account.usage.bindingWindow?.status == .exhausted)
    }

    @Test(arguments: [
        (0.0, UsageStatus.normal),
        (69.9, UsageStatus.normal),
        (70.0, UsageStatus.attention),
        (84.9, UsageStatus.attention),
        (85.0, UsageStatus.critical),
        (99.9, UsageStatus.critical),
        (100.0, UsageStatus.exhausted),
    ])
    func statusThresholds(pct: Double, expected: UsageStatus) {
        #expect(UsageStatus(utilizationPct: pct) == expected)
    }

    private static func loadFixture(_ name: String) throws -> Snapshot {
        let url = try #require(Bundle.testFixtures.url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder.bridgeDecoder.decode(Snapshot.self, from: data)
    }
}

extension Bundle {
    /// Locates the test bundle regardless of how the test runner names it,
    /// so fixture lookups don't depend on `Bundle.module` (SPM-only) or a
    /// hardcoded bundle identifier.
    static var testFixtures: Bundle {
        Bundle(for: BundleToken.self)
    }
}

private final class BundleToken {}
