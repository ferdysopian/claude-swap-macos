//
//  SnapshotMappingTests.swift
//  ClaudeSwapTests
//

import Testing
import Foundation
@testable import ClaudeSwap

struct SnapshotMappingTests {
    @Test func mapsCswapListJsonIntoSnapshot() throws {
        let json = """
        {
          "schemaVersion": 1,
          "activeAccountNumber": 2,
          "accounts": [
            {
              "number": 1,
              "email": "a@example.com",
              "organizationName": "Example Org",
              "organizationUuid": "org-1",
              "active": false,
              "usageStatus": "unavailable",
              "usage": null
            },
            {
              "number": 2,
              "email": "b@example.com",
              "organizationName": "Second Org",
              "organizationUuid": "org-2",
              "active": true,
              "usageStatus": "ok",
              "usage": {
                "fiveHour": { "pct": 22.0, "resetsAt": "2026-07-22T19:19:59Z" },
                "sevenDay": { "pct": 3.0, "resetsAt": "2026-07-28T19:59:59Z" },
                "scoped": [{ "name": "Fable", "pct": 0.0 }]
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let payload = try SnapshotMapping.jsonObject(from: json)
        let snapshot = SnapshotMapping.fromListPayload(
            payload,
            coreVersion: "cswap 0.22.0",
            corePath: "/usr/local/bin/cswap",
            usageCacheRows: [:]
        )

        #expect(snapshot.activeAccountId == "2")
        #expect(snapshot.accounts.count == 2)
        #expect(snapshot.accounts[0].displayName == "Example Org")
        #expect(snapshot.accounts[0].usage.unknown == true)
        #expect(snapshot.accounts[0].usage.lastError == "Not refreshed yet")
        #expect(snapshot.accounts[1].displayName == "Second Org")
        #expect(snapshot.accounts[1].isActive == true)
        #expect(snapshot.accounts[1].usage.windows.count == 3)
        #expect(snapshot.accounts[1].usage.windows.first?.utilizationPct == 22)
        #expect(snapshot.accounts[1].usage.windows.contains(where: { $0.id == "Fable" }))
    }

    @Test func preservesLastKnownUsageWhenJsonMarksInactiveUnavailable() throws {
        let freshJSON = """
        {
          "schemaVersion": 1,
          "activeAccountNumber": 1,
          "accounts": [
            {
              "number": 1,
              "email": "a@example.com",
              "organizationName": "A",
              "organizationUuid": "org-a",
              "active": true,
              "usageStatus": "ok",
              "usage": {
                "fiveHour": { "pct": 40.0, "resetsAt": "2026-07-22T19:19:59Z" },
                "sevenDay": { "pct": 10.0, "resetsAt": "2026-07-28T19:59:59Z" }
              }
            },
            {
              "number": 2,
              "email": "b@example.com",
              "organizationName": "B",
              "organizationUuid": "org-b",
              "active": false,
              "usageStatus": "ok",
              "usage": {
                "fiveHour": { "pct": 88.0, "resetsAt": "2026-07-22T18:00:00Z" },
                "sevenDay": { "pct": 50.0, "resetsAt": "2026-07-27T00:00:00Z" }
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let staleJSON = """
        {
          "schemaVersion": 1,
          "activeAccountNumber": 1,
          "accounts": [
            {
              "number": 1,
              "email": "a@example.com",
              "organizationName": "A",
              "organizationUuid": "org-a",
              "active": true,
              "usageStatus": "ok",
              "usage": {
                "fiveHour": { "pct": 41.0, "resetsAt": "2026-07-22T19:19:59Z" },
                "sevenDay": { "pct": 10.0, "resetsAt": "2026-07-28T19:59:59Z" }
              }
            },
            {
              "number": 2,
              "email": "b@example.com",
              "organizationName": "B",
              "organizationUuid": "org-b",
              "active": false,
              "usageStatus": "unavailable",
              "usage": null
            }
          ]
        }
        """.data(using: .utf8)!

        let previous = SnapshotMapping.fromListPayload(
            try SnapshotMapping.jsonObject(from: freshJSON),
            coreVersion: "cswap",
            corePath: nil,
            usageCacheRows: [:]
        )
        let next = SnapshotMapping.fromListPayload(
            try SnapshotMapping.jsonObject(from: staleJSON),
            coreVersion: "cswap",
            corePath: nil,
            usageCacheRows: [:]
        )
        let merged = SnapshotMapping.mergingPreservedUsage(previous: previous, next: next)

        #expect(merged.accounts[0].usage.windows.first?.utilizationPct == 41)
        #expect(merged.accounts[0].usage.isStale == false)
        #expect(merged.accounts[1].usage.isStale == true)
        #expect(merged.accounts[1].usage.unknown == false)
        #expect(merged.accounts[1].usage.windows.first?.utilizationPct == 88)
        #expect(merged.accounts[1].usage.lastError?.contains("Last known") == true)
    }

    @Test func enrichesUnavailableAccountFromUsageCacheLastGood() {
        let json = """
        {
          "schemaVersion": 1,
          "activeAccountNumber": 2,
          "accounts": [
            {
              "number": 1,
              "email": "a@example.com",
              "organizationName": "Example Org",
              "organizationUuid": "org-1",
              "active": false,
              "usageStatus": "unavailable",
              "usage": null
            },
            {
              "number": 2,
              "email": "b@example.com",
              "organizationName": "Second Org",
              "organizationUuid": "org-2",
              "active": true,
              "usageStatus": "ok",
              "usage": {
                "fiveHour": { "pct": 23.0, "resetsAt": "2026-07-22T19:19:59Z" },
                "sevenDay": { "pct": 9.0, "resetsAt": "2026-07-28T19:59:59Z" }
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let payload = try! SnapshotMapping.jsonObject(from: json)
        // Skip disk; inject cache rows matching human `cswap list` lastGood.
        let base = SnapshotMapping.fromListPayload(
            payload,
            coreVersion: "cswap",
            corePath: nil,
            usageCacheRows: [:]
        )
        // fromListPayload already tried disk; force a known cache overlay:
        let stripped = Snapshot(
            protocolVersion: base.protocolVersion,
            generatedAt: base.generatedAt,
            activeAccountId: base.activeAccountId,
            accounts: base.accounts.map { account in
                var copy = account
                if account.id == "1" {
                    copy.usage = UsageSnapshot(windows: [], unknown: true, lastError: "Not refreshed yet")
                }
                return copy
            },
            autoSwitch: base.autoSwitch,
            capabilities: base.capabilities,
            diagnostics: base.diagnostics
        )
        let fetchedAt = Date().addingTimeInterval(-10 * 3600)
        let enriched = SnapshotMapping.enrichingFromUsageCache(stripped, rows: [
            "1": .init(
                email: "a@example.com",
                organizationUuid: "org-1",
                fetchedAt: fetchedAt,
                lastGood: [
                    "five_hour": ["pct": 0.0],
                    "seven_day": [
                        "pct": 100.0,
                        "resets_at": "2026-07-23T18:59:59Z",
                    ],
                    "scoped": [
                        ["name": "Fable", "pct": 66.0, "resets_at": "2026-07-23T18:59:59Z"],
                    ],
                ]
            ),
        ])

        #expect(enriched.accounts[0].usage.isStale == true)
        #expect(enriched.accounts[0].usage.unknown == false)
        #expect(enriched.accounts[0].usage.windows.count == 3)
        #expect(enriched.accounts[0].usage.windows.first(where: { $0.id == "7d" })?.utilizationPct == 100)
        #expect(enriched.accounts[0].usage.windows.first(where: { $0.id == "Fable" })?.utilizationPct == 66)
        #expect(enriched.accounts[0].usage.lastError?.contains("Last known") == true)
        #expect(enriched.accounts[1].usage.isStale == false)
        #expect(enriched.accounts[1].usage.windows.first?.utilizationPct == 23)
    }
}
