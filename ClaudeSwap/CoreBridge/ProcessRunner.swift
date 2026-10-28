//
//  ProcessRunner.swift
//  ClaudeSwap
//
//  Runs an external executable with argv-only arguments and returns its
//  captured output. Pipes are drained concurrently (with a per-stream cap),
//  stdin is fed from a background thread, and timeout / task cancellation
//  both go SIGTERM -> grace period -> SIGKILL -> reap before the call
//  returns. No call here blocks the Swift cooperative thread pool.
//
//  Caveat: only the direct child is signalled. Grandchildren it spawned are
//  not killed (Foundation's `Process` offers no process-group control); once
//  the child is gone, pipe readers stop shortly after the streams go idle so
//  a lingering grandchild cannot hang the call.
//

import Foundation
import os

/// One process invocation. `executable` + `arguments` map straight to argv;
/// nothing is ever passed through a shell.
struct ProcessRequest: Sendable {
    var executable: URL
    var arguments: [String]
    /// `nil` inherits the parent environment.
    var environment: [String: String]? = nil
    var currentDirectory: URL? = nil
    /// `nil` connects stdin to /dev/null.
    var stdin: Data? = nil
    var timeout: Duration
    /// Per-stream cap. Bytes beyond it are read and discarded.
    var maxOutputBytes: Int = 4 * 1024 * 1024
}

/// Result of a finished process.
struct ProcessOutput: Sendable, Equatable {
    var exitStatus: Int32
    /// `Process.terminationReason == .uncaughtSignal`.
    var terminatedBySignal: Bool
    var stdout: Data
    var stderr: Data
    var stdoutTruncated: Bool
    var stderrTruncated: Bool
}

enum ProcessRunnerError: Error, Sendable, Equatable {
    case launchFailed(String)
    /// Partial output; the process was already terminated and reaped.
    case timedOut(ProcessOutput)
    /// The process was already terminated and reaped.
    case cancelled
}

protocol ProcessRunning: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessOutput
}

struct ProcessRunner: ProcessRunning {
    /// Time between SIGTERM and SIGKILL.
    var killGracePeriod: Duration

    init(killGracePeriod: Duration = .seconds(2)) {
        self.killGracePeriod = killGracePeriod
    }

    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        if Task.isCancelled { throw ProcessRunnerError.cancelled }

        let job = ProcessJob(grace: killGracePeriod)
        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.currentDirectory

        var fds: [Int32] = []
        func closeAll() { fds.forEach { _ = close($0) } }

        let outPipe: (read: Int32, write: Int32)
        let errPipe: (read: Int32, write: Int32)
        var inPipe: (read: Int32, write: Int32)?
        do {
            outPipe = try Self.makePipe()
            fds += [outPipe.read, outPipe.write]
            errPipe = try Self.makePipe()
            fds += [errPipe.read, errPipe.write]
            if request.stdin != nil {
                let pipe = try Self.makePipe()
                fds += [pipe.read, pipe.write]
                inPipe = pipe
            }
        } catch {
            closeAll()
            throw ProcessRunnerError.launchFailed(String(describing: error))
        }

        process.standardOutput = FileHandle(fileDescriptor: outPipe.write, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: errPipe.write, closeOnDealloc: false)
        if let inPipe {
            process.standardInput = FileHandle(fileDescriptor: inPipe.read, closeOnDealloc: false)
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.terminationHandler = { finished in
            job.markExited(
                status: finished.terminationStatus,
                bySignal: finished.terminationReason == .uncaughtSignal
            )
        }

        do {
            try process.run()
        } catch {
            closeAll()
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        // Parent must drop the child's ends or EOF never arrives.
        _ = close(outPipe.write)
        _ = close(errPipe.write)
        if let inPipe { _ = close(inPipe.read) }

        job.setPid(process.processIdentifier)

        let cap = max(0, request.maxOutputBytes)
        job.startReader(fd: outPipe.read, cap: cap, stream: .stdout)
        job.startReader(fd: errPipe.read, cap: cap, stream: .stderr)
        if let inPipe, let data = request.stdin {
            job.startWriter(fd: inPipe.write, data: data)
        }

        let timeoutSeconds = Self.seconds(request.timeout)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
            job.stop(.timedOut)
        }

        await withTaskCancellationHandler {
            await job.waitForExit()
        } onCancel: {
            job.stop(.cancelled)
        }
        await job.waitForIO()

        let (output, reason) = job.finish()
        switch reason {
        case .timedOut: throw ProcessRunnerError.timedOut(output)
        case .cancelled: throw ProcessRunnerError.cancelled
        case nil: return output
        }
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var pair: [Int32] = [-1, -1]
        guard pipe(&pair) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (pair[0], pair[1])
    }

    fileprivate static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Shared state of one run: exit bookkeeping, captured streams and the
/// terminate/kill escalation. Everything mutable lives behind one lock, and
/// the exit continuation is resumed exactly once.
private final class ProcessJob: Sendable {
    enum Stream: Sendable { case stdout, stderr }
    enum StopReason: Sendable { case timedOut, cancelled }

    struct Exit: Sendable {
        var status: Int32
        var bySignal: Bool
        var at: DispatchTime
    }

    struct Capture: Sendable {
        var data = Data()
        var truncated = false
    }

    struct State: Sendable {
        var pid: pid_t = 0
        var exit: Exit?
        var waiter: CheckedContinuation<Void, Never>?
        var reason: StopReason?
        var termSent = false
        var stdout = Capture()
        var stderr = Capture()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let group = DispatchGroup()
    private let grace: Duration

    init(grace: Duration) {
        self.grace = grace
    }

    // MARK: Lifecycle

    func setPid(_ pid: pid_t) {
        let pending = state.withLock { s -> Bool in
            s.pid = pid
            return s.reason != nil && s.exit == nil
        }
        if pending { terminate() }
    }

    func markExited(status: Int32, bySignal: Bool) {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.exit = Exit(status: status, bySignal: bySignal, at: .now())
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume()
    }

    func stop(_ reason: StopReason) {
        let launched = state.withLock { s -> Bool in
            guard s.exit == nil else { return false }
            if s.reason == nil { s.reason = reason }
            return s.pid > 0
        }
        if launched { terminate() }
    }

    private func terminate() {
        let sent = state.withLock { s -> Bool in
            guard s.exit == nil, s.pid > 0, !s.termSent else { return false }
            s.termSent = true
            kill(s.pid, SIGTERM)
            return true
        }
        guard sent else { return }
        let delay = ProcessRunner.seconds(grace)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
            state.withLock { s in
                if s.exit == nil, s.pid > 0 { kill(s.pid, SIGKILL) }
            }
        }
    }

    func waitForExit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyExited = state.withLock { s -> Bool in
                if s.exit != nil { return true }
                s.waiter = continuation
                return false
            }
            if alreadyExited { continuation.resume() }
        }
    }

    func waitForIO() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
    }

    func finish() -> (ProcessOutput, StopReason?) {
        state.withLock { s in
            let exit = s.exit
            let output = ProcessOutput(
                exitStatus: exit?.status ?? -1,
                terminatedBySignal: exit?.bySignal ?? false,
                stdout: s.stdout.data,
                stderr: s.stderr.data,
                stdoutTruncated: s.stdout.truncated,
                stderrTruncated: s.stderr.truncated
            )
            return (output, s.reason)
        }
    }

    // MARK: I/O threads

    func startReader(fd: Int32, cap: Int, stream: Stream) {
        group.enter()
        Thread.detachNewThread { [self] in
            let capture = drain(fd: fd, cap: cap)
            _ = close(fd)
            state.withLock { s in
                switch stream {
                case .stdout: s.stdout = capture
                case .stderr: s.stderr = capture
                }
            }
            group.leave()
        }
    }

    /// Reads until EOF, keeping at most `cap` bytes. Once the child has
    /// exited, stops when the pipe goes idle (or after a short deadline) so a
    /// grandchild holding the pipe open cannot block the caller.
    private func drain(fd: Int32, cap: Int) -> Capture {
        var capture = Capture()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 50)
            let exit = state.withLock { $0.exit }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                if exit != nil { break }
                continue
            }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
            if count == 0 { break }
            let room = max(0, cap - capture.data.count)
            let keep = min(room, count)
            if keep > 0 { capture.data.append(contentsOf: buffer[0..<keep]) }
            if keep < count { capture.truncated = true }
            if let exit, DispatchTime.now() > exit.at + .seconds(2) { break }
        }
        return capture
    }

    func startWriter(fd: Int32, data: Data) {
        group.enter()
        Thread.detachNewThread { [group] in
            // A child that never reads must surface as EPIPE, not SIGPIPE.
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        break  // EPIPE or any other error: child is gone or done.
                    }
                    offset += written
                }
            }
            _ = close(fd)
            group.leave()
        }
    }
}
