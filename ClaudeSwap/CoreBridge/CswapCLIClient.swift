//
//  CswapCLIClient.swift
//  ClaudeSwap
//
//  Production backend: drives the user's separately installed `cswap`
//  (claude-swap by realiti4) through its public command-line interface.
//  Account storage, switching, token refresh and credential locking all
//  stay in the CLI; this type only runs commands, maps their output, and
//  reports results honestly.
//
//  Every command goes through one queue, so a background refresh never
//  interleaves with a mutation (actor re-entrancy at `await` would
//  otherwise allow that). Mutations are never retried automatically.
//

import Foundation
import os.log

actor CswapCLIClient: CoreBridgeClientProtocol {
    struct Timeouts: Sendable {
        var probe: Duration = .seconds(15)
        /// `list --json` may fetch usage for every account over the network.
        var read: Duration = .seconds(90)
        var mutation: Duration = .seconds(120)
    }

    private enum CommandKind {
        case read
        /// Name shown to the user if the outcome becomes unknown.
        case mutation(String)
    }

    private let log = Logger(subsystem: "app.claudeswap.ClaudeSwap", category: "CswapCLIClient")
    private let cswapURL: URL
    private let runner: any ProcessRunning
    private let policy: CLICompatibilityPolicy
    private let automation: AutoSwitchDaemonService?
    private let childEnvironment: [String: String]
    private let timeouts: Timeouts

    private var started = false
    private var status: BackendStatus?
    private var latest: Snapshot = .empty
    private var lastConfigValues: [String: Any] = [:]
    /// Warnings raised outside a refresh, shown with the next snapshot.
    private var pendingWarnings: [String] = []
    private var eventContinuations: [UUID: AsyncStream<BridgeEvent>.Continuation] = [:]

    private var commandInFlight = false
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingRefresh: Task<Snapshot, Error>?

    /// `cswapURL` is the stable launcher path (e.g. `~/.local/bin/cswap`),
    /// which is also what the auto-switch LaunchAgent records.
    init(
        cswapURL: URL,
        runner: any ProcessRunning = ProcessRunner(),
        policy: CLICompatibilityPolicy = .load(),
        automation: AutoSwitchDaemonService? = AutoSwitchDaemonService(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        timeouts: Timeouts = Timeouts()
    ) {
        self.cswapURL = cswapURL
        self.runner = runner
        self.policy = policy
        self.automation = automation
        self.childEnvironment = CLIDiscovery.childEnvironment(for: cswapURL, base: baseEnvironment)
        self.timeouts = timeouts
    }

    // MARK: - Lifecycle

    func start() async -> BackendStatus {
        if started, let status { return status }
        started = true
        let probed = await probe()
        status = probed
        switch probed.readiness {
        case .ready:
            broadcast(.helperConnected)
        case .incompatible(let reason), .failed(let reason):
            broadcast(.helperDisconnected(reason: reason))
        case .cliNotFound, .demo:
            broadcast(.helperDisconnected(reason: nil))
        }
        return probed
    }

    func stop() async {
        started = false
        status = nil
        broadcast(.helperDisconnected(reason: "stopped"))
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()
    }

    /// Version check, then one `list --json` to prove the JSON contract.
    private func probe() async -> BackendStatus {
        var result = BackendStatus(kind: .cli, readiness: .ready, executablePath: cswapURL.path)
        do {
            let output = try await exclusive {
                try await cli(["--version"], timeout: timeouts.probe, kind: .read)
            }
            let text = String(decoding: output.stdout + output.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.version = Redactor.sanitize(text)
            let verdict = policy.evaluate(versionOutput: text)
            result.compatibility = verdict
            switch verdict {
            case .tooOld(let minimum):
                result.readiness = .incompatible(
                    "\(result.version ?? "This cswap") is older than \(minimum), the oldest version this app supports. Upgrade the CLI (for example `cswap upgrade`), then press Re-check."
                )
                return result
            case .unknownVersion:
                result.readiness = .incompatible(
                    "Couldn't read a version from `cswap --version`. Check that the selected file is the claude-swap CLI."
                )
                return result
            case .verified, .unverified:
                break
            }
        } catch {
            result.readiness = .failed(Self.describe(error))
            return result
        }

        migrateLegacyAutomation()

        // Publish the provisional status so refresh's schema check can mark
        // the backend incompatible instead of being overwritten afterwards.
        status = result
        do {
            _ = try await exclusive { try await refreshLocked() }
        } catch {
            if case .incompatible(let reason)? = (error as? BridgeError).flatMap(Self.incompatibleReason) {
                result.readiness = .incompatible(reason)
            } else {
                result.readiness = .failed(Self.describe(error))
            }
        }
        return result
    }

    /// One-time move of an auto-switch agent installed by an older build
    /// under a different label. Failure is surfaced as a warning.
    private func migrateLegacyAutomation() {
        guard let automation else { return }
        do {
            try automation.migrateLegacyAgents(cswapPath: cswapURL.path)
        } catch {
            pendingWarnings.append("Couldn't move the auto-switch service from an older version: \(Redactor.sanitize(error.localizedDescription))")
        }
    }

    private static func incompatibleReason(_ error: BridgeError) -> BackendStatus.Readiness? {
        if case .incompatible(let reason) = error { return .incompatible(reason) }
        return nil
    }

    // MARK: - Events

    func events() -> AsyncStream<BridgeEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            Task {
                await self.registerEventContinuation(id: id, continuation: continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id: id) }
            }
        }
    }

    private func registerEventContinuation(id: UUID, continuation: AsyncStream<BridgeEvent>.Continuation) {
        eventContinuations[id] = continuation
        // Replay so a late subscriber still sees the current state.
        if started, status?.readiness == .ready {
            continuation.yield(.helperConnected)
            if !latest.accounts.isEmpty { continuation.yield(.snapshotChanged(latest)) }
        }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func broadcast(_ event: BridgeEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Reads

    /// Concurrent callers share one in-flight refresh instead of queueing
    /// duplicate `cswap list` runs.
    @discardableResult
    func requestSnapshot() async throws -> Snapshot {
        if let pendingRefresh { return try await pendingRefresh.value }
        let task = Task { try await self.exclusive { try await self.refreshLocked() } }
        pendingRefresh = task
        defer { pendingRefresh = nil }
        return try await task.value
    }

    /// Must only run while holding the command queue.
    private func refreshLocked() async throws -> Snapshot {
        let output = try await cli(["list", "--json"], timeout: timeouts.read, kind: .read)
        let payload = try SnapshotMapping.jsonObject(from: output.stdout)
        let schema = payload["schemaVersion"] as? Int
        guard policy.supportsSchema(schema) else {
            let reason = "cswap returned JSON schema \(schema.map(String.init) ?? "(none)"), which this app doesn't understand. Changes are blocked until the app is updated."
            markIncompatible(reason)
            throw BridgeError.incompatible(reason)
        }

        var warnings = pendingWarnings
        pendingWarnings.removeAll()
        var configValues = lastConfigValues
        do {
            configValues = try await configListValuesLocked()
            lastConfigValues = configValues
        } catch {
            warnings.append("Couldn't read cswap settings; showing the last known values. \(Self.describe(error))")
        }

        let serviceStatus = automation?.status()
        let autoSwitch = SnapshotMapping.autoSwitchState(
            configValues: configValues,
            daemonRunning: serviceStatus?.plistInstalled ?? false
        )
        let snapshot = SnapshotMapping.fromListPayload(
            payload,
            coreVersion: status?.version ?? "cswap",
            corePath: cswapURL.path,
            warnings: warnings,
            autoSwitch: autoSwitch
        )
        latest = snapshot
        broadcast(.snapshotChanged(snapshot))
        return snapshot
    }

    /// `cswap config list --json` returns
    /// {"schemaVersion":1,"path":"...","settings":[{"key":"autoswitch.threshold","value":95.0,"isSet":true}, ...]}
    /// — a keyed array, not a flat dict.
    private func configListValuesLocked() async throws -> [String: Any] {
        let output = try await cli(["config", "list", "--json"], timeout: timeouts.read, kind: .read)
        let payload = try SnapshotMapping.jsonObject(from: output.stdout)
        return SnapshotMapping.configValues(fromConfigList: payload)
    }

    func currentClaudeLogin() async throws -> CurrentClaudeLogin? {
        let output = try await exclusive {
            try await cli(["status", "--json"], timeout: timeouts.read, kind: .read)
        }
        let payload = try SnapshotMapping.jsonObject(from: output.stdout)
        guard let active = payload["active"] as? [String: Any],
              let email = active["email"] as? String else {
            return nil
        }
        return CurrentClaudeLogin(
            email: email,
            organizationName: active["organizationName"] as? String,
            managed: (active["managed"] as? Bool) ?? false,
            accountNumber: active["number"] as? Int
        )
    }

    // MARK: - Account mutations

    @discardableResult
    func switchAccount(id: String) async throws -> Snapshot {
        let previous = latest.activeAccountId
        let snapshot = try await exclusive {
            try ensureMutable()
            _ = try await cli(["switch", id, "--json"], timeout: timeouts.mutation, kind: .mutation("Switch account"))
            return try await refreshLocked()
        }
        broadcast(.switched(from: previous, to: snapshot.activeAccountId ?? id, trigger: "manual"))
        return snapshot
    }

    @discardableResult
    func rotateAccount() async throws -> Snapshot {
        let previous = latest.activeAccountId
        let snapshot = try await exclusive {
            try ensureMutable()
            _ = try await cli(["switch", "--json"], timeout: timeouts.mutation, kind: .mutation("Switch to next account"))
            return try await refreshLocked()
        }
        if let active = snapshot.activeAccountId, active != previous {
            broadcast(.switched(from: previous, to: active, trigger: "manual"))
        }
        return snapshot
    }

    @discardableResult
    func addAccount(token: String, alias: String?, slot: Int?, overwrite: Bool) async throws -> Snapshot {
        // The CLI reads exactly one line; an embedded newline would be taken
        // as the answer to its overwrite prompt.
        let rawToken = token
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isNewline) else {
            throw BridgeError.requestFailed(code: "cli.input", message: "Paste the token as a single line.")
        }
        try Self.validateAlias(alias)
        return try await exclusive {
            try ensureMutable()
            try checkSlot(slot, overwrite: overwrite)
            let before = Set(latest.accounts.map(\.id))
            var arguments = ["add-token", "-"]
            if let slot { arguments += ["--slot", String(slot)] }
            // First stdin line is the token; the second answers the CLI's
            // "Overwrite slot N?" prompt only when the user confirmed it.
            var input = token + "\n"
            if overwrite { input += "y\n" }
            let output = try await cli(
                arguments,
                stdin: Data(input.utf8),
                timeout: timeouts.mutation,
                kind: .mutation("Add account"),
                secrets: [rawToken, token]
            )
            let snapshot = try await refreshLocked()
            if Self.cliCancelled(output) {
                throw Self.cancelledAdd(slot: slot, overwrite: overwrite)
            }
            return try await applyAliasAfterAdd(alias, slot: slot, before: before, snapshot: snapshot)
        }
    }

    @discardableResult
    func addCurrentAccount(alias: String?, slot: Int?, overwrite: Bool) async throws -> Snapshot {
        try Self.validateAlias(alias)
        return try await exclusive {
            try ensureMutable()
            try checkSlot(slot, overwrite: overwrite)
            var arguments = ["add"]
            if let slot { arguments += ["--slot", String(slot)] }
            if let alias, !alias.isEmpty { arguments += ["--alias", alias] }
            // Without confirmation stdin is closed, so the CLI's overwrite
            // prompt reads EOF and cancels instead of hanging.
            let output = try await cli(
                arguments,
                stdin: overwrite ? Data("y\n".utf8) : nil,
                timeout: timeouts.mutation,
                kind: .mutation("Add current login")
            )
            let snapshot = try await refreshLocked()
            if Self.cliCancelled(output) {
                throw Self.cancelledAdd(slot: slot, overwrite: overwrite)
            }
            return snapshot
        }
    }

    /// The CLI declined because the slot was occupied. If our snapshot was
    /// stale we didn't ask the user yet, so ask now instead of failing.
    private static func cancelledAdd(slot: Int?, overwrite: Bool) -> BridgeError {
        if let slot, !overwrite { return .slotOccupied(slot) }
        return .requestFailed(
            code: "cli.cancelled",
            message: "cswap didn't add the account: the slot is occupied and overwriting wasn't confirmed."
        )
    }

    /// argparse would read a leading "-" as an option.
    static func validateAlias(_ alias: String?) throws {
        guard let alias, alias.hasPrefix("-") else { return }
        throw BridgeError.requestFailed(code: "cli.input", message: "An alias can't start with \"-\".")
    }

    private func checkSlot(_ slot: Int?, overwrite: Bool) throws {
        guard let slot, !overwrite else { return }
        if latest.accounts.contains(where: { $0.id == String(slot) }) {
            throw BridgeError.slotOccupied(slot)
        }
    }

    /// `add-token` has no `--alias`, so the alias is a second command. If it
    /// fails the account still exists: report partial success, not failure.
    private func applyAliasAfterAdd(
        _ alias: String?,
        slot: Int?,
        before: Set<String>,
        snapshot: Snapshot
    ) async throws -> Snapshot {
        guard let alias, !alias.isEmpty else { return snapshot }
        let newID = slot.map(String.init)
            ?? Set(snapshot.accounts.map(\.id)).subtracting(before).sorted().first
        guard let newID else {
            throw BridgeError.partialSuccess(
                "Account added, but Claude Swap couldn't tell which slot it went into, so the alias wasn't set. Set it from Accounts."
            )
        }
        do {
            _ = try await cli(["alias", newID, alias], timeout: timeouts.mutation, kind: .mutation("Set alias"))
        } catch {
            throw BridgeError.partialSuccess(
                "Account added to slot \(newID), but setting the alias failed: \(Self.describe(error))"
            )
        }
        return try await refreshLocked()
    }

    @discardableResult
    func removeAccount(id: String) async throws -> Snapshot {
        try await exclusive {
            try ensureMutable()
            // The CLI asks for confirmation on stdin; the app has already
            // confirmed with the user, so answer it (older CLIs lack --yes).
            let output = try await cli(
                ["remove", id],
                stdin: Data("y\n".utf8),
                timeout: timeouts.mutation,
                kind: .mutation("Remove account")
            )
            let snapshot = try await refreshLocked()
            if Self.cliCancelled(output) {
                throw BridgeError.requestFailed(code: "cli.cancelled", message: "cswap cancelled the removal; nothing was changed.")
            }
            return snapshot
        }
    }

    @discardableResult
    func setAlias(id: String, alias: String?) async throws -> Snapshot {
        try Self.validateAlias(alias)
        return try await exclusive {
            try ensureMutable()
            let arguments = (alias?.isEmpty == false) ? ["alias", id, alias!] : ["alias", id, "--unset"]
            _ = try await cli(arguments, timeout: timeouts.mutation, kind: .mutation("Set alias"))
            return try await refreshLocked()
        }
    }

    @discardableResult
    func setDisabled(id: String, disabled: Bool) async throws -> Snapshot {
        try await exclusive {
            try ensureMutable()
            _ = try await cli(
                [disabled ? "disable" : "enable", id],
                timeout: timeouts.mutation,
                kind: .mutation(disabled ? "Disable account" : "Enable account")
            )
            return try await refreshLocked()
        }
    }

    // MARK: - Automation

    /// `cswap auto` is a foreground loop; a wrapper-owned LaunchAgent keeps
    /// it running. Its presence is the on/off state, and `cswap config` is
    /// the only source of its settings.
    @discardableResult
    func setAutoSwitchEnabled(_ enabled: Bool) async throws -> Snapshot {
        try await exclusive {
            try ensureMutable()
            guard let automation else {
                throw BridgeError.requestFailed(code: "automation.unavailable", message: "Auto-switch isn't available with this backend.")
            }
            do {
                if enabled {
                    try automation.enable(cswapPath: cswapURL.path)
                } else {
                    try automation.disable()
                }
            } catch {
                _ = try? await refreshLocked()
                throw BridgeError.requestFailed(
                    code: "automation.service",
                    message: Redactor.sanitize(error.localizedDescription)
                )
            }
            return try await refreshLocked()
        }
    }

    @discardableResult
    func updateAutoSwitchSettings(_ update: AutoSwitchSettingsUpdate) async throws -> Snapshot {
        try await exclusive {
            try ensureMutable()
            var changes: [(key: String, value: String)] = []
            if let threshold = update.thresholdPct {
                changes.append(("autoswitch.threshold", String(threshold)))
            }
            if let strategy = update.strategy {
                changes.append(("autoswitch.strategy", strategy == .consumeFirst ? "consume-first" : "best"))
            }
            if let cooldown = update.cooldownSeconds {
                changes.append(("autoswitch.cooldownSeconds", String(cooldown)))
            }
            if let include = update.includeAPIKeyAccounts {
                changes.append(("autoswitch.includeApiKeyAccounts", include ? "true" : "false"))
            }

            var failures: [String] = []
            var applied = 0
            for change in changes {
                do {
                    _ = try await cli(
                        ["config", "set", change.key, change.value],
                        timeout: timeouts.mutation,
                        kind: .mutation("Change \(change.key)")
                    )
                    applied += 1
                } catch {
                    failures.append("\(change.key): \(Self.describe(error))")
                }
            }
            // `cswap auto` reads settings at startup; restart our service so
            // the change takes effect now. No-op when automation is off.
            if applied > 0, let automation {
                do {
                    try automation.restartIfInstalled(cswapPath: cswapURL.path)
                } catch {
                    failures.append("Settings saved, but restarting auto-switch failed: \(Redactor.sanitize(error.localizedDescription))")
                }
            }
            let snapshot = try await refreshLocked()
            if !failures.isEmpty {
                let prefix = applied > 0 ? "Some settings were saved, others weren't. " : "Settings weren't saved. "
                throw BridgeError.partialSuccess(prefix + failures.joined(separator: " "))
            }
            return snapshot
        }
    }

    func automationServiceStatus() async -> AutoSwitchServiceStatus? {
        automation?.status()
    }

    // MARK: - Transfer

    func exportAccounts(to url: URL, accountID: String?) async throws {
        try await exclusive {
            try ensureMutable()
            var arguments = ["export", url.path]
            if let accountID { arguments += ["--account", accountID] }
            _ = try await cli(arguments, timeout: timeouts.mutation, kind: .read)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw BridgeError.requestFailed(code: "export.missing", message: "cswap finished but no export file was written.")
            }
        }
    }

    func importAccounts(from url: URL, overwriteExisting: Bool) async throws -> ImportOutcome {
        try await exclusive {
            try ensureMutable()
            var arguments = ["import", url.path]
            if overwriteExisting { arguments.append("--force") }
            let output = try await cli(arguments, timeout: timeouts.mutation, kind: .mutation("Import accounts"))
            let skipped = Redactor.sanitize(String(decoding: output.stdout, as: UTF8.self))
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("Skipped") }
            let snapshot = try await refreshLocked()
            return ImportOutcome(snapshot: snapshot, skipped: skipped)
        }
    }

    // MARK: - Command queue

    /// Runs `body` with exclusive use of the CLI. FIFO-ish: waiters are
    /// resumed in arrival order, and every waiter re-checks the flag.
    private func exclusive<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        while commandInFlight {
            await withCheckedContinuation { commandWaiters.append($0) }
        }
        commandInFlight = true
        defer {
            commandInFlight = false
            if !commandWaiters.isEmpty { commandWaiters.removeFirst().resume() }
        }
        return try await body()
    }

    private func ensureMutable() throws {
        if case .incompatible(let reason)? = status?.readiness {
            throw BridgeError.incompatible(reason)
        }
    }

    private func markIncompatible(_ reason: String) {
        guard var current = status else { return }
        current.readiness = .incompatible(reason)
        status = current
    }

    // MARK: - Process

    private func cli(
        _ arguments: [String],
        stdin: Data? = nil,
        timeout: Duration,
        kind: CommandKind,
        secrets: [String] = []
    ) async throws -> ProcessOutput {
        let request = ProcessRequest(
            executable: cswapURL,
            arguments: arguments,
            environment: childEnvironment,
            stdin: stdin,
            timeout: timeout
        )
        // Cancelled before anything ran: nothing can have changed.
        if Task.isCancelled { throw BridgeError.cancelled }
        let output: ProcessOutput
        do {
            output = try await runner.run(request)
        } catch let error as ProcessRunnerError {
            switch (error, kind) {
            case (.launchFailed(let reason), _):
                throw BridgeError.launchFailed(Redactor.sanitize(reason, secrets: secrets))
            case (.timedOut, .mutation(let name)), (.cancelled, .mutation(let name)):
                // The command may have taken effect. Never retry; re-read.
                _ = try? await refreshLocked()
                throw BridgeError.outcomeUnknown(operation: name)
            case (.timedOut, .read):
                throw BridgeError.timeout(method: "cswap \(arguments.first ?? "")")
            case (.cancelled, .read):
                throw BridgeError.cancelled
            }
        }
        if output.exitStatus != 0 || output.terminatedBySignal {
            let error = Self.classifyFailure(output, arguments: arguments, secrets: secrets)
            if case .mutation = kind {
                // A failing command may still have changed something (e.g.
                // a partial import); show the real state.
                _ = try? await refreshLocked()
            }
            log.error("cswap \(arguments.first ?? "", privacy: .public) failed: \(error.description, privacy: .private)")
            throw error
        }
        return output
    }

    /// Turns a failed run into a coarse, sanitized error. JSON-mode commands
    /// print `{"error":{"type":…,"message":…}}` on stdout; others use stderr.
    static func classifyFailure(_ output: ProcessOutput, arguments: [String], secrets: [String] = []) -> BridgeError {
        var message = ""
        var errorType = ""
        if let payload = try? SnapshotMapping.jsonObject(from: output.stdout),
           let error = payload["error"] as? [String: Any] {
            message = error["message"] as? String ?? ""
            errorType = error["type"] as? String ?? ""
        }
        if message.isEmpty {
            message = Redactor.summarizeOutput(String(decoding: output.stderr, as: UTF8.self), secrets: secrets)
        }
        if message.isEmpty {
            message = Redactor.summarizeOutput(String(decoding: output.stdout, as: UTF8.self), secrets: secrets)
        }
        message = Redactor.sanitize(message, secrets: secrets)
        if message.isEmpty {
            message = output.terminatedBySignal
                ? "cswap was terminated by signal \(output.exitStatus)."
                : "cswap exited with status \(output.exitStatus)."
        }

        let lowered = (message + " " + errorType).lowercased()
        let category: String
        if output.exitStatus == 2, lowered.contains("usage:") || lowered.contains("invalid choice") || lowered.contains("unrecognized arguments") {
            category = "cli.unsupported"
            message = "This cswap version rejected the command `cswap \(arguments.first ?? "")`. It may be incompatible with this app. \(message)"
        } else if ["unauthorized", "401", "invalid token", "token", "credential", "keychain", "oauth"].contains(where: lowered.contains) {
            category = "cli.credential"
        } else if ["network", "connection", "timed out", "resolve", "unreachable", "ssl"].contains(where: lowered.contains) {
            category = "cli.network"
        } else if ["not found", "no account", "invalid", "unknown account", "already"].contains(where: lowered.contains) {
            category = "cli.input"
        } else {
            category = "cli.failed"
        }
        return .requestFailed(code: category, message: message)
    }

    /// The CLI prints "Cancelled" and exits 0 when a confirmation prompt
    /// isn't answered; treat that as "nothing changed", not success.
    static func cliCancelled(_ output: ProcessOutput) -> Bool {
        Redactor.sanitize(String(decoding: output.stdout + output.stderr, as: UTF8.self))
            .split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "Cancelled" }
    }

    private static func describe(_ error: Error) -> String {
        if let bridgeError = error as? BridgeError { return bridgeError.description }
        return Redactor.sanitize(error.localizedDescription)
    }
}
