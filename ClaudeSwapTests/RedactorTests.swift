//
//  RedactorTests.swift
//  ClaudeSwapTests
//

import Foundation
import Testing
@testable import ClaudeSwap

@Suite struct RedactorTests {
    @Test func redactsAnthropicTokens() {
        let out = Redactor.sanitize("token sk-" + "ant-oat01-AbC_123-xyz used", home: "")
        #expect(!out.contains("sk-ant"))
        #expect(out.contains("<redacted-token>"))
    }

    @Test func redactsBearer() {
        let b = Redactor.sanitize("bearer abc.def-123", home: "")
        #expect(!b.contains("abc.def-123"))
    }

    /// PRODUCTION BUG (Redaction.swift `bearer` regex): in
    /// "Authorization: Bearer <tok>" the pattern consumes "Authorization: Bearer"
    /// as the keyword+value pair and leaves <tok> in the output.
    @Test func redactsAuthorizationBearerHeader() {
        let a = Redactor.sanitize("Authorization: Bearer abc.def-123", home: "")
        #expect(!a.contains("abc.def-123"))
    }

    @Test func redactsJSONTokenFields() {
        let text = #"{"accessToken":"hunter2hunter2","refresh_token":"zzz","email":"a@example.com"}"#
        let out = Redactor.sanitize(text, home: "")
        #expect(!out.contains("hunter2"))
        #expect(!out.contains("zzz"))
        #expect(out.contains("a@example.com"))
    }

    @Test func redactsLongOpaqueStrings() {
        let opaque = String(repeating: "Ab3", count: 20)
        let out = Redactor.sanitize("value \(opaque) end", home: "")
        #expect(!out.contains(opaque))
        #expect(Redactor.sanitize("short-ish-value", home: "") == "short-ish-value")
    }

    @Test func replacesHomePath() {
        let out = Redactor.sanitize("/home/tester/.local/bin/cswap failed", home: "/home/tester")
        #expect(out == "~/.local/bin/cswap failed")
        // Empty or root home must not mangle every slash.
        #expect(Redactor.sanitize("/a/b", home: "/") == "/a/b")
        #expect(Redactor.sanitize("/a/b", home: "") == "/a/b")
    }

    @Test func stripsANSI() {
        let out = Redactor.sanitize("\u{1B}[31mred\u{1B}[0m and \u{1B}[1;32mgreen\u{1B}[0m", home: "")
        #expect(out == "red and green")
    }

    @Test func emailsOnlyRemovedWhenShareable() {
        let text = "account a@example.com failed"
        #expect(Redactor.sanitize(text, level: .local, home: "").contains("a@example.com"))
        let shared = Redactor.sanitize(text, level: .shareable, home: "")
        #expect(!shared.contains("a@example.com"))
        #expect(shared.contains("<email>"))
    }

    @Test func removesExplicitSecrets() {
        let out = Redactor.sanitize("pasted my-short-secret here", home: "", secrets: ["my-short-secret"])
        #expect(!out.contains("my-short-secret"))
        // Secrets shorter than 4 chars are ignored so common words survive.
        #expect(Redactor.sanitize("abc abc", home: "", secrets: ["abc"]) == "abc abc")
    }

    @Test func summarizeKeepsLastLines() {
        let text = "one\ntwo\n\n  three  \nfour\nfive\n"
        #expect(Redactor.summarizeOutput(text) == "three four five")
        #expect(Redactor.summarizeOutput(text, maxLines: 1) == "five")
        #expect(Redactor.summarizeOutput("", maxLines: 3) == "")
    }

    @Test func summarizeScrubsSecrets() {
        let out = Redactor.summarizeOutput("error with token sk-" + "ant-api03-SECRETSECRET", secrets: [])
        #expect(!out.contains("SECRETSECRET"))
    }
}
