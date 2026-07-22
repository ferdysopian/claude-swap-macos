//
//  AppDelegate.swift
//  ClaudeSwap
//
//  Handles the bits SwiftUI's App protocol doesn't cover directly: dock
//  icon visibility (activation policy) and "reopen" when the user clicks
//  the menu bar icon / dock icon with no windows visible.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in NSApp.windows where window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Claude Swap lives in the menu bar; closing the main window
        // should not quit the app.
        false
    }

    /// Sets Dock visibility from `AppModel.showDockIcon` (or UserDefaults
    /// when the model isn't wired yet). Menu-bar-first: default is *hidden*.
    func applyActivationPolicy() {
        let showDockIcon: Bool
        if let appModel {
            showDockIcon = appModel.showDockIcon
        } else if UserDefaults.standard.object(forKey: "showDockIcon") != nil {
            showDockIcon = UserDefaults.standard.bool(forKey: "showDockIcon")
        } else {
            showDockIcon = false
        }
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        // Accessory apps can otherwise leave a lingering Dock tile until the
        // next activation-policy flip; hide explicitly when dockless.
        if !showDockIcon {
            NSApp.dockTile.badgeLabel = nil
        }
    }
}
