//
//  ClaudeSwapUITests.swift
//  ClaudeSwapUITests
//
//  One smoke test: the app launches, gets past onboarding (the app resets
//  onboarding state on launch via the `-uiTestReset` argument, see
//  `ClaudeSwapApp`/`AppModel` UserDefaults bootstrap), and the main window
//  renders its sidebar with all six tabs.
//

import XCTest

final class ClaudeSwapUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMainWindowShowsAllTabsAfterOnboarding() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSkipOnboarding", "1"]
        // XCUIApplication launches don't inherit the scheme's environment;
        // force demo data so the test never touches a real cswap.
        app.launchEnvironment["CLAUDE_SWAP_BACKEND"] = "fixture"
        app.launch()

        // Onboarding's final step is "Get Started"; if onboarding is showing
        // (first launch in a clean CI container), click through it so the
        // rest of the assertion is stable either way.
        let getStarted = app.buttons["Get Started"]
        if getStarted.waitForExistence(timeout: 5) {
            for _ in 0..<6 {
                if getStarted.exists {
                    getStarted.click()
                    break
                }
                let continueButton = app.buttons["Continue"]
                if continueButton.exists {
                    continueButton.click()
                }
            }
        }

        for tab in ["Dashboard", "Accounts", "Automation", "Activity", "Tools", "Settings"] {
            XCTAssertTrue(
                app.staticTexts[tab].waitForExistence(timeout: 5) || app.cells[tab].waitForExistence(timeout: 1),
                "Expected a sidebar entry for \(tab)"
            )
        }
    }
}
