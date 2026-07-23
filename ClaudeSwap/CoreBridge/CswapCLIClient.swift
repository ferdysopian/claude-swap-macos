//
//  CswapCLIClient.swift
//  ClaudeSwap
//
//  Live backend that shells out to an already-installed `cswap` on PATH
//  (or a resolved absolute path). Used when Claude Swap is installed but
//  the package does not yet ship `python -m claude_swap.bridge` — so the
//  macOS app still reads the user's real accounts instead of fixtures.
//

import Foundation
import os.log

actor CswapCLIClient: CoreBridgeClientProtocol {
    private let log = Logger(subsystem: "app.claudeswap.ClaudeSwap", category: "CswapCLIClient")
    private let cswapURL: URL
    private var started = false
    private var latest: Snapshot = .empty
    private var eventContinuations: [UUID: AsyncStream<BridgeEvent>.Continuation] = [:]

    init(cswapURL: URL) {
        self.cswapURL = cswapURL
    }

    func start() async {
        guard !started else { return }
        started = true
        broadcast(.helperConnected)
        do {
            _ = try await requestSnapshot()
        } catch {
            log.error("Initial cswap list failed: \(String(describing: error), privacy: .public)")
            broadcast(.helperDisconnected(reason: error.localizedDescription))
        }
    }

    func stop() async {
        started = false
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()
        broadcast(.helperDisconnected(reason: "stopped"))
    }

    func events() -> AsyncStream<BridgeEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            Task {
                await self.registerEventContinuation(id: id, continuation: continuation)
                // Replay so AppModel never misses the initial connected state.
                if await self.started {
                    continuation.yield(.helperConnected)
                    let snap = await self.latest
                    if !snap.accounts.isEmpty {
                        continuation.yield(.snapshotChanged(snap))
                    }
                }
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id: id) }
            }
        }
    }

    private func registerEventContinuation(id: UUID, continuation: AsyncStream<BridgeEvent>.Continuation) {
        eventContinuations[id] = continuation
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func broadcast(_ event: BridgeEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    @discardableResult
    func requestSnapshot() async throws -> Snapshot {
        let data = try await run(arguments: ["list", "--json"])
        let payload = try SnapshotMapping.jsonObject(from: data)
        let version = try? await runString(arguments: ["--version"])
        let snapshot = SnapshotMapping.fromListPayload(
            payload,
            coreVersion: version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "cswap",
            corePath: cswapURL.path
        )
        latest = snapshot
        broadcast(.snapshotChanged(snapshot))
        return snapshot
    }

    @discardableResult
    func switchAccount(id: String) async throws -> Snapshot {
        _ = try await run(arguments: ["switch", id])
        let snapshot = try await requestSnapshot()
        broadcast(.switched(from: nil, to: id, trigger: "manual"))
        return snapshot
    }

    @discardableResult
    func rotateAccount() async throws -> Snapshot {
        _ = try await run(arguments: ["switch"])
        return try await requestSnapshot()
    }

    @discardableResult
    func setAutoSwitchEnabled(_ enabled: Bool) async throws -> Snapshot {
        if enabled {
            // Start is long-running in CLI; toggle the setting only.
            _ = try? await run(arguments: ["config", "set", "autoswitch.enabled", enabled ? "true" : "false"])
        } else {
            _ = try? await run(arguments: ["config", "set", "autoswitch.enabled", "false"])
        }
        return try await requestSnapshot()
    }

    @discardableResult
    func updateAutoSwitchSettings(_ update: AutoSwitchSettingsUpdate) async throws -> Snapshot {
        if let threshold = update.thresholdPct {
            _ = try? await run(arguments: ["config", "set", "autoswitch.threshold", String(Int(threshold))])
        }
        if let cooldown = update.cooldownSeconds {
            _ = try? await run(arguments: ["config", "set", "autoswitch.cooldownSeconds", String(cooldown)])
        }
        if let include = update.includeAPIKeyAccounts {
            _ = try? await run(arguments: [
                "config", "set", "autoswitch.includeApiKeyAccounts", include ? "true" : "false",
            ])
        }
        return try await requestSnapshot()
    }

    @discardableResult
    func addAccount(token: String, alias: String?, slot: Int?) async throws -> Snapshot {
        var args = ["add-token", "-"]
        if let slot { args += ["--slot", String(slot)] }
        _ = try await run(arguments: args, stdin: token)
        if let alias, !alias.isEmpty {
            // Best-effort: alias by email is hard before we know the slot;
            // Accounts UI can set it after.
            _ = alias
        }
        return try await requestSnapshot()
    }

    @discardableResult
    func addCurrentAccount(alias: String?, slot: Int?) async throws -> Snapshot {
        var args = ["add"]
        if let slot { args += ["--slot", String(slot)] }
        if let alias, !alias.isEmpty { args += ["--alias", alias] }
        _ = try await run(arguments: args)
        return try await requestSnapshot()
    }

    func currentClaudeLogin() async throws -> CurrentClaudeLogin? {
        let data = try await run(arguments: ["status", "--json"])
        let payload = try SnapshotMapping.jsonObject(from: data)
        guard let active = payload["active"] as? [String: Any],
              let email = active["email"] as? String else {
            return nil
        }
        return CurrentClaudeLogin(
            email: email,
            organizationName: active["organizationName"] as? String,
            managed: (active["managed"] as? Bool) ?? false,
            accountNumber: active["number"] as? Int
        )
    }

    @discardableResult
    func removeAccount(id: String) async throws -> Snapshot {
        // CLI prompts for confirmation; answer yes on stdin (never use a
        // --yes flag — older installs don't have one).
        _ = try await run(arguments: ["remove", id], stdin: "y\n")
        return try await requestSnapshot()
    }

    @discardableResult
    func setAlias(id: String, alias: String?) async throws -> Snapshot {
        if let alias, !alias.isEmpty {
            _ = try await run(arguments: ["alias", id, alias])
        } else {
            _ = try await run(arguments: ["alias", id, "--unset"])
        }
        return try await requestSnapshot()
    }

    @discardableResult
    func setDisabled(id: String, disabled: Bool) async throws -> Snapshot {
        _ = try await run(arguments: [disabled ? "disable" : "enable", id])
        return try await requestSnapshot()
    }

    func exportConfig() async throws -> String {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-swap-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temp) }
        _ = try await run(arguments: ["export", temp.path])
        return try String(contentsOf: temp, encoding: .utf8)
    }

    @discardableResult
    func importConfig(_ json: String) async throws -> Snapshot {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-swap-import-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temp) }
        try json.write(to: temp, atomically: true, encoding: .utf8)
        _ = try await run(arguments: ["import", temp.path, "--force"])
        return try await requestSnapshot()
    }

    // MARK: - Process

    private func run(arguments: [String], stdin: String? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data = try Self.syncRun(
                        executable: self.cswapURL,
                        arguments: arguments,
                        stdin: stdin
                    )
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runString(arguments: [String]) async throws -> String {
        let data = try await run(arguments: arguments)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func syncRun(executable: URL, arguments: [String], stdin: String?) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        // Read pipes concurrently while waiting — otherwise a full pipe
        // buffer can deadlock `waitUntilExit` (classic Foundation Process pitfall).
        let group = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        try process.run()
        process.waitUntilExit()
        group.wait()

        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError.requestFailed(
                code: "cli.\(process.terminationStatus)",
                message: message.isEmpty ? "cswap exited \(process.terminationStatus)" : message
            )
        }
        return stdoutData
    }
}
