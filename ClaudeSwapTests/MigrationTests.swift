//
//  MigrationTests.swift
//  ClaudeSwapTests
//
//  Moving users of earlier builds (different bundle identifier and
//  LaunchAgent label) onto the current ones. Temp dirs and a fake
//  launchctl only.
//

import Foundation
import Testing
@testable import ClaudeSwap

@Suite struct MigrationTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePlist(_ object: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        try data.write(to: url)
    }

    private func makeService(root: URL, fake: FakeLaunchctl) throws -> (AutoSwitchDaemonService, URL, String) {
        let agents = root.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let cswap = root.appendingPathComponent("cswap")
        try "#!/bin/sh\nexit 0\n".write(to: cswap, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cswap.path)
        let env = AutoSwitchServiceEnvironment(
            launchAgentsDirectory: agents,
            logDirectory: root.appendingPathComponent("Logs", isDirectory: true),
            userID: 501,
            launchctl: fake,
            sleep: { _ in }
        )
        return (AutoSwitchDaemonService(environment: env), agents, cswap.path)
    }

    // MARK: LaunchAgent

    @Test func legacyAgentIsReplacedByCurrentLabel() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeLaunchctl()
        let (service, agents, cswap) = try makeService(root: root, fake: fake)
        let legacy = agents.appendingPathComponent("com.example.claudeswap.autoswitch.plist")
        try writePlist([
            "Label": "com.example.claudeswap.autoswitch",
            "ProgramArguments": [cswap, "auto", "--json", "--threshold", "90.0"],
        ], to: legacy)
        fake.registered = true

        #expect(try service.migrateLegacyAgents(cswapPath: cswap))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: service.plistURL.path))
        #expect(fake.calls.contains(["bootout", "gui/501/com.example.claudeswap.autoswitch"]))
        let data = try Data(contentsOf: service.plistURL)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["ProgramArguments"] as? [String] == [cswap, "auto", "--json"])
    }

    @Test func noLegacyAgentMeansNothingChanges() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeLaunchctl()
        let (service, _, cswap) = try makeService(root: root, fake: fake)

        #expect(try !service.migrateLegacyAgents(cswapPath: cswap))
        #expect(fake.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: service.plistURL.path))
    }

    @Test func unrelatedAgentsAreLeftAlone() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeLaunchctl()
        let (service, agents, cswap) = try makeService(root: root, fake: fake)
        // Matching file name but not a `cswap auto` job, plus an unrelated agent.
        let lookalike = agents.appendingPathComponent("com.example.claudeswap.autoswitch.plist")
        try writePlist(["Label": "com.example.claudeswap.autoswitch", "ProgramArguments": ["/bin/echo", "hi"]], to: lookalike)
        let other = agents.appendingPathComponent("com.cswap.menubar.plist")
        try writePlist(["Label": "com.cswap.menubar", "ProgramArguments": [cswap, "menubar"]], to: other)

        #expect(try !service.migrateLegacyAgents(cswapPath: cswap))
        #expect(FileManager.default.fileExists(atPath: lookalike.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(fake.calls.isEmpty)
    }

    // MARK: Preferences

    @Test func legacyPreferencesAreCopiedOnce() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "migration-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        try writePlist([
            "hasCompletedOnboarding": true,
            "themeMode": "dark",
            "cswapExecutablePath": "/opt/homebrew/bin/cswap",
            "unrelatedKey": "ignored",
        ], to: root.appendingPathComponent("com.example.ClaudeSwap.plist"))
        defaults.set("light", forKey: "themeMode")   // existing value wins

        let copied = LegacyPreferencesMigration.migrate(
            into: defaults, currentBundleID: "app.claudeswap.ClaudeSwap", preferencesDirectory: root
        )
        #expect(copied == 2)
        #expect(defaults.bool(forKey: "hasCompletedOnboarding"))
        #expect(defaults.string(forKey: "themeMode") == "light")
        #expect(defaults.string(forKey: "cswapExecutablePath") == "/opt/homebrew/bin/cswap")
        #expect(defaults.object(forKey: "unrelatedKey") == nil)

        // Second run is a no-op.
        defaults.removeObject(forKey: "hasCompletedOnboarding")
        #expect(LegacyPreferencesMigration.migrate(
            into: defaults, currentBundleID: "app.claudeswap.ClaudeSwap", preferencesDirectory: root
        ) == 0)
        #expect(defaults.object(forKey: "hasCompletedOnboarding") == nil)
    }

    @Test func currentPreferencesFileIsNotTreatedAsLegacy() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "migration-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try writePlist(["themeMode": "dark"], to: root.appendingPathComponent("app.claudeswap.ClaudeSwap.plist"))

        #expect(LegacyPreferencesMigration.migrate(
            into: defaults, currentBundleID: "app.claudeswap.ClaudeSwap", preferencesDirectory: root
        ) == 0)
    }
}
