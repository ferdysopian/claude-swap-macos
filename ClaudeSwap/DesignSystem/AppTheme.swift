//
//  AppTheme.swift
//  ClaudeSwap
//
//  App-wide theme preference (Light/Dark/System) plus a `reduceMotion`
//  aware animation helper used throughout the Features layer.
//

import SwiftUI

enum AppThemeMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Central place for motion-safe animation. Every view that animates
/// state (progress bars, switch confirmations) should pull its animation
/// from here instead of hardcoding `.spring()` etc., so Reduce Motion is
/// respected app-wide.
struct AppMotion {
    var reduceMotionEnabled: Bool

    func animation(_ base: Animation = .easeInOut(duration: 0.25)) -> Animation? {
        reduceMotionEnabled ? nil : base
    }

    static func environment(_ environment: EnvironmentValues) -> AppMotion {
        AppMotion(reduceMotionEnabled: environment.accessibilityReduceMotion)
    }
}

private struct AppMotionKey: EnvironmentKey {
    static let defaultValue = AppMotion(reduceMotionEnabled: false)
}

extension EnvironmentValues {
    var appMotion: AppMotion {
        get { self[AppMotionKey.self] }
        set { self[AppMotionKey.self] = newValue }
    }
}

/// Applies the resolved app theme + motion environment to a view tree.
/// Attach once at the root (`ClaudeSwapApp`) window/scene.
struct AppThemeModifier: ViewModifier {
    let mode: AppThemeMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(mode.colorScheme)
            .environment(\.appMotion, AppMotion(reduceMotionEnabled: reduceMotion))
            .tint(AppColors.accent)
    }
}

extension View {
    func appTheme(_ mode: AppThemeMode) -> some View {
        modifier(AppThemeModifier(mode: mode))
    }
}
