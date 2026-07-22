//
//  LiveBackendDiscoveryTests.swift
//  ClaudeSwapTests
//

import Testing
import Foundation
@testable import ClaudeSwap

struct LiveBackendDiscoveryTests {
    @Test func mapsCswapListJsonIntoSnapshot() throws {
        let json = """
        {
          "schemaVersion": 1,
          "activeAccountNumber": 2,
          "accounts": [
            {
              "number": 1,
              "email": "user1@example.com",
              "organizationName": "Acme",
              "organizationUuid": "org-1",
              "active": false,
              "usageStatus": "unavailable",
              "usage": null
            },
            {
              "number": 2,
              "email": "user2@example.com",
              "organizationName": "Globex",
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
            corePath: "/Users/me/.local/bin/cswap"
        )

        #expect(snapshot.activeAccountId == "2")
        #expect(snapshot.accounts.count == 2)
        #expect(snapshot.accounts[0].displayName == "Acme")
        #expect(snapshot.accounts[0].usage.unknown == true)
        #expect(snapshot.accounts[1].displayName == "Globex")
        #expect(snapshot.accounts[1].isActive == true)
        #expect(snapshot.accounts[1].usage.windows.count == 3)
        #expect(snapshot.accounts[1].usage.windows.first?.utilizationPct == 22)
        #expect(snapshot.accounts[1].usage.windows.contains(where: { $0.id == "Fable" }))
    }

    @Test func resolveBackendFindsInstalledCswapWhenPresent() {
        // On this machine `cswap` lives under ~/.local/bin — GUI PATH may omit
        // it, but HelperLocator always searches that directory.
        let backend = HelperLocator.resolveBackend()
        switch backend {
        case .cli, .bridge:
            break // live install found
        case .fixture:
            // Only acceptable if `cswap` truly isn't installed on the runner.
            let cswap = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".local/bin/cswap")
            #expect(!FileManager.default.isExecutableFile(atPath: cswap.path))
        }
    }
}
