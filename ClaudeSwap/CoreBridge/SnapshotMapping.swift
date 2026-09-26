//
//  SnapshotMapping.swift
//  ClaudeSwap
//
//  Maps live `cswap list --json` / bridge `snapshot` payloads into the
//  UI-facing `Snapshot` model. The Python shapes use `number`, nested
//  `usage.fiveHour`/`sevenDay`/`scoped`, and org fields that don't match
//  the fixture camelCase models 1:1.
//

import Foundation

enum SnapshotMapping {
    /// Build a UI snapshot from a `cswap list --json` (or bridge
    /// `list_accounts`) document.
    static func fromListPayload(
        _ payload: [String: Any],
        coreVersion: String,
        corePath: String?,
        warnings: [String] = [],
        autoSwitch: AutoSwitchState = .disabled
    ) -> Snapshot {
        let accountsRaw = payload["accounts"] as? [[String: Any]] ?? []
        let activeNumber = payload["activeAccountNumber"] as? Int
        let accounts = accountsRaw.map { mapAccount($0) }
        let activeId = activeNumber.map(String.init)
            ?? accounts.first(where: \.isActive)?.id

        return Snapshot(
            protocolVersion: BridgeProtocolVersion.current,
            generatedAt: Date(),
            activeAccountId: activeId,
            accounts: accounts,
            autoSwitch: autoSwitch,
            capabilities: Capabilities(
                supportsAutoSwitch: true,
                supportsAPIKeyAccounts: true,
                supportsExportImport: true,
                coreVersion: coreVersion
            ),
            diagnostics: Diagnostics(
                corePath: corePath,
                helperPID: nil,
                uptimeSeconds: 0,
                warnings: warnings
            )
        ).enrichingFromUsageCache()
    }

    /// Build a UI snapshot from a bridge `snapshot` result dict.
    static func fromBridgeSnapshot(
        _ payload: [String: Any],
        corePath: String?,
        helperPID: Int32?
    ) -> Snapshot {
        let accountsRaw = payload["accounts"] as? [[String: Any]] ?? []
        let accounts = accountsRaw.map { mapAccount($0) }
        let activeNumber = payload["activeAccountNumber"] as? Int
        let activeId = activeNumber.map(String.init)
            ?? accounts.first(where: \.isActive)?.id
        let coreVersion = (payload["coreVersion"] as? String)
            ?? (payload["capabilities"] as? [String: Any])?["coreVersion"] as? String
            ?? "unknown"
        let warnings = payload["warnings"] as? [String] ?? []
        let auto = mapAutoSwitch(payload["autoSwitch"] as? [String: Any] ?? [:])
        let capsRaw = payload["capabilities"] as? [String: Any] ?? [:]

        return Snapshot(
            protocolVersion: (payload["protocolVersion"] as? Int) ?? BridgeProtocolVersion.current,
            generatedAt: parseDate(payload["takenAt"] as? String) ?? Date(),
            activeAccountId: activeId,
            accounts: accounts,
            autoSwitch: auto,
            capabilities: Capabilities(
                supportsAutoSwitch: (capsRaw["supportsAutoSwitch"] as? Bool) ?? true,
                supportsAPIKeyAccounts: (capsRaw["supportsAPIKeyAccounts"] as? Bool)
                    ?? (capsRaw["secretsViaStdinOnly"] as? Bool) ?? true,
                supportsExportImport: (capsRaw["supportsExportImport"] as? Bool) ?? true,
                coreVersion: coreVersion
            ),
            diagnostics: Diagnostics(
                corePath: corePath,
                helperPID: helperPID,
                uptimeSeconds: 0,
                warnings: warnings
            )
        ).enrichingFromUsageCache()
    }

    // MARK: - Account

    static func mapAccount(_ raw: [String: Any]) -> Account {
        let number = raw["number"] as? Int
        let id = number.map(String.init)
            ?? (raw["id"] as? String)
            ?? (raw["email"] as? String)
            ?? UUID().uuidString
        let email = (raw["email"] as? String) ?? ""
        let alias = raw["alias"] as? String
        let orgName = raw["organizationName"] as? String
        let orgId = (raw["organizationId"] as? String)
            ?? (raw["organizationUuid"] as? String)
        let isActive = (raw["active"] as? Bool)
            ?? (raw["isActive"] as? Bool)
            ?? false
        let disabled = (raw["disabled"] as? Bool) ?? false
        let quarantined = (raw["quarantined"] as? Bool) ?? false
        let quarantineReason = raw["quarantineReason"] as? String
        let kind: AccountKind = {
            if let kind = raw["kind"] as? String {
                return kind == "apiKey" ? .apiKey : .oauth
            }
            // Heuristic for older list payloads.
            if email.hasSuffix("@token.local") { return .apiKey }
            return .oauth
        }()

        let usageStatus = raw["usageStatus"] as? String
        let usage = mapUsage(raw["usage"], usageStatus: usageStatus)

        return Account(
            id: id,
            email: email,
            alias: alias,
            organizationName: orgName,
            organizationId: orgId,
            kind: kind,
            isActive: isActive,
            switchable: (raw["switchable"] as? Bool) ?? !disabled,
            disabled: disabled,
            quarantined: quarantined,
            quarantineReason: quarantineReason,
            addedAt: parseDate(raw["addedAt"] as? String),
            usage: usage
        )
    }

    static func mapUsage(_ raw: Any?, usageStatus: String?) -> UsageSnapshot {
        let statusNote = Self.usageStatusNote(usageStatus)
        guard let dict = raw as? [String: Any] else {
            let unknown = usageStatus != "ok"
            return UsageSnapshot(
                windows: [],
                unknown: unknown || usageStatus == "unavailable",
                lastError: unknown ? statusNote : nil
            )
        }

        // Already UI-shaped?
        if let windowsRaw = dict["windows"] as? [[String: Any]] {
            let windows = windowsRaw.compactMap { window -> UsageWindow? in
                guard let id = window["id"] as? String else { return nil }
                let label = (window["label"] as? String) ?? id
                let pct = doubleValue(window["utilizationPct"]) ?? 0
                return UsageWindow(
                    id: id,
                    label: label,
                    utilizationPct: pct,
                    resetsAt: parseDate(window["resetsAt"] as? String)
                )
            }
            return UsageSnapshot(
                windows: windows,
                unknown: (dict["unknown"] as? Bool) ?? false,
                lastError: dict["lastError"] as? String,
                isStale: (dict["isStale"] as? Bool) ?? false
            )
        }

        var windows: [UsageWindow] = []
        // JSON list uses camelCase; on-disk lastGood uses snake_case.
        if let five = (dict["fiveHour"] as? [String: Any]) ?? (dict["five_hour"] as? [String: Any]) {
            windows.append(UsageWindow(
                id: "5h",
                label: "5 hour",
                utilizationPct: doubleValue(five["pct"]) ?? 0,
                resetsAt: parseDate((five["resetsAt"] as? String) ?? (five["resets_at"] as? String))
            ))
        }
        if let seven = (dict["sevenDay"] as? [String: Any]) ?? (dict["seven_day"] as? [String: Any]) {
            windows.append(UsageWindow(
                id: "7d",
                label: "7 day",
                utilizationPct: doubleValue(seven["pct"]) ?? 0,
                resetsAt: parseDate((seven["resetsAt"] as? String) ?? (seven["resets_at"] as? String))
            ))
        }
        if let scoped = dict["scoped"] as? [[String: Any]] {
            for entry in scoped {
                let name = (entry["name"] as? String) ?? "model"
                windows.append(UsageWindow(
                    id: name,
                    label: name,
                    utilizationPct: doubleValue(entry["pct"]) ?? 0,
                    resetsAt: parseDate((entry["resetsAt"] as? String) ?? (entry["resets_at"] as? String))
                ))
            }
        }

        let unknown = windows.isEmpty && usageStatus != "ok"
        return UsageSnapshot(
            windows: windows,
            unknown: unknown,
            lastError: unknown ? statusNote : nil
        )
    }

    /// Human-readable note for `cswap list --json` usageStatus values.
    static func usageStatusNote(_ status: String?) -> String {
        switch status {
        case nil, "unavailable":
            // Core JSON omits last-good once age > STALE_OK_S (~5m). Inactive
            // accounts commonly land here even though human `cswap list` still
            // shows the cached numbers.
            return "Not refreshed yet"
        case "ok":
            return "ok"
        case "token_expired":
            return "Token expired"
        case "relogin_required":
            return "Re-login required"
        case "no_credentials":
            return "No credentials"
        case "keychain_unavailable":
            return "Keychain unavailable"
        case "api_key":
            return "API key (no usage quota)"
        default:
            return status ?? "Not refreshed yet"
        }
    }

    /// Keep last-known usage bars when a refresh returns decision-stale
    /// `unavailable` / null usage (common for inactive accounts). Hard auth
    /// failures still clear the bars.
    static func mergingPreservedUsage(previous: Snapshot, next: Snapshot) -> Snapshot {
        let hardStatuses: Set<String> = [
            "Token expired",
            "Re-login required",
            "No credentials",
            "Keychain unavailable",
            "API key (no usage quota)",
            "token_expired",
            "relogin_required",
            "no_credentials",
            "keychain_unavailable",
            "api_key",
        ]
        let previousById = Dictionary(uniqueKeysWithValues: previous.accounts.map { ($0.id, $0) })
        var merged = next
        for index in merged.accounts.indices {
            let account = merged.accounts[index]
            if let err = account.usage.lastError, hardStatuses.contains(err) {
                continue
            }
            let softMiss = account.usage.windows.isEmpty
            guard softMiss, let prior = previousById[account.id], !prior.usage.windows.isEmpty else {
                continue
            }
            merged.accounts[index].usage = UsageSnapshot(
                windows: prior.usage.windows,
                unknown: false,
                lastError: "Last known — refreshes when this account is active",
                isStale: true
            )
        }
        return merged
    }

    /// Fill empty / decision-stale usage from `cache/usage.json` lastGood —
    /// the same source human `cswap list` shows for inactive accounts.
    static func enrichingFromUsageCache(
        _ snapshot: Snapshot,
        rows: [String: UsageCacheStore.Row]? = nil
    ) -> Snapshot {
        let cache = rows ?? UsageCacheStore.loadRows()
        guard !cache.isEmpty else { return snapshot }

        let hardStatuses: Set<String> = [
            "Token expired",
            "Re-login required",
            "No credentials",
            "Keychain unavailable",
            "API key (no usage quota)",
        ]
        var enriched = snapshot
        for index in enriched.accounts.indices {
            let account = enriched.accounts[index]
            if !account.usage.windows.isEmpty { continue }
            if let err = account.usage.lastError, hardStatuses.contains(err) { continue }
            guard let row = cache[account.id] else { continue }
            // Slot reuse guard: don't serve a previous account's lastGood.
            if let cachedEmail = row.email, !cachedEmail.isEmpty, cachedEmail != account.email {
                continue
            }
            let usage = mapUsage(row.lastGood, usageStatus: "ok")
            guard !usage.windows.isEmpty else { continue }
            let age = row.fetchedAt.map { UsageCacheStore.formatAge(since: $0) }
            enriched.accounts[index].usage = UsageSnapshot(
                windows: usage.windows,
                unknown: false,
                lastError: age.map { "Last known · \($0)" }
                    ?? "Last known — refreshes when this account is active",
                isStale: true
            )
        }
        return enriched
    }

    static func mapAutoSwitch(_ raw: [String: Any]) -> AutoSwitchState {
        let strategyRaw = (raw["strategy"] as? String) ?? "best"
        let strategy: AutoSwitchStrategy = strategyRaw == "consumeFirst" || strategyRaw == "consume-first"
            ? .consumeFirst
            : .best
        return AutoSwitchState(
            enabled: (raw["enabled"] as? Bool) ?? false,
            strategy: strategy,
            thresholdPct: doubleValue(raw["thresholdPct"]) ?? doubleValue(raw["threshold"]) ?? 85,
            cooldownSeconds: (raw["cooldownSeconds"] as? Int)
                ?? (raw["cooldown"] as? Int)
                ?? 300,
            includeAPIKeyAccounts: (raw["includeAPIKeyAccounts"] as? Bool)
                ?? (raw["includeApiKeyAccounts"] as? Bool)
                ?? false,
            lastSwitchAt: parseDate(raw["lastSwitchAt"] as? String),
            lastEventDescription: raw["lastEventDescription"] as? String
                ?? raw["lastSwitchTo"] as? String
        )
    }

    /// Flatten `cswap config list --json`
    /// (`{"settings":[{"key":"autoswitch.threshold","value":95.0,"isSet":true}, ...]}`)
    /// into a key → value dict.
    static func configValues(fromConfigList payload: [String: Any]) -> [String: Any] {
        let entries = (payload["settings"] as? [[String: Any]]) ?? []
        var values: [String: Any] = [:]
        for entry in entries {
            if let key = entry["key"] as? String {
                values[key] = entry["value"]
            }
        }
        return values
    }

    /// Auto-switch state for the CLI backend. `enabled` comes from whether
    /// the LaunchAgent is actually loaded — settings.json has no enabled
    /// flag, and a stray `autoswitch.enabled` entry is ignored.
    static func autoSwitchState(configValues values: [String: Any], daemonRunning: Bool) -> AutoSwitchState {
        let strategyRaw = (values["autoswitch.strategy"] as? String) ?? "best"
        return AutoSwitchState(
            enabled: daemonRunning,
            strategy: strategyRaw == "consumeFirst" || strategyRaw == "consume-first" ? .consumeFirst : .best,
            thresholdPct: doubleValue(values["autoswitch.threshold"]) ?? AutoSwitchState.disabled.thresholdPct,
            cooldownSeconds: doubleValue(values["autoswitch.cooldownSeconds"]).map { Int($0) }
                ?? AutoSwitchState.disabled.cooldownSeconds,
            includeAPIKeyAccounts: (values["autoswitch.includeApiKeyAccounts"] as? Bool) ?? false,
            lastSwitchAt: nil,
            lastEventDescription: nil
        )
    }

    // MARK: - Helpers

    static func jsonObject(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw BridgeError.decodingFailed("expected JSON object")
        }
        return dict
    }

    static func jsonObject(from value: JSONValue) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try jsonObject(from: data)
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        // Prefer fractional first — usage cache writes `…59.912942+00:00`.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: raw) { return d }
        return ISO8601DateFormatter().date(from: raw)
    }
}

extension Snapshot {
    func enrichingFromUsageCache(
        rows: [String: UsageCacheStore.Row]? = nil
    ) -> Snapshot {
        SnapshotMapping.enrichingFromUsageCache(self, rows: rows)
    }
}
