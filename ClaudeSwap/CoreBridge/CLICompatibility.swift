//
//  CLICompatibility.swift
//  ClaudeSwap
//
//  Which `cswap` releases this wrapper knows how to drive. The policy lives
//  in `Resources/CLICompatibility.json` so it can be reviewed and bumped
//  without touching Swift; the built-in copy below is only a fallback for
//  a bundle that lost the resource.
//

import Foundation

/// A dotted numeric version such as `0.26.0`, optionally with a
/// pre-release suffix (`0.27.0b1`), parsed from `cswap --version` output.
struct CLIVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    let components: [Int]
    let prerelease: String?

    init?(_ text: String) {
        // Accept "cswap 0.26.0", "0.26.0", "claude-swap 0.26.0\n".
        let token = text
            .split(whereSeparator: { $0.isWhitespace })
            .first(where: { $0.first?.isNumber == true })
        guard let token else { return nil }
        var numbers: [Int] = []
        var suffix: String?
        for (index, part) in token.split(separator: ".").enumerated() {
            let digits = part.prefix(while: \.isNumber)
            guard let value = Int(digits) else { return nil }
            numbers.append(value)
            let rest = part.dropFirst(digits.count)
            if !rest.isEmpty {
                suffix = String(rest) + token.split(separator: ".").dropFirst(index + 1).map { ".\($0)" }.joined()
                break
            }
        }
        guard !numbers.isEmpty else { return nil }
        components = numbers
        prerelease = suffix
    }

    var description: String {
        components.map(String.init).joined(separator: ".") + (prerelease ?? "")
    }

    static func < (lhs: CLIVersion, rhs: CLIVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        // 0.27.0b1 sorts before 0.27.0.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (left?, right?): return left < right
        }
    }
}

struct CLICompatibilityPolicy: Codable, Sendable, Equatable {
    var minimumVersion: String
    var baselineVersion: String
    var verifiedVersions: [String]
    var jsonSchemaVersions: [Int]
    var upstream: String

    enum Verdict: Sendable, Equatable {
        /// Listed in `verifiedVersions`.
        case verified
        /// At or above the minimum but not yet run through the contract checklist.
        case unverified
        /// Older than `minimumVersion`; the wrapper must not drive it.
        case tooOld(minimum: String)
        /// `--version` output we couldn't parse.
        case unknownVersion
    }

    static let builtIn = CLICompatibilityPolicy(
        minimumVersion: "0.26.0",
        baselineVersion: "0.26.0",
        verifiedVersions: [],
        jsonSchemaVersions: [1],
        upstream: "https://github.com/realiti4/claude-swap"
    )

    static func load(bundle: Bundle = .main) -> CLICompatibilityPolicy {
        guard let url = bundle.url(forResource: "CLICompatibility", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let policy = try? JSONDecoder().decode(CLICompatibilityPolicy.self, from: data) else {
            return builtIn
        }
        return policy
    }

    func evaluate(versionOutput: String) -> Verdict {
        guard let version = CLIVersion(versionOutput) else { return .unknownVersion }
        if let minimum = CLIVersion(minimumVersion), version < minimum {
            return .tooOld(minimum: minimumVersion)
        }
        let verified = verifiedVersions.compactMap(CLIVersion.init)
        return verified.contains(version) ? .verified : .unverified
    }

    func supportsSchema(_ schemaVersion: Int?) -> Bool {
        guard let schemaVersion else { return false }
        return jsonSchemaVersions.contains(schemaVersion)
    }
}
