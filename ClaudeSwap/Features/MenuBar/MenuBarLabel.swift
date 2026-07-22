//
//  MenuBarLabel.swift
//  ClaudeSwap
//
//  The compact label rendered directly in the menu bar (the
//  `MenuBarExtra` "label" closure). Kept dependency-light and synchronous
//  since it's redrawn on every `AppModel` change. Shows a status glyph for
//  the active account's binding usage window, plus optional percentage /
//  account-name text driven by the same `@AppStorage` keys as
//  Settings > Menu Bar.
//

import SwiftUI

struct MenuBarLabel: View {
    let appModel: AppModel

    @AppStorage("menuBarShowsPercentage") private var showsPercentage = true
    @AppStorage("menuBarShowsAccountName") private var showsAccountName = false
    @AppStorage("menuBarShowsResetCountdown") private var showsResetCountdown = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
            if let text = MenuBarLabelFormatter.displayText(
                for: appModel.activeAccount,
                showsPercentage: showsPercentage,
                showsAccountName: showsAccountName,
                showsResetCountdown: showsResetCountdown
            ) {
                Text(text)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude Swap")
        .accessibilityValue(Text(MenuBarLabelFormatter.accessibilityValue(
            for: appModel.activeAccount,
            showsPercentage: true,
            showsAccountName: true,
            showsResetCountdown: true
        )))
    }

    /// SF Symbol reflecting the active account's binding-window status, so
    /// the menu bar communicates urgency even when text is turned off.
    private var symbolName: String {
        guard let status = appModel.activeAccount?.usage.bindingWindow?.status,
              appModel.activeAccount?.usage.unknown != true else {
            return "arrow.triangle.swap"
        }
        switch status {
        case .normal: return "circle.fill"
        case .attention: return "circle.lefthalf.filled"
        case .critical: return "exclamationmark.circle.fill"
        case .exhausted: return "exclamationmark.triangle.fill"
        }
    }

}

/// Pure formatting helpers, unit-testable without rendering a view.
enum MenuBarLabelFormatter {
    /// Compact text shown next to the menu-bar glyph (or `nil` when only the glyph should show).
    /// Example: `Globex · 22% · 1h 41m` when name, percentage, and reset are enabled.
    static func displayText(
        for account: Account?,
        showsPercentage: Bool,
        showsAccountName: Bool,
        showsResetCountdown: Bool = true,
        now: Date = Date()
    ) -> String? {
        guard let account else { return "No account" }
        var parts: [String] = []
        if showsAccountName { parts.append(account.displayName) }
        if let window = account.usage.bindingWindow, !account.usage.unknown {
            if showsPercentage {
                parts.append(String(format: "%.0f%%", window.utilizationPct))
            }
            if showsResetCountdown, let countdown = UsageCountdown.compact(until: window.resetsAt, now: now) {
                parts.append(countdown)
            }
        }
        if parts.isEmpty { return account.displayName }
        return parts.joined(separator: " · ")
    }

    /// VoiceOver-facing description of the current menu bar state.
    static func accessibilityValue(
        for account: Account?,
        showsPercentage: Bool,
        showsAccountName: Bool,
        showsResetCountdown: Bool = true,
        now: Date = Date()
    ) -> String {
        guard let account else { return "No active account" }
        var parts: [String] = []
        if showsAccountName { parts.append(account.displayName) }
        if let window = account.usage.bindingWindow, !account.usage.unknown {
            if showsPercentage {
                parts.append("\(window.label) usage \(String(format: "%.0f", window.utilizationPct)) percent")
            }
            if showsResetCountdown, let countdown = UsageCountdown.compact(until: window.resetsAt, now: now) {
                parts.append("resets in \(countdown)")
            }
        }
        return parts.isEmpty ? account.displayName : parts.joined(separator: ", ")
    }

    /// Back-compat alias used by older call sites / tests.
    static func text(for account: Account?, showsPercentage: Bool, showsAccountName: Bool) -> String {
        displayText(
            for: account,
            showsPercentage: showsPercentage,
            showsAccountName: showsAccountName,
            showsResetCountdown: false
        )
            ?? account?.displayName
            ?? "No account"
    }
}

/// Compact countdown matching `cswap list` style: `41m`, `1h 41m`, `1d 1h`.
enum UsageCountdown {
    static func compact(until resetsAt: Date?, now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let seconds = Int(resetsAt.timeIntervalSince(now))
        if seconds <= 0 { return "now" }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(minutes, 1))m"
    }
}
