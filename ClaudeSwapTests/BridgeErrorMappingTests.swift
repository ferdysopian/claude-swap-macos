//
//  BridgeErrorMappingTests.swift
//  ClaudeSwapTests
//

import Testing
import Foundation
@testable import ClaudeSwap

struct BridgeErrorMappingTests {
    @Test func requestFailedDescribesCodeAndMessage() {
        let error = BridgeError.requestFailed(code: "not-switchable", message: "Backup is not switchable right now.")
        #expect(error.description == "Backup is not switchable right now. (not-switchable)")
        #expect(error.isRecoverable == false)
    }

    @Test func processExitedIsRecoverable() {
        let error = BridgeError.processExited(status: 1)
        #expect(error.isRecoverable == true)
        #expect(error.description.contains("status 1"))
    }

    @Test func protocolMismatchIsNotRecoverable() {
        let error = BridgeError.protocolMismatch(expected: 1, got: 2)
        #expect(error.isRecoverable == false)
        #expect(error.description.contains("v1"))
        #expect(error.description.contains("v2"))
    }

    @Test func helperNotFoundIsNotRecoverable() {
        #expect(BridgeError.helperNotFound.isRecoverable == false)
    }

    @Test func timeoutIncludesMethodName() {
        let error = BridgeError.timeout(method: "getSnapshot")
        #expect(error.description.contains("getSnapshot"))
        #expect(error.isRecoverable == true)
    }

    @Test func localizedErrorMatchesDescription() {
        let error = BridgeError.notConnected
        #expect(error.errorDescription == error.description)
    }

    @Test func malformedEnvelopeFailsSnapshotDecoding() {
        let malformed = "{ \"id\": \"abc\", \"ok\": true, \"result\": \"not-an-object\" }"
        let data = Data(malformed.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder.bridgeDecoder.decode(BridgeEnvelope.self, from: data).result?.decoded(as: Snapshot.self)
        }
    }
}
