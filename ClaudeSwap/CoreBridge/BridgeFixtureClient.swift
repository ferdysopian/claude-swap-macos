//
//  BridgeFixtureClient.swift
//  ClaudeSwap
//
//  In-memory stand-in for `CoreBridgeClient`, used for SwiftUI previews,
//  unit tests, and whenever no core helper is installed/reachable. Reads a
//  golden fixture snapshot and applies every mutation locally, so the UI
//  is fully interactive without a running Python process.
//

import Foundation

actor BridgeFixtureClient: CoreBridgeClientProtocol {
    private var snapshot: Snapshot
    private var eventContinuations: [UUID: AsyncStream<BridgeEvent>.Continuation] = [:]
    /// Simulated per-account usage drift, applied on demand so the
    /// dashboard doesn't feel frozen during a demo/preview session.
    private var driftTask: Task<Void, Never>?

    init(snapshot: Snapshot = BridgeFixtureClient.loadBundledFixture()) {
        self.snapshot = snapshot
    }

    // MARK: - CoreBridgeClientProtocol

    func start() async -> BackendStatus {
        broadcast(.helperConnected)
        broadcast(.snapshotChanged(snapshot))
        return .demo
    }

    func stop() async {
        driftTask?.cancel()
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()
    }

    func events() -> AsyncStream<BridgeEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            self.eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id: id) }
            }
        }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    @discardableResult
    func requestSnapshot() async throws -> Snapshot {
        snapshot
    }

    @discardableResult
    func switchAccount(id: String) async throws -> Snapshot {
        guard let target = snapshot.accounts.first(where: { $0.id == id }) else {
            throw BridgeError.requestFailed(code: "unknown-account", message: "No account with id \(id).")
        }
        guard target.switchable, !target.disabled, !target.quarantined else {
            throw BridgeError.requestFailed(code: "not-switchable", message: "\(target.displayName) is not switchable right now.")
        }
        let previousId = snapshot.activeAccountId
        mutateAccounts { accounts in
            for index in accounts.indices {
                accounts[index].isActive = (accounts[index].id == id)
            }
        }
        snapshot.activeAccountId = id
        publishSnapshot()
        broadcast(.switched(from: previousId, to: id, trigger: "manual"))
        return snapshot
    }

    @discardableResult
    func rotateAccount() async throws -> Snapshot {
        let candidates = snapshot.accounts.filter { $0.switchable && !$0.disabled && !$0.quarantined && !$0.isActive }
        guard let best = candidates.max(by: { headroom(of: $0) < headroom(of: $1) }) else {
            throw BridgeError.requestFailed(code: "no-candidates", message: "No other switchable account is available.")
        }
        return try await switchAccount(id: best.id)
    }

    @discardableResult
    func setAutoSwitchEnabled(_ enabled: Bool) async throws -> Snapshot {
        snapshot.autoSwitch.enabled = enabled
        publishSnapshot()
        broadcast(.autoSwitchStatus(snapshot.autoSwitch))
        return snapshot
    }

    @discardableResult
    func updateAutoSwitchSettings(_ update: AutoSwitchSettingsUpdate) async throws -> Snapshot {
        if let thresholdPct = update.thresholdPct { snapshot.autoSwitch.thresholdPct = thresholdPct }
        if let strategy = update.strategy { snapshot.autoSwitch.strategy = strategy }
        if let cooldownSeconds = update.cooldownSeconds { snapshot.autoSwitch.cooldownSeconds = cooldownSeconds }
        if let includeAPIKeyAccounts = update.includeAPIKeyAccounts { snapshot.autoSwitch.includeAPIKeyAccounts = includeAPIKeyAccounts }
        publishSnapshot()
        broadcast(.autoSwitchStatus(snapshot.autoSwitch))
        return snapshot
    }

    @discardableResult
    func addAccount(token: String, alias: String?, slot: Int?, overwrite: Bool) async throws -> Snapshot {
        if let slot, !overwrite, snapshot.accounts.contains(where: { $0.id == String(slot) }) {
            throw BridgeError.slotOccupied(slot)
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError.requestFailed(code: "empty-token", message: "Token cannot be empty.")
        }
        let number = slot ?? ((snapshot.accounts.map(\.id).compactMap { Int($0) }.max() ?? 0) + 1)
        let newAccount = Account(
            id: String(number),
            email: "new-account-\(number)@example.com",
            alias: alias,
            organizationName: nil,
            organizationId: nil,
            kind: .oauth,
            isActive: false,
            switchable: true,
            disabled: false,
            quarantined: false,
            quarantineReason: nil,
            addedAt: Date(),
            usage: UsageSnapshot(
                windows: [
                    UsageWindow(id: "5h", label: "5 hour", utilizationPct: 0, resetsAt: Date().addingTimeInterval(5 * 3600)),
                    UsageWindow(id: "7d", label: "7 day", utilizationPct: 0, resetsAt: Date().addingTimeInterval(7 * 86400)),
                ],
                unknown: false,
                lastError: nil
            )
        )
        snapshot.accounts.append(newAccount)
        publishSnapshot()
        return snapshot
    }

    @discardableResult
    func addCurrentAccount(alias: String?, slot: Int?, overwrite: Bool) async throws -> Snapshot {
        if let slot, !overwrite, snapshot.accounts.contains(where: { $0.id == String(slot) }) {
            throw BridgeError.slotOccupied(slot)
        }
        let number = slot ?? ((snapshot.accounts.map(\.id).compactMap { Int($0) }.max() ?? 0) + 1)
        if let existing = snapshot.accounts.firstIndex(where: { $0.id == String(number) }) {
            var updated = snapshot.accounts[existing]
            if let alias { updated.alias = alias }
            updated.isActive = true
            snapshot.accounts[existing] = updated
            snapshot.activeAccountId = updated.id
        } else {
            let account = Account(
                id: String(number),
                email: "current@example.com",
                alias: alias ?? "Current login",
                organizationName: "Personal",
                organizationId: nil,
                kind: .oauth,
                isActive: true,
                switchable: true,
                disabled: false,
                quarantined: false,
                quarantineReason: nil,
                addedAt: Date(),
                usage: .empty
            )
            for i in snapshot.accounts.indices {
                snapshot.accounts[i].isActive = false
            }
            snapshot.accounts.append(account)
            snapshot.activeAccountId = account.id
        }
        publishSnapshot()
        return snapshot
    }

    func currentClaudeLogin() async throws -> CurrentClaudeLogin? {
        if let active = snapshot.accounts.first(where: { $0.isActive }) {
            return CurrentClaudeLogin(
                email: active.email,
                organizationName: active.organizationName,
                managed: true,
                accountNumber: Int(active.id)
            )
        }
        return CurrentClaudeLogin(
            email: "logged-in@example.com",
            organizationName: nil,
            managed: false,
            accountNumber: nil
        )
    }

    @discardableResult
    func removeAccount(id: String) async throws -> Snapshot {
        guard snapshot.accounts.contains(where: { $0.id == id }) else {
            throw BridgeError.requestFailed(code: "unknown-account", message: "No account with id \(id).")
        }
        snapshot.accounts.removeAll { $0.id == id }
        if snapshot.activeAccountId == id {
            snapshot.activeAccountId = snapshot.accounts.first?.id
        }
        publishSnapshot()
        return snapshot
    }

    @discardableResult
    func setAlias(id: String, alias: String?) async throws -> Snapshot {
        mutateAccounts { accounts in
            guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
            accounts[index].alias = (alias?.isEmpty == true) ? nil : alias
        }
        publishSnapshot()
        return snapshot
    }

    @discardableResult
    func setDisabled(id: String, disabled: Bool) async throws -> Snapshot {
        mutateAccounts { accounts in
            guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
            accounts[index].disabled = disabled
        }
        publishSnapshot()
        return snapshot
    }

    /// Demo export: a small, clearly labelled file with no credentials, so
    /// the Save panel flow can be exercised without a real CLI.
    func exportAccounts(to url: URL, accountID: String?) async throws {
        let accounts = snapshot.accounts
            .filter { accountID == nil || $0.id == accountID }
            .map { ["number": $0.id, "email": $0.email, "alias": $0.alias ?? ""] }
        let object: [String: Any] = ["demo": true, "note": "Claude Swap demo data, not a cswap export.", "accounts": accounts]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// Demo import never changes accounts; it only reports what it read.
    func importAccounts(from url: URL, overwriteExisting: Bool) async throws -> ImportOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BridgeError.requestFailed(code: "import.missing", message: "The selected file doesn't exist.")
        }
        publishSnapshot()
        return ImportOutcome(snapshot: snapshot, skipped: overwriteExisting ? [] : ["Skipped (demo mode: nothing is imported)"])
    }

    func automationServiceStatus() async -> AutoSwitchServiceStatus? { nil }

    // MARK: - Helpers

    private func headroom(of account: Account) -> Double {
        100 - (account.usage.bindingWindow?.utilizationPct ?? 0)
    }

    private func mutateAccounts(_ transform: (inout [Account]) -> Void) {
        transform(&snapshot.accounts)
    }

    private func publishSnapshot() {
        broadcast(.snapshotChanged(snapshot))
    }

    private func broadcast(_ event: BridgeEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Fixture loading

    /// Loads `PreviewContent/fixture_snapshot.json` from the app bundle,
    /// falling back to an in-memory default if it isn't present (e.g. a
    /// SPM test target without the resource copied in).
    nonisolated static func loadBundledFixture() -> Snapshot {
        if let url = Bundle.main.url(forResource: "fixture_snapshot", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let snapshot = try? JSONDecoder.bridgeDecoder.decode(Snapshot.self, from: data) {
            return snapshot
        }
        return .demo
    }
}

extension Snapshot {
    /// A small, self-consistent demo snapshot used when no fixture file is
    /// bundled (unit tests construct their own fixtures explicitly).
    static var demo: Snapshot {
        let now = Date()
        let accounts = [
            Account(
                id: "1",
                email: "primary@example.com",
                alias: "Primary",
                organizationName: nil,
                organizationId: nil,
                kind: .oauth,
                isActive: true,
                switchable: true,
                disabled: false,
                quarantined: false,
                quarantineReason: nil,
                addedAt: now.addingTimeInterval(-86400 * 30),
                usage: UsageSnapshot(
                    windows: [
                        UsageWindow(id: "5h", label: "5 hour", utilizationPct: 62, resetsAt: now.addingTimeInterval(3600 * 2)),
                        UsageWindow(id: "7d", label: "7 day", utilizationPct: 41, resetsAt: now.addingTimeInterval(86400 * 3)),
                    ],
                    unknown: false,
                    lastError: nil
                )
            ),
            Account(
                id: "2",
                email: "team@example.org",
                alias: nil,
                organizationName: "Acme Corp",
                organizationId: "org_acme",
                kind: .oauth,
                isActive: false,
                switchable: true,
                disabled: false,
                quarantined: false,
                quarantineReason: nil,
                addedAt: now.addingTimeInterval(-86400 * 10),
                usage: UsageSnapshot(
                    windows: [
                        UsageWindow(id: "5h", label: "5 hour", utilizationPct: 88, resetsAt: now.addingTimeInterval(3600)),
                        UsageWindow(id: "7d", label: "7 day", utilizationPct: 73, resetsAt: now.addingTimeInterval(86400 * 2)),
                    ],
                    unknown: false,
                    lastError: nil
                )
            ),
            Account(
                id: "3",
                email: "backup@example.com",
                alias: "Backup",
                organizationName: nil,
                organizationId: nil,
                kind: .oauth,
                isActive: false,
                switchable: false,
                disabled: true,
                quarantined: false,
                quarantineReason: nil,
                addedAt: now.addingTimeInterval(-86400 * 60),
                usage: UsageSnapshot(
                    windows: [
                        UsageWindow(id: "5h", label: "5 hour", utilizationPct: 100, resetsAt: now.addingTimeInterval(1800)),
                        UsageWindow(id: "7d", label: "7 day", utilizationPct: 100, resetsAt: now.addingTimeInterval(86400)),
                    ],
                    unknown: false,
                    lastError: nil
                )
            ),
        ]
        return Snapshot(
            protocolVersion: BridgeProtocolVersion.current,
            generatedAt: now,
            activeAccountId: "1",
            accounts: accounts,
            autoSwitch: AutoSwitchState(
                enabled: true,
                strategy: .best,
                thresholdPct: 85,
                cooldownSeconds: 300,
                includeAPIKeyAccounts: false,
                lastSwitchAt: now.addingTimeInterval(-3600),
                lastEventDescription: "Switched Account-1 -> Account-2 (proactive)"
            ),
            capabilities: Capabilities(
                supportsAutoSwitch: true,
                supportsAPIKeyAccounts: true,
                supportsExportImport: true,
                coreVersion: "fixture-0.0.0"
            ),
            diagnostics: Diagnostics(
                corePath: nil,
                helperPID: nil,
                uptimeSeconds: 0,
                warnings: []
            )
        )
    }
}
