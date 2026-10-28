//
//  BridgeError.swift
//  ClaudeSwap
//

import Foundation

/// Every failure mode the bridge layer can surface to the UI. Kept coarse
/// enough for `AppModel` to render a single sensible banner per case, with
/// enough detail for Settings > Advanced diagnostics.
enum BridgeError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The helper executable could not be found at any known location.
    case helperNotFound
    /// `Process.run()` threw (permissions, missing file, etc.).
    case launchFailed(String)
    /// The helper exited before/while a request was in flight.
    case processExited(status: Int32)
    /// A request had no response within its timeout.
    case timeout(method: String)
    /// A line on stdout wasn't valid JSON, or didn't match the envelope shape.
    case malformedMessage(String)
    /// The helper's protocol version doesn't match what this client speaks.
    case protocolMismatch(expected: Int, got: Int)
    /// The helper answered with `ok: false`.
    case requestFailed(code: String, message: String)
    /// The request was cancelled locally (app quit, restart, superseded).
    case cancelled
    /// No client is currently connected/running.
    case notConnected
    /// Decoding a well-formed JSON payload into a Swift model failed.
    case decodingFailed(String)
    /// No `cswap` launcher was found, or the configured path isn't executable.
    case cliNotFound(String?)
    /// The installed `cswap` is outside the supported range or speaks an
    /// unknown JSON schema; mutations are blocked.
    case incompatible(String)
    /// A mutating command timed out or was cancelled after launch. It may or
    /// may not have taken effect; state must be re-read before retrying.
    case outcomeUnknown(operation: String)
    /// The main step succeeded but a follow-up step (e.g. alias) failed.
    case partialSuccess(String)
    /// Adding into an occupied slot needs explicit overwrite confirmation.
    case slotOccupied(Int)

    var description: String {
        switch self {
        case .helperNotFound:
            return "The Claude Swap core helper could not be found."
        case .launchFailed(let reason):
            return "Failed to launch the core helper: \(reason)"
        case .processExited(let status):
            return "The core helper exited unexpectedly (status \(status))."
        case .timeout(let method):
            return "Request \"\(method)\" timed out."
        case .malformedMessage(let detail):
            return "Received a malformed message from the core helper: \(detail)"
        case .protocolMismatch(let expected, let got):
            return "Protocol mismatch: app speaks v\(expected), helper speaks v\(got)."
        case .requestFailed(let code, let message):
            return "\(message) (\(code))"
        case .cancelled:
            return "Request cancelled."
        case .notConnected:
            return "Not connected to the core helper."
        case .decodingFailed(let detail):
            return "Failed to decode core helper response: \(detail)"
        case .cliNotFound(let path):
            if let path {
                return "No executable cswap at \(path). Choose the cswap command-line tool in Settings > Command-Line Tool."
            }
            return "The cswap command-line tool isn't installed or couldn't be found. Install claude-swap, then choose it in Settings > Command-Line Tool."
        case .incompatible(let reason):
            return reason
        case .outcomeUnknown(let operation):
            return "\"\(operation)\" didn't finish in time. It may or may not have been applied; Claude Swap re-read the account state. Check it before trying again."
        case .partialSuccess(let message):
            return message
        case .slotOccupied(let slot):
            return "Slot \(slot) already holds an account."
        }
    }

    /// Whether it's reasonable to automatically retry/restart after this
    /// error, versus surfacing a hard failure that needs user action.
    var isRecoverable: Bool {
        switch self {
        case .helperNotFound, .protocolMismatch, .requestFailed, .cliNotFound, .incompatible,
             .outcomeUnknown, .partialSuccess, .slotOccupied:
            return false
        default:
            return true
        }
    }
}

extension BridgeError: LocalizedError {
    var errorDescription: String? { description }
}
