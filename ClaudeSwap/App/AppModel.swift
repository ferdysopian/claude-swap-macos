//
//  AppModel.swift
//  ClaudeSwap
//
//  Single source of truth for the whole app: owns the backend client
//  (installed `cswap` CLI, explicit demo data, or the "no CLI" stand-in),
//  the latest snapshot, connection status, activity log, and every
//  user-facing mutation. All Features screens read from
//  and call into this type — none of them talk to CoreBridge directly.
//

import Foundation
import Observation

enum ConnectionState: Sendable, Equatable {
    /// Probing the CLI (version, JSON contract).
    case connecting
    /// Probes passed; the CLI is driving real accounts.
    case connected
    /// Explicit demo data only (previews, tests, `-demoMode`).
    case fixtureMode
    /// No executable `cswap`; `configuredPath` is set when an explicit
    /// path was chosen but isn't usable.
    case cliNotFound(configuredPath: String?)
    /// CLI too old or speaking an unknown JSON schema; changes are blocked.
    case incompatible(reason: String)
    /// Probe or process failure (launch error, credentials, network…).
    case disconnected(reason: String?)

    var isLive: Bool { self == .connected }
}

/// Outcome of a user action, rich enough for sheets to react (e.g. ask
/// before overwriting a slot) without parsing banner text.
enum MutationResult: Sendable, Equatable {
    case success
    /// The main step worked but a follow-up didn't; state was refreshed.
    case partial(String)
    case slotOccupied(Int)
    case failed(String)

    var succeeded: Bool {
        switch self {
        case .success, .partial: return true
        case .slotOccupied, .failed: return false
        }
    }
}

struct ActivityEntry: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case switched
        case quarantined
        case unquarantined
        case autoSwitch
        case connection
        case log
        case error
    }

    let id: UUID
    let timestamp: Date
    let kind: Kind
    let message: String
}

enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case dashboard
    case accounts
    case automation
    case activity
    case tools
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .accounts: return "Accounts"
        case .automation: return "Automation"
        case .activity: return "Activity"
        case .tools: return "Tools"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.50percent"
        case .accounts: return "person.2"
        case .automation: return "arrow.triangle.2.circlepath"
        case .activity: return "clock.arrow.circlepath"
        case .tools: return "wrench.and.screwdriver"
        case .settings: return "gearshape"
        }
    }

    /// 1-based index for Cmd-1..N keyboard shortcuts (Tools/Settings are
    /// reachable via the sidebar; only the first four get shortcuts per
    /// the spec).
    var commandShortcutDigit: Character? {
        switch self {
        case .dashboard: return "1"
        case .accounts: return "2"
        case .automation: return "3"
        case .activity: return "4"
        default: return nil
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // MARK: - Published state

    var snapshot: Snapshot = .empty
    var connectionState: ConnectionState = .connecting
    var selectedTab: AppTab = .dashboard
    var activity: [ActivityEntry] = []
    var errorBanner: String?
    var isBusy = false

    var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.onboarded) }
    }

    var themeMode: AppThemeMode {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: Keys.themeMode) }
    }

    var launchAtLoginEnabled = false
    var showDockIcon: Bool {
        didSet { UserDefaults.standard.set(showDockIcon, forKey: Keys.showDockIcon) }
    }

    /// Explicit `cswap` launcher chosen in Settings (nil = auto-detect).
    private(set) var cswapExecutablePath: String?

    /// What the last backend probe found (path, version, compatibility).
    private(set) var backendStatus: BackendStatus?
    /// Wrapper-owned auto-switch LaunchAgent state (nil without a CLI).
    private(set) var automationStatus: AutoSwitchServiceStatus?
    /// Set when a background refresh failed; the snapshot shown is older.
    private(set) var lastBackgroundRefreshError: String?
    /// Coarse categories of recent failures, for diagnostics only.
    private(set) var recentErrorCodes: [String] = []

    /// Wall-clock used by countdown UI. Ticked locally so reset timers advance
    /// without re-querying the core (and without `TimelineView` in the menu bar).
    var displayNow: Date = Date()

    // MARK: - Dependencies

    private(set) var bridge: any CoreBridgeClientProtocol
    private var eventTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var quietRefreshInFlight = false
    private var usingFixture: Bool
    /// Bumped on every reconnect. Work started against an older backend
    /// checks it after each await and drops its result.
    private var backendGeneration = 0

    /// Local countdown tick — cheap Observation update only.
    private static let clockTickInterval: Duration = .seconds(30)
    /// Re-fetch usage from core/CLI. Kept deliberately slow: `cswap list`
    /// can hit the network for every account and must not thrash the UI.
    private static let snapshotPollInterval: Duration = .seconds(300)

    private enum Keys {
        static let onboarded = "hasCompletedOnboarding"
        static let themeMode = "themeMode"
        static let showDockIcon = "showDockIcon"
    }

    // MARK: - Init

    init(bridge: (any CoreBridgeClientProtocol)? = nil) {
        let defaults = UserDefaults.standard
        // Hosted unit tests share this process; never read real preferences there.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            LegacyPreferencesMigration.migrate(into: defaults)
        }
        let skipOnboardingForUITests = ProcessInfo.processInfo.arguments.contains("-uiTestSkipOnboarding")
        self.hasCompletedOnboarding = skipOnboardingForUITests || defaults.bool(forKey: Keys.onboarded)
        self.themeMode = AppThemeMode(rawValue: defaults.string(forKey: Keys.themeMode) ?? "") ?? .system
        self.showDockIcon = defaults.object(forKey: Keys.showDockIcon) as? Bool ?? false
        self.cswapExecutablePath = defaults.string(forKey: CLIDiscovery.executablePathDefaultsKey)

        if let bridge {
            self.bridge = bridge
            self.usingFixture = bridge is BridgeFixtureClient
        } else {
            let made = Self.makeBackend()
            self.bridge = made.client
            self.usingFixture = made.isFixture
        }
    }

    private static func makeBackend() -> (client: any CoreBridgeClientProtocol, isFixture: Bool) {
        switch HelperLocator.resolveBackend() {
        case .bridge:
            return (CoreBridgeClient(), false)
        case .cli(let candidate):
            return (CswapCLIClient(cswapURL: candidate.url), false)
        case .fixture:
            return (BridgeFixtureClient(), true)
        case .unavailable(let configuredPath):
            return (UnavailableBackendClient(configuredPath: configuredPath), false)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard eventTask == nil else { return }
        connectionState = usingFixture ? .fixtureMode : .connecting
        let bridge = self.bridge
        let generation = backendGeneration
        eventTask = Task { [weak self] in
            // Subscribe *before* start() so connection/snapshot events aren't dropped.
            let events = await bridge.events()
            let status = await bridge.start()
            guard let self, !Task.isCancelled, generation == self.backendGeneration else { return }
            self.apply(status)
            if status.readiness == .ready || status.readiness == .demo {
                await self.refreshAutomationStatus()
                self.startClock()
                self.startPolling()
            }
            for await event in events {
                await self.handle(event)
            }
        }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        clockTask?.cancel()
        clockTask = nil
        pollTask?.cancel()
        pollTask = nil
        let bridge = self.bridge
        Task { await bridge.stop() }
    }

    /// Re-resolves the backend (after a CLI path change, an install, or an
    /// upgrade) and probes it again. Refused while an action is running so
    /// a mutation never straddles two backends.
    @discardableResult
    func reconnect() -> Bool {
        guard !isBusy else {
            errorBanner = "Wait for the current action to finish, then re-check the command-line tool."
            return false
        }
        stop()
        backendGeneration += 1
        let made = Self.makeBackend()
        bridge = made.client
        usingFixture = made.isFixture
        backendStatus = nil
        automationStatus = nil
        snapshot = .empty
        errorBanner = nil
        start()
        return true
    }

    /// Saves (or clears, with nil) the explicit `cswap` path, then reconnects.
    func setCLIExecutablePath(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        cswapExecutablePath = value
        UserDefaults.standard.set(value, forKey: CLIDiscovery.executablePathDefaultsKey)
        reconnect()
    }

    /// Every `cswap` found on PATH and the usual install locations, for the
    /// Settings picker when there's more than one installation.
    func detectedCLICandidates() -> [CLICandidate] {
        CLIDiscovery.candidates()
    }

    private func apply(_ status: BackendStatus) {
        backendStatus = status
        switch status.readiness {
        case .ready:
            connectionState = .connected
        case .demo:
            connectionState = .fixtureMode
        case .cliNotFound(let path):
            connectionState = .cliNotFound(configuredPath: path)
        case .incompatible(let reason):
            connectionState = .incompatible(reason: reason)
            record(.error, reason)
        case .failed(let reason):
            connectionState = .disconnected(reason: reason)
            record(.error, reason)
        }
    }

    func refreshAutomationStatus() async {
        automationStatus = await bridge.automationServiceStatus()
    }

    /// Advance countdown labels without touching the bridge.
    private func startClock() {
        guard clockTask == nil else { return }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.clockTickInterval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.displayNow = Date()
            }
        }
    }

    /// Occasional background usage refresh. Skips if a user action or another
    /// quiet poll is already in flight so the CLI actor never piles up work.
    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.snapshotPollInterval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await self.refreshSnapshot(showBusy: false)
            }
        }
    }

    private func handle(_ event: BridgeEvent) async {
        switch event {
        case .snapshotChanged(let snapshot):
            applySnapshot(snapshot)
        case .switched(let from, let to, let trigger):
            let name = snapshot.accounts.first(where: { $0.id == to })?.displayName ?? to
            record(.switched, "Switched to \(name)" + (trigger == "manual" ? "" : " (\(trigger))"))
            NotificationService.shared.notifySwitch(from: from, to: name, trigger: trigger)
        case .autoSwitchStatus(let state):
            snapshot.autoSwitch = state
            record(.autoSwitch, state.enabled ? "Auto-switch enabled" : "Auto-switch disabled")
        case .accountQuarantined(let accountId, let reason):
            let name = snapshot.accounts.first(where: { $0.id == accountId })?.displayName ?? accountId
            record(.quarantined, "\(name) quarantined: \(reason)")
            NotificationService.shared.notifyQuarantined(accountName: name, reason: reason)
        case .accountUnquarantined(let accountId):
            let name = snapshot.accounts.first(where: { $0.id == accountId })?.displayName ?? accountId
            record(.unquarantined, "\(name) back in rotation")
        case .log(let level, let message):
            record(level == "error" ? .error : .log, message)
        case .helperConnected:
            if usingFixture {
                connectionState = .fixtureMode
            } else if case .disconnected = connectionState {
                connectionState = .connected
            }
            record(.connection, usingFixture ? "Demo data loaded" : "Connected to cswap")
        case .helperDisconnected(let reason):
            guard !usingFixture, connectionState == .connected else { break }
            connectionState = .disconnected(reason: reason)
            record(.connection, "Disconnected from cswap" + (reason.map { ": \($0)" } ?? ""))
        case .unknown:
            break
        }
    }

    /// Activity is sanitized on the way in (tokens, home path, terminal
    /// escapes) so nothing raw from the CLI is kept or later copied.
    private func record(_ kind: ActivityEntry.Kind, _ message: String) {
        let clean = Redactor.sanitize(message)
        activity.insert(ActivityEntry(id: UUID(), timestamp: Date(), kind: kind, message: clean), at: 0)
        if activity.count > 200 { activity.removeLast(activity.count - 200) }
    }

    // MARK: - Snapshot

    /// Apply a bridge/CLI snapshot, keeping last-known usage for accounts the
    /// core marked decision-stale (`usageStatus: unavailable`).
    private func applySnapshot(_ next: Snapshot) {
        snapshot = SnapshotMapping.mergingPreservedUsage(previous: snapshot, next: next)
        displayNow = Date()
    }

    func refreshSnapshot(showBusy: Bool = true) async {
        if showBusy {
            // A read, so allowed while disconnected (that's how Retry works).
            await runMutation(requiresReady: false) { [bridge] in try await bridge.requestSnapshot() }
            return
        }
        guard !quietRefreshInFlight, !isBusy, connectionState.isLive || usingFixture else { return }
        quietRefreshInFlight = true
        defer { quietRefreshInFlight = false }
        let generation = backendGeneration
        do {
            let next = try await bridge.requestSnapshot()
            guard generation == backendGeneration else { return }
            applySnapshot(next)
            lastBackgroundRefreshError = nil
        } catch {
            guard generation == backendGeneration else { return }
            noteStateChange(from: error)
            // Keep the last good snapshot and don't overwrite a user-visible
            // banner, but remember the failure so the UI can show the data
            // is stale instead of silently looking current.
            lastBackgroundRefreshError = Redactor.sanitize(describeError(error))
        }
    }

    // MARK: - Account actions

    /// Mutating actions are only offered (and only run) against a backend
    /// whose probes passed, or explicit demo data.
    var canMutate: Bool {
        connectionState == .connected || connectionState == .fixtureMode
    }

    var activeAccount: Account? {
        snapshot.accounts.first(where: { $0.id == snapshot.activeAccountId })
    }

    func switchAccount(id: String) async {
        await run { [bridge] in try await bridge.switchAccount(id: id) }
    }

    func rotateToBestAccount() async {
        await run { [bridge] in try await bridge.rotateAccount() }
    }

    /// Register via setup-token / API key (`cswap add-token -`; the token
    /// only ever travels on stdin). `overwrite` only after the user
    /// confirmed replacing the account in `slot`.
    func addAccount(token: String, alias: String?, slot: Int?, overwrite: Bool = false) async -> MutationResult {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return await runMutation(secrets: [token, trimmed]) { [bridge] in
            try await bridge.addAccount(token: token, alias: alias, slot: slot, overwrite: overwrite)
        }
    }

    /// Capture whatever Claude Code is currently logged in as (`cswap add`).
    func addCurrentAccount(alias: String?, slot: Int?, overwrite: Bool = false) async -> MutationResult {
        await runMutation { [bridge] in
            try await bridge.addCurrentAccount(alias: alias, slot: slot, overwrite: overwrite)
        }
    }

    /// Peek at the live Claude login without adding it (`cswap status --json`).
    /// Failure is surfaced to the caller as nil plus a banner, not hidden.
    func peekCurrentClaudeLogin() async -> CurrentClaudeLogin? {
        do {
            return try await bridge.currentClaudeLogin()
        } catch BridgeError.cancelled {
            return nil   // the sheet switched modes; not a failure
        } catch {
            noteError(error)
            return nil
        }
    }

    func removeAccount(id: String) async {
        await run { [bridge] in try await bridge.removeAccount(id: id) }
    }

    func setAlias(id: String, alias: String?) async {
        await run { [bridge] in try await bridge.setAlias(id: id, alias: alias) }
    }

    func setDisabled(id: String, disabled: Bool) async {
        await run { [bridge] in try await bridge.setDisabled(id: id, disabled: disabled) }
    }

    // MARK: - Automation

    @discardableResult
    func setAutoSwitchEnabled(_ enabled: Bool) async -> MutationResult {
        let result = await runMutation { [bridge] in try await bridge.setAutoSwitchEnabled(enabled) }
        await refreshAutomationStatus()
        return result
    }

    @discardableResult
    func updateAutoSwitchSettings(_ update: AutoSwitchSettingsUpdate) async -> MutationResult {
        let result = await runMutation { [bridge] in try await bridge.updateAutoSwitchSettings(update) }
        await refreshAutomationStatus()
        return result
    }

    // MARK: - Tools

    /// Writes the CLI's export file to `url`. The file contains credentials.
    func exportAccounts(to url: URL, accountID: String? = nil) async -> MutationResult {
        isBusy = true
        defer { isBusy = false }
        do {
            try await bridge.exportAccounts(to: url, accountID: accountID)
            errorBanner = nil
            record(.log, "Exported accounts to \(url.lastPathComponent)")
            return .success
        } catch {
            return .failed(noteError(error))
        }
    }

    /// Imports a CLI export file; existing accounts are only replaced when
    /// the user explicitly chose to overwrite them.
    func importAccounts(from url: URL, overwriteExisting: Bool) async -> MutationResult {
        isBusy = true
        defer { isBusy = false }
        do {
            let outcome = try await bridge.importAccounts(from: url, overwriteExisting: overwriteExisting)
            applySnapshot(outcome.snapshot)
            errorBanner = nil
            if outcome.skipped.isEmpty {
                record(.log, "Imported accounts from \(url.lastPathComponent)")
                return .success
            }
            let message = "Imported, but \(outcome.skipped.count) existing account(s) were left unchanged: "
                + outcome.skipped.joined(separator: "; ")
            record(.log, message)
            return .partial(message)
        } catch {
            return .failed(noteError(error))
        }
    }

    /// The `cswap run` command line users can copy to launch Claude Code
    /// against the currently active account from a terminal.
    var cswapRunCommand: String {
        guard let active = activeAccount else { return "cswap run" }
        return "cswap run --account \(active.id)"
    }

    // MARK: - Helpers

    @discardableResult
    private func run(_ operation: @escaping () async throws -> Snapshot) async -> Bool {
        await runMutation(operation).succeeded
    }

    /// Runs one backend action. Partial success and "outcome unknown" keep
    /// the refreshed snapshot (the client already re-read and broadcast it)
    /// and explain what happened instead of pretending to fail or succeed.
    @discardableResult
    private func runMutation(
        requiresReady: Bool = true,
        secrets: [String] = [],
        _ operation: @escaping () async throws -> Snapshot
    ) async -> MutationResult {
        guard canMutate || !requiresReady else {
            let message = "Claude Swap can't make changes until the cswap command-line tool is ready. Check Settings › Advanced."
            errorBanner = message
            return .failed(message)
        }
        isBusy = true
        defer { isBusy = false }
        let generation = backendGeneration
        do {
            let next = try await operation()
            guard generation == backendGeneration else { return .failed("The command-line tool changed while this was running.") }
            applySnapshot(next)
            errorBanner = nil
            // A successful call proves the CLI works again (e.g. manual
            // refresh after a failed probe).
            if case .disconnected = connectionState, !usingFixture { connectionState = .connected }
            return .success
        } catch BridgeError.slotOccupied(let slot) {
            return .slotOccupied(slot)
        } catch BridgeError.partialSuccess(let message) {
            let clean = Redactor.sanitize(message, secrets: secrets)
            errorBanner = clean
            record(.error, clean)
            return .partial(clean)
        } catch {
            return .failed(noteError(error, secrets: secrets))
        }
    }

    /// Shows a sanitized banner, logs it to Activity, and remembers the
    /// error category for diagnostics.
    @discardableResult
    private func noteError(_ error: Error, secrets: [String] = []) -> String {
        noteStateChange(from: error)
        let message = Redactor.sanitize(describeError(error), secrets: secrets)
        errorBanner = message
        record(.error, message)
        recentErrorCodes.insert(Self.errorCode(error), at: 0)
        if recentErrorCodes.count > 10 { recentErrorCodes.removeLast(recentErrorCodes.count - 10) }
        return message
    }

    /// Errors that change what the backend can do also change the
    /// connection state (e.g. the CLI was upgraded to an unknown schema).
    private func noteStateChange(from error: Error) {
        switch error as? BridgeError {
        case .incompatible(let reason)?:
            connectionState = .incompatible(reason: Redactor.sanitize(reason))
        case .cliNotFound(let path)?:
            connectionState = .cliNotFound(configuredPath: path)
        case .launchFailed(let reason)?:
            connectionState = .disconnected(reason: Redactor.sanitize(reason))
        default:
            break
        }
    }

    private static func errorCode(_ error: Error) -> String {
        guard let bridgeError = error as? BridgeError else { return "other" }
        switch bridgeError {
        case .requestFailed(let code, _): return code
        case .timeout: return "timeout"
        case .outcomeUnknown: return "outcome-unknown"
        case .cliNotFound: return "cli-not-found"
        case .incompatible: return "incompatible"
        case .launchFailed: return "launch-failed"
        case .partialSuccess: return "partial"
        case .slotOccupied: return "slot-occupied"
        case .cancelled: return "cancelled"
        default: return "bridge"
        }
    }

    private func describeError(_ error: Error) -> String {
        if let bridgeError = error as? BridgeError { return bridgeError.description }
        return error.localizedDescription
    }

    func dismissError() {
        errorBanner = nil
    }
}
