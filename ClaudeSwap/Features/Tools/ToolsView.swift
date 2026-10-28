//
//  ToolsView.swift
//  ClaudeSwap
//
//  Export/import of cswap transfer files, mapping display, and a copyable `cswap run`
//  command for users who also work from the terminal.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ToolsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var statusMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                ExportSection(statusMessage: $statusMessage)
                ImportSection(statusMessage: $statusMessage)
                MappingsSection()
                TerminalSection()

                if let statusMessage {
                    Text(statusMessage)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            .padding(AppSpacing.lg)
        }
        .background(AppColors.background)
    }
}

/// Export writes cswap's own export file straight to the chosen location.
/// The file contains credentials, so its contents are never shown in the
/// UI or put on the clipboard.
private struct ExportSection: View {
    @Environment(AppModel.self) private var appModel
    @Binding var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            CardHeader(
                title: "Export Accounts",
                subtitle: "Writes a `cswap export` file. It contains your account credentials: keep it private and delete it when you're done."
            )
            Button("Export…") { chooseDestination() }
                .disabled(appModel.isBusy || !appModel.snapshot.capabilities.supportsExportImport)
        }
        .cardStyle()
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "claude-swap-export.json"
        panel.message = "The export contains credentials. Save it somewhere private."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            switch await appModel.exportAccounts(to: url) {
            case .success, .partial:
                statusMessage = "Exported to \(url.lastPathComponent). Treat this file like a password."
            case .failed(let message):
                statusMessage = "Export failed: \(message)"
            case .slotOccupied:
                break
            }
        }
    }
}

/// Import hands a chosen `cswap export` file to `cswap import`. Existing
/// accounts are skipped unless the user explicitly ticks overwrite.
private struct ImportSection: View {
    @Environment(AppModel.self) private var appModel
    @Binding var statusMessage: String?
    @State private var selectedFile: URL?
    @State private var overwriteExisting = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            CardHeader(title: "Import Accounts", subtitle: "Reads a file made by `cswap export`.")
            HStack {
                Button("Choose File…") { chooseFile() }
                Text(selectedFile?.lastPathComponent ?? "No file selected")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Toggle("Overwrite accounts that already exist", isOn: $overwriteExisting)
            Text(overwriteExisting
                 ? "Matching accounts will be replaced with the credentials from the file (`cswap import --force`)."
                 : "Accounts that already exist are left unchanged and listed as skipped.")
                .font(AppTypography.caption)
                .foregroundStyle(overwriteExisting ? AppColors.status(.attention) : AppColors.textTertiary)
            Button("Import") { runImport() }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFile == nil || appModel.isBusy || !appModel.snapshot.capabilities.supportsExportImport)
        }
        .cardStyle()
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { selectedFile = panel.url }
    }

    private func runImport() {
        guard let selectedFile else { return }
        let overwrite = overwriteExisting
        Task {
            switch await appModel.importAccounts(from: selectedFile, overwriteExisting: overwrite) {
            case .success:
                statusMessage = "Import applied."
            case .partial(let message):
                statusMessage = message
            case .failed(let message):
                statusMessage = "Import failed: \(message)"
            case .slotOccupied:
                break
            }
            overwriteExisting = false
        }
    }
}

private struct MappingsSection: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            CardHeader(title: "Account Mappings", subtitle: "Slot number, alias, and email at a glance.")
            if appModel.snapshot.accounts.isEmpty {
                Text("No accounts to map yet.").font(AppTypography.subheadline).foregroundStyle(AppColors.textSecondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: AppSpacing.md, verticalSpacing: AppSpacing.xs) {
                    GridRow {
                        Text("Slot").font(AppTypography.captionEmphasized)
                        Text("Alias").font(AppTypography.captionEmphasized)
                        Text("Email").font(AppTypography.captionEmphasized)
                    }
                    ForEach(appModel.snapshot.accounts) { account in
                        GridRow {
                            Text(account.id)
                            Text(account.alias ?? "—")
                            Text(account.email)
                        }
                        .font(AppTypography.subheadline)
                    }
                }
            }
        }
        .cardStyle()
    }
}

private struct TerminalSection: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            CardHeader(title: "Run from Terminal")
            HStack {
                Text(appModel.cswapRunCommand)
                    .font(.system(.body, design: .monospaced))
                    .padding(AppSpacing.xs)
                    .background(RoundedRectangle(cornerRadius: 6).fill(AppColors.surfaceElevated))
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appModel.cswapRunCommand, forType: .string)
                }
            }
        }
        .cardStyle()
    }
}
