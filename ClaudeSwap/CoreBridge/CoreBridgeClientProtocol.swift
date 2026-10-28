//
//  CoreBridgeClientProtocol.swift
//  ClaudeSwap
//
//  Shared interface for every backend: the production `CswapCLIClient`
//  (drives the separately installed `cswap`), the development-only NDJSON
//  `CoreBridgeClient`, the explicit demo `BridgeFixtureClient`, and
//  `UnavailableBackendClient` when no CLI is installed. `AppModel` talks
//  only to this protocol, so it never needs to know which backend is live.
//

import Foundation

/// What `start()` found out about the backend. `AppModel` turns this into
/// the connection state the UI shows; "ready" is only reported after the
/// required probes succeeded.
struct BackendStatus: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case cli
        case devBridge
        case demo
        case none
    }

    enum Readiness: Sendable, Equatable {
        case ready
        case demo
        case cliNotFound(configuredPath: String?)
        case incompatible(String)
        case failed(String)
    }

    var kind: Kind
    var readiness: Readiness
    /// Stable launcher path of the CLI in use (never a credential).
    var executablePath: String?
    /// `cswap --version` output, trimmed.
    var version: String?
    var compatibility: CLICompatibilityPolicy.Verdict?

    static let demo = BackendStatus(kind: .demo, readiness: .demo)
}

/// Result of `cswap import`: entries the CLI skipped because they already
/// exist (only possible without overwrite) are reported, not hidden.
struct ImportOutcome: Sendable, Equatable {
    var snapshot: Snapshot
    var skipped: [String]
}

protocol CoreBridgeClientProtocol: Actor {
    /// Starts the client and probes the backend. Safe to call again after
    /// `stop()`; returns the cached status while already started.
    func start() async -> BackendStatus

    /// Stops the client and releases any subprocess/resources.
    func stop() async

    /// A live stream of events (connection changes, snapshot pushes,
    /// switch notifications, log lines). Each call returns a fresh stream
    /// backed by the same underlying source.
    func events() -> AsyncStream<BridgeEvent>

    @discardableResult
    func requestSnapshot() async throws -> Snapshot

    @discardableResult
    func switchAccount(id: String) async throws -> Snapshot

    @discardableResult
    func rotateAccount() async throws -> Snapshot

    @discardableResult
    func setAutoSwitchEnabled(_ enabled: Bool) async throws -> Snapshot

    @discardableResult
    func updateAutoSwitchSettings(_ update: AutoSwitchSettingsUpdate) async throws -> Snapshot

    /// Register a setup-token / API key (`cswap add-token -`, token on stdin).
    /// `overwrite` must only be true after the user confirmed replacing the
    /// account already in `slot`.
    @discardableResult
    func addAccount(token: String, alias: String?, slot: Int?, overwrite: Bool) async throws -> Snapshot

    /// Register the account Claude Code is currently logged in as (`cswap add`).
    @discardableResult
    func addCurrentAccount(alias: String?, slot: Int?, overwrite: Bool) async throws -> Snapshot

    /// Read-only peek at the live Claude login (`cswap status --json`).
    func currentClaudeLogin() async throws -> CurrentClaudeLogin?

    @discardableResult
    func removeAccount(id: String) async throws -> Snapshot

    @discardableResult
    func setAlias(id: String, alias: String?) async throws -> Snapshot

    @discardableResult
    func setDisabled(id: String, disabled: Bool) async throws -> Snapshot

    /// Writes the CLI's own export file (it contains credentials) to `url`.
    func exportAccounts(to url: URL, accountID: String?) async throws

    /// Imports a CLI export file. Existing accounts are only replaced when
    /// `overwriteExisting` is true (`--force`), after explicit user choice.
    func importAccounts(from url: URL, overwriteExisting: Bool) async throws -> ImportOutcome

    /// State of the wrapper-owned auto-switch LaunchAgent; nil when the
    /// backend doesn't use one (demo, dev bridge, no CLI).
    func automationServiceStatus() async -> AutoSwitchServiceStatus?
}
