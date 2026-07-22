//
//  OnboardingView.swift
//  ClaudeSwap
//
//  First-run flow: welcome -> Claude Code check -> accounts detected ->
//  Keychain explanation -> launch-at-login offer -> done. Every step is
//  driven by real `AppModel` state (the detected accounts, in particular)
//  rather than placeholder copy.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var appModel
    @State private var step = 0
    @State private var launchAtLoginChoice = true
    @State private var claudeCodeFound: Bool?

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
                case 1: ClaudeCodeCheckStep(found: $claudeCodeFound)
                case 2: AccountsDetectedStep()
                case 3: KeychainExplainStep()
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
            Text("Not affiliated with or endorsed by Anthropic.")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textTertiary)
        }
        .multilineTextAlignment(.center)
    }
}

private struct ClaudeCodeCheckStep: View {
    @Binding var found: Bool?

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: found == false ? "exclamationmark.triangle" : "checkmark.seal")
                .font(.system(size: 44))
                .foregroundStyle(found == false ? AppColors.status(.attention) : AppColors.status(.normal))
            Text("Checking for Claude Code")
                .font(AppTypography.title)
            Text(found == false
                 ? "We couldn't confirm a Claude Code installation. You can still continue — Claude Swap will just show preview data until it detects one."
                 : "Claude Swap works alongside your existing Claude Code CLI installation and manages the credentials it already uses.")
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .task {
            found = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude")
        }
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
                Text("Found \(appModel.snapshot.accounts.count) account\(appModel.snapshot.accounts.count == 1 ? "" : "s") already known to Claude Swap:")
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
        .task { await appModel.refreshSnapshot() }
    }
}

private struct KeychainExplainStep: View {
    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(AppColors.accentSecondary)
            Text("Your credentials stay in the Keychain")
                .font(AppTypography.title)
            Text("Claude Swap never stores tokens in preferences, logs, or on disk in plain text. Every credential is read from and written to the macOS Keychain, the same place Claude Code itself keeps them.")
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
