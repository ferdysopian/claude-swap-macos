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
        warnings: [String] = []
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
            autoSwitch: .disabled,
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
        )
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
        )
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
        guard let dict = raw as? [String: Any] else {
            let unknown = usageStatus != "ok"
            let error = unknown ? (usageStatus ?? "unavailable") : nil
            return UsageSnapshot(windows: [], unknown: unknown || usageStatus == "unavailable", lastError: error)
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
                lastError: dict["lastError"] as? String
            )
        }

        var windows: [UsageWindow] = []
        if let five = dict["fiveHour"] as? [String: Any] {
            windows.append(UsageWindow(
                id: "5h",
                label: "5 hour",
                utilizationPct: doubleValue(five["pct"]) ?? 0,
                resetsAt: parseDate(five["resetsAt"] as? String)
            ))
        }
        if let seven = dict["sevenDay"] as? [String: Any] {
            windows.append(UsageWindow(
                id: "7d",
                label: "7 day",
                utilizationPct: doubleValue(seven["pct"]) ?? 0,
                resetsAt: parseDate(seven["resetsAt"] as? String)
            ))
        }
        if let scoped = dict["scoped"] as? [[String: Any]] {
            for entry in scoped {
                let name = (entry["name"] as? String) ?? "model"
                windows.append(UsageWindow(
                    id: name,
                    label: name,
                    utilizationPct: doubleValue(entry["pct"]) ?? 0,
                    resetsAt: parseDate(entry["resetsAt"] as? String)
                ))
            }
        }

        let unknown = windows.isEmpty && usageStatus != "ok"
        return UsageSnapshot(
            windows: windows,
            unknown: unknown,
            lastError: unknown ? (usageStatus ?? "unavailable") : nil
        )
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
        if let d = ISO8601DateFormatter().date(from: raw) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw)
    }
}
