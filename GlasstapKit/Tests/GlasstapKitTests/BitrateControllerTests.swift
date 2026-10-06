import Foundation
import Testing
@testable import GlasstapKit

extension BitrateController {
    /// A tick with the host-side measurements only, as for a viewer that does not report.
    mutating func tick(backlog: Int, slowestSend: Duration, now: Duration) -> Change? {
        tick(LinkSample(backlog: backlog, slowestSend: slowestSend), now: now)
    }
}

@Suite struct BitrateControllerTests {
    /// Time for the controller. The tests move it by hand.
    struct FakeClock {
        var now: Duration = .seconds(100)
        mutating func advance(_ d: Duration) { now += d }
    }

    let configured = StreamStats(bitrate: 800_000, fps: 30)
    let fast = Duration.milliseconds(20)

    func congested(_ c: inout BitrateController, _ clock: FakeClock) -> BitrateController.Change? {
        c.tick(backlog: 6, slowestSend: fast, now: clock.now)
    }

    func clear(_ c: inout BitrateController, _ clock: FakeClock) -> BitrateController.Change? {
        c.tick(backlog: 0, slowestSend: fast, now: clock.now)
    }

    @Test func aLongBacklogCutsTheBitrate() {
        var c = BitrateController(configured: configured)
        let change = c.tick(backlog: 6, slowestSend: fast, now: FakeClock().now)
        #expect(change?.target == StreamStats(bitrate: 560_000, fps: 30))
        #expect(change?.reason == .congested(backlog: 6, slowestSend: fast))
    }

    @Test func aSlowSendCutsTheBitrate() {
        var c = BitrateController(configured: configured)
        let change = c.tick(backlog: 1, slowestSend: .milliseconds(301), now: FakeClock().now)
        #expect(change?.target.bitrate == 560_000)
    }

    @Test func theLimitsThemselvesAreNotCongestion() {
        var c = BitrateController(configured: configured)
        #expect(c.tick(backlog: 5, slowestSend: .milliseconds(300), now: FakeClock().now) == nil)
        #expect(c.target == configured)
    }

    @Test func oneBurstCutsOnceUntilTheHoldEnds() {
        var c = BitrateController(configured: configured)
        var clock = FakeClock()
        #expect(congested(&c, clock)?.target.bitrate == 560_000)
        clock.advance(.milliseconds(250))
        #expect(congested(&c, clock) == nil)
        clock.advance(.milliseconds(700))
        #expect(congested(&c, clock) == nil)
        #expect(c.target.bitrate == 560_000)
        clock.advance(.milliseconds(50))
        #expect(congested(&c, clock)?.target.bitrate == 392_000)
    }

    @Test func twoClearSecondsRaiseTheBitrateByATenth() {
        var c = BitrateController(configured: configured)
        var clock = FakeClock()
        _ = congested(&c, clock)
        _ = congested(&c, clock)
        clock.advance(.seconds(1))
        _ = congested(&c, clock)
        #expect(c.target.bitrate == 392_000)
        // The clear period starts with the first clear tick.
        clock.advance(.milliseconds(250))
        #expect(clear(&c, clock) == nil)
        clock.advance(.milliseconds(1750))
        #expect(clear(&c, clock) == nil)
        clock.advance(.milliseconds(250))
        let raised = clear(&c, clock)
        #expect(raised?.target.bitrate == 431_200)
        #expect(raised?.reason == .clear)
        // The next raise needs another two clear seconds.
        clock.advance(.milliseconds(1750))
        #expect(clear(&c, clock) == nil)
        clock.advance(.milliseconds(250))
        #expect(clear(&c, clock)?.target.bitrate == 474_320)
    }

    @Test func congestionRestartsTheClearPeriod() {
        var c = BitrateController(configured: configured)
        var clock = FakeClock()
        _ = congested(&c, clock)
        clock.advance(.milliseconds(250))
        _ = clear(&c, clock)
        clock.advance(.milliseconds(500))
        // A slow send inside the hold cuts nothing, but the link was not clear.
        #expect(congested(&c, clock) == nil)
        clock.advance(.milliseconds(250))
        _ = clear(&c, clock)
        clock.advance(.milliseconds(1750))
        #expect(clear(&c, clock) == nil)
        clock.advance(.milliseconds(250))
        #expect(clear(&c, clock)?.target.bitrate == 616_000)
    }

    @Test func theBitrateRisesNoHigherThanTheSettings() {
        var c = BitrateController(configured: configured)
        var clock = FakeClock()
        _ = congested(&c, clock)
        #expect(c.target.bitrate == 560_000)
        var raises: [Int] = []
        for _ in 0..<40 {
            clock.advance(.milliseconds(250))
            if let change = clear(&c, clock) { raises.append(change.target.bitrate) }
        }
        #expect(raises == [616_000, 677_600, 745_360, 800_000])
        #expect(c.target == configured)
    }

    @Test func theLadderHasThreeEvenSizes() {
        let ladder = BitrateController.ladder(width: 590)
        #expect(ladder.map(\.width) == [590, 392, 294])
        #expect(ladder.map(\.floor) == [250_000, 150_000, 75_000])
        #expect(ladder.map(\.keyFrameInterval) == [2, 2, 4])
        // Another width scales the floors with the area.
        #expect(BitrateController.ladder(width: 800).map(\.width) == [800, 532, 400])
        #expect(BitrateController.ladder(width: 800)[0].floor == 460_000)
    }

    @Test func atAFloorTheSizeStepsDown() {
        var c = BitrateController(configured: configured)
        var clock = FakeClock()
        var steps: [String] = []
        for _ in 0..<9 {
            if let change = congested(&c, clock) { steps.append("\(change.target.bitrate / 100) \(change.size.width)") }
            clock.advance(.seconds(1))
        }
        // Each floor ends the cuts at its size. The step down cuts the bitrate too, to no less than the next floor.
        #expect(steps == ["5600 590", "3920 590", "2744 590", "2500 590", "1750 392", "1500 392", "1050 294", "750 294"])
        #expect(c.target.fps == 30)
    }

    @Test func theSizeComesBackOnceTheBitrateReachesItsFloor() {
        var c = BitrateController(configured: configured)
        var clock = FakeClock()
        for _ in 0..<8 {
            _ = congested(&c, clock)
            clock.advance(.seconds(1))
        }
        #expect(c.size.width == 294)
        var changes: [BitrateController.Change] = []
        for _ in 0..<(4 * 120) {
            if let change = clear(&c, clock) { changes.append(change) }
            clock.advance(.milliseconds(250))
        }
        // At 75 kbit/s, 392 px would starve the frames. The bitrate rises first.
        #expect(changes.first?.size.width == 294)
        #expect(changes.first?.target.bitrate == 82_500)
        // Each step up keeps the bitrate, which has reached the larger size's floor.
        for (before, after) in zip(changes, changes.dropFirst()) where after.size.width > before.size.width {
            #expect(after.target.bitrate == before.target.bitrate)
            #expect(after.target.bitrate >= after.size.floor)
        }
        #expect(changes.map(\.size.width).filter { $0 != 294 }.first == 392)
        #expect(c.size.width == 590)
        #expect(c.target == configured)
    }

    @Test func settingsUnderTheFloorAreTheFloor() {
        var c = BitrateController(configured: StreamStats(bitrate: 200_000, fps: 30))
        let change = congested(&c, FakeClock())
        #expect(change?.size.width == 392)
        #expect(change?.target.bitrate == 150_000)
    }

    @Test func atTheSmallestSizeAndFloorCongestionChangesNothing() {
        var c = BitrateController(configured: StreamStats(bitrate: 75_000, fps: 30))
        var clock = FakeClock()
        #expect(congested(&c, clock)?.size.width == 392)
        clock.advance(.seconds(1))
        #expect(congested(&c, clock)?.size.width == 294)
        clock.advance(.seconds(1))
        #expect(congested(&c, clock) == nil)
        #expect(c.target == StreamStats(bitrate: 75_000, fps: 30))
    }

    @Test func resetGoesBackToTheSettings() {
        var c = BitrateController(configured: configured)
        var clock = FakeClock()
        #expect(c.reset() == nil)
        _ = congested(&c, clock)
        let change = c.reset()
        #expect(change?.target == configured)
        #expect(change?.reason == .noViewer)
        // The hold ends with the viewer: a new viewer's first congestion cuts at once.
        clock.advance(.milliseconds(250))
        #expect(congested(&c, clock)?.target.bitrate == 560_000)
    }

    @Test func reasonsReadWell() {
        #expect(BitrateController.Reason.congested(backlog: 7, slowestSend: .milliseconds(420)).description
            == "congested: 7 messages waiting, slowest send 420 ms")
        #expect(BitrateController.Reason.clear.description == "link clear for 2000 ms")
    }
}

/// The rules with a fresh report from the viewer. At 800 kbit/s, one second is 100 KB.
@Suite struct ViewerFeedbackRuleTests {
    let configured = StreamStats(bitrate: 800_000, fps: 30)

    func tick(_ c: inout BitrateController, queue: Int, growth: Int = 0, keyFrame: Int = 0, backlog: Int = 0,
              at now: Duration = .seconds(10)) -> BitrateController.Change? {
        let feedback = ViewerFeedback(queue: queue, growth: growth, keyFrame: keyFrame)
        return c.tick(LinkSample(backlog: backlog, slowestSend: .zero, feedback: feedback), now: now)
    }

    @Test func aQueueOfMoreThanOneSecondCuts() {
        var c = BitrateController(configured: configured)
        #expect(tick(&c, queue: 100_000) == nil)
        let change = tick(&c, queue: 100_001)
        #expect(change?.target.bitrate == 560_000)
        #expect(change?.reason == .queued(bytes: 100_001, growing: false))
    }

    @Test func onlyAMeaningfulGrowthAboveHalfASecondCuts() {
        var c = BitrateController(configured: configured)
        // Growth must be more than 16 KB (0.15 s is 15 KB here), the queue more than 0.5 s.
        #expect(tick(&c, queue: 50_001, growth: 16 * 1024) == nil)
        #expect(tick(&c, queue: 50_000, growth: 40_000) == nil)
        #expect(tick(&c, queue: 50_001, growth: 16 * 1024 + 1)?.reason == .queued(bytes: 50_001, growing: true))
    }

    @Test func aShrinkingQueueIsNotCutAgain() {
        var c = BitrateController(configured: configured)
        #expect(tick(&c, queue: 300_000, growth: -1) == nil)
        #expect(c.target == configured)
        #expect(tick(&c, queue: 300_000, growth: 0)?.target.bitrate == 560_000)
    }

    @Test func oneKeyFrameFitsUnderEveryThreshold() {
        // At the floor, one second is a few KB, and a key frame is more than that.
        var c = BitrateController(configured: StreamStats(bitrate: 150_000, fps: 30))
        _ = tick(&c, queue: 100_000, at: .seconds(9))
        #expect(c.size.width == 392)
        let key = 40_000
        // The key frame just went out: the queue jumps by its size. It is not congestion.
        #expect(tick(&c, queue: key, growth: key, keyFrame: key, at: .seconds(10)) == nil)
        // Nor does it stop the clear count, which started with it.
        #expect(tick(&c, queue: key + 2_000, growth: 2_000, keyFrame: key, at: .seconds(11)) == nil)
        #expect(tick(&c, queue: 3_000, growth: -key, keyFrame: key, at: .seconds(12))?.reason == .clear)
        #expect(c.size.width == 590)
        // A queue of more than a key frame and a second still cuts.
        #expect(tick(&c, queue: 65_536 + 1, keyFrame: key, at: .seconds(13))?.size.width == 392)
    }

    @Test func theFloorsHoldAtALowBitrate() {
        var c = BitrateController(configured: StreamStats(bitrate: 150_000, fps: 30))
        #expect(tick(&c, queue: 64 * 1024) == nil)
        #expect(tick(&c, queue: 32 * 1024, growth: 20_000) == nil)
        #expect(tick(&c, queue: 32 * 1024 + 1, growth: 20_000)?.size.width == 392)
    }

    @Test func clearIsAQuarterSecondAboveOneKeyFrame() {
        var c = BitrateController(configured: configured)
        _ = tick(&c, queue: 200_000)
        #expect(c.target.bitrate == 560_000)
        // A quarter second at 560 kbit/s is 17 500 bytes, above the floor of 16 KB.
        #expect(tick(&c, queue: 17_499, at: .seconds(11)) == nil)
        // Between clear and congested: no raise, and the clear period starts again.
        #expect(tick(&c, queue: 17_500, at: .milliseconds(12_900)) == nil)
        #expect(tick(&c, queue: 17_499, at: .seconds(13)) == nil)
        #expect(tick(&c, queue: 17_499, at: .milliseconds(14_900)) == nil)
        #expect(tick(&c, queue: 17_499, at: .seconds(15))?.reason == .clear)
        // A key frame in flight leaves room for its own size.
        #expect(tick(&c, queue: 50_000, keyFrame: 40_000, at: .seconds(16)) == nil)
        #expect(tick(&c, queue: 50_000, keyFrame: 40_000, at: .seconds(17))?.reason == .clear)
    }

    @Test func freshFeedbackOverridesTheHostSideSignal() {
        var c = BitrateController(configured: configured)
        // The host's backlog says congested, but the viewer has everything.
        #expect(tick(&c, queue: 0, backlog: 9) == nil)
        #expect(c.target == configured)
    }

    @Test func withoutFeedbackTheHostSideSignalDecides() {
        var c = BitrateController(configured: configured)
        let change = c.tick(LinkSample(backlog: 9, slowestSend: .zero, feedback: nil), now: .seconds(10))
        #expect(change?.reason == .congested(backlog: 9, slowestSend: .zero))
    }

    @Test func aNewViewerStartsFromTheSettings() {
        var c = BitrateController(configured: configured)
        _ = tick(&c, queue: 200_000)
        let change = c.reset(.newViewer)
        #expect(change?.target == configured)
        #expect(change?.reason == .newViewer)
        // The hold of the viewer before is gone.
        #expect(tick(&c, queue: 200_000, at: .milliseconds(10_250))?.target.bitrate == 560_000)
    }

    @Test func reasonsReadWell() {
        #expect(BitrateController.Reason.queued(bytes: 120_000, growing: true).description
            == "congested: 120 KB queued for the viewer and growing")
        #expect(BitrateController.Reason.newViewer.description == "new viewer")
    }
}

@Suite struct LinkFeedbackTests {
    @Test func theQueueIsWhatIsInFlightAboveTheBaseline() {
        var f = LinkFeedback()
        #expect(f.sample(at: .seconds(1)) == nil)
        // 40 KB in flight: the pipe of this path.
        f.add(sent: 70_000)
        f.report(received: 30_000, at: .seconds(1))
        #expect(f.sample(at: .seconds(1))?.queue == 0)
        // 60 KB in flight: 20 KB above the pipe.
        f.add(sent: 50_000)
        f.report(received: 60_000, at: .milliseconds(1250))
        #expect(f.sample(at: .milliseconds(1250))?.queue == 20_000)
        // A report beyond the bytes sent counts as nothing in flight.
        f.report(received: 200_000, at: .milliseconds(1500))
        #expect(f.sample(at: .milliseconds(1500))?.queue == 0)
    }

    @Test func theBaselineRisesWhenItsLowPointIsTenSecondsOld() {
        var f = LinkFeedback()
        f.add(sent: 10_000)
        f.report(received: 10_000, at: .seconds(0))
        // From now on, the path holds 30 KB.
        f.add(sent: 30_000)
        for t in 1...10 {
            f.report(received: 10_000, at: .seconds(t))
            #expect(f.sample(at: .seconds(t))?.queue == 30_000)
        }
        f.report(received: 10_000, at: .milliseconds(10_001))
        #expect(f.sample(at: .milliseconds(10_001))?.queue == 0)
    }

    @Test func aReportOlderThanOneSecondIsNoFeedback() {
        var f = LinkFeedback()
        f.add(sent: 10_000)
        f.report(received: 0, at: .seconds(1))
        #expect(f.sample(at: .seconds(2)) != nil)
        #expect(f.sample(at: .milliseconds(2001)) == nil)
    }

    @Test func growthComparesWithAReportOneSecondOlder() {
        var f = LinkFeedback()
        // 20 KB a tick goes out, 10 KB a tick arrives: in flight grows by 10 KB a tick.
        for tick in 0..<6 {
            f.add(sent: 20_000)
            f.report(received: tick * 10_000, at: .milliseconds(250 * tick))
            // The first second has no older report to compare with.
            #expect(f.sample(at: .milliseconds(250 * tick))?.growth == (tick >= 4 ? 40_000 : 0))
        }
        // Nothing more goes out, and the viewer catches up: in flight falls.
        f.report(received: 120_000, at: .milliseconds(2250))
        #expect(f.sample(at: .milliseconds(2250))?.growth == -70_000)
    }

    @Test func theLargestRecentKeyFrameCounts() {
        var f = LinkFeedback()
        f.add(keyFrame: 50_000, at: .seconds(0))
        f.add(keyFrame: 30_000, at: .seconds(5))
        f.report(received: 0, at: .seconds(5))
        #expect(f.sample(at: .seconds(5))?.keyFrame == 50_000)
        f.add(keyFrame: 20_000, at: .milliseconds(10_001))
        f.report(received: 0, at: .milliseconds(10_001))
        #expect(f.sample(at: .milliseconds(10_001))?.keyFrame == 30_000)
    }
}

/// The host-side measurement, from each viewer's own queue of sends.
@Suite struct HostSideSampleTests {
    let delta = StreamMessage.encode(.deltaFrame, Data([0, 0, 0, 1, 0x02]))
    let key = StreamMessage.encode(.keyFrame, Data([0, 0, 0, 1, 0x40]))
    let config = StreamConfig(codec: CodecString.hevc, width: 590, height: 1278)

    @Test func noViewerIsNoSample() {
        var s = ViewerState<Int>()
        let sample = s.takeSample(at: .seconds(1))
        #expect(sample == nil)
    }

    @Test func aSendTakesFromEnqueueToCompletion() {
        var s = ViewerState<Int>()
        _ = s.join(1)
        _ = s.frame(key, key: true, config: config, at: .milliseconds(1000))
        s.sent(1, at: .milliseconds(1050))
        s.sent(1, at: .milliseconds(1400))
        let sample = s.takeSample(at: .milliseconds(1500))
        #expect(sample == LinkSample(backlog: 0, slowestSend: .milliseconds(400)))
        // Each sample starts again.
        let sample2 = s.takeSample(at: .milliseconds(1750))
        #expect(sample2 == LinkSample(backlog: 0, slowestSend: .zero))
    }

    @Test func aSendThatStillWaitsCountsWithItsAge() {
        var s = ViewerState<Int>()
        _ = s.join(1)
        _ = s.frame(key, key: true, config: config, at: .milliseconds(1000))
        let sample = s.takeSample(at: .milliseconds(1400))
        #expect(sample == LinkSample(backlog: 2, slowestSend: .milliseconds(400)))
        s.sent(1, at: .milliseconds(1500))
        s.sent(1, at: .milliseconds(1700))
        let sample2 = s.takeSample(at: .milliseconds(1950))
        #expect(sample2 == LinkSample(backlog: 0, slowestSend: .milliseconds(700)))
    }

    @Test func aFreshReportReplacesTheHostSideSignal() {
        var s = ViewerState<Int>()
        _ = s.join(1, session: "abc")
        _ = s.frame(key, key: true, config: config, at: .milliseconds(1000))
        let accepted = s.report(session: "abc", received: 0, at: .milliseconds(1100))
        #expect(accepted)
        let accepted2 = s.report(session: "other", received: 0, at: .milliseconds(1100))
        #expect(!accepted2)
        let sample = s.takeSample(at: .milliseconds(1200))
        #expect(sample?.feedback != nil)
        #expect(sample?.backlog == 0)
        // Without a fresh report, the host-side signal is back.
        let sample2 = s.takeSample(at: .milliseconds(2200))
        #expect(sample2?.backlog == 2)
    }
}

@Suite struct KeyFrameRetryTests {
    @Test func theWaitsDoubleToTwoSeconds() {
        #expect((1...6).map { CaptureEngine.keyRetryDelay(afterDrops: $0) }
            == [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(2), .seconds(2)])
    }
}
