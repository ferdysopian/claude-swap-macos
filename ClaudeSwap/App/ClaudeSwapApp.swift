//
//  ClaudeSwapApp.swift
//  ClaudeSwap
//
//  Entry point: one shared `AppModel` feeds a main `WindowGroup`, a
//  `MenuBarExtra` popover, and a `Settings` scene. Claude Swap is an
//  independent, unofficial companion app for Claude Code — see AboutView
//  for the full disclaimer.
//

import SwiftUI
import AppKit

@main
struct ClaudeSwapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(appModel)
                .appTheme(appModel.themeMode)
                .frame(minWidth: 860, minHeight: 560)
                .task {
                    appDelegate.appModel = appModel
                    // Apply before the first frame so we never flash a Dock tile
                    // when running as a menu-bar app.
                    appDelegate.applyActivationPolicy()
                    appModel.start()
                    await NotificationService.shared.requestAuthorizationIfNeeded()
                }
                .onChange(of: appModel.showDockIcon) {
                    appDelegate.applyActivationPolicy()
                }
                .onAppear {
                    appDelegate.appModel = appModel
                    appDelegate.applyActivationPolicy()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            AppCommands(appModel: appModel)
            CommandGroup(replacing: .appInfo) {
                Button("About Claude Swap") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "about")
                }
            }
        }

        Window("About Claude Swap", id: "about") {
            AboutView()
                .appTheme(appModel.themeMode)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarView()
                .environment(appModel)
                .appTheme(appModel.themeMode)
        } label: {
            MenuBarLabel(appModel: appModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appModel)
                .appTheme(appModel.themeMode)
                .frame(width: 520, height: 420)
        }
    }
}

/// Root content: onboarding until it's completed, the main tabbed UI after.
private struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if appModel.hasCompletedOnboarding {
            MainWindowView()
        } else {
            OnboardingView()
        }
    }
}
