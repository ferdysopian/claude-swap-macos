//
//  DashboardView.swift
//  ClaudeSwap
//
//  At-a-glance view of *every* managed account's usage windows (same
//  coverage as `cswap list`), with the active account highlighted, plus
//  auto-switch and quick actions. When there is no usable `cswap` it shows
//  an honest, actionable state instead of any placeholder data.
//

import SwiftUI
import AppKit

/// Install commands users can copy, plus Re-check / Settings actions.
/// Shared by the Dashboard (roomy) and the menu bar popover (compact).
struct ConnectionProblemView: View {
    @Environment(AppModel.self) private var appModel
    var compact = false
    /// Opens Settings; the menu bar passes a `SettingsLink` instead.
    var openSettings: (() -> Void)?

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            switch appModel.connectionState {
            case .connecting:
                ProgressView()
                Text("Checking for cswap…")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
            case .cliNotFound(let path):
                Image(systemName: "terminal")
                    .font(.system(size: compact ? 26 : 36))
                    .foregroundStyle(AppColors.textTertiary)
                Text(path.map { "No executable cswap at \($0)" } ?? "cswap isn't installed")
                    .font(AppTypography.headline)
                    .multilineTextAlignment(.center)
                Text("Claude Swap needs the cswap command-line tool. Install it with one of:")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                CopyableCommand(command: "uv tool install claude-swap")
                CopyableCommand(command: "pipx install claude-swap")
                actions(recheckTitle: "Re-check")
            case .incompatible(let reason):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: compact ? 26 : 36))
                    .foregroundStyle(AppColors.status(.attention))
                Text("This cswap can't be used")
                    .font(AppTypography.headline)
                Text(reason)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Text("Changes are disabled until this is fixed.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
                actions(recheckTitle: "Re-check")
            case .disconnected(let reason):
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: compact ? 26 : 36))
                    .foregroundStyle(AppColors.status(.critical))
                Text("Couldn't talk to cswap")
                    .font(AppTypography.headline)
                Text(Redactor.sanitize(reason ?? "cswap didn't respond."))
                    .font(AppTypography.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(compact ? 4 : 8)
                    .textSelection(.enabled)
                actions(recheckTitle: "Retry")
            case .connected, .fixtureMode:
                EmptyView()
            }
        }
        .padding(compact ? AppSpacing.sm : AppSpacing.xl)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func actions(recheckTitle: String) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Button(recheckTitle) { appModel.reconnect() }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.isBusy)
            if let openSettings {
                Button("Open Settings", action: openSettings)
            } else {
                SettingsLink { Text("Open Settings") }
            }
        }
        .padding(.top, AppSpacing.xs)
    }
}

struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: AppSpacing.xs)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .buttonStyle(.link)
            .font(AppTypography.caption)
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .background(RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusSmall).fill(AppColors.surfaceElevated))
    }
}

/// "Demo data — not your accounts" badge for fixture mode.
struct DemoDataBadge: View {
    var body: some View {
        Label("Demo data — not your accounts", systemImage: "theatermasks")
            .font(AppTypography.captionEmphasized)
            .foregroundStyle(AppColors.status(.attention))
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.xxs)
            .background(Capsule().fill(AppColors.status(.attention).opacity(0.15)))
    }
}

struct DashboardView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            if appModel.connectionState != .connected && appModel.connectionState != .fixtureMode {
                ConnectionProblemView(openSettings: { appModel.selectedTab = .settings })
                    .cardStyle()
                    .padding(AppSpacing.lg)
            } else {
                connectedContent
            }
        }
        .background(AppColors.background)
    }

    private var connectedContent: some View {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                if appModel.connectionState == .fixtureMode {
                    DemoDataBadge()
                }
                if appModel.snapshot.accounts.isEmpty {
                    EmptyState(
                        systemImage: "person.crop.circle.badge.questionmark",
                        title: "No accounts yet",
                        message: "Add an account to start tracking usage and enable auto-switch.",
                        actionTitle: "Go to Accounts"
                    ) {
                        appModel.selectedTab = .accounts
                    }
                    .cardStyle()
                } else {
                    AllAccountsStatusSection()
                }

                AutoSwitchCard()

                QuickActionsRow()

                DashboardFootnotes()
            }
            .padding(AppSpacing.lg)
    }
}

private struct DashboardFootnotes: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            if appModel.lastBackgroundRefreshError != nil {
                Text(staleText)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
            if appModel.connectionState == .connected,
               case .unverified? = appModel.backendStatus?.compatibility {
                let version = appModel.backendStatus?.version ?? "This version of"
                Text("cswap \(version) is supported but not yet verified with this app version.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    private var staleText: String {
        let at = appModel.snapshot.generatedAt
        guard at > .distantPast else { return "Couldn't refresh — no data loaded yet." }
        let relative = RelativeDateTimeFormatter().localizedString(for: at, relativeTo: appModel.displayNow)
        return "Couldn't refresh — showing data from \(relative)."
    }
}

private struct AllAccountsStatusSection: View {
    @Environment(AppModel.self) private var appModel

    /// Active first, then slot order (stable id sort as fallback).
    private var orderedAccounts: [Account] {
        let activeId = appModel.snapshot.activeAccountId
        return appModel.snapshot.accounts.sorted { lhs, rhs in
            if lhs.id == activeId { return true }
            if rhs.id == activeId { return false }
            return (Int(lhs.id) ?? 0) < (Int(rhs.id) ?? 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            CardHeader(
                title: "Account Status",
                subtitle: "Usage for every managed account — not just the active one."
            )

            ForEach(orderedAccounts) { account in
                AccountStatusCard(
                    account: account,
                    isActive: account.id == appModel.snapshot.activeAccountId
                )
            }
        }
    }
}

private struct AccountStatusCard: View {
    @Environment(AppModel.self) private var appModel
    let account: Account
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: AppSpacing.xxs) {
                        Text(isActive ? "Active" : "Account \(account.id)")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.textSecondary)
                        if account.disabled { TagBadge(text: "Disabled") }
                        if account.quarantined {
                            StatusBadge(text: "Quarantined", status: .exhausted)
                        }
                    }
                    Text(account.displayName)
                        .font(isActive ? AppTypography.largeTitle : AppTypography.title)
                    HStack(spacing: AppSpacing.xxs) {
                        TagBadge(text: account.orgTag)
                        TagBadge(text: account.kind == .apiKey ? "API key" : "OAuth")
                        Text(account.email)
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if let binding = account.usage.bindingWindow, !account.usage.unknown {
                    UsageRing(
                        percent: binding.utilizationPct,
                        status: binding.status,
                        diameter: isActive ? 56 : 44
                    )
                }
            }

            Divider()

            AccountUsageOverview(account: account)

            if !isActive {
                HStack {
                    Spacer()
                    Button("Switch to This Account") {
                        Task { await appModel.switchAccount(id: account.id) }
                    }
                    .disabled(
                        !appModel.canMutate
                            || !account.switchable
                            || account.disabled
                            || account.quarantined
                            || appModel.isBusy
                    )
                }
            }
        }
        .cardStyle(padding: AppSpacing.lg)
        .opacity(account.disabled ? 0.65 : 1)
    }
}

private struct AutoSwitchCard: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            CardHeader(
                title: "Auto-Switch",
                subtitle: appModel.snapshot.autoSwitch.enabled
                    ? "Watching usage and switching before limits hit."
                    : "Currently off — you'll need to switch manually."
            ) {
                Toggle("", isOn: Binding(
                    get: { appModel.snapshot.autoSwitch.enabled },
                    set: { newValue in Task { await appModel.setAutoSwitchEnabled(newValue) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!appModel.canMutate || appModel.isBusy)
            }

            HStack(spacing: AppSpacing.lg) {
                LabeledContent("Strategy", value: appModel.snapshot.autoSwitch.strategy.displayName)
                LabeledContent("Threshold", value: "\(Int(appModel.snapshot.autoSwitch.thresholdPct))%")
                LabeledContent("Cooldown", value: "\(appModel.snapshot.autoSwitch.cooldownSeconds / 60)m")
            }
            .font(AppTypography.subheadline)

            if let description = appModel.snapshot.autoSwitch.lastEventDescription {
                Text(description)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }

            Button("Configure Auto-Switch…") { appModel.selectedTab = .automation }
                .buttonStyle(.link)
        }
        .cardStyle()
    }
}

private struct QuickActionsRow: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Button {
                Task { await appModel.rotateToBestAccount() }
            } label: {
                Label("Rotate to Best Account", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .disabled(appModel.isBusy || !appModel.canMutate)

            Button {
                Task { await appModel.refreshSnapshot() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(appModel.isBusy)

            Spacer()

            if appModel.isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }
}
