//
//  SettingsView.swift
//  ClaudeSwap
//
//  Backs both the `Settings` scene (Cmd-,) and the in-window Settings tab.
//  Sections: General, Appearance, Menu Bar, Updates, Advanced.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsPane()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            MenuBarSettingsPane()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            UpdatesSettingsPane()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            AdvancedSettingsPane()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var appModel
    @State private var launchAtLogin = LaunchAtLoginService.shared.isEnabled
    @State private var launchAtLoginError: String?

    var body: some View {
        @Bindable var appModel = appModel
        Form {
            Toggle("Launch Claude Swap at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        try LaunchAtLoginService.shared.setEnabled(newValue)
                        launchAtLoginError = nil
                    } catch {
                        launchAtLoginError = "Approve Claude Swap in System Settings > Login Items."
                        launchAtLogin = LaunchAtLoginService.shared.isEnabled
                    }
                }
            if let launchAtLoginError {
                Text(launchAtLoginError).font(AppTypography.caption).foregroundStyle(AppColors.status(.attention))
            }

            Toggle("Show Dock icon", isOn: $appModel.showDockIcon)
            Text("Off by default. Claude Swap stays in the menu bar when you close the window; turn this on only if you want a Dock icon too.")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textTertiary)

            Divider()

            Button("Restart Onboarding") {
                appModel.hasCompletedOnboarding = false
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AppearanceSettingsPane: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        Form {
            Picker("Appearance", selection: $appModel.themeMode) {
                ForEach(AppThemeMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            Text("Claude Swap respects Reduce Motion (System Settings > Accessibility) for all progress bars and transitions.")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct MenuBarSettingsPane: View {
    @AppStorage("menuBarShowsPercentage") private var showsPercentage = true
    @AppStorage("menuBarShowsAccountName") private var showsAccountName = false
    @AppStorage("menuBarShowsResetCountdown") private var showsResetCountdown = true

    var body: some View {
        Form {
            Toggle("Show usage percentage", isOn: $showsPercentage)
            Toggle("Show reset countdown", isOn: $showsResetCountdown)
            Toggle("Show account name", isOn: $showsAccountName)
            Text("Example: 22% · 1h 41m — same style as `cswap list`. The status glyph always reflects the binding window.")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct UpdatesSettingsPane: View {
    var body: some View {
        Form {
            Text("Automatic updates aren't available in this build.")
                .font(AppTypography.body)
            Link("View releases on GitHub",
                 destination: URL(string: "https://github.com/ferdysopian/claude-swap-macos/releases")!)
            Text("Download new versions manually from the releases page. cswap itself is updated separately, for example with `uv tool upgrade claude-swap`.")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AdvancedSettingsPane: View {
    @Environment(AppModel.self) private var appModel
    @State private var pathDraft = ""
    @State private var candidates: [CLICandidate] = []
    @State private var report: DiagnosticsReport?
    @State private var copied = false

    var body: some View {
        Form {
            Section("Command-Line Tool") {
                LabeledContent("In use") {
                    Text(appModel.backendStatus?.executablePath ?? "none")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Version") {
                    Text(appModel.backendStatus?.version ?? "unknown")
                        .font(AppTypography.caption)
                }
                LabeledContent("Status") {
                    Text(statusText)
                        .font(AppTypography.caption)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    TextField("Auto-detect (leave empty)", text: $pathDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseExecutable() }
                }
                HStack {
                    Button("Use This Path") { appModel.setCLIExecutablePath(pathDraft) }
                        .disabled(appModel.isBusy)
                    Button("Use Auto-Detect") {
                        pathDraft = ""
                        appModel.setCLIExecutablePath(nil)
                    }
                    .disabled(appModel.isBusy || appModel.cswapExecutablePath == nil)
                    Spacer()
                    Button("Re-check") { appModel.reconnect() }
                        .disabled(appModel.isBusy)
                }
                if candidates.count > 1 {
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text("Found more than one cswap:").font(AppTypography.captionEmphasized)
                        ForEach(candidates) { candidate in
                            Button(candidate.path) { pathDraft = candidate.path }
                                .buttonStyle(.link)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                Text("Claude Swap uses the cswap command-line tool you installed (for example with `uv tool install claude-swap`). Point it at the `cswap` launcher, such as ~/.local/bin/cswap, not a file inside a virtual environment.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Section("Diagnostics") {
                Button("Generate Report") {
                    report = DiagnosticsService.buildReport(model: appModel)
                    copied = false
                }
                if let report {
                    Text("Review before sharing. Tokens, email addresses and your home folder are removed, and account names aren't included.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                    ScrollView {
                        Text(report.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    Button(copied ? "Copied" : "Copy Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.text, forType: .string)
                        copied = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            pathDraft = appModel.cswapExecutablePath ?? ""
            candidates = appModel.detectedCLICandidates()
        }
    }

    private var statusText: String {
        switch appModel.connectionState {
        case .connecting: return "Checking…"
        case .connected:
            if case .unverified? = appModel.backendStatus?.compatibility {
                return "Ready. This cswap version is supported but not yet verified with this app version."
            }
            return "Ready"
        case .fixtureMode: return "Demo data (no real accounts)"
        case .cliNotFound(let path):
            return path.map { "Not executable: \($0)" } ?? "cswap not found"
        case .incompatible(let reason): return reason
        case .disconnected(let reason): return reason ?? "Couldn't run cswap"
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.resolvesAliases = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        if panel.runModal() == .OK, let url = panel.url {
            pathDraft = url.path
        }
    }
}

#if canImport(AppKit)
import AppKit
#endif
