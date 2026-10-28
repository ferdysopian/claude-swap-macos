//
//  OnboardingView.swift
//  ClaudeSwap
//
//  First-run flow: welcome -> cswap check -> accounts detected ->
//  privacy notes -> launch-at-login offer -> done. Every step is
//  driven by real `AppModel` state (the detected accounts, in particular)
//  rather than placeholder copy.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var appModel
    @State private var step = 0
    @State private var launchAtLoginChoice = true

    private let stepCount = 5

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(step + 1), total: Double(stepCount))
                .progressViewStyle(.linear)
                .padding(.horizontal, AppSpacing.xl)
                .padding(.top, AppSpacing.lg)

            Spacer()

            Group {
                switch step {
                case 0: WelcomeStep()
                case 1: CLICheckStep()
                case 2: AccountsDetectedStep()
                case 3: PrivacyStep()
                default: LaunchAtLoginStep(choice: $launchAtLoginChoice)
                }
            }
            .frame(maxWidth: 480)
            .transition(.opacity)

            Spacer()

            HStack {
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }
                }
                Spacer()
                Button(step == stepCount - 1 ? "Get Started" : "Continue") {
                    if step == stepCount - 1 {
                        finish()
                    } else {
                        withAnimation { step += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(AppSpacing.xl)
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(AppColors.background)
    }

    private func finish() {
        if launchAtLoginChoice {
            try? LaunchAtLoginService.shared.setEnabled(true)
            appModel.launchAtLoginEnabled = LaunchAtLoginService.shared.isEnabled
        }
        appModel.hasCompletedOnboarding = true
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 56))
                .foregroundStyle(AppColors.accent)
            Text("Welcome to Claude Swap")
                .font(AppTypography.largeTitle)
            Text("Claude Swap is an independent, unofficial companion app that helps you manage multiple Claude Code accounts and rotate between them before you hit a usage limit.")
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
            Text("A native macOS companion for claude-swap by realiti4. Account management is done by the separately installed cswap CLI.")
                .font(AppTypography.subheadline)
                .foregroundStyle(AppColors.textSecondary)
            Text("Not affiliated with or endorsed by Anthropic.")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textTertiary)
        }
        .multilineTextAlignment(.center)
    }
}

private struct CLICheckStep: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            switch appModel.connectionState {
            case .connecting:
                ProgressView()
                Text("Looking for cswap…").font(AppTypography.title)
            case .connected:
                icon("checkmark.seal", AppColors.status(.normal))
                Text("cswap found").font(AppTypography.title)
                if let path = appModel.backendStatus?.executablePath {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let version = appModel.backendStatus?.version {
                    Text("Version \(version)")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                }
            case .fixtureMode:
                icon("theatermasks", AppColors.status(.attention))
                Text("Demo data").font(AppTypography.title)
                Text("Claude Swap is showing demo data, not your accounts.")
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textSecondary)
            case .cliNotFound(let path):
                icon("exclamationmark.triangle", AppColors.status(.attention))
                Text(path.map { "No executable cswap at \($0)" } ?? "cswap isn't installed")
                    .font(AppTypography.title)
                    .multilineTextAlignment(.center)
                Text("Install it yourself with one of these commands. Claude Swap won't install anything for you.")
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textSecondary)
                CopyableCommand(command: "uv tool install claude-swap")
                CopyableCommand(command: "pipx install claude-swap")
            case .incompatible(let reason):
                icon("exclamationmark.triangle", AppColors.status(.attention))
                Text("This cswap can't be used").font(AppTypography.title)
                Text(reason)
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textSecondary)
                    .textSelection(.enabled)
            case .disconnected(let reason):
                icon("exclamationmark.triangle", AppColors.status(.critical))
                Text("Couldn't run cswap").font(AppTypography.title)
                Text(Redactor.sanitize(reason ?? "cswap didn't respond."))
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textSecondary)
                    .textSelection(.enabled)
            }

            if needsRecheck {
                Button("Re-check") { appModel.reconnect() }
                    .disabled(appModel.isBusy)
                Text("Installed somewhere unusual? Choose it in Settings › Advanced › Command-Line Tool. You can also continue now and set this up later.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .multilineTextAlignment(.center)
    }

    private var needsRecheck: Bool {
        switch appModel.connectionState {
        case .cliNotFound, .incompatible, .disconnected: return true
        default: return false
        }
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 44)).foregroundStyle(color)
    }
}

private struct AccountsDetectedStep: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.system(size: 44))
                .foregroundStyle(AppColors.accent)
            Text("Accounts")
                .font(AppTypography.title)
            if appModel.snapshot.accounts.isEmpty {
                Text("No accounts detected yet. You can add one from the Accounts tab any time — nothing is modified until you do.")
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Found \(appModel.snapshot.accounts.count) account\(appModel.snapshot.accounts.count == 1 ? "" : "s") managed by cswap:")
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textSecondary)
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    ForEach(appModel.snapshot.accounts) { account in
                        Label(account.displayName, systemImage: "person.crop.circle")
                            .font(AppTypography.subheadline)
                    }
                }
            }
        }
        .task { if appModel.canMutate { await appModel.refreshSnapshot() } }
    }
}

private struct PrivacyStep: View {
    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(AppColors.accentSecondary)
            Text("Privacy")
                .font(AppTypography.title)
            Text("Claude Swap itself sends no telemetry. The cswap tool it runs stores and switches your account credentials, and contacts Anthropic services to read usage. Claude Swap never asks for or stores your tokens in its own preferences or logs.")
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }
}

private struct LaunchAtLoginStep: View {
    @Binding var choice: Bool

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "power")
                .font(.system(size: 44))
                .foregroundStyle(AppColors.accent)
            Text("Launch at login?")
                .font(AppTypography.title)
            Text("Claude Swap lives in the menu bar and can watch your usage in the background. You can change this any time in Settings.")
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
            Toggle("Launch Claude Swap at login", isOn: $choice)
                .toggleStyle(.switch)
                .padding(.top, AppSpacing.sm)
        }
    }
}
