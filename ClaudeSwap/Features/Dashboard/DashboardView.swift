//
//  DashboardView.swift
//  ClaudeSwap
//
//  At-a-glance view of *every* managed account's usage windows (same
//  coverage as `cswap list`), with the active account highlighted, plus
//  auto-switch and quick actions.
//

import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
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
            }
            .padding(AppSpacing.lg)
        }
        .background(AppColors.background)
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
                        !account.switchable
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
            .disabled(appModel.isBusy)

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
