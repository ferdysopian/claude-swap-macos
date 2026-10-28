//
//  DiagnosticsService.swift
//  ClaudeSwap
//
//  Builds the plain-text diagnostics report for Settings > Advanced and
//  bug reports. Everything is sanitized for sharing: no tokens, no email
//  addresses or account names, home directory shown as `~`, and only coarse
//  error categories instead of raw CLI output. Users see the full text
//  before anything is copied.
//

import Foundation

struct DiagnosticsReport: Sendable, Equatable {
    var generatedAt: Date
    var appVersion: String
    var buildNumber: String
    var osVersion: String
    var architecture: String
    var backend: String
    var connection: String
    var cliPath: String?
    var cliVersion: String?
    var compatibility: String?
    var accountCount: Int
    var automation: String
    var upstreamMenuBarAgentInstalled: Bool
    var recentErrorCodes: [String]
    var warnings: [String]

    var text: String {
        """
        Claude Swap Diagnostics
        Generated: \(generatedAt.formatted(.iso8601))
        App version: \(appVersion) (\(buildNumber))
        macOS: \(osVersion) [\(architecture)]
        Backend: \(backend)
        Connection: \(connection)
        cswap path: \(cliPath ?? "none")
        cswap version: \(cliVersion ?? "unknown")
        Compatibility: \(compatibility ?? "n/a")
        Managed accounts: \(accountCount)
        Auto-switch service: \(automation)
        Upstream menu bar agent installed: \(upstreamMenuBarAgentInstalled)
        Recent error categories: \(recentErrorCodes.isEmpty ? "none" : recentErrorCodes.joined(separator: ", "))
        Warnings:
        \(warnings.isEmpty ? "  none" : warnings.map { "  - \($0)" }.joined(separator: "\n"))
        """
    }
}

@MainActor
enum DiagnosticsService {
    static func buildReport(model: AppModel, bundle: Bundle = .main, home: String = NSHomeDirectory()) -> DiagnosticsReport {
        let info = bundle.infoDictionary
        let status = model.backendStatus
        func clean(_ text: String) -> String {
            Redactor.sanitize(text, level: .shareable, home: home)
        }

        return DiagnosticsReport(
            generatedAt: Date(),
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            buildNumber: info?["CFBundleVersion"] as? String ?? "0",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            backend: status?.kind.rawValue ?? "unknown",
            connection: clean(describe(model.connectionState)),
            cliPath: status?.executablePath.map(clean),
            cliVersion: status?.version.map(clean),
            compatibility: status?.compatibility.map(describe),
            accountCount: model.snapshot.accounts.count,
            automation: model.automationStatus.map { describe($0.health) } ?? "n/a",
            upstreamMenuBarAgentInstalled: model.automationStatus?.upstreamMenuBarAgentInstalled ?? false,
            recentErrorCodes: model.recentErrorCodes,
            warnings: model.snapshot.diagnostics.warnings.map(clean)
        )
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func describe(_ state: ConnectionState) -> String {
        switch state {
        case .connecting: return "checking"
        case .connected: return "ready"
        case .fixtureMode: return "demo data"
        case .cliNotFound(let path): return path == nil ? "cswap not found" : "configured cswap path not executable"
        case .incompatible(let reason): return "incompatible: \(reason)"
        case .disconnected(let reason): return "failed" + (reason.map { ": \($0)" } ?? "")
        }
    }

    private static func describe(_ verdict: CLICompatibilityPolicy.Verdict) -> String {
        switch verdict {
        case .verified: return "verified"
        case .unverified: return "supported, not yet verified with this app version"
        case .tooOld(let minimum): return "too old (minimum \(minimum))"
        case .unknownVersion: return "unknown version"
        }
    }

    static func describe(_ health: AutoSwitchServiceStatus.Health) -> String {
        switch health {
        case .disabled: return "off"
        case .running: return "running"
        case .starting: return "starting"
        case .failing(let status): return "failing (last exit \(status))"
        case .launcherMissing: return "cswap launcher missing"
        case .orphanedRegistration: return "registered without plist"
        case .notLoaded: return "installed but not loaded"
        }
    }
}
