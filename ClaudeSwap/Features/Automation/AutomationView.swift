//
//  AutomationView.swift
//  ClaudeSwap
//
//  Controls for the auto-switch engine: enable/disable, strategy,
//  threshold, cooldown, and whether API-key accounts participate.
//

import SwiftUI

struct AutomationView: View {
    @Environment(AppModel.self) private var appModel

    @State private var threshold: Double = 85
    @State private var strategy: AutoSwitchStrategy = .best
    @State private var cooldownMinutes: Double = 5
    @State private var includeAPIKeyAccounts = false
    @State private var hasLoadedInitialValues = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable Auto-Switch", isOn: Binding(
                    get: { appModel.snapshot.autoSwitch.enabled },
                    set: { newValue in Task { await appModel.setAutoSwitchEnabled(newValue) } }
                ))
                .toggleStyle(.switch)
            } footer: {
                Text("When enabled, Claude Swap watches every account's usage and switches proactively before you hit a rate limit.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }

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

            if let description = appModel.snapshot.autoSwitch.lastEventDescription {
                Section("Last Event") {
                    Text(description).font(AppTypography.subheadline)
                }
            }
        }
        .formStyle(.grouped)
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
