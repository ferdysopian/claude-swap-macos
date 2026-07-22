//
//  MenuBarView.swift
//  ClaudeSwap
//
//  Popover content for the `MenuBarExtra` scene: active account summary
//  with its binding usage window, an auto-switch toggle, a quick-switch
//  list for the other switchable accounts, and shortcuts into the main
//  window / quit. Everything here reads from and writes to `AppModel` —
//  no local mock state.
//

import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    /// Every managed account, active first, then slot order — same coverage as `cswap list`.
    private var allAccounts: [Account] {
        let activeId = appModel.snapshot.activeAccountId
        return appModel.snapshot.accounts.sorted { lhs, rhs in
            if lhs.id == activeId { return true }
            if rhs.id == activeId { return false }
            return (Int(lhs.id) ?? 0) < (Int(rhs.id) ?? 0)
        }
    }

    var body: some View {
        @Bindable var appModel = appModel
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            header

            if allAccounts.isEmpty {
                EmptyState(
                    systemImage: "person.crop.circle.badge.questionmark",
                    title: "No accounts yet",
                    message: "Add one from the main window to start switching."
                )
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text("All Accounts")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                    ForEach(allAccounts) { account in
                        let isActive = account.id == appModel.snapshot.activeAccountId
                        AccountMenuRow(account: account, isActive: isActive) {
                            guard !isActive else { return }
                            Task { await appModel.switchAccount(id: account.id) }
                        }
                    }
                }
            }

            Divider()

            AutoSwitchRow(appModel: appModel)

            Divider()

            HStack {
                Button {
                    Task { await appModel.rotateToBestAccount() }
                } label: {
                    Label("Rotate Best", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(appModel.isBusy || allAccounts.count < 2)
                .accessibilityHint("Switches to whichever switchable account has the most headroom left.")

                Spacer()

                Button("Open Claude Swap") {
                    openMainWindow()
                }
            }
            .buttonStyle(.link)
            .font(AppTypography.caption)

            Button("Quit Claude Swap") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.link)
            .font(AppTypography.caption)
            .foregroundStyle(AppColors.textSecondary)
        }
        .padding(AppSpacing.md)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Claude Swap").font(AppTypography.headline)
            Spacer()
            ConnectionIndicator(state: indicatorState)
        }
    }

    private var indicatorState: ConnectionIndicator.State {
        switch appModel.connectionState {
        case .connecting: return .connecting
        case .connected: return .connected
        case .fixtureMode: return .fixture
        case .disconnected: return .disconnected
        }
    }

    /// Brings the main window forward, opening it if it isn't currently visible.
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let existing = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeKey }
        if let existing {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

private struct AutoSwitchRow: View {
    @Bindable var appModel: AppModel

    var body: some View {
        Toggle(isOn: Binding(
            get: { appModel.snapshot.autoSwitch.enabled },
            set: { newValue in Task { await appModel.setAutoSwitchEnabled(newValue) } }
        )) {
            Text("Auto-Switch").font(AppTypography.subheadline)
        }
        .toggleStyle(.switch)
        .accessibilityLabel("Auto-switch")
        .accessibilityHint("When on, switches accounts automatically before you hit a usage limit.")
    }
}

private struct AccountMenuRow: View {
    let account: Account
    let isActive: Bool
    let onSwitch: () -> Void

    private var isDisabled: Bool {
        isActive || !account.switchable || account.disabled || account.quarantined
    }

    var body: some View {
        Button(action: onSwitch) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: AppSpacing.xxs) {
                    Text(account.displayName).font(AppTypography.subheadline)
                    if isActive { TagBadge(text: "Active") }
                    if account.disabled { TagBadge(text: "Disabled") }
                    if account.quarantined {
                        StatusBadge(text: "Quarantined", status: .exhausted)
                    }
                    Spacer(minLength: 0)
                }
                AccountUsageChips(account: account)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusSmall, style: .continuous)
                    .fill(isActive ? AppColors.surfaceElevated : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled && !isActive)
        .opacity(account.disabled ? 0.5 : 1)
        .accessibilityLabel(Text(account.displayName))
        .accessibilityHint(isActive ? "Currently active" : (isDisabled ? "Not switchable right now" : "Switch to this account"))
    }
}
