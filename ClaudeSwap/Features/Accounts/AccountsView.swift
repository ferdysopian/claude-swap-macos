//
//  AccountsView.swift
//  ClaudeSwap
//
//  List of managed accounts with search, switch, alias editing, disable,
//  add (SecureField-backed token entry), and remove with confirmation.
//

import SwiftUI

struct AccountsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""
    @State private var showingAddSheet = false
    @State private var pendingRemoval: Account?
    @State private var editingAliasFor: Account?
    @State private var aliasDraft = ""

    private var filteredAccounts: [Account] {
        guard !searchText.isEmpty else { return appModel.snapshot.accounts }
        let query = searchText.lowercased()
        return appModel.snapshot.accounts.filter {
            $0.email.lowercased().contains(query) ||
            ($0.alias?.lowercased().contains(query) ?? false) ||
            ($0.organizationName?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search accounts", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Spacer()
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!appModel.canMutate)
            }
            .padding(AppSpacing.md)

            if filteredAccounts.isEmpty {
                EmptyState(
                    systemImage: "person.crop.circle.badge.plus",
                    title: appModel.snapshot.accounts.isEmpty ? "No accounts yet" : "No matches",
                    message: appModel.snapshot.accounts.isEmpty
                        ? "Add your first account to start switching between Claude Code sessions."
                        : "Try a different search term.",
                    actionTitle: appModel.snapshot.accounts.isEmpty && appModel.canMutate ? "Add Account" : nil,
                    action: appModel.snapshot.accounts.isEmpty && appModel.canMutate ? { showingAddSheet = true } : nil
                )
                Spacer()
            } else {
                List {
                    ForEach(filteredAccounts) { account in
                        AccountRow(
                            account: account,
                            isActive: account.id == appModel.snapshot.activeAccountId,
                            canMutate: appModel.canMutate && !appModel.isBusy,
                            onSwitch: { Task { await appModel.switchAccount(id: account.id) } },
                            onToggleDisabled: { Task { await appModel.setDisabled(id: account.id, disabled: !account.disabled) } },
                            onEditAlias: {
                                aliasDraft = account.alias ?? ""
                                editingAliasFor = account
                            },
                            onRemove: { pendingRemoval = account }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(AppColors.background)
        .sheet(isPresented: $showingAddSheet) {
            AddAccountSheet()
        }
        .sheet(item: $editingAliasFor) { account in
            AliasEditSheet(account: account, alias: $aliasDraft) { newAlias in
                Task { await appModel.setAlias(id: account.id, alias: newAlias) }
            }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.displayName ?? "this account")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let account = pendingRemoval {
                    Task { await appModel.removeAccount(id: account.id) }
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("cswap will remove this account from its managed accounts. Failures or partial results are shown in the banner at the top of the window.")
        }
    }
}

private struct AccountRow: View {
    let account: Account
    let isActive: Bool
    let canMutate: Bool
    let onSwitch: () -> Void
    let onToggleDisabled: () -> Void
    let onEditAlias: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? AppColors.status(.normal) : AppColors.textTertiary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                HStack(spacing: AppSpacing.xxs) {
                    Text(account.displayName).font(AppTypography.headline)
                    if isActive { TagBadge(text: "Active") }
                    if account.disabled { TagBadge(text: "Disabled") }
                    if account.quarantined { StatusBadge(text: "Quarantined", status: .exhausted) }
                }
                Text(account.email).font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                AccountUsageChips(account: account)
            }

            Spacer(minLength: AppSpacing.sm)

            Menu {
                Button("Switch To This Account", action: onSwitch)
                    .disabled(!canMutate || isActive || !account.switchable || account.disabled || account.quarantined)
                Button(account.disabled ? "Enable" : "Disable", action: onToggleDisabled)
                    .disabled(!canMutate)
                Button("Edit Alias…", action: onEditAlias)
                    .disabled(!canMutate)
                Divider()
                Button("Remove…", role: .destructive, action: onRemove)
                    .disabled(!canMutate)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden) // avoid system chevron next to our ellipsis
            .frame(width: 24)
            .help("Account actions")
            .accessibilityLabel("Account actions")
        }
        .padding(.vertical, AppSpacing.xxs)
        .opacity(account.disabled ? 0.6 : 1)
    }
}

private struct AliasEditSheet: View {
    let account: Account
    @Binding var alias: String
    let onSave: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Alias for \(account.email)").font(AppTypography.headline)
            TextField("Alias (optional)", text: $alias)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(alias.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(AppSpacing.lg)
        .frame(width: 360)
    }
}
