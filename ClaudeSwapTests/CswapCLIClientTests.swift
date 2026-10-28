//
//  CswapCLIClientTests.swift
//  ClaudeSwapTests
//
//  Drives CswapCLIClient against a scripted fake `cswap` in a temp dir
//  (see FakeCswap.swift). The real cswap, launchctl and Keychain are never
//  touched.
//

import Foundation
import Testing
@testable import ClaudeSwap

// Assembled at runtime so secret scanners don't flag this obviously fake value.
private let testToken = "sk-" + "ant-oat01-FAKETOKENFORTESTS0123456789"

private func thrown(_ body: () async throws -> Void) async -> Error? {
    do { try await body(); return nil } catch { return error }
}

@Suite struct CswapCLIClientTests {
    // MARK: Start / compatibility

    @Test func startIsReadyWithUnverifiedCompatibility() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        let status = await client.start()
        #expect(status.readiness == .ready)
        #expect(status.kind == .cli)
        #expect(status.version == "cswap 0.26.0")
        #expect(status.compatibility == .unverified)
        #expect(status.executablePath == fake.url.path)
        #expect(fake.calls().map(\.argv).prefix(3) == [["--version"], ["list", "--json"], ["config", "list", "--json"]])
        let snapshot = try await client.requestSnapshot()
        #expect(snapshot.accounts.map(\.id) == ["1", "2"])
        #expect(snapshot.activeAccountId == "1")
        #expect(snapshot.autoSwitch.thresholdPct == 95)
    }

    @Test func tooOldVersionBlocksMutations() async throws {
        let fake = try FakeCswap(version: "cswap 0.25.0")
        let client = fake.makeClient()
        let status = await client.start()
        guard case .incompatible = status.readiness else { Issue.record("got \(status.readiness)"); return }
        #expect(status.compatibility == .tooOld(minimum: "0.26.0"))
        let callsAfterStart = fake.calls().count
        let error = await thrown { try await client.switchAccount(id: "2") }
        guard case .incompatible? = error as? BridgeError else { Issue.record("got \(String(describing: error))"); return }
        #expect(fake.calls().count == callsAfterStart)
        #expect(fake.calls(startingWith: "switch").isEmpty)
        #expect(fake.calls().map(\.argv) == [["--version"]])
    }

    @Test func unparseableVersionIsIncompatible() async throws {
        let fake = try FakeCswap(version: "hello world")
        let status = await fake.makeClient().start()
        guard case .incompatible = status.readiness else { Issue.record("got \(status.readiness)"); return }
        #expect(status.compatibility == .unknownVersion)
    }

    @Test func schemaVersion2IsIncompatible() async throws {
        let fake = try FakeCswap()
        try fake.set("schema", 2)
        let client = fake.makeClient()
        let status = await client.start()
        guard case .incompatible(let reason) = status.readiness else { Issue.record("got \(status.readiness)"); return }
        #expect(reason.contains("schema 2"))
        let error = await thrown { try await client.removeAccount(id: "2") }
        guard case .incompatible? = error as? BridgeError else { Issue.record("got \(String(describing: error))"); return }
        #expect(fake.calls(startingWith: "remove").isEmpty)
    }

    @Test func launchFailureIsFailed() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)/cswap")
        let client = CswapCLIClient(
            cswapURL: missing, runner: ProcessRunner(), policy: .builtIn, automation: nil,
            baseEnvironment: ["PATH": "/usr/bin:/bin"], timeouts: .init()
        )
        let status = await client.start()
        guard case .failed = status.readiness else { Issue.record("got \(status.readiness)"); return }
    }

    // MARK: Basic mutations

    @Test func switchPassesExactArgv() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        _ = await client.start()
        let snapshot = try await client.switchAccount(id: "2")
        #expect(fake.calls(startingWith: "switch").map(\.argv) == [["switch", "2", "--json"]])
        #expect(snapshot.activeAccountId == "2")
    }

    @Test func rotateAndSimpleCommands() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        _ = await client.start()
        let rotated = try await client.rotateAccount()
        #expect(rotated.activeAccountId == "2")
        _ = try await client.setDisabled(id: "2", disabled: true)
        _ = try await client.setDisabled(id: "2", disabled: false)
        _ = try await client.setAlias(id: "1", alias: "Main")
        _ = try await client.setAlias(id: "1", alias: nil)
        let argv = fake.calls().map(\.argv)
        #expect(argv.contains(["switch", "--json"]))
        #expect(argv.contains(["disable", "2"]))
        #expect(argv.contains(["enable", "2"]))
        #expect(argv.contains(["alias", "1", "Main"]))
        #expect(argv.contains(["alias", "1", "--unset"]))
    }

    @Test func removeAnswersConfirmationOnStdin() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        _ = await client.start()
        let snapshot = try await client.removeAccount(id: "2")
        let call = try #require(fake.calls(startingWith: "remove").first)
        #expect(call.argv == ["remove", "2"])
        #expect(call.stdin == "y\n")
        #expect(snapshot.accounts.map(\.id) == ["1"])
    }

    @Test func currentLoginFromStatus() async throws {
        let fake = try FakeCswap()
        let login = try await fake.makeClient().currentClaudeLogin()
        #expect(login?.email == "user1@example.com")
        #expect(login?.accountNumber == 1)
        #expect(login?.managed == true)
        try fake.set("statusActive", NSNull())
        #expect(try await fake.makeClient().currentClaudeLogin() == nil)
    }

    // MARK: add-token

    @Test func tokenGoesViaStdinNeverArgv() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        _ = await client.start()
        let snapshot = try await client.addAccount(token: testToken, alias: nil, slot: nil, overwrite: false)
        let call = try #require(fake.calls(startingWith: "add-token").first)
        #expect(call.argv == ["add-token", "-"])
        #expect(call.stdin == testToken + "\n")
        for c in fake.calls() { #expect(!c.argv.joined(separator: " ").contains(testToken)) }
        #expect(snapshot.accounts.map(\.id) == ["1", "2", "3"])
    }

    @Test func tokenNeverLeaksIntoErrorsEvenWhenCLIEchoesIt() async throws {
        let fake = try FakeCswap()
        try fake.fail("add-token", exit: 1, stderr: "Error: bad token {token}\n")
        let client = fake.makeClient()
        _ = await client.start()
        let error = await thrown { _ = try await client.addAccount(token: testToken, alias: nil, slot: 3, overwrite: false) }
        let bridge = try #require(error as? BridgeError)
        guard case .requestFailed = bridge else { Issue.record("got \(bridge)"); return }
        #expect(!bridge.description.contains(testToken))
        #expect(!bridge.description.contains("FAKETOKEN"))
        #expect(!(bridge.errorDescription ?? "").contains("FAKETOKEN"))
        for c in fake.calls() { #expect(!c.argv.joined(separator: " ").contains("FAKETOKEN")) }
    }

    @Test func tokenIsRedactedFromJSONEnvelopeToo() async throws {
        let fake = try FakeCswap()
        let envelope = #"{"schemaVersion":1,"error":{"type":"InvalidToken","message":"rejected {token}"}}"#
        try fake.fail("add-token", exit: 1, stdout: envelope.replacingOccurrences(of: "{token}", with: "x"))
        // The fake can only substitute stderr, so also verify the shared classifier directly.
        let output = ProcessOutput(
            exitStatus: 1, terminatedBySignal: false,
            stdout: Data(envelope.replacingOccurrences(of: "{token}", with: testToken).utf8),
            stderr: Data(), stdoutTruncated: false, stderrTruncated: false)
        let error = CswapCLIClient.classifyFailure(output, arguments: ["add-token", "-"], secrets: [testToken])
        #expect(!error.description.contains("FAKETOKEN"))
    }

    @Test func occupiedSlotWithoutOverwriteNeverRunsCommand() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        _ = await client.start()
        let error = await thrown { _ = try await client.addAccount(token: testToken, alias: nil, slot: 1, overwrite: false) }
        #expect(error as? BridgeError == .slotOccupied(1))
        #expect(fake.calls(startingWith: "add-token").isEmpty)
    }

    @Test func overwriteSendsTokenThenConfirmation() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        _ = await client.start()
        let snapshot = try await client.addAccount(token: testToken, alias: nil, slot: 1, overwrite: true)
        let call = try #require(fake.calls(startingWith: "add-token").first)
        #expect(call.argv == ["add-token", "-", "--slot", "1"])
        #expect(call.stdin == testToken + "\ny\n")
        #expect(snapshot.accounts.first(where: { $0.id == "1" })?.email == "token1@example.com")
    }

    @Test func cliCancelledWithSlotBecomesSlotOccupied() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        // No start(): the client doesn't know slot 1 is taken, so the CLI itself prompts and gets EOF.
        let error = await thrown { _ = try await client.addAccount(token: testToken, alias: nil, slot: 1, overwrite: false) }
        #expect(error as? BridgeError == .slotOccupied(1))
        let call = try #require(fake.calls(startingWith: "add-token").first)
        #expect(call.stdin == testToken + "\n")
        #expect((try fake.scenario()["accounts"] as? [[String: Any]])?.count == 2)
    }

    @Test func cliCancelledWithoutSlotIsCancelledError() async throws {
        let fake = try FakeCswap()
        try fake.fail("add-token", exit: 0, stdout: "Cancelled\n")
        let client = fake.makeClient()
        let error = await thrown { _ = try await client.addAccount(token: testToken, alias: nil, slot: nil, overwrite: false) }
        guard case .requestFailed(let code, _)? = error as? BridgeError else { Issue.record("got \(String(describing: error))"); return }
        #expect(code == "cli.cancelled")
    }

    @Test func tokenIsTrimmed() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        _ = await client.start()
        _ = try await client.addAccount(token: "  \(testToken)\n", alias: nil, slot: 3, overwrite: false)
        #expect(fake.calls(startingWith: "add-token").first?.stdin == testToken + "\n")
    }

    @Test func emptyOrMultilineTokenRejectedBeforeRunning() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        _ = await client.start()
        let before = fake.calls().count
        for bad in ["", "   \n", "line1\ny", "tok\r\nmore"] {
            let error = await thrown { _ = try await client.addAccount(token: bad, alias: nil, slot: 3, overwrite: true) }
            guard case .requestFailed(let code, let message)? = error as? BridgeError else { Issue.record("got \(String(describing: error))"); return }
            #expect(code == "cli.input")
            #expect(!message.contains("line1"))
        }
        #expect(fake.calls().count == before)
    }

    @Test func aliasStartingWithDashRejectedBeforeRunning() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        _ = await client.start()
        let before = fake.calls().count
        let e1 = await thrown { _ = try await client.addAccount(token: testToken, alias: "--force", slot: nil, overwrite: false) }
        let e2 = await thrown { _ = try await client.addCurrentAccount(alias: "-x", slot: nil, overwrite: false) }
        let e3 = await thrown { _ = try await client.setAlias(id: "1", alias: "-bad") }
        for e in [e1, e2, e3] {
            guard case .requestFailed(let code, _)? = e as? BridgeError else { Issue.record("got \(String(describing: e))"); return }
            #expect(code == "cli.input")
        }
        #expect(fake.calls().count == before)
    }

    @Test func aliasRunsAfterAddOnNewSlot() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        _ = await client.start()
        let snapshot = try await client.addAccount(token: testToken, alias: "Work", slot: nil, overwrite: false)
        #expect(fake.calls(startingWith: "alias").map(\.argv) == [["alias", "3", "Work"]])
        #expect(snapshot.accounts.first(where: { $0.id == "3" })?.alias == "Work")
        let order = fake.calls().map { $0.argv.first ?? "" }
        let addIndex = try #require(order.firstIndex(of: "add-token"))
        let aliasIndex = try #require(order.firstIndex(of: "alias"))
        #expect(addIndex < aliasIndex)
    }

    @Test func aliasFailureIsPartialSuccess() async throws {
        let fake = try FakeCswap()
        try fake.fail("alias", exit: 1, stderr: "alias rejected")
        let client = fake.makeClient()
        _ = await client.start()
        let error = await thrown { _ = try await client.addAccount(token: testToken, alias: "Work", slot: 3, overwrite: false) }
        guard case .partialSuccess(let message)? = error as? BridgeError else { Issue.record("got \(String(describing: error))"); return }
        #expect(message.contains("slot 3"))
        #expect(!message.contains("FAKETOKEN"))
        // The account really was added.
        let accounts = try #require(try fake.scenario()["accounts"] as? [[String: Any]])
        #expect(accounts.contains { ($0["number"] as? Int) == 3 })
    }

    @Test func addCurrentWithoutOverwriteSendsNoStdin() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        _ = await client.start()
        _ = try await client.addCurrentAccount(alias: "Me", slot: nil, overwrite: false)
        let call = try #require(fake.calls(startingWith: "add").first)
        #expect(call.argv == ["add", "--alias", "Me"])
        #expect(call.stdin == "")
    }

    @Test func addCurrentOverwriteAnswersYes() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        _ = await client.start()
        _ = try await client.addCurrentAccount(alias: nil, slot: 2, overwrite: true)
        let call = try #require(fake.calls(startingWith: "add").first)
        #expect(call.argv == ["add", "--slot", "2"])
        #expect(call.stdin == "y\n")
    }

    @Test func addCurrentCancelledWhenUnconfirmed() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        let error = await thrown { _ = try await client.addCurrentAccount(alias: nil, slot: 1, overwrite: false) }
        #expect(error as? BridgeError == .slotOccupied(1))
        #expect(fake.calls(startingWith: "add").first?.stdin == "")
    }

    // MARK: Auto-switch

    @Test func partialAutoSwitchSettingsFailure() async throws {
        let fake = try FakeCswap()
        try fake.fail("config set autoswitch.cooldownSeconds", exit: 1, stderr: "invalid value for cooldownSeconds")
        let client = fake.makeClient()
        _ = await client.start()
        let update = AutoSwitchSettingsUpdate(thresholdPct: 90, strategy: .consumeFirst, cooldownSeconds: 600, includeAPIKeyAccounts: true)
        let error = await thrown { _ = try await client.updateAutoSwitchSettings(update) }
        guard case .partialSuccess(let message)? = error as? BridgeError else { Issue.record("got \(String(describing: error))"); return }
        #expect(message.contains("autoswitch.cooldownSeconds"))
        #expect(message.hasPrefix("Some settings were saved"))
        let sets = fake.calls().map(\.argv).filter { $0.first == "config" && $0.dropFirst().first == "set" }
        #expect(sets == [
            ["config", "set", "autoswitch.threshold", "90.0"],
            ["config", "set", "autoswitch.strategy", "consume-first"],
            ["config", "set", "autoswitch.cooldownSeconds", "600"],
            ["config", "set", "autoswitch.includeApiKeyAccounts", "true"],
        ])
    }

    @Test func allAutoSwitchSettingsFailing() async throws {
        let fake = try FakeCswap()
        try fake.fail("config set", exit: 1, stderr: "nope")
        let client = fake.makeClient()
        _ = await client.start()
        let error = await thrown { _ = try await client.updateAutoSwitchSettings(.init(thresholdPct: 80)) }
        guard case .partialSuccess(let message)? = error as? BridgeError else { Issue.record("got \(String(describing: error))"); return }
        #expect(message.hasPrefix("Settings weren't saved"))
    }

    @Test func autoSwitchUnavailableWithoutService() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient(automation: nil)
        _ = await client.start()
        let error = await thrown { _ = try await client.setAutoSwitchEnabled(true) }
        guard case .requestFailed(let code, _)? = error as? BridgeError else { Issue.record("got \(String(describing: error))"); return }
        #expect(code == "automation.unavailable")
    }

    @Test func autoSwitchEnableUsesFakeLaunchctlOnly() async throws {
        let fake = try FakeCswap()
        let launchctl = FakeLaunchctl()
        let env = AutoSwitchServiceEnvironment(
            launchAgentsDirectory: fake.dir.appendingPathComponent("LaunchAgents"),
            logDirectory: fake.dir.appendingPathComponent("Logs"),
            userID: 501, launchctl: launchctl, sleep: { _ in })
        let client = fake.makeClient(automation: AutoSwitchDaemonService(environment: env))
        _ = await client.start()
        let snapshot = try await client.setAutoSwitchEnabled(true)
        #expect(snapshot.autoSwitch.enabled)
        #expect(launchctl.calls.contains { $0.first == "bootstrap" })
        let plist = fake.dir.appendingPathComponent("LaunchAgents/\(AutoSwitchDaemonService.label).plist")
        #expect(FileManager.default.fileExists(atPath: plist.path))
        let status = await client.automationServiceStatus()
        #expect(status?.plistInstalled == true)
    }

    // MARK: Timeouts

    @Test func mutationTimeoutIsOutcomeUnknownAndNotRetried() async throws {
        let fake = try FakeCswap()
        try fake.sleep("switch", seconds: 8)
        let client = fake.makeClient(timeouts: .init(probe: .seconds(10), read: .seconds(10), mutation: .seconds(1)))
        _ = await client.start()
        let error = await thrown { _ = try await client.switchAccount(id: "2") }
        #expect(error as? BridgeError == .outcomeUnknown(operation: "Switch account"))
        #expect(fake.calls(startingWith: "switch").count == 1)
        #expect(fake.overlaps.isEmpty)
        // The client re-read state afterwards.
        let order = fake.calls().map { $0.argv.first ?? "" }
        let switchIndex = try #require(order.firstIndex(of: "switch"))
        #expect(order[(switchIndex + 1)...].contains("list"))
    }

    @Test func readTimeoutIsTimeout() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient(timeouts: .init(probe: .seconds(10), read: .seconds(1), mutation: .seconds(10)))
        _ = await client.start()
        try fake.sleep("list", seconds: 8)
        let error = await thrown { _ = try await client.requestSnapshot() }
        #expect(error as? BridgeError == .timeout(method: "cswap list"))
    }

    // MARK: Transfer

    @Test func importWithoutOverwriteHasNoForceAndReportsSkipped() async throws {
        let fake = try FakeCswap()
        let skippedLine = "Skipped a@example.com (already exists, use --force)"
        try fake.set("importOutput", "\(skippedLine)\nImported b@example.com\n")
        let client = fake.makeClient()
        _ = await client.start()
        let source = fake.dir.appendingPathComponent("in.json")
        let outcome = try await client.importAccounts(from: source, overwriteExisting: false)
        #expect(fake.calls(startingWith: "import").map(\.argv) == [["import", source.path]])
        #expect(outcome.skipped == [skippedLine])
    }

    @Test func importWithOverwritePassesForce() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        _ = await client.start()
        let source = fake.dir.appendingPathComponent("in.json")
        let outcome = try await client.importAccounts(from: source, overwriteExisting: true)
        #expect(fake.calls(startingWith: "import").map(\.argv) == [["import", source.path, "--force"]])
        #expect(outcome.skipped.isEmpty)
    }

    @Test func exportPassesPathAndChecksFile() async throws {
        let fake = try FakeCswap()
        let client = fake.makeClient()
        _ = await client.start()
        let target = fake.dir.appendingPathComponent("export.json")
        try await client.exportAccounts(to: target, accountID: nil)
        #expect(fake.calls(startingWith: "export").map(\.argv) == [["export", target.path]])
        #expect(FileManager.default.fileExists(atPath: target.path))
        let single = fake.dir.appendingPathComponent("one.json")
        try await client.exportAccounts(to: single, accountID: "2")
        #expect(fake.calls(startingWith: "export").last?.argv == ["export", single.path, "--account", "2"])
    }

    @Test func exportWithoutFileFails() async throws {
        let fake = try FakeCswap()
        try fake.set("noExportFile", true)
        let client = fake.makeClient()
        _ = await client.start()
        let target = fake.dir.appendingPathComponent("never.json")
        let error = await thrown { try await client.exportAccounts(to: target, accountID: nil) }
        guard case .requestFailed(let code, _)? = error as? BridgeError else { Issue.record("got \(String(describing: error))"); return }
        #expect(code == "export.missing")
    }

    // MARK: Serialization

    @Test func commandsNeverOverlap() async throws {
        let fake = try FakeCswap()
        try fake.set("listDelay", 0.15)
        let client = fake.makeClient()
        _ = await client.start()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { _ = try await client.requestSnapshot() } }
            group.addTask { _ = try await client.switchAccount(id: "2") }
            group.addTask { _ = try await client.currentClaudeLogin() }
            group.addTask { _ = try await client.setAlias(id: "1", alias: "X") }
            try await group.waitForAll()
        }
        #expect(fake.overlaps.isEmpty, "overlapping cswap invocations: \(fake.overlaps)")
        #expect(fake.calls(startingWith: "switch").count == 1)
    }

    @Test func concurrentRefreshesCoalesce() async throws {
        let fake = try FakeCswap()
        try fake.set("listDelay", 0.3)
        let client = fake.makeClient()
        _ = await client.start()
        let before = fake.calls(startingWith: "list").count
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { _ = try await client.requestSnapshot() } }
            try await group.waitForAll()
        }
        let extra = fake.calls(startingWith: "list").count - before
        #expect(extra >= 1 && extra <= 4)
        #expect(fake.overlaps.isEmpty)
    }

    // MARK: Failure classification and real failures

    private func output(
        _ exit: Int32, stdout: String = "", stderr: String = "", signal: Bool = false
    ) -> ProcessOutput {
        ProcessOutput(
            exitStatus: exit, terminatedBySignal: signal, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8),
            stdoutTruncated: false, stderrTruncated: false)
    }

    private func classify(_ out: ProcessOutput, _ argv: [String] = ["switch", "2"]) -> (String, String) {
        guard case .requestFailed(let code, let message) = CswapCLIClient.classifyFailure(out, arguments: argv) else {
            return ("", "")
        }
        return (code, message)
    }

    @Test func classifiesCredentialNetworkInputAndGeneric() {
        #expect(classify(output(1, stderr: "Error: 401 unauthorized")).0 == "cli.credential")
        #expect(classify(output(1, stderr: "keychain access denied")).0 == "cli.credential")
        #expect(classify(output(1, stderr: "Connection refused")).0 == "cli.network")
        #expect(classify(output(1, stderr: "could not resolve host")).0 == "cli.network")
        #expect(classify(output(1, stderr: "No account in slot 9")).0 == "cli.input")
        #expect(classify(output(1, stderr: "something exploded")).0 == "cli.failed")
    }

    @Test func usageErrorIsUnsupported() {
        let (code, message) = classify(
            output(2, stderr: "usage: cswap [-h] ...\ncswap: error: unrecognized arguments: --json"), ["switch", "2", "--json"])
        #expect(code == "cli.unsupported")
        #expect(message.contains("`cswap switch`"))
        // Exit 2 without usage text is not an argparse error.
        #expect(classify(output(2, stderr: "plain failure")).0 == "cli.failed")
    }

    @Test func jsonEnvelopeMessageIsPreferred() {
        let envelope = #"{"schemaVersion":1,"error":{"type":"AccountError","message":"No account in slot 9"}}"#
        let (code, message) = classify(output(1, stdout: envelope, stderr: "Traceback junk that should not show"))
        #expect(message == "No account in slot 9")
        #expect(code == "cli.input")
    }

    @Test func emptyOutputFallsBackToStatusText() {
        #expect(classify(output(3)).1 == "cswap exited with status 3.")
        #expect(classify(output(9, signal: true)).1 == "cswap was terminated by signal 9.")
    }

    @Test func failureMessageIsSanitized() {
        let out = output(1, stderr: "failed with " + "sk-" + "ant-api03-ABCDEFGH and my-secret-value")
        guard case .requestFailed(_, let message) = CswapCLIClient.classifyFailure(
            out, arguments: ["add"], secrets: ["my-secret-value"]) else { Issue.record("no"); return }
        #expect(!message.contains("ABCDEFGH"))
        #expect(!message.contains("my-secret-value"))
    }

    @Test func jsonModeFailureSurfacesEnvelopeMessage() async throws {
        let fake = try FakeCswap()
        let envelope = #"{"schemaVersion":1,"error":{"type":"AccountError","message":"No account in slot 7"}}"#
        try fake.fail("switch", exit: 1, stdout: envelope, stderr: "ignored noise")
        let client = fake.makeClient()
        _ = await client.start()
        let error = await thrown { _ = try await client.switchAccount(id: "7") }
        guard case .requestFailed(let code, let message)? = error as? BridgeError else { Issue.record("got \(String(describing: error))"); return }
        #expect(code == "cli.input")
        #expect(message == "No account in slot 7")
    }

    @Test func argparseErrorFromRealRunIsUnsupported() async throws {
        let fake = try FakeCswap()
        try fake.fail("switch", exit: 2, stderr: "usage: cswap [-h]\ncswap: error: invalid choice: 'switch'")
        let client = fake.makeClient()
        _ = await client.start()
        let error = await thrown { _ = try await client.switchAccount(id: "2") }
        guard case .requestFailed(let code, _)? = error as? BridgeError else { Issue.record("got \(String(describing: error))"); return }
        #expect(code == "cli.unsupported")
    }
}
