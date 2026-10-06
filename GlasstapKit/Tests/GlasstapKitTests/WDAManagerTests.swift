import Foundation
import os
import Testing
@testable import GlasstapKit

/// A clock that moves only when the test calls `advance(by:)`.
final class ManualClock: WDAClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Duration = .zero
        var sleepers: [Sleeper] = []
        var cancelled: Set<UUID> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: Duration { state.withLock { $0.now } }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let early: Result<Void, any Error>? = state.withLock { s in
                    if s.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    s.sleepers.append(Sleeper(id: id, deadline: s.now + duration, continuation: continuation))
                    return nil
                }
                if let early { continuation.resume(with: early) }
            }
        } onCancel: {
            let sleeper: Sleeper? = state.withLock { s in
                guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else {
                    s.cancelled.insert(id)
                    return nil
                }
                return s.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due: [Sleeper] = state.withLock { s in
            s.now += duration
            let due = s.sleepers.filter { $0.deadline <= s.now }
            s.sleepers.removeAll { $0.deadline <= s.now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }
}

final class FakeProcess: WDAProcess, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let sink: AsyncStream<String>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: (status: Int32?.none, terminated: false))

    init() {
        (lines, sink) = AsyncStream.makeStream(of: String.self)
    }

    var wasTerminated: Bool { state.withLock { $0.terminated } }

    func emit(_ line: String) {
        sink.yield(line)
    }

    func exit(_ status: Int32) {
        state.withLock { $0.status = status }
        sink.finish()
    }

    func exitStatus() async -> Int32 {
        state.withLock { $0.status } ?? -1
    }

    func terminate() async {
        state.withLock { s in
            s.terminated = true
            if s.status == nil { s.status = 143 }
        }
        sink.finish()
    }
}

final class FakeHost: WDAHost, @unchecked Sendable {
    struct State {
        var sourceInstalled = true
        var downloads = 0
        var builds: [WDABuild] = []
        var cachedKeys: Set<String> = []
        var removedKeys: [String] = []
        var buildFailure: WDABuildFailure?
        var processes: [FakeProcess] = []
        /// Set if a run started while an earlier one had not been stopped.
        var overlappingRuns = false
        var healthy = true
        var address = "fd00:1111:2222::1"
        var osVersion = "26.5"
        /// While set, `deviceDetails` waits.
        var holdDetails = false
        var detailsCalls = 0
        var launchedUDIDs: [String] = []
    }

    let state = OSAllocatedUnfairLock(initialState: State())
    let source = URL(fileURLWithPath: "/fake/WebDriverAgent")

    var processes: [FakeProcess] { state.withLock { $0.processes } }
    var builds: [WDABuild] { state.withLock { $0.builds } }

    let wdaVersion = "16.12.10"

    func installedSource() -> URL? {
        state.withLock { $0.sourceInstalled } ? source : nil
    }

    func downloadSource() async throws -> URL {
        state.withLock { s in
            s.downloads += 1
            s.sourceInstalled = true
        }
        return source
    }

    func deviceDetails(udid: String) async throws -> CoreDevice {
        state.withLock { $0.detailsCalls += 1 }
        while state.withLock({ $0.holdDetails }) { await ChildProcess.pause(.milliseconds(1)) }
        return state.withLock { s in
            CoreDevice(udid: udid, name: "Test iPhone", isPhysical: true, tunnelState: "connected",
                       developerModeStatus: "enabled", osVersion: s.osVersion,
                       tunnelIPAddress: s.address)
        }
    }

    func cachedTestRun(for build: WDABuild) -> URL? {
        state.withLock { $0.cachedKeys.contains(build.cacheKey) } ? URL(fileURLWithPath: "/fake/\(build.cacheKey).xctestrun") : nil
    }

    func build(_ build: WDABuild, source: URL, udid: String) async throws -> URL {
        try state.withLock { s in
            s.builds.append(build)
            if let failure = s.buildFailure { throw failure }
            s.cachedKeys.insert(build.cacheKey)
        }
        return URL(fileURLWithPath: "/fake/\(build.cacheKey).xctestrun")
    }

    func removeBuild(_ build: WDABuild) {
        state.withLock { s in
            s.cachedKeys.remove(build.cacheKey)
            s.removedKeys.append(build.cacheKey)
        }
    }

    func launch(testRun: URL, udid: String) async throws -> any WDAProcess {
        let process = FakeProcess()
        state.withLock { s in
            if s.processes.contains(where: { !$0.wasTerminated }) { s.overlappingRuns = true }
            s.processes.append(process)
            s.launchedUDIDs.append(udid)
        }
        return process
    }

    func isHealthy(_ baseURL: URL) async -> Bool {
        state.withLock { $0.healthy }
    }
}

/// Polls until the condition holds. The manager runs on its own tasks, so its states arrive a little later.
func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

@Suite struct RestartBackoffTests {
    @Test func doublesUpToFiveMinutes() {
        var backoff = RestartBackoff()
        let delays = (0..<11).map { _ in backoff.next().components.seconds }
        #expect(delays == [2, 4, 8, 16, 32, 64, 128, 256, 300, 300, 300])
        backoff.reset()
        #expect(backoff.next() == .seconds(2))
    }

    @Test func manyFailuresDoNotOverflow() {
        var backoff = RestartBackoff()
        for _ in 0..<1000 { _ = backoff.next() }
        #expect(backoff.next() == .seconds(300))
    }
}

@Suite struct WDAManagerTests {
    let ready = "2026-10-06 10:12:22.579455+0300 WebDriverAgentRunner-Runner[8826:3164416] ServerURLHere->http://192.0.2.10:8100<-ServerURLHere"
    let signing = WDASigning(teamID: "ABCDE12345", bundlePrefix: "glasstap.wda.abcde12345")
    var target: WDATarget { WDATarget(udid: "00008101-000A1B2C3D4E5F60", signing: signing) }

    struct Rig {
        let host = FakeHost()
        let clock = ManualClock()
        let manager: WDAManager

        init() {
            manager = WDAManager(host: host, clock: clock)
        }

        func state() async -> WDAState { await manager.status.state }

        func waitFor(_ state: WDAState) async -> Bool {
            await eventually { await self.state() == state }
        }

        func waitForProcess(_ count: Int) async -> FakeProcess? {
            guard await eventually({ host.processes.count == count }) else { return nil }
            return host.processes.last
        }

        /// Waits until the manager sleeps, then moves the clock, so that no wake-up is missed.
        func advance(by duration: Duration) async {
            #expect(await eventually { clock.sleeperCount > 0 })
            clock.advance(by: duration)
        }

        /// Starts a run and brings it to `running`.
        func startRunning(_ target: WDATarget, ready: String, processNumber: Int = 1) async throws -> FakeProcess {
            let process = try #require(await waitForProcess(processNumber))
            process.emit(ready)
            #expect(await waitFor(.running))
            return process
        }
    }

    @Test func firstRunDownloadsBuildsStartsAndReportsTheTunnelAddress() async throws {
        let rig = Rig()
        rig.host.state.withLock { $0.sourceInstalled = false }
        let updates = await rig.manager.subscribe()
        rig.manager.setTarget(target)
        await rig.manager.commandsDone()
        let process = try await rig.startRunning(target, ready: ready)

        var states: [WDAState] = []
        for await status in updates {
            states.append(status.state)
            if status.state == .running { break }
        }
        #expect(states == [.notConfigured, .downloading, .building, .starting, .running])
        // The start reuses the tunnel address of the lookup before the build.
        #expect(rig.host.state.withLock { $0.detailsCalls } == 1)
        #expect(rig.manager.baseURL?.absoluteString == "http://[fd00:1111:2222::1]:8100")
        let status = await rig.manager.status
        #expect(status.baseURL?.absoluteString == "http://[fd00:1111:2222::1]:8100")
        #expect(rig.host.state.withLock { $0.downloads } == 1)
        #expect(rig.host.builds == [WDABuild(wdaVersion: "16.12.10", signing: signing, iOSMajorVersion: 26)])
        #expect(!process.wasTerminated)
    }

    @Test func aCachedBuildIsNotBuiltAgain() async throws {
        let rig = Rig()
        rig.manager.setTarget(target)
        await rig.manager.commandsDone()
        _ = try await rig.startRunning(target, ready: ready)
        rig.manager.restart()
        await rig.manager.commandsDone()
        _ = try await rig.startRunning(target, ready: ready, processNumber: 2)
        #expect(rig.host.builds.count == 1)
        // A new iOS major version needs a new build.
        rig.host.state.withLock { $0.osVersion = "27.0" }
        rig.manager.restart()
        await rig.manager.commandsDone()
        _ = try await rig.startRunning(target, ready: ready, processNumber: 3)
        #expect(rig.host.builds.map(\.iOSMajorVersion) == [26, 27])
    }

    @Test func threeFailedChecksRestartWithAGrowingWait() async throws {
        let rig = Rig()
        rig.manager.setTarget(target)
        await rig.manager.commandsDone()
        let first = try await rig.startRunning(target, ready: ready)

        rig.host.state.withLock { $0.healthy = false }
        await rig.advance(by: .seconds(5))
        await rig.advance(by: .seconds(5))
        #expect(await rig.state() == .running)
        await rig.advance(by: .seconds(5))
        #expect(await rig.waitFor(.restarting(in: .seconds(2))))
        #expect(first.wasTerminated)
        #expect(await rig.manager.status.lastError == "WDA stopped answering.")
        #expect(await rig.manager.status.baseURL == nil)

        rig.host.state.withLock { $0.healthy = true }
        await rig.advance(by: .seconds(2))
        let second = try await rig.startRunning(target, ready: ready, processNumber: 2)
        #expect(await rig.manager.status.lastError == nil)

        // The child ends: the next wait is longer.
        second.exit(65)
        #expect(await rig.waitFor(.restarting(in: .seconds(4))))
        #expect(await rig.manager.status.lastError == "xcodebuild ended with status 65.")
        #expect(!rig.host.state.withLock { $0.overlappingRuns })
    }

    @Test func sixtySecondsOfHealthResetTheWait() async throws {
        let rig = Rig()
        rig.manager.setTarget(target)
        await rig.manager.commandsDone()
        let first = try await rig.startRunning(target, ready: ready)
        first.exit(1)
        #expect(await rig.waitFor(.restarting(in: .seconds(2))))
        await rig.advance(by: .seconds(2))
        let second = try await rig.startRunning(target, ready: ready, processNumber: 2)
        for _ in 0..<12 { await rig.advance(by: .seconds(5)) }
        // Wait until the twelfth check has been handled before the child ends.
        #expect(await eventually { rig.clock.sleeperCount > 0 })
        second.exit(1)
        #expect(await rig.waitFor(.restarting(in: .seconds(2))))
    }

    @Test func aShortRunDoesNotResetTheWait() async throws {
        let rig = Rig()
        rig.manager.setTarget(target)
        await rig.manager.commandsDone()
        try await rig.startRunning(target, ready: ready).exit(1)
        #expect(await rig.waitFor(.restarting(in: .seconds(2))))
        await rig.advance(by: .seconds(2))
        let second = try await rig.startRunning(target, ready: ready, processNumber: 2)
        for _ in 0..<11 { await rig.advance(by: .seconds(5)) }
        #expect(await eventually { rig.clock.sleeperCount > 0 })
        second.exit(1)
        #expect(await rig.waitFor(.restarting(in: .seconds(4))))
    }

    @Test func noServerURLWithinTheTimeoutRestarts() async throws {
        let rig = Rig()
        rig.manager.setTarget(target)
        await rig.manager.commandsDone()
        let process = try #require(await rig.waitForProcess(1))
        process.emit("Testing started")
        // The line reaches the manager on another task.
        try await Task.sleep(for: .milliseconds(50))
        await rig.advance(by: WDAManager.startTimeout)
        #expect(await rig.waitFor(.restarting(in: .seconds(2))))
        #expect(process.wasTerminated)
        #expect(await rig.manager.status.lastLines == ["Testing started"])
    }

    @Test func aSigningErrorAtStartRebuildsOnceThenFails() async throws {
        let rig = Rig()
        rig.manager.setTarget(target)
        await rig.manager.commandsDone()
        let line = WDABuildTests.syntheticSigningErrors[6]
        let first = try #require(await rig.waitForProcess(1))
        first.emit(line)
        first.exit(65)
        // The rebuild starts at once, with no wait.
        let second = try #require(await rig.waitForProcess(2))
        #expect(rig.host.builds.count == 2)
        #expect(rig.host.state.withLock { $0.removedKeys.count } == 1)
        second.emit(line)
        second.exit(65)
        #expect(await rig.waitFor(.failed(XcodebuildOutput.signingHint)))
        #expect(await rig.manager.status.lastLines == [line])
        // A failure waits for the user: no more runs.
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.host.processes.count == 2)

        // Restart WDA tries again.
        rig.manager.restart()
        await rig.manager.commandsDone()
        _ = try await rig.startRunning(target, ready: ready, processNumber: 3)
    }

    @Test func aBuildFailureNeedsTheUser() async throws {
        let rig = Rig()
        rig.host.state.withLock { $0.buildFailure = WDABuildFailure(kind: .other, lines: ["error: something"]) }
        rig.manager.setTarget(target)
        await rig.manager.commandsDone()
        #expect(await rig.waitFor(.failed("The WebDriverAgent build failed.")))
        #expect(await rig.manager.status.lastLines == ["error: something"])
        rig.host.state.withLock { $0.buildFailure = WDABuildFailure(kind: .signing, lines: []) }
        rig.manager.restart()
        await rig.manager.commandsDone()
        #expect(await rig.waitFor(.failed(XcodebuildOutput.signingHint)))
        #expect(rig.host.processes.isEmpty)
    }

    @Test func aBuildThatFailsOnABusyIPhoneIsTriedAgain() async throws {
        let rig = Rig()
        let line = WDABuildTests.syntheticDeviceNotReady[1]
        rig.host.state.withLock { $0.buildFailure = WDABuildFailure(kind: .deviceNotReady, lines: [line]) }
        rig.manager.setTarget(target)
        await rig.manager.commandsDone()
        #expect(await rig.waitFor(.restarting(in: .seconds(2))))
        #expect(await rig.manager.status.lastLines == [line])
        rig.host.state.withLock { $0.buildFailure = nil }
        await rig.advance(by: .seconds(2))
        _ = try await rig.startRunning(target, ready: ready)
        #expect(rig.host.builds.count == 2)
    }

    @Test func aNewTargetStartsWithTheShortestWait() async throws {
        let rig = Rig()
        rig.manager.setTarget(target)
        await rig.manager.commandsDone()
        try await rig.startRunning(target, ready: ready).exit(1)
        #expect(await rig.waitFor(.restarting(in: .seconds(2))))
        await rig.advance(by: .seconds(2))
        try await rig.startRunning(target, ready: ready, processNumber: 2).exit(1)
        #expect(await rig.waitFor(.restarting(in: .seconds(4))))
        var other = target
        other.udid = "00008110-0001A2B3C4D5E6F7"
        rig.manager.setTarget(other)
        await rig.manager.commandsDone()
        try await rig.startRunning(other, ready: ready, processNumber: 3).exit(1)
        #expect(await rig.waitFor(.restarting(in: .seconds(2))))
    }

    @Test func aStopDuringTheDeviceLookupBuildsNothing() async throws {
        let rig = Rig()
        rig.host.state.withLock { $0.holdDetails = true }
        rig.manager.setTarget(target)
        await rig.manager.commandsDone()
        #expect(await eventually { rig.host.state.withLock { $0.detailsCalls } == 1 })
        let stop = Task {
            rig.manager.setTarget(nil)
            await rig.manager.commandsDone()
        }
        // The stop cancels the loop, then waits for it. The lookup ends after the cancel.
        try await Task.sleep(for: .milliseconds(20))
        rig.host.state.withLock { $0.holdDetails = false }
        await stop.value
        #expect(rig.host.builds.isEmpty)
        #expect(rig.host.processes.isEmpty)
        #expect(await rig.state() == .notConfigured)
    }

    @Test func aNewTargetStopsTheOldRunFirst() async throws {
        let rig = Rig()
        rig.manager.setTarget(target)
        await rig.manager.commandsDone()
        let first = try await rig.startRunning(target, ready: ready)
        var other = target
        other.signing.bundlePrefix = "com.example.wda"
        rig.manager.setTarget(other)
        await rig.manager.commandsDone()
        #expect(first.wasTerminated)
        _ = try await rig.startRunning(other, ready: ready, processNumber: 2)
        #expect(!rig.host.state.withLock { $0.overlappingRuns })
        // The same target again changes nothing.
        rig.manager.setTarget(other)
        await rig.manager.commandsDone()
        #expect(rig.host.processes.count == 2)
    }

    @Test func noTargetStopsWDA() async throws {
        let rig = Rig()
        rig.manager.setTarget(target)
        await rig.manager.commandsDone()
        let process = try await rig.startRunning(target, ready: ready)
        rig.manager.setTarget(nil)
        await rig.manager.commandsDone()
        #expect(process.wasTerminated)
        #expect(await rig.state() == .notConfigured)
        #expect(await rig.manager.status.baseURL == nil)
    }

    @Test func stopDuringTheWaitEndsTheLoop() async throws {
        let rig = Rig()
        rig.manager.setTarget(target)
        await rig.manager.commandsDone()
        try await rig.startRunning(target, ready: ready).exit(1)
        #expect(await rig.waitFor(.restarting(in: .seconds(2))))
        await rig.manager.stop()
        #expect(await rig.state() == .notConfigured)
        rig.clock.advance(by: .seconds(10))
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.host.processes.count == 1)
    }

    @Test func refreshAddressFollowsANewTunnelAddress() async throws {
        let rig = Rig()
        rig.manager.setTarget(target)
        await rig.manager.commandsDone()
        _ = try await rig.startRunning(target, ready: ready)
        rig.host.state.withLock { $0.address = "fd00:5555:6666::1" }
        await rig.manager.refreshAddress()
        #expect(await rig.manager.status.baseURL?.absoluteString == "http://[fd00:5555:6666::1]:8100")
    }

    @Test func stopIsFinal() async throws {
        let rig = Rig()
        rig.manager.setTarget(target)
        let process = try await rig.startRunning(target, ready: ready)
        await rig.manager.stop()
        #expect(process.wasTerminated)
        // A call that arrives during the quit must not start WDA again.
        rig.manager.setTarget(target)
        rig.manager.restart()
        await rig.manager.commandsDone()
        #expect(rig.host.processes.count == 1)
        #expect(await rig.state() == .notConfigured)
    }

    @Test func commandsTakeEffectInTheirOrder() async throws {
        let rig = Rig()
        var other = target
        other.udid = "00008110-0001A2B3C4D5E6F7"
        rig.manager.setTarget(target)
        rig.manager.setTarget(nil)
        rig.manager.setTarget(other)
        await rig.manager.commandsDone()
        // The first target may start before the stop arrives, but the last one is the one that stays.
        #expect(await eventually { rig.host.state.withLock { $0.launchedUDIDs.last } == other.udid })
        #expect(rig.host.processes.dropLast().allSatisfy { $0.wasTerminated })
        #expect(!rig.host.state.withLock { $0.overlappingRuns })
    }

    @Test func theUsersOwnWDAIsWatchedButNotStarted() async throws {
        let rig = Rig()
        let url = URL(string: "http://127.0.0.1:8100")!
        rig.manager.setMode(.external(url))
        #expect(await rig.waitFor(.running))
        #expect(rig.manager.baseURL == url)

        rig.host.state.withLock { $0.healthy = false }
        await rig.advance(by: WDAManager.healthInterval)
        await rig.advance(by: WDAManager.healthInterval)
        #expect(await rig.state() == .running)
        await rig.advance(by: WDAManager.healthInterval)
        #expect(await rig.waitFor(.restarting(in: WDAManager.healthInterval)))
        #expect(await rig.manager.status.lastError == "WDA at http://127.0.0.1:8100 does not answer.")
        // The client keeps the URL: the user's WDA may come back at any time.
        #expect(rig.manager.baseURL == url)

        rig.host.state.withLock { $0.healthy = true }
        await rig.advance(by: WDAManager.healthInterval)
        #expect(await rig.waitFor(.running))
        #expect(rig.host.processes.isEmpty)
        #expect(rig.host.builds.isEmpty)

        rig.manager.setMode(.off)
        await rig.manager.commandsDone()
        #expect(await rig.state() == .notConfigured)
        #expect(rig.manager.baseURL == nil)
    }

    @Test func subscribersGetTheCurrentStatusFirst() async throws {
        let rig = Rig()
        rig.manager.setTarget(target)
        _ = try await rig.startRunning(target, ready: ready)
        var iterator = await rig.manager.subscribe().makeAsyncIterator()
        #expect(await iterator.next()?.state == .running)
    }
}
