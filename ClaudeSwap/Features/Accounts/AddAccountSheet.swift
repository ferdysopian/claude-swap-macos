//
//  AddAccountSheet.swift
//  ClaudeSwap
//
//  Two ways to add an account, matching the core CLI:
//  1. `cswap add` — capture whatever Claude Code is currently logged in as
//  2. `cswap add-token` — paste a setup-token / API key (SecureField only)
//

import SwiftUI

struct AddAccountSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case currentLogin = "Current Claude login"
        case pasteToken = "Paste token"

        var id: String { rawValue }
    }

    @State private var mode: Mode = .currentLogin
    @State private var token = ""
    @State private var alias = ""
    @State private var slotText = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var currentLogin: CurrentClaudeLogin?
    @State private var isLoadingLogin = false
    /// Set when the CLI reported the chosen slot is taken; the user must
    /// confirm before anything is overwritten.
    @State private var occupiedSlot: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Add Account").font(AppTypography.title)

            Picker("Method", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .currentLogin:
                currentLoginSection
            case .pasteToken:
                pasteTokenSection
            }

            sharedOptions

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.status(.critical))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    submit()
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(mode == .currentLogin ? "Add Current Login" : "Add Token")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit || isSubmitting)
            }
        }
        .padding(AppSpacing.lg)
        .frame(width: 460)
        .confirmationDialog(
            "Replace the account in slot \(occupiedSlot.map(String.init) ?? "")?",
            isPresented: Binding(get: { occupiedSlot != nil }, set: { if !$0 { occupiedSlot = nil } }),
            titleVisibility: .visible
        ) {
            Button("Replace Account", role: .destructive) {
                occupiedSlot = nil
                submit(overwrite: true)
            }
            Button("Cancel", role: .cancel) { occupiedSlot = nil }
        } message: {
            Text("That slot already holds an account. Replacing it removes the stored credentials for the old account from cswap. Leave the slot blank to add a new slot instead.")
        }
        .task(id: mode) {
            guard mode == .currentLogin else { return }
            await refreshCurrentLogin()
        }
    }

    private var currentLoginSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Uses the account Claude Code is logged into right now — same as `cswap add`.")
                .font(AppTypography.subheadline)
                .foregroundStyle(AppColors.textSecondary)

            Group {
                if isLoadingLogin {
                    HStack(spacing: AppSpacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Detecting current Claude login…")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                } else if let currentLogin {
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text(currentLogin.email).font(AppTypography.headline)
                        if let org = currentLogin.organizationName, !org.isEmpty {
                            TagBadge(text: org)
                        }
                        if currentLogin.managed {
                            Text("Already managed as account \(currentLogin.accountNumber.map(String.init) ?? "?") — adding again refreshes its stored credentials.")
                                .font(AppTypography.caption)
                                .foregroundStyle(AppColors.textTertiary)
                        } else {
                            Text("Not managed yet — will be added as a new account.")
                                .font(AppTypography.caption)
                                .foregroundStyle(AppColors.textTertiary)
                        }
                    }
                    .padding(AppSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusMedium)
                            .fill(AppColors.surfaceElevated)
                    )
                } else {
                    Label("No Claude Code login detected. Sign in with Claude Code first, then try again.", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.status(.attention))
                }
            }

            Button("Refresh") {
                Task { await refreshCurrentLogin() }
            }
            .buttonStyle(.link)
            .disabled(isLoadingLogin)
        }
    }

    private var pasteTokenSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text("Paste a setup-token or API key — same as `cswap add-token`. It's passed to cswap on standard input, never on the command line, and this app doesn't store it; cswap saves it with the account.")
                .font(AppTypography.subheadline)
                .foregroundStyle(AppColors.textSecondary)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("Token").font(AppTypography.captionEmphasized)
                SecureField("Paste token", text: $token)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var sharedOptions: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("Alias (optional)").font(AppTypography.captionEmphasized)
                TextField("e.g. Personal, Work", text: $alias)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text("Slot (optional)").font(AppTypography.captionEmphasized)
                TextField("Leave blank to append", text: $slotText)
                    .textFieldStyle(.roundedBorder)
                Text("Same as `cswap add --slot N` / `add-token --slot N`.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    private var canSubmit: Bool {
        switch mode {
        case .currentLogin:
            return currentLogin != nil && slotIsValid
        case .pasteToken:
            return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && slotIsValid
        }
    }

    private var slotIsValid: Bool {
        let trimmed = slotText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || (Int(trimmed).map { $0 > 0 } ?? false)
    }

    private var parsedSlot: Int? {
        let trimmed = slotText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed)
    }

    private func refreshCurrentLogin() async {
        isLoadingLogin = true
        defer { isLoadingLogin = false }
        currentLogin = await appModel.peekCurrentClaudeLogin()
    }

    private func submit(overwrite: Bool = false) {
        isSubmitting = true
        errorMessage = nil
        let submittedAlias = alias.trimmingCharacters(in: .whitespaces)
        let aliasValue = submittedAlias.isEmpty ? nil : submittedAlias
        let slot = parsedSlot

        Task {
            let result: MutationResult
            switch mode {
            case .currentLogin:
                result = await appModel.addCurrentAccount(alias: aliasValue, slot: slot, overwrite: overwrite)
            case .pasteToken:
                result = await appModel.addAccount(token: token, alias: aliasValue, slot: slot, overwrite: overwrite)
            }
            isSubmitting = false
            switch result {
            case .success:
                token = ""
                dismiss()
            case .partial(let message):
                // The account exists; close and let the banner explain.
                token = ""
                appModel.errorBanner = message
                dismiss()
            case .slotOccupied(let slot):
                occupiedSlot = slot
            case .failed(let message):
                errorMessage = message
            }
        }
    }
}
