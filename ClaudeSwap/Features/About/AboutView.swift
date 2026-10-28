//
//  AboutView.swift
//  ClaudeSwap
//
//  Independent-companion disclaimer lives here in full, plus version info
//  pulled straight from the bundle (never hardcoded so it can't drift).
//

import SwiftUI

struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    var body: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 48))
                .foregroundStyle(AppColors.accent)

            Text("Claude Swap").font(AppTypography.largeTitle)
            Text("Version \(version) (\(build))")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)

            Divider().padding(.vertical, AppSpacing.xs)

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Text("A native macOS companion for claude-swap by realiti4. Account management — switching, token refresh, credential storage and auto-switch decisions — is done by the separately installed upstream `cswap` command-line tool. This wrapper is maintained independently and is not an official claude-swap app.")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(AppColors.textSecondary)

                Text("Not affiliated with, endorsed by, or sponsored by Anthropic, PBC. \"Claude\" is a trademark of Anthropic; it is used here only to describe compatibility.")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(AppColors.textSecondary)

                Text("This app sends no telemetry and makes no network requests of its own. cswap stores your credentials and contacts Anthropic's services to refresh tokens and read usage.")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: 420)
            .multilineTextAlignment(.leading)

            HStack(spacing: AppSpacing.md) {
                Link("claude-swap by realiti4", destination: URL(string: "https://github.com/realiti4/claude-swap")!)
                Link("Wrapper source on GitHub", destination: URL(string: "https://github.com/ferdysopian/claude-swap-macos")!)
            }
            .font(AppTypography.caption)
        }
        .padding(AppSpacing.xl)
        .frame(width: 460)
    }
}
