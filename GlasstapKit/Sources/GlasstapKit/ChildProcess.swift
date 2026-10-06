import Darwin
import Foundation
import os

/// A child process in a process group of its own. A stop signals the whole group,
/// because `xcodebuild` starts helpers that stay alive when only `xcodebuild` ends.
public final class ChildProcess: @unchecked Sendable {
    public struct SpawnError: Error, CustomStringConvertible {
        public let description: String
    }

    /// What a finished command printed and how it ended.
    public struct Output: Sendable {
        public let status: Int32
        /// The last lines of stdout and stderr together.
        public let lines: [String]
    }

    /// A command that `run` stopped because it took too long.
    public struct Timeout: Error, CustomStringConvertible {
        public let command: String
        public let limit: Duration

        public var description: String { "\(command) did not finish within \(limit.components.seconds) s" }
    }

    private struct State {
        var status: Int32?
        var exitWaiters: [UUID: CheckedContinuation<Int32?, Never>] = [:]
        var pipeClosed = false
    }

    public let pid: pid_t
    /// stdout and stderr, line by line. It ends at the end of the output, or 2 s after the exit.
    public let lines: AsyncStream<String>
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Both sources wake only for an event, so an idle child costs nothing.
    private let reader: any DispatchSourceRead
    private let exitWatch: any DispatchSourceProcess

    /// Starts `path` with `arguments`. stdin is /dev/null.
    public init(_ path: String, _ arguments: [String], environment extra: [String: String] = [:]) throws {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw SpawnError(description: "pipe: \(String(cString: strerror(errno)))") }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Group 0 makes the child the leader of a new group, so its pid is the group id.
        // CLOEXEC_DEFAULT keeps the app's own sockets and files out of the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        // The app may ignore SIGPIPE, and an ignored signal stays ignored across exec.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        let environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        close(writeEnd)
        guard result == 0 else {
            close(readEnd)
            throw SpawnError(description: "\(path): \(String(cString: strerror(result)))")
        }
        self.pid = pid
        let (stream, sink) = AsyncStream.makeStream(of: String.self)
        lines = stream
        reader = Self.makeReader(readEnd, state: state, sink: sink)
        exitWatch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: Self.exitQueue)
        watchExit()
    }

    /// Runs a command to its end. A cancelled task or a passed `timeout` stops the command.
    /// `onLine` sees every line, also those that `keepLines` drops.
    public static func run(_ path: String, _ arguments: [String], environment: [String: String] = [:],
                           keepLines: Int = 200, timeout: Duration? = nil,
                           onLine: (String) -> Void = { _ in }) async throws -> Output {
        let child = try ChildProcess(path, arguments, environment: environment)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let timer = timeout.map { limit in
            Task.detached {
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                timedOut.withLock { $0 = true }
                await child.terminate()
            }
        }
        defer { timer?.cancel() }
        var tail = LineTail(limit: keepLines)
        for await line in child.lines {
            tail.append(line)
            onLine(line)
        }
        if Task.isCancelled {
            await child.terminate()
            throw CancellationError()
        }
        let status = await child.exitStatus()
        if let timer, let timeout, timedOut.withLock({ $0 }) {
            // The timer has stopped the group. Wait until it is gone.
            await timer.value
            throw Timeout(command: URL(fileURLWithPath: path).lastPathComponent, limit: timeout)
        }
        return Output(status: status, lines: tail.lines)
    }

    /// Waits for the exit. A signal gives 128 + its number, as in a shell.
    public func exitStatus() async -> Int32 {
        // With no timeout, the wait ends only at the exit.
        await waitForExit(timeout: nil) ?? -1
    }

    /// SIGTERM to the group, then SIGKILL after the grace period. Returns once the child has exited
    /// and no process of its group is left, so that a new run never meets an old one.
    /// A cancelled task cannot cut it short: its waits do not end on cancellation.
    public func terminate(grace: Duration = .seconds(5)) async {
        await Self.stopGroup(pid, grace: grace) { limit in await self.waitForExit(timeout: limit) != nil }
        _ = await exitStatus()
        // No process of the group can write any more. A process outside the group may still
        // hold the pipe, so the reader stops here, and no fd or source outlives the run.
        reader.cancel()
    }

    /// SIGTERM to the group, then SIGKILL after `grace`. Returns once no process of the group is left,
    /// or 5 s after SIGKILL. `waitForLeader` waits for the leader's exit by an event, so that the
    /// group is polled only for what remains after the leader. A caller that is not the parent
    /// cannot see that event, and the default polls at once.
    static func stopGroup(_ pgid: pid_t, grace: Duration,
                          waitForLeader: (Duration) async -> Bool = { _ in true }) async {
        let deadline = ContinuousClock.now + grace
        // The group may outlive its leader, so it gets the signal even after the exit.
        kill(-pgid, SIGTERM)
        if await waitForLeader(grace), await waitForGroupEnd(pgid, until: deadline) { return }
        kill(-pgid, SIGKILL)
        _ = await waitForGroupEnd(pgid, until: .now + .seconds(5))
    }

    /// Polls with a growing wait, from 10 ms to 200 ms.
    private static func waitForGroupEnd(_ pgid: pid_t, until deadline: ContinuousClock.Instant) async -> Bool {
        var wait: Duration = .milliseconds(10)
        // EPERM means that a process of the group exists.
        while kill(-pgid, 0) == 0 || errno == EPERM {
            guard ContinuousClock.now < deadline else { return false }
            await pause(min(wait, deadline - .now))
            wait = min(wait * 2, .milliseconds(200))
        }
        return true
    }

    /// A wait that a cancelled task cannot cut short.
    static func pause(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + duration.dispatchInterval) { continuation.resume() }
        }
    }

    /// True once the reader has closed the pipe.
    var isPipeClosed: Bool { state.withLock { $0.pipeClosed } }

    private func waitForExit(timeout: Duration?) async -> Int32? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let status: Int32?? = state.withLock { s in
                if let status = s.status { return .some(status) }
                s.exitWaiters[id] = continuation
                return .none
            }
            if let status { return continuation.resume(returning: status) }
            guard let timeout else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.dispatchInterval) { [state] in
                state.withLock { $0.exitWaiters.removeValue(forKey: id) }?.resume(returning: nil)
            }
        }
    }

    private static let exitQueue = DispatchQueue(label: "glasstap.child-exit")

    /// Reaps the child when the kernel reports its exit.
    private func watchExit() {
        let pid = pid
        let reader = reader
        let exitWatch = exitWatch
        let reap: @Sendable () -> Void = { [state] in
            var raw: Int32 = 0
            guard state.withLock({ $0.status == nil }), waitpid(pid, &raw, WNOHANG) == pid else { return }
            exitWatch.cancel()
            // WIFEXITED and friends are macros that Swift does not import.
            let signal = raw & 0x7f
            let status = signal == 0 ? (raw >> 8) & 0xff : 128 + signal
            let waiters = state.withLock { s in
                s.status = status
                defer { s.exitWaiters = [:] }
                return Array(s.exitWaiters.values)
            }
            waiters.forEach { $0.resume(returning: status) }
            // A helper that inherited the pipe can keep it open after the exit. The output then ends 2 s after the exit.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { reader.cancel() }
        }
        exitWatch.setEventHandler(handler: reap)
        exitWatch.resume()
        // A child that exited before the source was set up gives no event. Its zombie is still there to reap.
        Self.exitQueue.async(execute: reap)
    }

    /// Reads the pipe when it has data, and splits it into lines. Cancelling the source closes the pipe.
    private static func makeReader(_ fd: Int32, state: OSAllocatedUnfairLock<State>,
                                   sink: AsyncStream<String>.Continuation) -> any DispatchSourceRead {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "glasstap.child-output"))
        let splitter = LineSplitter(sink: sink)
        source.setEventHandler { [unowned source] in
            if splitter.readAvailable(fd) == .ended { source.cancel() }
        }
        source.setCancelHandler {
            splitter.finish()
            close(fd)
            state.withLock { $0.pipeClosed = true }
            sink.finish()
        }
        source.resume()
        return source
    }
}

/// The bytes of a pipe, cut into lines. Used only on the reader's queue.
private final class LineSplitter: @unchecked Sendable {
    enum ReadResult { case more, ended }

    private let sink: AsyncStream<String>.Continuation
    private var pending: [UInt8] = []
    private var buffer = [UInt8](repeating: 0, count: 16 * 1024)

    init(sink: AsyncStream<String>.Continuation) {
        self.sink = sink
    }

    /// Reads until the pipe is empty for now, or at its end.
    func readAvailable(_ fd: Int32) -> ReadResult {
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                pending.append(contentsOf: buffer[..<count])
                emitLines()
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN { return .more }
            return .ended
        }
    }

    func finish() {
        if !pending.isEmpty { emit(pending[...]) }
        pending.removeAll()
    }

    /// Removes the consumed bytes once for each chunk, not once for each line.
    private func emitLines() {
        var start = 0
        while let newline = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
            emit(pending[start..<newline])
            start = newline + 1
        }
        // A line with no end must not grow without limit.
        if pending.count - start > 64 * 1024 {
            emit(pending[start...])
            start = pending.count
        }
        pending.removeFirst(start)
    }

    private func emit(_ bytes: ArraySlice<UInt8>) {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        sink.yield(line)
    }
}

extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}

/// The last lines of an output, for error messages. A ring buffer, so an append costs the same at any length.
public struct LineTail: Sendable {
    public let limit: Int
    private var storage: [String] = []
    /// The oldest line, once the buffer is full.
    private var oldest = 0

    public init(limit: Int) {
        self.limit = max(limit, 0)
    }

    public mutating func append(_ line: String) {
        guard limit > 0 else { return }
        if storage.count < limit {
            storage.append(line)
        } else {
            storage[oldest] = line
            oldest = (oldest + 1) % limit
        }
    }

    public var lines: [String] {
        Array(storage[oldest...] + storage[..<oldest])
    }
}
