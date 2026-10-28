//
//  LegacyPreferencesMigration.swift
//  ClaudeSwap
//
//  Earlier builds used a different bundle identifier, so their settings
//  live in another preferences file (`<old id>.ClaudeSwap.plist`). On first
//  launch under the current identifier, copy the app's own keys across once.
//  Only keys this app defines are copied, and existing values win.
//

import Foundation

enum LegacyPreferencesMigration {
    static let doneKey = "legacyPreferencesMigrated"

    static let keys = [
        "hasCompletedOnboarding",
        "themeMode",
        "showDockIcon",
        CLIDiscovery.executablePathDefaultsKey,
        "menuBarShowsPercentage",
        "menuBarShowsAccountName",
        "menuBarShowsResetCountdown",
    ]

    /// Returns the number of keys copied.
    @discardableResult
    static func migrate(
        into defaults: UserDefaults = .standard,
        currentBundleID: String? = Bundle.main.bundleIdentifier,
        preferencesDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true),
        fileManager: FileManager = .default
    ) -> Int {
        guard !defaults.bool(forKey: doneKey), let currentBundleID else { return 0 }
        defaults.set(true, forKey: doneKey)

        let currentFile = "\(currentBundleID).plist"
        let candidates = ((try? fileManager.contentsOfDirectory(
            at: preferencesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".ClaudeSwap.plist") && $0.lastPathComponent != currentFile }
        // Most recently used legacy file first.
        let newest = candidates.max { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
        guard let newest,
              let data = try? Data(contentsOf: newest),
              let legacy = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return 0
        }

        var copied = 0
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy[key] {
                defaults.set(value, forKey: key)
                copied += 1
            }
        }
        return copied
    }
}
