//
//  StatusBadge.swift
//  ClaudeSwap
//

import SwiftUI

struct StatusBadge: View {
    let text: String
    let status: UsageStatus

    var body: some View {
        Text(text)
            .font(AppTypography.captionEmphasized)
            .padding(.horizontal, AppSpacing.xs)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(AppColors.statusBackground(status))
            )
            .foregroundStyle(AppColors.status(status))
            .accessibilityLabel(Text("\(text), status \(status.rawValue)"))
    }
}

/// Small neutral pill for non-semantic tags (org name, kind, etc.).
struct TagBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTypography.caption)
            .padding(.horizontal, AppSpacing.xs)
            .padding(.vertical, 2)
            .background(Capsule().fill(AppColors.divider.opacity(0.3)))
            .foregroundStyle(AppColors.textSecondary)
    }
}

/// Connectivity indicator used in the sidebar footer and menu bar.
/// Connecting shows a spinner (not a stuck orange dot); connected shows a
/// green check so it reads as a status, not a broken button.
struct ConnectionIndicator: View {
    enum State {
        case connected
        case connecting
        case fixture
        case disconnected
    }

    let state: State

    var body: some View {
        HStack(spacing: AppSpacing.xxs) {
            statusGlyph
            Text(label)
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch state {
        case .connecting:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.status(.normal))
        case .fixture:
            Image(systemName: "eye.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.accentSecondary)
        case .disconnected:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.status(.exhausted))
        }
    }

    private var label: String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .fixture: return "Preview Data"
        case .disconnected: return "Disconnected"
        }
    }
}
