//
//  AppCommands.swift
//  ClaudeSwap
//
//  Menu bar keyboard shortcuts: Cmd-1..4 jump between the main tabs,
//  Cmd-R refreshes the snapshot, and Cmd-Shift-R rotates to the best
//  available account — the same action as the Dashboard's "Rotate" button.
//

import SwiftUI

struct AppCommands: Commands {
    let appModel: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) { }

        CommandMenu("Account") {
            ForEach(AppTab.allCases.filter { $0.commandShortcutDigit != nil }) { tab in
                Button(tab.title) { appModel.selectedTab = tab }
                    .keyboardShortcut(KeyEquivalent(tab.commandShortcutDigit!), modifiers: .command)
            }

            Divider()

            Button("Refresh Snapshot") {
                Task { await appModel.refreshSnapshot() }
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Rotate to Best Account") {
                Task { await appModel.rotateToBestAccount() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(appModel.isBusy)
        }
    }
}
