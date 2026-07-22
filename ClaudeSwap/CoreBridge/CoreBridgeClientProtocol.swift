//
//  CoreBridgeClientProtocol.swift
//  ClaudeSwap
//
//  Shared interface implemented by both the real, process-backed
//  `CoreBridgeClient` and the in-memory `BridgeFixtureClient` used for
//  previews, tests, and dev environments without a helper installed.
//  `AppModel` talks only to this protocol, so it never needs to know which
//  backend is live.
//

import Foundation

protocol CoreBridgeClientProtocol: Actor {
    /// Starts the client (launches the process, or seeds fixture state).
    /// Safe to call multiple times; subsequent calls are no-ops while
    /// already started.
    func start() async

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

    @discardableResult
    func addAccount(token: String, alias: String?, slot: Int?) async throws -> Snapshot

    /// Register the account Claude Code is currently logged in as (`cswap add`).
    @discardableResult
    func addCurrentAccount(alias: String?, slot: Int?) async throws -> Snapshot

    /// Read-only peek at the live Claude login (`cswap status --json`).
    func currentClaudeLogin() async throws -> CurrentClaudeLogin?

    @discardableResult
    func removeAccount(id: String) async throws -> Snapshot

    @discardableResult
    func setAlias(id: String, alias: String?) async throws -> Snapshot

    @discardableResult
    func setDisabled(id: String, disabled: Bool) async throws -> Snapshot

    func exportConfig() async throws -> String

    @discardableResult
    func importConfig(_ json: String) async throws -> Snapshot
}
