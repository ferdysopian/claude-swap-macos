//
//  DiagnosticsService.swift
//  ClaudeSwap
//
//  Builds a plain-text diagnostics report for Settings > Advanced /
//  bug reports. Deliberately excludes anything sensitive: no tokens, no
//  full account emails beyond what's already visible in the UI, no raw
//  Keychain contents.
//

import Foundation
import os.log

struct DiagnosticsReport: Sendable {
    var generatedAt: Date
    var appVersion: String
    var buildNumber: String
    var osVersion: String
    var corePath: String?
    var helperConnected: Bool
    var accountCount: Int
    var warnings: [String]

    var text: String {
        """
        Claude Swap Diagnostics
        Generated: \(generatedAt.formatted(.iso8601))
        App version: \(appVersion) (\(buildNumber))
        macOS: \(osVersion)
        Core path override: \(corePath ?? "none")
        Helper connected: \(helperConnected)
        Managed accounts: \(accountCount)
        Warnings:
        \(warnings.isEmpty ? "  none" : warnings.map { "  - \($0)" }.joined(separator: "\n"))
        """
    }
}

@MainActor
final class DiagnosticsService {
    static let shared = DiagnosticsService()

    private let logger = Logger(subsystem: "app.claudeswap.ClaudeSwap", category: "Diagnostics")

    private init() {}

    func buildReport(snapshot: Snapshot, corePath: String?, helperConnected: Bool) -> DiagnosticsReport {
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let buildNumber = info?["CFBundleVersion"] as? String ?? "0"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        return DiagnosticsReport(
            generatedAt: Date(),
            appVersion: appVersion,
            buildNumber: buildNumber,
            osVersion: osVersion,
            corePath: corePath,
            helperConnected: helperConnected,
            accountCount: snapshot.accounts.count,
            warnings: snapshot.diagnostics.warnings
        )
    }

    func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }
}
