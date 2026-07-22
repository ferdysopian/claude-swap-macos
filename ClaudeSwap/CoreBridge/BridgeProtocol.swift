//
//  BridgeProtocol.swift
//  ClaudeSwap
//
//  Wire types for the NDJSON bridge protocol (v1) spoken over the helper
//  process's stdin/stdout. Every line on stdout is exactly one JSON object:
//  either a response correlated to a request `id`, or an unsolicited event.
//
//  Request  -> { "protocolVersion": 1, "id": "...", "method": "...", "params": {...} }
//  Response -> { "protocolVersion": 1, "id": "...", "ok": true,  "result": {...} }
//            | { "protocolVersion": 1, "id": "...", "ok": false, "error": { "code": "...", "message": "..." } }
//  Event    -> { "protocolVersion": 1, "event": "...", "payload": {...} }
//
//  No secrets (tokens, credentials) ever appear in any of these payloads.
//

import Foundation

/// Current protocol version this client speaks. The helper is expected to
/// reject (or the client to refuse) a mismatched major version.
enum BridgeProtocolVersion {
    static let current = 1
}

/// A method name understood by the helper. Kept as a plain string wrapper
/// (rather than an enum) so a helper can add new methods without the app
/// needing a matching case, but callers should prefer the static constants.
struct BridgeMethod: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    // Python `cswap-bridge` dialect (canonical).
    static let handshake = BridgeMethod("handshake")
    static let ping = BridgeMethod("ping")
    static let snapshot = BridgeMethod("snapshot")
    static let capabilities = BridgeMethod("capabilities")
    static let accountsSwitch = BridgeMethod("accounts.switch")
    static let accountsSwitchTo = BridgeMethod("accounts.switchTo")
    static let accountsRemove = BridgeMethod("accounts.remove")
    static let accountsSetAlias = BridgeMethod("accounts.setAlias")
    static let accountsSetDisabled = BridgeMethod("accounts.setDisabled")
    static let accountsAddToken = BridgeMethod("accounts.addToken")
    static let accountsAddCurrent = BridgeMethod("accounts.addCurrent")
    static let settingsGet = BridgeMethod("settings.get")
    static let settingsSet = BridgeMethod("settings.set")
    static let autoSwitchState = BridgeMethod("autoSwitch.state")
    static let shutdown = BridgeMethod("shutdown")
}

/// Outbound request envelope matching the Python bridge (no top-level
/// `protocolVersion` — that lives inside handshake `params` only).
struct BridgeRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    var id: String
    var method: String
    var params: Params
}

/// Marker payload for requests with no parameters.
struct EmptyParams: Encodable, Sendable {}

struct HandshakeParams: Encodable, Sendable {
    struct Version: Encodable, Sendable {
        var major: Int
        var minor: Int
    }
    var protocolVersion: Version
    var capabilities: [String] = []
}

/// Raw inbound line, decoded just enough to route it: a line with an `id`
/// is a response; a line with an `event` is an event.
struct BridgeEnvelope: Decodable, Sendable {
    var id: String?
    var ok: Bool?
    var result: JSONValue?
    var error: BridgeErrorPayload?
    var event: String?
    /// Python bridge event payload key.
    var data: JSONValue?
    /// Legacy Swift-dialect event payload key.
    var payload: JSONValue?

    var eventPayload: JSONValue? { data ?? payload }
}

/// Wire shape of an error response's `error` object. Python uses integer
/// JSON-RPC-style codes; older drafts used strings — accept both.
struct BridgeErrorPayload: Decodable, Sendable, Equatable {
    var code: String
    var message: String

    private enum CodingKeys: String, CodingKey { case code, message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        if let intCode = try? container.decode(Int.self, forKey: .code) {
            code = String(intCode)
        } else {
            code = try container.decode(String.self, forKey: .code)
        }
    }
}

// MARK: - Request payload types

struct SwitchToParams: Encodable, Sendable {
    var target: String
    var force: Bool = false
}

struct SwitchParams: Encodable, Sendable {
    var strategy: String?
}

struct IdentifierParams: Encodable, Sendable {
    var identifier: String
}

struct RemoveAccountParams: Encodable, Sendable {
    var identifier: String
    var confirmed: Bool = true
}

struct SetAliasParams: Encodable, Sendable {
    var identifier: String
    var alias: String
}

struct SetDisabledParams: Encodable, Sendable {
    var identifier: String
    var disabled: Bool
}

struct AddTokenParams: Encodable, Sendable {
    var secret: String
    var alias: String?
    var slot: Int?
    var overwrite: Bool = false
}

struct AddCurrentParams: Encodable, Sendable {
    var alias: String?
    var slot: Int?
    var overwrite: Bool = false
}

struct SettingsSetParams: Encodable, Sendable {
    var key: String
    var value: JSONValue
}

// MARK: - JSONValue

/// A minimal `Codable` box for arbitrary JSON, used for envelope fields
/// whose shape depends on the method/event being decoded.
enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Re-decode this boxed value as a concrete `Decodable` type.
    func decoded<T: Decodable>(as type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder.bridgeDecoder.decode(T.self, from: data)
    }
}

extension JSONDecoder {
    /// Shared decoder for bridge payloads: ISO-8601 dates, snake_case is
    /// never used on the wire (the protocol is camelCase throughout).
    static let bridgeDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let bridgeEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// Typed event delivered over the bridge's event stream (`event` envelopes).
enum BridgeEvent: Sendable, Equatable {
    case snapshotChanged(Snapshot)
    case switched(from: String?, to: String, trigger: String)
    case autoSwitchStatus(AutoSwitchState)
    case accountQuarantined(accountId: String, reason: String)
    case accountUnquarantined(accountId: String)
    case log(level: String, message: String)
    case helperConnected
    case helperDisconnected(reason: String?)
    case unknown(name: String)
}
