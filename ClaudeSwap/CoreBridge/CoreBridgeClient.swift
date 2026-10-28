//
//  CoreBridgeClient.swift
//  ClaudeSwap
//
//  Actor that owns the helper `Process`, its pipes, request/response
//  correlation, timeouts, and restart-with-backoff. This is the only type
//  in the app that speaks raw NDJSON.
//

import Foundation
import os.log

actor CoreBridgeClient: CoreBridgeClientProtocol {
    private let log = Logger(subsystem: "app.claudeswap.ClaudeSwap", category: "CoreBridgeClient")

    private var bridgeProcess = BridgeProcess()
    private var readTask: Task<Void, Never>?
    private var pendingRequests: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var eventContinuations: [UUID: AsyncStream<BridgeEvent>.Continuation] = [:]
    private var started = false
    private var stopping = false
    private var restartAttempt = 0
    private var latestSnapshot: Snapshot = .empty
    private var launchStart: Date?

    /// How long a single request waits for a response before failing.
    private let requestTimeout: Duration = .seconds(10)
    /// Backoff schedule for automatic restarts after an unexpected exit.
    private let backoffSchedule: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)]

    // MARK: - Lifecycle

    func start() async -> BackendStatus {
        let path = HelperLocator.locate()?.launchDescription
        guard !started else {
            return BackendStatus(kind: .devBridge, readiness: .ready, executablePath: path)
        }
        started = true
        stopping = false
        await launchOnce()
        return BackendStatus(kind: .devBridge, readiness: .ready, executablePath: path)
    }

    func stop() async {
        stopping = true
        started = false
        readTask?.cancel()
        readTask = nil
        bridgeProcess.terminate()
        failAllPending(with: .cancelled)
        broadcast(.helperDisconnected(reason: "stopped"))
        for continuation in eventContinuations.values { continuation.finish() }
        eventContinuations.removeAll()
    }

    func events() -> AsyncStream<BridgeEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            self.registerEventContinuation(id: id, continuation: continuation)
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

    private func launchOnce() async {
        guard let location = HelperLocator.locate() else {
            log.notice("No core helper found; caller should fall back to fixture mode.")
            broadcast(.helperDisconnected(reason: BridgeError.helperNotFound.description))
            return
        }
        do {
            launchStart = Date()
            let lines = try bridgeProcess.launch(location)
            log.info("Launched core helper: \(location.launchDescription, privacy: .public)")
            readTask = Task { [weak self] in
                await self?.consume(lines)
            }
            try await handshake()
            broadcast(.helperConnected)
            restartAttempt = 0
        } catch {
            log.error("Failed to launch core helper: \(String(describing: error), privacy: .public)")
            bridgeProcess.terminate()
            broadcast(.helperDisconnected(reason: "\(error)"))
        }
    }

    private func handshake() async throws {
        let params = HandshakeParams(
            protocolVersion: .init(major: BridgeProtocolVersion.current, minor: 0)
        )
        _ = try await send(method: .handshake, params: params)
    }

    private func consume(_ lines: AsyncStream<String>) async {
        for await line in lines {
            handle(line: line)
        }
        // Stream ended: the helper's stdout closed (it exited or crashed).
        if !stopping {
            let status = bridgeProcess.process?.terminationStatus ?? -1
            let error = BridgeError.processExited(status: status)
            log.error("Core helper stdout closed: \(error.description, privacy: .public)")
            failAllPending(with: error)
            broadcast(.helperDisconnected(reason: error.description))
            await scheduleRestart()
        }
    }

    private func scheduleRestart() async {
        guard started, !stopping else { return }
        let delay = backoffSchedule[min(restartAttempt, backoffSchedule.count - 1)]
        restartAttempt += 1
        log.notice("Restarting core helper in \(delay.components.seconds, privacy: .public)s (attempt \(self.restartAttempt, privacy: .public))")
        try? await Task.sleep(for: delay)
        guard started, !stopping else { return }
        await launchOnce()
    }

    // MARK: - Message handling

    private func handle(line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let envelope: BridgeEnvelope
        do {
            envelope = try JSONDecoder.bridgeDecoder.decode(BridgeEnvelope.self, from: data)
        } catch {
            log.error("Malformed line from helper: \(line, privacy: .private)")
            broadcast(.log(level: "error", message: "malformed message from helper"))
            return
        }

        if let id = envelope.id {
            completeRequest(id: id, envelope: envelope)
            return
        }
        if let eventName = envelope.event {
            handleEvent(name: eventName, payload: envelope.eventPayload)
            return
        }
    }

    private func completeRequest(id: String, envelope: BridgeEnvelope) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
        if let error = envelope.error {
            continuation.resume(throwing: BridgeError.requestFailed(code: error.code, message: error.message))
        } else if envelope.ok == false {
            continuation.resume(throwing: BridgeError.malformedMessage("response ok=false without error"))
        } else if envelope.result != nil || envelope.ok == true {
            continuation.resume(returning: envelope.result ?? .null)
        } else {
            continuation.resume(throwing: BridgeError.malformedMessage("response missing result/error"))
        }
    }

    private func handleEvent(name: String, payload: JSONValue?) {
        switch name {
        case "snapshotChanged", "snapshot.changed":
            guard let payload, let snapshot = try? decodeLiveSnapshot(payload) else { return }
            latestSnapshot = snapshot
            broadcast(.snapshotChanged(snapshot))
        case "accounts.changed", "snapshotInvalidated":
            // Mutation side-effect: pull a fresh snapshot for the UI.
            Task { try? await self.requestSnapshot() }
        case "switched":
            guard let payload, case .object(let object) = payload else { return }
            let from = (object["from"].flatMap { if case .string(let s) = $0 { s } else { nil } })
            let to = (object["to"].flatMap { if case .string(let s) = $0 { s } else { nil } }) ?? ""
            let trigger = (object["trigger"].flatMap { if case .string(let s) = $0 { s } else { nil } }) ?? "manual"
            broadcast(.switched(from: from, to: to, trigger: trigger))
        case "autoSwitchStatus":
            guard let payload, let state = try? payload.decoded(as: AutoSwitchState.self) else { return }
            broadcast(.autoSwitchStatus(state))
        case "accountQuarantined":
            guard let payload, case .object(let object) = payload,
                  case .string(let accountId)? = object["accountId"] else { return }
            let reason = (object["reason"].flatMap { if case .string(let s) = $0 { s } else { nil } }) ?? "unknown"
            broadcast(.accountQuarantined(accountId: accountId, reason: reason))
        case "accountUnquarantined":
            guard let payload, case .object(let object) = payload,
                  case .string(let accountId)? = object["accountId"] else { return }
            broadcast(.accountUnquarantined(accountId: accountId))
        case "log":
            guard let payload, case .object(let object) = payload else { return }
            let level = (object["level"].flatMap { if case .string(let s) = $0 { s } else { nil } }) ?? "info"
            let message = (object["message"].flatMap { if case .string(let s) = $0 { s } else { nil } }) ?? ""
            broadcast(.log(level: level, message: message))
        default:
            broadcast(.unknown(name: name))
        }
    }

    private func broadcast(_ event: BridgeEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func failAllPending(with error: BridgeError) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Request/response

    private func send<Params: Encodable & Sendable>(
        method: BridgeMethod,
        params: Params
    ) async throws -> JSONValue {
        guard bridgeProcess.isRunning else { throw BridgeError.notConnected }
        let id = UUID().uuidString
        let request = BridgeRequest(id: id, method: method.rawValue, params: params)
        let data: Data
        do {
            data = try JSONEncoder.bridgeEncoder.encode(request)
        } catch {
            throw BridgeError.decodingFailed(error.localizedDescription)
        }
        guard let line = String(data: data, encoding: .utf8) else {
            throw BridgeError.decodingFailed("non-UTF8 request payload")
        }

        let timeout = requestTimeout
        let methodName = method.rawValue
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await self.registerAndWrite(id: id, line: line)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BridgeError.timeout(method: methodName)
            }
            defer { group.cancelAll() }
            return try await group.next() ?? { throw BridgeError.timeout(method: methodName) }()
        }
    }

    private func registerAndWrite(id: String, line: String) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            do {
                try bridgeProcess.writeLine(line)
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - CoreBridgeClientProtocol

    @discardableResult
    func requestSnapshot() async throws -> Snapshot {
        let value = try await send(method: .snapshot, params: EmptyParams())
        let snapshot = try decodeLiveSnapshot(value)
        latestSnapshot = snapshot
        broadcast(.snapshotChanged(snapshot))
        return snapshot
    }

    @discardableResult
    func switchAccount(id: String) async throws -> Snapshot {
        _ = try await send(method: .accountsSwitchTo, params: SwitchToParams(target: id))
        return try await requestSnapshot()
    }

    @discardableResult
    func rotateAccount() async throws -> Snapshot {
        _ = try await send(method: .accountsSwitch, params: EmptyParams())
        return try await requestSnapshot()
    }

    @discardableResult
    func setAutoSwitchEnabled(_ enabled: Bool) async throws -> Snapshot {
        _ = try await send(
            method: .settingsSet,
            params: SettingsSetParams(key: "autoswitch.enabled", value: .bool(enabled))
        )
        return try await requestSnapshot()
    }

    @discardableResult
    func updateAutoSwitchSettings(_ update: AutoSwitchSettingsUpdate) async throws -> Snapshot {
        if let threshold = update.thresholdPct {
            _ = try await send(
                method: .settingsSet,
                params: SettingsSetParams(key: "autoswitch.threshold", value: .number(threshold))
            )
        }
        if let cooldown = update.cooldownSeconds {
            _ = try await send(
                method: .settingsSet,
                params: SettingsSetParams(
                    key: "autoswitch.cooldownSeconds",
                    value: .number(Double(cooldown))
                )
            )
        }
        if let include = update.includeAPIKeyAccounts {
            _ = try await send(
                method: .settingsSet,
                params: SettingsSetParams(
                    key: "autoswitch.includeApiKeyAccounts",
                    value: .bool(include)
                )
            )
        }
        return try await requestSnapshot()
    }

    @discardableResult
    func addAccount(token: String, alias: String?, slot: Int?, overwrite: Bool) async throws -> Snapshot {
        _ = try await send(
            method: .accountsAddToken,
            params: AddTokenParams(secret: token, alias: alias, slot: slot)
        )
        return try await requestSnapshot()
    }

    @discardableResult
    func addCurrentAccount(alias: String?, slot: Int?, overwrite: Bool) async throws -> Snapshot {
        _ = try await send(
            method: .accountsAddCurrent,
            params: AddCurrentParams(alias: alias, slot: slot)
        )
        return try await requestSnapshot()
    }

    func currentClaudeLogin() async throws -> CurrentClaudeLogin? {
        let value = try await send(method: BridgeMethod("accounts.status"), params: EmptyParams())
        let object = try SnapshotMapping.jsonObject(from: value)
        guard let active = object["active"] as? [String: Any],
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
        _ = try await send(
            method: .accountsRemove,
            params: RemoveAccountParams(identifier: id, confirmed: true)
        )
        return try await requestSnapshot()
    }

    @discardableResult
    func setAlias(id: String, alias: String?) async throws -> Snapshot {
        let value = alias ?? ""
        _ = try await send(
            method: .accountsSetAlias,
            params: SetAliasParams(identifier: id, alias: value)
        )
        return try await requestSnapshot()
    }

    @discardableResult
    func setDisabled(id: String, disabled: Bool) async throws -> Snapshot {
        _ = try await send(
            method: .accountsSetDisabled,
            params: SetDisabledParams(identifier: id, disabled: disabled)
        )
        return try await requestSnapshot()
    }

    func exportAccounts(to url: URL, accountID: String?) async throws {
        throw BridgeError.requestFailed(
            code: "unsupported",
            message: "Export isn't available in the development bridge; use `cswap export`."
        )
    }

    func importAccounts(from url: URL, overwriteExisting: Bool) async throws -> ImportOutcome {
        throw BridgeError.requestFailed(
            code: "unsupported",
            message: "Import isn't available in the development bridge; use `cswap import`."
        )
    }

    func automationServiceStatus() async -> AutoSwitchServiceStatus? { nil }

    private func decodeLiveSnapshot(_ value: JSONValue) throws -> Snapshot {
        let object = try SnapshotMapping.jsonObject(from: value)
        return SnapshotMapping.fromBridgeSnapshot(
            object,
            corePath: HelperLocator.locate().map(\.launchDescription),
            helperPID: bridgeProcess.processIdentifier
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        do {
            return try value.decoded(as: type)
        } catch {
            throw BridgeError.decodingFailed(error.localizedDescription)
        }
    }
}
