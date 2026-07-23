//
//  ProgressComponents.swift
//  ClaudeSwap
//

import SwiftUI

/// A labeled usage bar for a single rolling window (5h/7d/etc.), colored
/// by semantic status and respecting Reduce Motion for its fill animation.
struct UsageWindowBar: View {
    let window: UsageWindow
    var showsResetTime: Bool = true

    @Environment(AppModel.self) private var appModel
    @Environment(\.appMotion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            HStack {
                Text(window.label)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Text(percentLabel)
                    .font(AppTypography.captionEmphasized)
                    .foregroundStyle(AppColors.status(window.status))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(AppColors.divider.opacity(0.4))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(AppColors.status(window.status))
                        .frame(width: proxy.size.width * fraction)
                        .animation(motion.animation(), value: fraction)
                }
            }
            .frame(height: 8)
            if showsResetTime, let resetsAt = window.resetsAt {
                let countdown = UsageCountdown.compact(until: resetsAt, now: appModel.displayNow) ?? ""
                Text(countdown.isEmpty ? "Resets \(resetsAt.formatted(.relative(presentation: .named)))" : "Resets in \(countdown)")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.label) usage")
        .accessibilityValue(percentLabel)
    }

    private var fraction: Double {
        min(max(window.utilizationPct / 100.0, 0), 1)
    }

    private var percentLabel: String {
        String(format: "%.0f%%", window.utilizationPct)
    }
}

/// Compact ring used in the menu bar popover / dashboard hero to show the
/// binding (highest-utilization) window at a glance.
struct UsageRing: View {
    let percent: Double
    let status: UsageStatus
    var lineWidth: CGFloat = 6
    var diameter: CGFloat = 56

    @Environment(\.appMotion) private var motion

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppColors.divider.opacity(0.4), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(percent / 100.0, 0), 1))
                .stroke(AppColors.status(status), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(motion.animation(), value: percent)
            Text(String(format: "%.0f%%", percent))
                .font(.system(size: diameter * 0.26, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColors.textPrimary)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage")
        .accessibilityValue(String(format: "%.0f percent", percent))
    }
}

/// Compact one-line summary of every usage window (matches `cswap list`
/// density): `5h 22% · 7d 3% · Fable 0%`, with reset countdown when known.
struct AccountUsageChips: View {
    let account: Account

    @Environment(AppModel.self) private var appModel

    var body: some View {
        chips(now: appModel.displayNow)
    }

    @ViewBuilder
    private func chips(now: Date) -> some View {
        if account.usage.unknown || account.usage.windows.isEmpty {
            Text(account.usage.lastError ?? "usage unavailable")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textTertiary)
                .lineLimit(1)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppSpacing.xs) {
                    ForEach(account.usage.windows) { window in
                        HStack(spacing: 2) {
                            Text(shortLabel(for: window))
                                .foregroundStyle(AppColors.textTertiary)
                            Text(String(format: "%.0f%%", window.utilizationPct))
                                .foregroundStyle(AppColors.status(window.status))
                                .fontWeight(.semibold)
                            if !account.usage.isStale,
                               let countdown = UsageCountdown.compact(until: window.resetsAt, now: now) {
                                Text(countdown)
                                    .foregroundStyle(AppColors.textTertiary)
                            }
                        }
                        .font(AppTypography.caption)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(accessibilityLabel(for: window, now: now))
                    }
                }
                if account.usage.isStale, let note = account.usage.lastError {
                    Text(note)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func shortLabel(for window: UsageWindow) -> String {
        switch window.id {
        case "5h": return "5h"
        case "7d": return "7d"
        default: return window.label
        }
    }

    private func accessibilityLabel(for window: UsageWindow, now: Date) -> String {
        var label = "\(window.label) \(Int(window.utilizationPct)) percent"
        if let countdown = UsageCountdown.compact(until: window.resetsAt, now: now) {
            label += ", resets in \(countdown)"
        }
        return label
    }
}

/// Full multi-window usage block used on the dashboard for every account,
/// not only the active one.
struct AccountUsageOverview: View {
    let account: Account
    var showsResetTime: Bool = true

    var body: some View {
        if account.usage.unknown || account.usage.windows.isEmpty {
            Label(
                account.usage.lastError ?? "Usage unavailable right now.",
                systemImage: "questionmark.circle"
            )
            .font(AppTypography.subheadline)
            .foregroundStyle(AppColors.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                if account.usage.isStale, let note = account.usage.lastError {
                    Text(note)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
                ForEach(account.usage.windows) { window in
                    UsageWindowBar(window: window, showsResetTime: showsResetTime && !account.usage.isStale)
                }
            }
        }
    }
}
