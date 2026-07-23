//
//  BridgeModels.swift
//  ClaudeSwap
//
//  Domain models decoded from the helper's `getSnapshot` result / the
//  `snapshotChanged` event payload. These mirror the Python core's
//  `AccountsSnapshot` / usage-window shapes closely enough to round-trip,
//  but are intentionally UI-facing: no secrets, no filesystem paths beyond
//  what's needed for diagnostics.
//

import Foundation

/// Top-level state of the world, as reported by the helper.
struct Snapshot: Codable, Sendable, Equatable {
    var protocolVersion: Int
    var generatedAt: Date
    var activeAccountId: String?
    var accounts: [Account]
    var autoSwitch: AutoSwitchState
    var capabilities: Capabilities
    var diagnostics: Diagnostics

    static let empty = Snapshot(
        protocolVersion: BridgeProtocolVersion.current,
        generatedAt: .distantPast,
        activeAccountId: nil,
        accounts: [],
        autoSwitch: .disabled,
        capabilities: .none,
        diagnostics: .empty
    )
}

/// Kind of credential backing an account.
enum AccountKind: String, Codable, Sendable, Equatable {
    case oauth
    case apiKey
}

/// One managed Claude account.
struct Account: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var email: String
    var alias: String?
    var organizationName: String?
    var organizationId: String?
    var kind: AccountKind
    var isActive: Bool
    var switchable: Bool
    var disabled: Bool
    var quarantined: Bool
    var quarantineReason: String?
    var addedAt: Date?
    var usage: UsageSnapshot

    /// Display label: alias if set, else organization name, else email.
    var displayName: String {
        if let alias, !alias.isEmpty { return alias }
        if let organizationName, !organizationName.isEmpty { return organizationName }
        return email
    }

    /// Org tag for display: the org name, or "personal".
    var orgTag: String {
        organizationName?.isEmpty == false ? organizationName! : "personal"
    }
}

/// Usage across an account's rolling windows (5h, 7d, and any
/// model-scoped windows the helper reports).
struct UsageSnapshot: Codable, Sendable, Equatable {
    var windows: [UsageWindow]
    /// True when the helper could not read usage this cycle (network error,
    /// token expired, etc.) — bars should render as "unknown", not 0%.
    var unknown: Bool
    var lastError: String?
    /// True when bars are retained from a previous fresh fetch because the
    /// core's JSON list only serves decision-fresh usage (≤ ~5 minutes).
    /// Inactive accounts often fall into this state — matching `cswap list`
    /// human output, which still shows last-known numbers with an age note.
    var isStale: Bool

    /// The window with the highest utilization ("binding" window) — the one
    /// that determines whether the account is near a limit.
    var bindingWindow: UsageWindow? {
        windows.max(by: { $0.utilizationPct < $1.utilizationPct })
    }

    init(
        windows: [UsageWindow],
        unknown: Bool,
        lastError: String? = nil,
        isStale: Bool = false
    ) {
        self.windows = windows
        self.unknown = unknown
        self.lastError = lastError
        self.isStale = isStale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windows = try container.decode([UsageWindow].self, forKey: .windows)
        unknown = try container.decode(Bool.self, forKey: .unknown)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        isStale = try container.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
    }

    static let empty = UsageSnapshot(windows: [], unknown: true, lastError: nil, isStale: false)
}

/// One rolling usage window (e.g. "5h", "7d", or a model-scoped name).
struct UsageWindow: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var label: String
    var utilizationPct: Double
    var resetsAt: Date?

    /// Semantic status bucket for UI coloring.
    var status: UsageStatus {
        UsageStatus(utilizationPct: utilizationPct)
    }
}

/// Semantic status bucket shared by progress bars, badges, and menu bar text.
enum UsageStatus: String, Sendable, Equatable, CaseIterable {
    case normal
    case attention
    case critical
    case exhausted

    init(utilizationPct: Double) {
        switch utilizationPct {
        case ..<70: self = .normal
        case ..<85: self = .attention
        case ..<100: self = .critical
        default: self = .exhausted
        }
    }
}

/// Auto-switch engine configuration + last-known status, as reported by
/// the helper. Mirrors the Python `AutoSwitchSettings` + engine state.
struct AutoSwitchState: Codable, Sendable, Equatable {
    var enabled: Bool
    var strategy: AutoSwitchStrategy
    var thresholdPct: Double
    var cooldownSeconds: Int
    var includeAPIKeyAccounts: Bool
    var lastSwitchAt: Date?
    var lastEventDescription: String?

    static let disabled = AutoSwitchState(
        enabled: false,
        strategy: .best,
        thresholdPct: 85,
        cooldownSeconds: 300,
        includeAPIKeyAccounts: false,
        lastSwitchAt: nil,
        lastEventDescription: nil
    )
}

enum AutoSwitchStrategy: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case best
    case consumeFirst

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .best: return "Best headroom"
        case .consumeFirst: return "Consume first"
        }
    }
}

/// Feature flags reported by the helper so the UI can hide/disable actions
/// it doesn't support (e.g. an older core without export/import).
struct Capabilities: Codable, Sendable, Equatable {
    var supportsAutoSwitch: Bool
    var supportsAPIKeyAccounts: Bool
    var supportsExportImport: Bool
    var coreVersion: String

    static let none = Capabilities(
        supportsAutoSwitch: false,
        supportsAPIKeyAccounts: false,
        supportsExportImport: false,
        coreVersion: "unknown"
    )
}

/// Non-sensitive diagnostic info surfaced in Settings > Advanced. Never
/// contains tokens, credentials, or full home-directory paths beyond what
/// the user already knows.
struct Diagnostics: Codable, Sendable, Equatable {
    var corePath: String?
    var helperPID: Int32?
    var uptimeSeconds: Double
    var warnings: [String]

    static let empty = Diagnostics(corePath: nil, helperPID: nil, uptimeSeconds: 0, warnings: [])
}

// MARK: - Update payloads (app -> helper, mirrored back into local state)

/// Local-only representation of pending changes to auto-switch settings,
/// built by the Automation screen before being sent over the bridge.
struct AutoSwitchSettingsUpdate: Sendable, Equatable {
    var thresholdPct: Double?
    var strategy: AutoSwitchStrategy?
    var cooldownSeconds: Int?
    var includeAPIKeyAccounts: Bool?
}

/// What Claude Code is currently logged in as, for the "Add current login" flow.
struct CurrentClaudeLogin: Sendable, Equatable {
    var email: String
    var organizationName: String?
    var managed: Bool
    var accountNumber: Int?
}
