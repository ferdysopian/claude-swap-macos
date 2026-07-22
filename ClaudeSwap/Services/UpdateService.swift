//
//  UpdateService.swift
//  ClaudeSwap
//
//  Update checking is stubbed behind the `ENABLE_SPARKLE_UPDATES` build
//  flag so this project builds cleanly without adding the Sparkle SPM
//  dependency. Flip the flag (and add the package in project.yml) to wire
//  a real `SPUStandardUpdaterController` implementation later — the rest
//  of the app only depends on `UpdateServiceProtocol`.
//

import Foundation

enum UpdateCheckResult: Sendable, Equatable {
    case upToDate
    case updateAvailable(version: String)
    case checkFailed(String)
    case unsupported
}

protocol UpdateServiceProtocol: Sendable {
    func checkForUpdates() async -> UpdateCheckResult
    var automaticallyChecksForUpdates: Bool { get set }
}

#if ENABLE_SPARKLE_UPDATES
// Real implementation would live here, backed by SPUStandardUpdaterController.
// Left unimplemented intentionally: enabling the flag without vendoring the
// Sparkle package will fail to compile, which is the point (fail loudly
// rather than silently no-op in a release build).
#else
/// No-op implementation used for unsigned/dev builds and whenever Sparkle
/// isn't vendored. Always reports "unsupported" so Settings > Updates can
/// show an honest message instead of pretending to check.
final class NoopUpdateService: UpdateServiceProtocol, @unchecked Sendable {
    var automaticallyChecksForUpdates: Bool = false

    func checkForUpdates() async -> UpdateCheckResult {
        .unsupported
    }
}

typealias UpdateService = NoopUpdateService
#endif
