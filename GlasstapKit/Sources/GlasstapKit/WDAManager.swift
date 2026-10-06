import Foundation
import os

public enum WDAState: Sendable, Equatable {
    /// No iPhone or no team.
    case notConfigured
    case downloading
    case building
    case starting
    case running
    case restarting(in: Duration)
    /// Needs the user: a restart, a new setting or a new device starts again.
    case failed(String)
}

public struct WDAStatus: Sendable, Equatable {
    public var state: WDAState = .notConfigured
    /// Set while the managed WDA runs, and always for the user's own WDA.
    public var baseURL: URL?
    /// Why the last attempt ended, kept until WDA runs again.
    public var lastError: String?
    /// The last output lines of the attempt that failed.
    public var lastLines: [String] = []

    public init() {}
}

/// What WDA the manager looks after.
public enum WDAMode: Sendable, Equatable {
    case off
    /// glasstap builds, starts and watches WDA on this iPhone.
    case managed(WDATarget)
    /// The user runs WDA at this URL (the override). glasstap only checks its health.
    case external(URL)
}

/// The iPhone and the signing that one WDA run needs.
public struct WDATarget: Sendable, Equatable {
    public var udid: String
    public var signing: WDASigning

    public init(udid: String, signing: WDASigning) {
        self.udid = udid
        self.signing = signing
    }
}

/// A running `xcodebuild test-without-building`.
public protocol WDAProcess: Sendable {
    /// The output, line by line. It ends when the process ends.
    var lines: AsyncStream<String> { get }
    func exitStatus() async -> Int32
    /// Stops the process and everything that it started. Returns once all of it has exited.
    /// A cancelled task cannot cut it short, so a stop always gets its grace period.
    func terminate() async
}

/// The side effects of the manager, so that tests can replace them.
public protocol WDAHost: Sendable {
    var wdaVersion: String { get }
    func installedSource() -> URL?
    func downloadSource() async throws -> URL
    func deviceDetails(udid: String) async throws -> CoreDevice
    func cachedTestRun(for build: WDABuild) async -> URL?
    /// Returns the `.xctestrun` file. Throws `WDABuildFailure` when xcodebuild fails.
    func build(_ build: WDABuild, source: URL, udid: String) async throws -> URL
    /// Makes the next build a clean one. Throws only when the task is cancelled.
    func removeBuild(_ build: WDABuild) async throws
    /// Starts the test run. It first stops a test run that an earlier app launch left behind.
    func launch(testRun: URL, udid: String) async throws -> any WDAProcess
    func isHealthy(_ baseURL: URL) async -> Bool
}

public struct WDABuildFailure: Error, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// Needs the user in Xcode > Settings > Accounts.
        case signing
        /// The iPhone was locked, busy or still preparing. A later try can work.
        case deviceNotReady
        /// A compile or configuration error.
        case other
    }

    public let kind: Kind
    public let lines: [String]

    public init(kind: Kind, lines: [String]) {
        self.kind = kind
        self.lines = lines
    }

    public var description: String {
        switch kind {
        case .signing: XcodebuildOutput.signingHint
        case .deviceNotReady: "The iPhone was not ready for the WebDriverAgent build. Unlock it and keep it plugged in."
        case .other: "The WebDriverAgent build failed."
        }
    }
}

/// Time for the manager. Tests drive it by hand.
public protocol WDAClock: Sendable {
    /// The time since a fixed point.
    var now: Duration { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemWDAClock: WDAClock {
    private let start = ContinuousClock.now

    public init() {}

    public var now: Duration { ContinuousClock.now - start }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// The waits between restarts: 2, 4, 8 … seconds, at most 5 minutes.
public struct RestartBackoff: Sendable, Equatable {
    public static let first: Duration = .seconds(2)
    public static let limit: Duration = .seconds(300)
    private var failures = 0

    public init() {}

    public mutating func next() -> Duration {
        // Stop doubling at the limit, so the count cannot overflow.
        let delay = min(Self.first * (1 << min(failures, 16)), Self.limit)
        failures += 1
        return delay
    }

    public mutating func reset() {
        failures = 0
    }
}

/// Builds, starts, watches and restarts WDA for one iPhone, or watches the user's own WDA.
public actor WDAManager {
    public static let startTimeout: Duration = .seconds(180)
    public static let healthInterval: Duration = .seconds(5)
    public static let failedChecksBeforeRestart = 3
    /// After this long in good health, the next restart waits the shortest time again.
    public static let healthyResetAfter: Duration = .seconds(60)
    static let keptLines = 200

    public private(set) var status = WDAStatus()
    private let host: any WDAHost
    private let clock: any WDAClock
    private let log = Logger(subsystem: "io.github.necatisozer.glasstap", category: "wda")
    private let commands: AsyncStream<Command>.Continuation
    /// The base URL of the latest status, for readers that cannot wait for the actor.
    private let latestBaseURL = OSAllocatedUnfairLock<URL?>(initialState: nil)
    private var subscribers: [UUID: AsyncStream<WDAStatus>.Continuation] = [:]
    private var mode = WDAMode.off
    private var isStopped = false
    private var loop: Task<Void, Never>?
    private var backoff = RestartBackoff()

    private enum Command {
        case setMode(WDAMode)
        case restart
        case stop
        /// Resumes when every command before it is done.
        case barrier(CheckedContinuation<Void, Never>)
    }

    public init(host: any WDAHost, clock: any WDAClock = SystemWDAClock()) {
        self.host = host
        self.clock = clock
        let (stream, commands) = AsyncStream.makeStream(of: Command.self)
        self.commands = commands
        // One command at a time, in the order of the calls, so that a stop and a start cannot overlap.
        Task { [weak self] in
            for await command in stream { await self?.handle(command) }
        }
    }

    /// The WDA base URL now. The WDA client reads it for each request.
    public nonisolated var baseURL: URL? { latestBaseURL.withLock { $0 } }

    /// Sets what to look after. A new mode stops the old run first.
    public nonisolated func setMode(_ mode: WDAMode) {
        commands.yield(.setMode(mode))
    }

    public nonisolated func setTarget(_ target: WDATarget?) {
        setMode(target.map(WDAMode.managed) ?? .off)
    }

    /// The user's "Restart WDA". It also starts again after a failure.
    public nonisolated func restart() {
        commands.yield(.restart)
    }

    /// Stops WDA for good, at quit, and returns once its process has exited. Later commands do nothing.
    public nonisolated func stop() async {
        commands.yield(.stop)
        await commandsDone()
    }

    /// Returns when every command given before it is done.
    public nonisolated func commandsDone() async {
        await withCheckedContinuation { commands.yield(.barrier($0)) }
    }

    /// The current status, then every change, in order.
    public func subscribe() -> AsyncStream<WDAStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: WDAStatus.self, bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        continuation.yield(status)
        return stream
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    /// Reads the tunnel address again. It changes when the iPhone is plugged in again.
    public func refreshAddress() async {
        guard status.state == .running, case let .managed(target) = mode, let port = status.baseURL?.port else { return }
        guard let url = await address(udid: target.udid, port: port),
              url != status.baseURL, status.state == .running, mode == .managed(target) else { return }
        log.notice("WDA address changed to \(url.absoluteString, privacy: .public)")
        publish(.running, baseURL: url)
    }

    private func handle(_ command: Command) async {
        switch command {
        case let .barrier(continuation):
            return continuation.resume()
        case _ where isStopped:
            return
        case let .setMode(new):
            guard new != mode else { return }
            mode = new
            // The failures of the old target say nothing about the new one.
            backoff.reset()
        case .restart:
            backoff.reset()
        case .stop:
            mode = .off
            isStopped = true
        }
        // Two test runs on one device conflict, so the old run ends before a new one starts.
        if let loop {
            loop.cancel()
            await loop.value
        }
        loop = nil
        switch mode {
        case .off: publish(.notConfigured)
        case let .managed(target): loop = Task { await self.run(target) }
        case let .external(url): loop = Task { await self.watchExternal(url) }
        }
    }

    // MARK: - The user's own WDA

    /// The same health checks as for the managed WDA, but glasstap cannot restart it.
    private func watchExternal(_ url: URL) async {
        publish(.starting, baseURL: url)
        var failedChecks = 0
        while !Task.isCancelled {
            if await host.isHealthy(url) {
                failedChecks = 0
                if status.state != .running { publish(.running, baseURL: url) }
            } else {
                failedChecks += 1
                if failedChecks >= Self.failedChecksBeforeRestart, status.state == .running || status.state == .starting {
                    let reason = "WDA at \(url.absoluteString) does not answer."
                    publish(.restarting(in: Self.healthInterval), baseURL: url, problem: (reason, []))
                }
            }
            do { try await clock.sleep(for: Self.healthInterval) } catch { return }
        }
    }

    // MARK: - The managed WDA

    private enum Outcome {
        case cancelled
        case rebuild(WDABuild)
        case failed(String, lines: [String])
        case retry(String, lines: [String], wasRunning: Bool)
    }

    private func run(_ target: WDATarget) async {
        var rebuiltForSigning = false
        while !Task.isCancelled {
            let outcome = await attempt(target, mayRebuild: !rebuiltForSigning)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .cancelled:
                return
            case let .rebuild(build):
                log.notice("WDA failed to start with a signing error. Building again.")
                do { try await host.removeBuild(build) } catch { return }
                rebuiltForSigning = true
            case let .failed(reason, lines):
                log.error("WDA failed: \(reason, privacy: .public)")
                return publish(.failed(reason), problem: (reason, lines))
            case let .retry(reason, lines, wasRunning):
                // A profile can expire again later, and then one more rebuild is due.
                if wasRunning { rebuiltForSigning = false }
                let delay = backoff.next()
                log.notice("WDA: \(reason, privacy: .public) Restarting in \(delay, privacy: .public).")
                publish(.restarting(in: delay), problem: (reason, lines))
                do { try await clock.sleep(for: delay) } catch { return }
            }
        }
    }

    private func attempt(_ target: WDATarget, mayRebuild: Bool) async -> Outcome {
        let source: URL
        if let installed = host.installedSource() {
            source = installed
        } else {
            publish(.downloading)
            do {
                source = try await host.downloadSource()
            } catch is CancellationError {
                return .cancelled
            } catch let error as WDASource.InstallError {
                if case .hashMismatch = error { return .failed(error.description, lines: []) }
                return .retry(error.description, lines: [], wasRunning: false)
            } catch {
                return .retry("The WebDriverAgent download failed: \(error.localizedDescription)", lines: [], wasRunning: false)
            }
        }
        guard !Task.isCancelled else { return .cancelled }

        let device: CoreDevice
        do {
            device = try await host.deviceDetails(udid: target.udid)
        } catch {
            guard !Task.isCancelled else { return .cancelled }
            return .retry("devicectl could not read the iPhone: \(error)", lines: [], wasRunning: false)
        }
        // A stop during the lookup must not lead to a build: it would publish a state for an old target.
        guard !Task.isCancelled else { return .cancelled }
        guard let major = device.osMajorVersion else {
            return .retry("devicectl gave no iOS version.", lines: [], wasRunning: false)
        }
        let build = WDABuild(wdaVersion: host.wdaVersion, signing: target.signing, iOSMajorVersion: major)

        let testRun: URL
        if let cached = await host.cachedTestRun(for: build) {
            testRun = cached
        } else {
            publish(.building)
            do {
                testRun = try await host.build(build, source: source, udid: target.udid)
            } catch is CancellationError {
                return .cancelled
            } catch let failure as WDABuildFailure {
                if failure.kind == .deviceNotReady { return .retry(failure.description, lines: failure.lines, wasRunning: false) }
                return .failed(failure.description, lines: failure.lines)
            } catch {
                return .failed("The WebDriverAgent build failed: \(error)", lines: [])
            }
        }
        guard !Task.isCancelled else { return .cancelled }

        publish(.starting)
        let process: any WDAProcess
        do {
            process = try await host.launch(testRun: testRun, udid: target.udid)
        } catch {
            return .retry("xcodebuild did not start: \(error)", lines: [], wasRunning: false)
        }
        let outcome = await watch(process, target: target, tunnelAddress: device.tunnelIPAddress,
                                  build: build, mayRebuild: mayRebuild)
        await process.terminate()
        return outcome
    }

    private enum RunEvent {
        case line(String)
        case exited(Int32)
        case startTimedOut
        case health(Bool)
    }

    /// Follows one run: waits for `ServerURLHere`, then checks `/status` until something fails.
    /// `tunnelAddress` comes from the lookup before the build, so the start needs no second devicectl call.
    private func watch(_ process: any WDAProcess, target: WDATarget, tunnelAddress: String?,
                       build: WDABuild, mayRebuild: Bool) async -> Outcome {
        let (events, eventSink) = AsyncStream.makeStream(of: RunEvent.self)
        let reader = Task {
            for await line in process.lines { eventSink.yield(.line(line)) }
            eventSink.yield(.exited(await process.exitStatus()))
        }
        let timer = Task { [clock] in
            if (try? await clock.sleep(for: Self.startTimeout)) != nil { eventSink.yield(.startTimedOut) }
        }
        var health: Task<Void, Never>?
        defer {
            reader.cancel()
            timer.cancel()
            health?.cancel()
            eventSink.finish()
        }

        var output = XcodebuildScan(keepLines: Self.keptLines)
        var runningSince: Duration?
        var failedChecks = 0
        for await event in events {
            switch event {
            case let .line(line):
                output.consume(line)
                guard runningSince == nil, let ready = XcodebuildOutput.serverURL(in: line) else { continue }
                timer.cancel()
                let port = ready.port ?? 8100
                var url = tunnelAddress.flatMap { Devicectl.wdaURL(tunnelAddress: $0, port: port) }
                if url == nil { url = await address(udid: target.udid, port: port) }
                guard let url else {
                    return .retry("WDA started, but devicectl gave no tunnel address.", lines: output.lines, wasRunning: false)
                }
                guard !Task.isCancelled else { return .cancelled }
                runningSince = clock.now
                log.notice("WDA running at \(url.absoluteString, privacy: .public)")
                publish(.running, baseURL: url)
                health = Task { [clock] in
                    while (try? await clock.sleep(for: Self.healthInterval)) != nil {
                        guard let url = self.status.baseURL else { return }
                        eventSink.yield(.health(await self.host.isHealthy(url)))
                    }
                }
            case let .health(healthy):
                guard let since = runningSince else { continue }
                if healthy {
                    failedChecks = 0
                    if clock.now - since >= Self.healthyResetAfter { backoff.reset() }
                } else {
                    failedChecks += 1
                    if failedChecks >= Self.failedChecksBeforeRestart {
                        return .retry("WDA stopped answering.", lines: output.lines, wasRunning: true)
                    }
                }
            case .startTimedOut:
                guard runningSince == nil else { continue }
                return .retry("WDA did not start within \(Self.startTimeout.components.seconds) s.",
                              lines: output.lines, wasRunning: false)
            case let .exited(code):
                if runningSince == nil && output.sawSigningError {
                    return mayRebuild ? .rebuild(build) : .failed(XcodebuildOutput.signingHint, lines: output.lines)
                }
                let reason = runningSince == nil
                    ? "WDA did not start: xcodebuild ended with status \(code)."
                    : "xcodebuild ended with status \(code)."
                return .retry(reason, lines: output.lines, wasRunning: runningSince != nil)
            }
        }
        return .cancelled
    }

    private func address(udid: String, port: Int) async -> URL? {
        guard let device = try? await host.deviceDetails(udid: udid), let address = device.tunnelIPAddress else { return nil }
        return Devicectl.wdaURL(tunnelAddress: address, port: port)
    }

    private func publish(_ state: WDAState, baseURL: URL? = nil, problem: (String, [String])? = nil) {
        status.state = state
        status.baseURL = baseURL
        if state == .running {
            status.lastError = nil
            status.lastLines = []
        }
        if let (reason, lines) = problem {
            status.lastError = reason
            status.lastLines = lines
        }
        latestBaseURL.withLock { $0 = baseURL }
        for subscriber in subscribers.values { subscriber.yield(status) }
    }
}
