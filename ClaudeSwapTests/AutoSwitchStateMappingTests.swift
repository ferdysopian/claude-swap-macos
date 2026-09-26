//
//  AutoSwitchStateMappingTests.swift
//  ClaudeSwapTests
//

import Testing
import Foundation
@testable import ClaudeSwap

struct AutoSwitchStateMappingTests {
    private let configList = """
    {"schemaVersion":1,"path":"/tmp/settings.json","settings":[
      {"key":"autoswitch.enabled","value":true,"isSet":true},
      {"key":"autoswitch.threshold","value":95.0,"isSet":true},
      {"key":"autoswitch.cooldownSeconds","value":120,"isSet":true},
      {"key":"autoswitch.strategy","value":"consume-first","isSet":true},
      {"key":"autoswitch.includeApiKeyAccounts","value":true,"isSet":true}
    ]}
    """

    private func values() throws -> [String: Any] {
        let payload = try SnapshotMapping.jsonObject(from: Data(configList.utf8))
        return SnapshotMapping.configValues(fromConfigList: payload)
    }

    @Test func mapsConfigListSettings() throws {
        let state = SnapshotMapping.autoSwitchState(configValues: try values(), daemonRunning: true)
        #expect(state.enabled == true)
        #expect(state.thresholdPct == 95)
        #expect(state.cooldownSeconds == 120)
        #expect(state.strategy == .consumeFirst)
        #expect(state.includeAPIKeyAccounts == true)
    }

    @Test func enabledFollowsDaemonNotSettingsFlag() throws {
        // settings.json says enabled, but no LaunchAgent is loaded.
        let state = SnapshotMapping.autoSwitchState(configValues: try values(), daemonRunning: false)
        #expect(state.enabled == false)
    }

    @Test func emptyConfigFallsBackToDefaults() {
        let state = SnapshotMapping.autoSwitchState(configValues: [:], daemonRunning: false)
        #expect(state == .disabled)
    }

    @Test func listPayloadCarriesAutoSwitchState() throws {
        let auto = SnapshotMapping.autoSwitchState(configValues: try values(), daemonRunning: true)
        let snapshot = SnapshotMapping.fromListPayload(
            ["accounts": []],
            coreVersion: "test",
            corePath: nil,
            autoSwitch: auto
        )
        #expect(snapshot.autoSwitch == auto)
    }
}
