//
//  UnavailableBackendClient.swift
//  ClaudeSwap
//
//  Stand-in backend when no `cswap` is installed (or the configured path
//  is wrong). It holds no data and every operation fails with an
//  actionable error, so the UI shows onboarding instead of demo accounts.
//

import Foundation

actor UnavailableBackendClient: CoreBridgeClientProtocol {
    private let configuredPath: String?

    init(configuredPath: String?) {
        self.configuredPath = configuredPath
    }

    private var error: BridgeError { .cliNotFound(configuredPath) }

    func start() async -> BackendStatus {
        BackendStatus(kind: .none, readiness: .cliNotFound(configuredPath: configuredPath), executablePath: configuredPath)
    }

    func stop() async {}

    func events() -> AsyncStream<BridgeEvent> {
        AsyncStream { $0.finish() }
    }

    func requestSnapshot() async throws -> Snapshot { throw error }
    func switchAccount(id: String) async throws -> Snapshot { throw error }
    func rotateAccount() async throws -> Snapshot { throw error }
    func setAutoSwitchEnabled(_ enabled: Bool) async throws -> Snapshot { throw error }
    func updateAutoSwitchSettings(_ update: AutoSwitchSettingsUpdate) async throws -> Snapshot { throw error }
    func addAccount(token: String, alias: String?, slot: Int?, overwrite: Bool) async throws -> Snapshot { throw error }
    func addCurrentAccount(alias: String?, slot: Int?, overwrite: Bool) async throws -> Snapshot { throw error }
    func currentClaudeLogin() async throws -> CurrentClaudeLogin? { throw error }
    func removeAccount(id: String) async throws -> Snapshot { throw error }
    func setAlias(id: String, alias: String?) async throws -> Snapshot { throw error }
    func setDisabled(id: String, disabled: Bool) async throws -> Snapshot { throw error }
    func exportAccounts(to url: URL, accountID: String?) async throws { throw error }
    func importAccounts(from url: URL, overwriteExisting: Bool) async throws -> ImportOutcome { throw error }
    func automationServiceStatus() async -> AutoSwitchServiceStatus? { nil }
}
