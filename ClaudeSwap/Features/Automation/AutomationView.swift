//
//  AutomationView.swift
//  ClaudeSwap
//
//  Controls for the auto-switch engine: enable/disable (backed by a
//  per-user LaunchAgent running `cswap auto`), strategy, threshold,
//  cooldown, and whether API-key accounts participate. Settings are
//  cswap's own `autoswitch.*` settings.
//

import SwiftUI

struct AutomationView: View {
    @Environment(AppModel.self) private var appModel

    @State private var threshold: Double = 85
    @State private var strategy: AutoSwitchStrategy = .best
    @State private var cooldownMinutes: Double = 5
    @State private var includeAPIKeyAccounts = false
    @State private var hasLoadedInitialValues = false
    @State private var confirmingEnable = false
    @State private var actionMessage: String?
    @State private var actionFailed = false

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { appModel.snapshot.autoSwitch.enabled },
            set: { newValue in
                if newValue && appModel.automationStatus?.upstreamMenuBarAgentInstalled == true {
                    confirmingEnable = true
                } else {
                    apply(enabled: newValue)
                }
            }
        )
    }

    private func apply(enabled: Bool) {
        Task {
            let result = await appModel.setAutoSwitchEnabled(enabled)
            switch result {
            case .success:
                actionMessage = nil
            case .partial(let message):
                actionMessage = message
                actionFailed = false
            case .failed(let message):
                actionMessage = message
                actionFailed = true
            case .slotOccupied:
                actionMessage = "Couldn't change auto-switch."
                actionFailed = true
            }
        }
    }

    private var statusText: String {
        guard let status = appModel.automationStatus else { return "Not available without cswap" }
        switch status.health {
        case .disabled: return "Off"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .failing(let code): return "Failing (last exit \(code)). See logs in ~/Library/Logs/ClaudeSwap."
        case .launcherMissing: return "The cswap launcher is missing. Fix the command-line tool path, then re-enable auto-switch."
        case .orphanedRegistration: return "Registered without a plist. Turn auto-switch off, then on again."
        case .notLoaded: return "Installed but not loaded. Turn auto-switch off, then on again."
        }
    }

    private var statusIsProblem: Bool {
        switch appModel.automationStatus?.health {
        case .failing, .launcherMissing, .orphanedRegistration, .notLoaded: return true
        default: return false
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Auto-Switch", isOn: enabledBinding)
                    .toggleStyle(.switch)
                    .disabled(!appModel.canMutate || appModel.isBusy)
                LabeledContent("Service") {
                    Text(statusText)
                        .font(AppTypography.caption)
                        .foregroundStyle(statusIsProblem ? AppColors.status(.attention) : AppColors.textSecondary)
                        .multilineTextAlignment(.trailing)
                }
                if let actionMessage {
                    Text(actionMessage)
                        .font(AppTypography.caption)
                        .foregroundStyle(actionFailed ? AppColors.status(.critical) : AppColors.status(.attention))
                        .textSelection(.enabled)
                }
                if !appModel.canMutate {
                    Text("Automation is unavailable until cswap is connected. See the Dashboard.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
            } footer: {
                Text("When enabled, a background service runs `cswap auto`, watches every account's usage and switches before you hit a limit. The options below are cswap's own autoswitch settings; the service restarts when they change. Turning auto-switch off removes the LaunchAgent, so it stays off after you log in again.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Group {
            Section("Strategy") {
                Picker("Strategy", selection: $strategy) {
                    ForEach(AutoSwitchStrategy.allCases) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: strategy) { _, newValue in
                    Task { await appModel.updateAutoSwitchSettings(AutoSwitchSettingsUpdate(strategy: newValue)) }
                }
            }

            Section("Threshold") {
                VStack(alignment: .leading) {
                    Slider(value: $threshold, in: 50...100, step: 1) {
                        Text("Threshold")
                    } minimumValueLabel: {
                        Text("50%")
                    } maximumValueLabel: {
                        Text("100%")
                    }
                    .onChange(of: threshold) { _, newValue in
                        Task { await appModel.updateAutoSwitchSettings(AutoSwitchSettingsUpdate(thresholdPct: newValue)) }
                    }
                    Text("Switch when the active account's binding window reaches \(Int(threshold))%.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }

            Section("Cooldown") {
                VStack(alignment: .leading) {
                    Slider(value: $cooldownMinutes, in: 1...30, step: 1) {
                        Text("Cooldown")
                    } minimumValueLabel: {
                        Text("1m")
                    } maximumValueLabel: {
                        Text("30m")
                    }
                    .onChange(of: cooldownMinutes) { _, newValue in
                        Task { await appModel.updateAutoSwitchSettings(AutoSwitchSettingsUpdate(cooldownSeconds: Int(newValue * 60))) }
                    }
                    Text("Wait at least \(Int(cooldownMinutes)) minute\(Int(cooldownMinutes) == 1 ? "" : "s") between proactive switches.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }

            Section("Accounts") {
                Toggle("Include API-key accounts in rotation", isOn: $includeAPIKeyAccounts)
                    .disabled(!appModel.snapshot.capabilities.supportsAPIKeyAccounts)
                    .onChange(of: includeAPIKeyAccounts) { _, newValue in
                        Task { await appModel.updateAutoSwitchSettings(AutoSwitchSettingsUpdate(includeAPIKeyAccounts: newValue)) }
                    }
            }

            }
            .disabled(!appModel.canMutate)

            if let description = appModel.snapshot.autoSwitch.lastEventDescription {
                Section("Last Event") {
                    Text(description).font(AppTypography.subheadline)
                }
            }
        }
        .formStyle(.grouped)
                .alert("Upstream menu bar agent is installed", isPresented: $confirmingEnable) {
            Button("Enable Anyway") { apply(enabled: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("cswap's own menu bar agent is installed and may also run auto-switch. Running both can cause duplicate switches, and Claude Swap won't stop it. Enable anyway?")
        }
        .task {
            await appModel.refreshAutomationStatus()
        }
        .task {
            guard !hasLoadedInitialValues else { return }
            hasLoadedInitialValues = true
            let state = appModel.snapshot.autoSwitch
            threshold = state.thresholdPct
            strategy = state.strategy
            cooldownMinutes = Double(state.cooldownSeconds) / 60
            includeAPIKeyAccounts = state.includeAPIKeyAccounts
        }
    }
}
