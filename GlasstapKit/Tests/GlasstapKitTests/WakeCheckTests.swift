import Foundation
import os
import Testing
@testable import GlasstapKit

@Suite struct WakeCheckTests {
    final class Probe: @unchecked Sendable {
        let state = OSAllocatedUnfairLock(initialState: (frame: false, presses: 0, hints: [Bool](), springBoard: true))
        var hints: [Bool] { state.withLock { $0.hints } }
        var presses: Int { state.withLock { $0.presses } }
        func frameArrives() { state.withLock { $0.frame = true } }
    }

    func running() -> WDAStatus {
        var status = WDAStatus()
        status.state = .running
        return status
    }

    func start(_ probe: Probe, clock: ManualClock) -> (Task<Void, Never>, AsyncStream<WDAStatus>.Continuation) {
        let (statuses, sink) = AsyncStream.makeStream(of: WDAStatus.self)
        let task = Task {
            await WakeCheck.run(
                statuses: statuses,
                hasFrame: { probe.state.withLock { $0.frame } },
                pressHomeIfSpringBoard: { probe.state.withLock { s in s.presses += 1; return s.springBoard } },
                clock: clock,
                showHint: { show in probe.state.withLock { $0.hints.append(show) } })
        }
        return (task, sink)
    }

    @Test func waitsForWDAThenPressesHomeOnSpringBoard() async throws {
        let probe = Probe()
        let clock = ManualClock()
        let (task, sink) = start(probe, clock: clock)
        sink.yield(WDAStatus())
        try await Task.sleep(for: .milliseconds(20))
        // No WDA yet, so no 4 s count either.
        #expect(clock.sleeperCount == 0)
        sink.yield(running())
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: WakeCheck.delay)
        await task.value
        #expect(probe.presses == 1)
        #expect(probe.hints.isEmpty)
    }

    @Test func inAnAppTheHintShowsUntilAFrameComes() async throws {
        let probe = Probe()
        probe.state.withLock { $0.springBoard = false }
        let clock = ManualClock()
        let (task, sink) = start(probe, clock: clock)
        sink.yield(running())
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: WakeCheck.delay)
        #expect(await eventually { probe.hints == [true] })
        #expect(await eventually { clock.sleeperCount == 1 })
        probe.frameArrives()
        clock.advance(by: WakeCheck.frameInterval)
        await task.value
        #expect(probe.hints == [true, false])
    }

    @Test func aFrameMeansNothingToDo() async throws {
        let probe = Probe()
        let clock = ManualClock()
        let (task, sink) = start(probe, clock: clock)
        sink.yield(running())
        #expect(await eventually { clock.sleeperCount == 1 })
        probe.frameArrives()
        clock.advance(by: WakeCheck.delay)
        await task.value
        #expect(probe.presses == 0)
        #expect(probe.hints.isEmpty)
    }

    @Test func noWDAMeansNoCheck() async {
        let probe = Probe()
        let (task, sink) = start(probe, clock: ManualClock())
        sink.finish()
        await task.value
        #expect(probe.presses == 0)
    }
}

@Suite struct SetupReportTests {
    func problems(xcode: XcodeStatus? = .ready(developerDir: "/X.app/Contents/Developer"), team: String = "ABCDE12345",
                  override: URL? = nil, identity: DeviceIdentity = DeviceIdentity(), now: Duration = .zero,
                  cameraDenied: Bool = false, wda: WDAState = .running) -> [SetupProblem] {
        var settings = GlasstapSettings.defaults
        settings.teamID = team
        settings.wdaURLOverride = override
        return SetupReport.problems(xcode: xcode, settings: settings,
                                    devices: [SetupReport.Device(id: "A", identity: identity, now: now, wda: wda)],
                                    cameraDenied: cameraDenied)
    }

    @Test func eachCheck() {
        #expect(problems().isEmpty)
        #expect(problems(xcode: nil).isEmpty)
        #expect(problems(xcode: .commandLineToolsOnly(developerDir: "/Library/Developer/CommandLineTools")) == [.xcode])
        #expect(problems(team: "") == [.teamID])
        #expect(problems(team: "", override: URL(string: "http://127.0.0.1:8100")).isEmpty)
        #expect(problems(cameraDenied: true) == [.camera])
        #expect(problems(wda: .failed("x")) == [.wda(device: "A", "x")])
        #expect(problems(wda: .waitingForUnlock) == [.wda(device: "A", WDAState.unlockHint)])
        #expect(problems(wda: .restarting(in: .seconds(2))).isEmpty)
        var identity = DeviceIdentity()
        identity.record(.failure(.notPaired), at: .zero)
        #expect(problems(identity: identity, now: .seconds(14)).isEmpty)
        #expect(problems(identity: identity, now: .seconds(15)) == [.iPhone(device: "A", .notPaired)])
    }

    @Test func eachIPhoneHasItsOwnProblems() {
        var settings = GlasstapSettings.defaults
        settings.teamID = "ABCDE12345"
        var unpaired = DeviceIdentity()
        unpaired.record(.failure(.notPaired), at: .zero)
        let devices = [
            SetupReport.Device(id: "A", identity: unpaired, now: .seconds(20), wda: .notConfigured),
            SetupReport.Device(id: "B", identity: unpaired, now: .seconds(20), wda: .failed("x")),
            SetupReport.Device(id: "C", identity: DeviceIdentity(), now: .seconds(20), wda: .failed("x")),
        ]
        // The same problem on two iPhones stays two problems, so the Setup window shows both.
        #expect(SetupReport.problems(xcode: nil, settings: settings, devices: devices, cameraDenied: false) == [
            .iPhone(device: "A", .notPaired), .iPhone(device: "B", .notPaired),
            .wda(device: "B", "x"), .wda(device: "C", "x"),
        ])
    }

    @Test func onlyNewProblemsOpenTheWindow() {
        var tracker = SetupProblemTracker()
        #expect(tracker.newProblems(in: [.teamID]) == [.teamID])
        #expect(tracker.newProblems(in: [.teamID]).isEmpty)
        #expect(tracker.newProblems(in: [.teamID, .wda(device: "A", "a")]) == [.wda(device: "A", "a")])
        // Another reason is another problem.
        #expect(tracker.newProblems(in: [.teamID, .wda(device: "A", "b")]) == [.wda(device: "A", "b")])
        // The same reason on another iPhone too.
        #expect(tracker.newProblems(in: [.teamID, .wda(device: "A", "b"), .wda(device: "B", "b")]) == [.wda(device: "B", "b")])
        #expect(tracker.newProblems(in: []).isEmpty)
        #expect(tracker.newProblems(in: [.teamID]) == [.teamID])
    }
}

@Suite struct LineTailTests {
    @Test func keepsTheLastLinesInOrder() {
        var tail = LineTail(limit: 3)
        #expect(tail.lines.isEmpty)
        for line in ["1", "2"] { tail.append(line) }
        #expect(tail.lines == ["1", "2"])
        for line in ["3", "4", "5", "6", "7"] { tail.append(line) }
        #expect(tail.lines == ["5", "6", "7"])
        var none = LineTail(limit: 0)
        none.append("x")
        #expect(none.lines.isEmpty)
    }
}
