//
//  MenuBarLabelFormattingTests.swift
//  ClaudeSwapTests
//
//  Covers `MenuBarLabelFormatter`: the compact `displayText`/`text` shown
//  next to the menu bar glyph, and the more verbose `accessibilityValue`
//  used for VoiceOver.
//

import Testing
import Foundation
@testable import ClaudeSwap

struct MenuBarLabelFormattingTests {
    @Test func noAccountShowsPlaceholder() {
        let text = MenuBarLabelFormatter.text(for: nil, showsPercentage: true, showsAccountName: true)
        #expect(text == "No account")
    }

    @Test func percentageOnlyByDefault() {
        let account = Self.account(utilization: 62)
        let text = MenuBarLabelFormatter.text(for: account, showsPercentage: true, showsAccountName: false)
        #expect(text == "62%")
    }

    @Test func nameAndPercentageCombined() {
        let account = Self.account(utilization: 88, alias: "Work")
        let text = MenuBarLabelFormatter.text(for: account, showsPercentage: true, showsAccountName: true)
        #expect(text == "Work · 88%")
    }

    @Test func nameOnlyFallsBackWhenUsageUnknown() {
        let account = Self.account(utilization: 0, alias: "Work", unknown: true)
        let text = MenuBarLabelFormatter.text(for: account, showsPercentage: true, showsAccountName: true)
        #expect(text == "Work")
    }

    @Test func neitherFlagStillShowsDisplayName() {
        let account = Self.account(utilization: 50, alias: "Personal")
        let text = MenuBarLabelFormatter.text(for: account, showsPercentage: false, showsAccountName: false)
        #expect(text == "Personal")
    }

    @Test func accessibilityValueIsMoreVerbose() {
        let account = Self.account(utilization: 88, alias: "Work")
        let value = MenuBarLabelFormatter.accessibilityValue(for: account, showsPercentage: true, showsAccountName: true)
        #expect(value == "Work, 5 hour usage 88 percent")
    }

    @Test func accessibilityValueForNoAccount() {
        let value = MenuBarLabelFormatter.accessibilityValue(for: nil, showsPercentage: true, showsAccountName: true)
        #expect(value == "No active account")
    }

    @Test func percentageWithResetCountdown() {
        let now = Date()
        let resetsAt = now.addingTimeInterval(3600 + 41 * 60)
        let account = Self.account(utilization: 22, resetsAt: resetsAt)
        let text = MenuBarLabelFormatter.displayText(
            for: account,
            showsPercentage: true,
            showsAccountName: false,
            showsResetCountdown: true,
            now: now
        )
        #expect(text == "22% · 1h 41m")
    }

    @Test func compactCountdownFormats() {
        let now = Date()
        #expect(UsageCountdown.compact(until: now.addingTimeInterval(90), now: now) == "1m")
        #expect(UsageCountdown.compact(until: now.addingTimeInterval(3600 + 41 * 60), now: now) == "1h 41m")
        #expect(UsageCountdown.compact(until: now.addingTimeInterval(86_400 + 3600), now: now) == "1d 1h")
        #expect(UsageCountdown.compact(until: nil, now: now) == nil)
    }

    private static func account(
        utilization: Double,
        alias: String? = nil,
        unknown: Bool = false,
        resetsAt: Date? = nil
    ) -> Account {
        Account(
            id: "1",
            email: "user@example.com",
            alias: alias,
            organizationName: nil,
            organizationId: nil,
            kind: .oauth,
            isActive: true,
            switchable: true,
            disabled: false,
            quarantined: false,
            quarantineReason: nil,
            addedAt: nil,
            usage: UsageSnapshot(
                windows: [UsageWindow(id: "5h", label: "5 hour", utilizationPct: utilization, resetsAt: resetsAt)],
                unknown: unknown,
                lastError: nil
            )
        )
    }
}
