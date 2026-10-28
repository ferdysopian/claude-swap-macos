//
//  ProcessRunnerTests.swift
//  ClaudeSwapTests
//
//  Exercises ProcessRunner against throwaway /bin/sh scripts. No network,
//  Keychain, real cswap or launchd involved.
//

import Foundation
import Testing
@testable import ClaudeSwap

@Suite struct ProcessRunnerTests {
    // MARK: Helpers

    private func withTempDir<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    private func script(_ body: String, in dir: URL, name: String = "fake.sh", mode: Int = 0o755) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    private func readPid(_ url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return pid
    }

    private func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    private func request(_ exe: URL, _ args: [String] = [], stdin: Data? = nil,
                         timeout: Duration = .seconds(20)) -> ProcessRequest {
        ProcessRequest(executable: exe, arguments: args, stdin: stdin, timeout: timeout)
    }

    // MARK: Tests

    @Test func capturesStdoutStderrAndExitCode() async throws {
        try await withTempDir { dir in
            let exe = try script("echo out; echo err >&2; exit 3", in: dir)
            let result = try await ProcessRunner().run(request(exe))
            #expect(result.exitStatus == 3)
            #expect(!result.terminatedBySignal)
            #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
            #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
            #expect(!result.stdoutTruncated && !result.stderrTruncated)
        }
    }

    @Test func argumentsAreDeliveredLiterally() async throws {
        try await withTempDir { dir in
            let exe = try script(#"for a in "$@"; do printf '%s\n' "$a"; done"#, in: dir)
            let args = ["a b", "it's \"q\"", "$(echo pwned)", "x;y", "line1\nline2", "`id`"]
            let result = try await ProcessRunner().run(request(exe, args))
            let expected = args.map { $0 + "\n" }.joined()
            #expect(String(decoding: result.stdout, as: UTF8.self) == expected)
        }
    }

    @Test func stdinRoundTripOneMegabyte() async throws {
        try await withTempDir { dir in
            let exe = try script("exec cat", in: dir)
            let input = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            let result = try await ProcessRunner().run(request(exe, stdin: input))
            #expect(result.exitStatus == 0)
            #expect(result.stdout == input)
        }
    }

    @Test func childIgnoringLargeStdinDoesNotCrash() async throws {
        try await withTempDir { dir in
            let exe = try script("exit 0", in: dir)
            let input = Data(repeating: 0x41, count: 4 * 1024 * 1024)
            let result = try await ProcessRunner().run(request(exe, stdin: input))
            #expect(result.exitStatus == 0)
        }
    }

    @Test func largeOutputOnBothStreamsIsCapped() async throws {
        try await withTempDir { dir in
            let exe = try script(
                "head -c 6000000 /dev/zero &\nhead -c 6000000 /dev/zero >&2\nwait", in: dir)
            let cap = 4 * 1024 * 1024
            let result = try await ProcessRunner().run(request(exe))
            #expect(result.exitStatus == 0)
            #expect(result.stdoutTruncated && result.stderrTruncated)
            #expect(result.stdout.count == cap)
            #expect(result.stderr.count == cap)
        }
    }

    @Test func timeoutTerminatesAndReaps() async throws {
        try await withTempDir { dir in
            let pidFile = dir.appendingPathComponent("pid")
            let exe = try script("echo started\necho $$ > '\(pidFile.path)'\nexec sleep 30", in: dir)
            let clock = ContinuousClock()
            let start = clock.now
            do {
                _ = try await ProcessRunner().run(request(exe, timeout: .milliseconds(500)))
                Issue.record("expected timeout")
            } catch let ProcessRunnerError.timedOut(partial) {
                #expect(String(decoding: partial.stdout, as: UTF8.self) == "started\n")
            }
            #expect(clock.now - start < .seconds(5))
            let pid = try #require(readPid(pidFile))
            #expect(isGone(pid))
        }
    }

    @Test func childIgnoringSigtermIsKilled() async throws {
        try await withTempDir { dir in
            let pidFile = dir.appendingPathComponent("pid")
            let exe = try script("trap '' TERM\necho $$ > '\(pidFile.path)'\nexec sleep 30", in: dir)
            let clock = ContinuousClock()
            let start = clock.now
            do {
                _ = try await ProcessRunner(killGracePeriod: .milliseconds(300))
                    .run(request(exe, timeout: .milliseconds(500)))
                Issue.record("expected timeout")
            } catch let ProcessRunnerError.timedOut(partial) {
                #expect(partial.terminatedBySignal)
            }
            #expect(clock.now - start < .seconds(5))
            let pid = try #require(readPid(pidFile))
            #expect(isGone(pid))
        }
    }

    @Test func cancellationTerminatesAndReaps() async throws {
        try await withTempDir { dir in
            let pidFile = dir.appendingPathComponent("pid")
            let exe = try script("echo $$ > '\(pidFile.path)'\nexec sleep 30", in: dir)
            let req = request(exe)
            let task = Task { try await ProcessRunner().run(req) }

            var pid: pid_t?
            for _ in 0..<100 {
                pid = readPid(pidFile)
                if pid != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let started = try #require(pid)

            let clock = ContinuousClock()
            let start = clock.now
            task.cancel()
            let result = await task.result
            #expect(clock.now - start < .seconds(5))
            switch result {
            case .failure(let error):
                #expect(error as? ProcessRunnerError == .cancelled)
            case .success:
                Issue.record("expected cancellation")
            }
            #expect(isGone(started))
        }
    }

    @Test func alreadyCancelledTaskNeverLaunches() async throws {
        try await withTempDir { dir in
            let marker = dir.appendingPathComponent("ran")
            let exe = try script("touch '\(marker.path)'", in: dir)
            let req = request(exe)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await ProcessRunner().run(req)
            }
            let result = await task.result
            if case .failure(let error) = result {
                #expect(error as? ProcessRunnerError == .cancelled)
            } else {
                Issue.record("expected cancellation")
            }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func launchFailureForMissingAndNonExecutable() async throws {
        try await withTempDir { dir in
            let missing = dir.appendingPathComponent("nope")
            do {
                _ = try await ProcessRunner().run(request(missing))
                Issue.record("expected launchFailed")
            } catch ProcessRunnerError.launchFailed {
            }

            let plain = try script("echo hi", in: dir, name: "plain.sh", mode: 0o644)
            do {
                _ = try await ProcessRunner().run(request(plain, stdin: Data("x".utf8)))
                Issue.record("expected launchFailed")
            } catch ProcessRunnerError.launchFailed {
            }

            do {
                _ = try await ProcessRunner().run(request(dir))
                Issue.record("expected launchFailed")
            } catch ProcessRunnerError.launchFailed {
            }
        }
    }
}
