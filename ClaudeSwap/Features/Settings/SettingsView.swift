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
    @State private var isChecking = false
    @State private var result: UpdateCheckResult?
    private let updateService: any UpdateServiceProtocol = UpdateService()

    var body: some View {
        Form {
            Button {
                Task {
                    isChecking = true
                    result = await updateService.checkForUpdates()
                    isChecking = false
                }
            } label: {
                if isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Check for Updates…")
                }
            }
            .disabled(isChecking)

            if let result {
                Text(message(for: result))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func message(for result: UpdateCheckResult) -> String {
        switch result {
        case .upToDate: return "You're up to date."
        case .updateAvailable(let version): return "Version \(version) is available."
        case .checkFailed(let reason): return "Check failed: \(reason)"
        case .unsupported: return "Automatic updates aren't configured in this build. Check the GitHub releases page manually."
        }
    }
}

private struct AdvancedSettingsPane: View {
    @Environment(AppModel.self) private var appModel
    @State private var overrideDraft = ""
    @State private var report: DiagnosticsReport?

    var body: some View {
        @Bindable var appModel = appModel
        Form {
            Section {
                TextField("Local claude-swap checkout path", text: $overrideDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        appModel.coreOverridePath = overrideDraft.isEmpty ? nil : overrideDraft
                    }
                Text("Overrides where Claude Swap looks for a `claude_swap` Python checkout in development (equivalent to CLAUDE_SWAP_CORE_PATH). Restart the app after changing this.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Section {
                Button("Copy Diagnostics Report") {
                    let report = DiagnosticsService.shared.buildReport(
                        snapshot: appModel.snapshot,
                        corePath: appModel.coreOverridePath,
                        helperConnected: appModel.connectionState == .connected
                    )
                    self.report = report
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.text, forType: .string)
                }
                if let report {
                    Text(report.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { overrideDraft = appModel.coreOverridePath ?? "" }
    }
}

#if canImport(AppKit)
import AppKit
#endif
