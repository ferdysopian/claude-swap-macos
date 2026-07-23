//
//  AppModel.swift
//  ClaudeSwap
//
//  Single source of truth for the whole app: owns the bridge client
//  (real or fixture), the latest snapshot, connection status, activity
//  log, and every user-facing mutation. All Features screens read from
//  and call into this type — none of them talk to CoreBridge directly.
//

import Foundation
import Observation

enum ConnectionState: Sendable, Equatable {
    case connecting
    case connected
    case fixtureMode
    case disconnected(reason: String?)
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

    var coreOverridePath: String? {
        didSet { UserDefaults.standard.set(coreOverridePath, forKey: HelperLocator.userDefaultsKey) }
    }

    /// Wall-clock used by countdown UI. Ticked locally so reset timers advance
    /// without re-querying the core (and without `TimelineView` in the menu bar).
    var displayNow: Date = Date()

    // MARK: - Dependencies

    let bridge: any CoreBridgeClientProtocol
    private var eventTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var quietRefreshInFlight = false
    private let usingFixture: Bool

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
        let skipOnboardingForUITests = ProcessInfo.processInfo.arguments.contains("-uiTestSkipOnboarding")
        self.hasCompletedOnboarding = skipOnboardingForUITests || defaults.bool(forKey: Keys.onboarded)
        self.themeMode = AppThemeMode(rawValue: defaults.string(forKey: Keys.themeMode) ?? "") ?? .system
        self.showDockIcon = defaults.object(forKey: Keys.showDockIcon) as? Bool ?? false
        self.coreOverridePath = defaults.string(forKey: HelperLocator.userDefaultsKey)

        if let bridge {
            self.bridge = bridge
            self.usingFixture = bridge is BridgeFixtureClient
        } else {
            switch HelperLocator.resolveBackend() {
            case .bridge:
                self.bridge = CoreBridgeClient()
                self.usingFixture = false
            case .cli(let cswapURL):
                self.bridge = CswapCLIClient(cswapURL: cswapURL)
                self.usingFixture = false
            case .fixture:
                self.bridge = BridgeFixtureClient()
                self.usingFixture = true
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard eventTask == nil else { return }
        connectionState = usingFixture ? .fixtureMode : .connecting
        let bridge = self.bridge
        let fixture = usingFixture
        eventTask = Task { [weak self] in
            // Subscribe *before* start() so connection/snapshot events aren't dropped.
            let events = await bridge.events()
            await bridge.start()
            guard let self else { return }

            // `start()` succeeding means the live backend is ready. Don't rely
            // solely on a helperConnected event (easy to miss if it raced).
            if fixture {
                self.connectionState = .fixtureMode
            } else {
                self.connectionState = .connected
            }

            await self.refreshSnapshot()
            self.startClock()
            self.startPolling()
            // If refresh failed, run() already set errorBanner; still stay
            // connected so the UI isn't stuck on "Connecting…".
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
            connectionState = usingFixture ? .fixtureMode : .connected
            record(.connection, "Core helper connected")
        case .helperDisconnected(let reason):
            connectionState = usingFixture ? .fixtureMode : .disconnected(reason: reason)
            record(.connection, "Core helper disconnected" + (reason.map { ": \($0)" } ?? ""))
        case .unknown:
            break
        }
    }

    private func record(_ kind: ActivityEntry.Kind, _ message: String) {
        activity.insert(ActivityEntry(id: UUID(), timestamp: Date(), kind: kind, message: message), at: 0)
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
            await run { [bridge] in try await bridge.requestSnapshot() }
            return
        }
        guard !quietRefreshInFlight, !isBusy else { return }
        quietRefreshInFlight = true
        defer { quietRefreshInFlight = false }
        do {
            let next = try await bridge.requestSnapshot()
            applySnapshot(next)
        } catch {
            // Keep the last good snapshot; don't overwrite a user-visible
            // error banner with a transient background-poll failure.
        }
    }

    // MARK: - Account actions

    var activeAccount: Account? {
        snapshot.accounts.first(where: { $0.id == snapshot.activeAccountId })
    }

    func switchAccount(id: String) async {
        await run { [bridge] in try await bridge.switchAccount(id: id) }
    }

    func rotateToBestAccount() async {
        await run { [bridge] in try await bridge.rotateAccount() }
    }

    /// Register via setup-token / API key (`cswap add-token`).
    func addAccount(token: String, alias: String?, slot: Int?) async -> Bool {
        await run { [bridge] in try await bridge.addAccount(token: token, alias: alias, slot: slot) }
    }

    /// Capture whatever Claude Code is currently logged in as (`cswap add`).
    func addCurrentAccount(alias: String?, slot: Int?) async -> Bool {
        await run { [bridge] in try await bridge.addCurrentAccount(alias: alias, slot: slot) }
    }

    /// Peek at the live Claude login without adding it (`cswap status --json`).
    func peekCurrentClaudeLogin() async -> CurrentClaudeLogin? {
        do {
            return try await bridge.currentClaudeLogin()
        } catch {
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

    func setAutoSwitchEnabled(_ enabled: Bool) async {
        await run { [bridge] in try await bridge.setAutoSwitchEnabled(enabled) }
    }

    func updateAutoSwitchSettings(_ update: AutoSwitchSettingsUpdate) async {
        await run { [bridge] in try await bridge.updateAutoSwitchSettings(update) }
    }

    // MARK: - Tools

    func exportConfig() async -> String? {
        do {
            isBusy = true
            defer { isBusy = false }
            return try await bridge.exportConfig()
        } catch {
            errorBanner = describeError(error)
            return nil
        }
    }

    func importConfig(_ json: String) async -> Bool {
        await run { [bridge] in try await bridge.importConfig(json) }
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
        isBusy = true
        defer { isBusy = false }
        do {
            applySnapshot(try await operation())
            errorBanner = nil
            return true
        } catch {
            errorBanner = describeError(error)
            return false
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
