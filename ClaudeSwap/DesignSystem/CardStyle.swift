//
//  CardStyle.swift
//  ClaudeSwap
//

import SwiftUI

/// Standard elevated-card container used across Dashboard/Accounts/Tools.
struct CardStyle: ViewModifier {
    var padding: CGFloat = AppSpacing.md

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusMedium, style: .continuous)
                    .fill(AppColors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppSpacing.cornerRadiusMedium, style: .continuous)
                    .strokeBorder(AppColors.divider.opacity(0.6), lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle(padding: CGFloat = AppSpacing.md) -> some View {
        modifier(CardStyle(padding: padding))
    }
}

/// A card with a leading title/subtitle row and trailing accessory,
/// commonly used to head off a dashboard section.
struct CardHeader: View {
    let title: String
    var subtitle: String?
    var accessory: (() -> AnyView)?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = nil
    }

    init<Accessory: View>(title: String, subtitle: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = { AnyView(accessory()) }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(AppTypography.headline)
                if let subtitle {
                    Text(subtitle).font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                }
            }
            Spacer()
            accessory?()
        }
    }
}
