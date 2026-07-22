//
//  ClaudeSwapTests.swift
//  ClaudeSwapTests
//
//  Minimal smoke-test scaffold. Team 10 (QA / Docs / Final Audit) owns
//  fleshing this target out with real coverage.
//

import Testing
@testable import ClaudeSwap

struct ClaudeSwapTests {
    @Test func demoSnapshotHasAccounts() async throws {
        let snapshot = Snapshot.demo
        #expect(!snapshot.accounts.isEmpty)
        #expect(snapshot.activeAccountId != nil)
    }

    @Test func fixtureClientStartsAndReportsSnapshot() async throws {
        let client = BridgeFixtureClient()
        await client.start()
        let snapshot = try await client.requestSnapshot()
        #expect(!snapshot.accounts.isEmpty)
    }
}
