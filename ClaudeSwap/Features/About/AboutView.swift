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
                Text("Claude Swap is an independent, unofficial companion app for managing multiple Claude Code accounts. It is not affiliated with, endorsed by, or sponsored by Anthropic, PBC. \"Claude\" is a trademark of Anthropic; it is used here only to describe compatibility.")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(AppColors.textSecondary)

                Text("Credentials are read from and written to the macOS Keychain only. Claude Swap never transmits your tokens anywhere outside your machine.")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: 420)
            .multilineTextAlignment(.leading)

            Link("View Source on GitHub", destination: URL(string: "https://github.com/ferdysopian/claude-swap-macos")!)
                .font(AppTypography.caption)
        }
        .padding(AppSpacing.xl)
        .frame(width: 460)
    }
}
