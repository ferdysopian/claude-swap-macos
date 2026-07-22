//
//  ToolsView.swift
//  ClaudeSwap
//
//  Export/import panels, mapping display, and a copyable `cswap run`
//  command for users who also work from the terminal.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ToolsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var exportedText: String?
    @State private var importText = ""
    @State private var statusMessage: String?
    @State private var showingImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                ExportSection(exportedText: $exportedText, statusMessage: $statusMessage)
                ImportSection(importText: $importText, statusMessage: $statusMessage, showingImporter: $showingImporter)
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
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                    importText = text
                }
            case .failure(let error):
                statusMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}

private struct ExportSection: View {
    @Environment(AppModel.self) private var appModel
    @Binding var exportedText: String?
    @Binding var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            CardHeader(title: "Export Configuration", subtitle: "Account list, aliases, and disabled state — no tokens.")
            HStack {
                Button("Export…") {
                    Task {
                        exportedText = await appModel.exportConfig()
                        statusMessage = exportedText != nil ? "Exported \(appModel.snapshot.accounts.count) account(s)." : "Export failed."
                    }
                }
                .disabled(!appModel.snapshot.capabilities.supportsExportImport)

                if let exportedText {
                    Button("Copy to Clipboard") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(exportedText, forType: .string)
                        statusMessage = "Copied export to clipboard."
                    }
                    Button("Save As…") { save(exportedText) }
                }
            }
            if let exportedText {
                TextEditor(text: .constant(exportedText))
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 140)
                    .border(AppColors.divider)
            }
        }
        .cardStyle()
    }

    private func save(_ text: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "claude-swap-export.json"
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Saved to \(url.lastPathComponent)."
        }
    }
}

private struct ImportSection: View {
    @Environment(AppModel.self) private var appModel
    @Binding var importText: String
    @Binding var statusMessage: String?
    @Binding var showingImporter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            CardHeader(title: "Import Configuration")
            TextEditor(text: $importText)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 100)
                .border(AppColors.divider)
            HStack {
                Button("Choose File…") { showingImporter = true }
                Button("Import") {
                    Task {
                        let success = await appModel.importConfig(importText)
                        statusMessage = success ? "Import applied." : "Import failed — check the file format."
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !appModel.snapshot.capabilities.supportsExportImport)
            }
        }
        .cardStyle()
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
