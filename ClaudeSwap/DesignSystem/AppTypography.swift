//
//  AppTypography.swift
//  ClaudeSwap
//

import SwiftUI

enum AppTypography {
    static let largeTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let title = Font.system(.title2, design: .rounded, weight: .semibold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)
    static let body = Font.system(.body, design: .default, weight: .regular)
    static let subheadline = Font.system(.subheadline, design: .default, weight: .regular)
    static let caption = Font.system(.caption, design: .default, weight: .regular)
    static let captionEmphasized = Font.system(.caption, design: .default, weight: .semibold)
    static let monospacedFigures = Font.system(.body, design: .monospaced, weight: .regular)
    static let numericLarge = Font.system(size: 28, weight: .semibold, design: .rounded)
}
