//
//  Redaction.swift
//  ClaudeSwap
//
//  Scrubs CLI output and error text before it reaches the activity
//  timeline, error banners, or a diagnostics report someone might paste
//  into a public issue.
//

import Foundation

enum Redactor {
    enum Level: Sendable {
        /// Secrets, home path, terminal escapes. Emails stay: the UI already
        /// shows them to the signed-in user.
        case local
        /// Everything in `.local` plus email addresses, for text that
        /// leaves the machine (diagnostics, bug reports).
        case shareable
    }

    private static let ansi = try! NSRegularExpression(pattern: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#)
    private static let anthropicKey = try! NSRegularExpression(pattern: #"sk-ant-[A-Za-z0-9_\-]+"#)
    // "Authorization: Bearer <tok>", "authorization <tok>" and "bearer <tok>".
    private static let bearer = try! NSRegularExpression(
        pattern: #"(?i)\b(authorization:?\s*(?:bearer|basic)?|bearer)\s+[A-Za-z0-9._\-~+/=]+"#
    )
    private static let jsonSecret = try! NSRegularExpression(
        pattern: #"(?i)"(access_?token|refresh_?token|token|api_?key|secret|password)"\s*:\s*"[^"]*""#
    )
    private static let longOpaque = try! NSRegularExpression(pattern: #"[A-Za-z0-9_\-]{40,}"#)
    private static let email = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
    )

    static func sanitize(
        _ text: String,
        level: Level = .local,
        home: String = NSHomeDirectory(),
        secrets: [String] = []
    ) -> String {
        var output = text
        // Exact values first (e.g. the token the user just pasted) so even a
        // short or oddly shaped secret never survives.
        for secret in secrets where secret.count >= 4 {
            output = output.replacingOccurrences(of: secret, with: "<redacted>")
        }
        output = replace(ansi, in: output, with: "")
        output = replace(anthropicKey, in: output, with: "<redacted-token>")
        output = replace(bearer, in: output, with: "$1 <redacted>")
        output = replace(jsonSecret, in: output, with: "\"$1\": \"<redacted>\"")
        output = replace(longOpaque, in: output, with: "<redacted>")
        if !home.isEmpty, home != "/" {
            output = output.replacingOccurrences(of: home, with: "~")
        }
        if level == .shareable {
            output = replace(email, in: output, with: "<email>")
        }
        return output
    }

    /// Last few meaningful lines of a CLI's stderr/stdout, sanitized, for an
    /// error banner. Tracebacks are collapsed to their final line.
    static func summarizeOutput(_ text: String, maxLines: Int = 3, secrets: [String] = []) -> String {
        let lines = sanitize(text, secrets: secrets)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(maxLines).joined(separator: " ")
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
