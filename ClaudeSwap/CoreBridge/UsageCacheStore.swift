//
//  UsageCacheStore.swift
//  ClaudeSwap
//
//  Reads `cache/usage.json` written by the Python core (same store human
//  `cswap list` uses for last-known bars). `cswap list --json` deliberately
//  omits usage once age > STALE_OK_S (~5m) so scripts don't act on stale
//  data — the macOS UI still wants those bars, annotated as last-known.
//

import Foundation

enum UsageCacheStore {
    struct Row {
        var email: String?
        var organizationUuid: String?
        var fetchedAt: Date?
        var lastGood: [String: Any]
    }

    /// Candidate locations for the core's usage cache (macOS uses the legacy
    /// `~/.claude-swap-backup` layout; Linux/XDG is listed for completeness).
    static func candidateURLs(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".local/share", isDirectory: true)
        return [
            home.appendingPathComponent(".claude-swap-backup/cache/usage.json"),
            xdg.appendingPathComponent("claude-swap/cache/usage.json"),
        ]
    }

    /// Load account-number → last-good rows. Lock-free: the core writes via
    /// atomic replace, matching `UsageStore` reader semantics.
    static func loadRows(fileManager: FileManager = .default) -> [String: Row] {
        // Hosted unit tests run inside the app; never read the developer's
        // real cswap cache there. Tests inject rows explicitly instead.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return [:] }
        for url in candidateURLs() {
            guard fileManager.isReadableFile(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accounts = object["accounts"] as? [String: Any]
            else { continue }

            var rows: [String: Row] = [:]
            for (number, value) in accounts {
                guard let row = value as? [String: Any],
                      let lastGood = row["lastGood"] as? [String: Any],
                      !lastGood.isEmpty
                else { continue }
                let fetchedAt: Date? = {
                    if let ts = row["fetchedAt"] as? Double { return Date(timeIntervalSince1970: ts) }
                    if let ts = row["fetchedAt"] as? Int { return Date(timeIntervalSince1970: Double(ts)) }
                    return nil
                }()
                rows[number] = Row(
                    email: row["email"] as? String,
                    organizationUuid: row["organizationUuid"] as? String,
                    fetchedAt: fetchedAt,
                    lastGood: lastGood
                )
            }
            if !rows.isEmpty { return rows }
        }
        return [:]
    }

    /// Compact age like the CLI: `10h ago`, `3d ago`, `just now`.
    static func formatAge(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}
