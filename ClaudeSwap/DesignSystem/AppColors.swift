//
//  AppColors.swift
//  ClaudeSwap
//
//  Original color identity for Claude Swap — intentionally distinct from
//  Anthropic's own brand palette. Claude Swap is an independent, unofficial
//  companion app; see AboutView for the full disclaimer.
//

import SwiftUI

enum AppColors {
    /// Primary brand hue: a cool violet, chosen specifically to avoid any
    /// resemblance to Anthropic's terracotta/clay identity.
    static let accent = Color(hex: 0x6C5CE7)
    static let accentSecondary = Color(hex: 0x00B8D9)

    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let surfaceElevated = Color(nsColor: .underPageBackgroundColor)

    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    static let divider = Color(nsColor: .separatorColor)

    // Semantic status colors, shared by progress bars, badges, and the
    // menu bar label. Values chosen for AA contrast in both appearances.
    static func status(_ level: UsageStatus) -> Color {
        switch level {
        case .normal: return Color(hex: 0x2ECC71)
        case .attention: return Color(hex: 0xF5A623)
        case .critical: return Color(hex: 0xE8590C)
        case .exhausted: return Color(hex: 0xE53E3E)
        }
    }

    static func statusBackground(_ level: UsageStatus) -> Color {
        status(level).opacity(0.16)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let red = Double((hex & 0xFF0000) >> 16) / 255.0
        let green = Double((hex & 0x00FF00) >> 8) / 255.0
        let blue = Double(hex & 0x0000FF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
