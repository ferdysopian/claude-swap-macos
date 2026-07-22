//
//  ActivityView.swift
//  ClaudeSwap
//
//  Chronological timeline of everything AppModel has recorded: switches,
//  quarantines, auto-switch status changes, connection events, and logs.
//

import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.activity.isEmpty {
                EmptyState(
                    systemImage: "clock.arrow.circlepath",
                    title: "No activity yet",
                    message: "Switches, auto-switch decisions, and connection events will show up here."
                )
            } else {
                List(appModel.activity) { entry in
                    ActivityRow(entry: entry)
                }
                .listStyle(.inset)
            }
        }
        .background(AppColors.background)
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message).font(AppTypography.subheadline)
                Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
            Spacer()
        }
        .padding(.vertical, AppSpacing.xxs)
    }

    private var icon: String {
        switch entry.kind {
        case .switched: return "arrow.triangle.2.circlepath"
        case .quarantined: return "exclamationmark.triangle.fill"
        case .unquarantined: return "checkmark.circle"
        case .autoSwitch: return "gearshape.2"
        case .connection: return "cable.connector"
        case .log: return "text.alignleft"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .switched: return AppColors.accent
        case .quarantined, .error: return AppColors.status(.critical)
        case .unquarantined: return AppColors.status(.normal)
        case .autoSwitch: return AppColors.accentSecondary
        case .connection: return AppColors.textSecondary
        case .log: return AppColors.textTertiary
        }
    }
}
