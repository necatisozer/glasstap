import Foundation
import Testing
@testable import GlasstapKit

@Suite struct ViewerStateTests {
    let config = StreamConfig(codec: CodecString.hevc, width: 590, height: 1278)
    let key = StreamMessage.encode(.keyFrame, Data([0, 0, 0, 1, 0x40]))
    let delta = StreamMessage.encode(.deltaFrame, Data([0, 0, 0, 1, 0x02]))

    func types(_ messages: [Data]) -> [UInt8] { messages.map { $0[$0.startIndex + 4] } }

    @Test func newestViewerReplacesTheOldOne() {
        var s = ViewerState<Int>()
        let replacedByFirst = s.join(1)
        #expect(replacedByFirst.isEmpty)
        _ = s.frame(key, key: true, config: config)
        #expect(!s.wantKeyFrame)
        let replacedBySecond = s.join(2)
        #expect(replacedBySecond == [1])
        #expect(s.count == 1)
        #expect(!s.contains(1))
        #expect(s.contains(2))
        // A new viewer asks for a key frame.
        #expect(s.wantKeyFrame)
        // The old viewer gets nothing more.
        let out = s.frame(key, key: true, config: config)
        #expect(out.map(\.id) == [2])
        #expect(!s.wantKeyFrame)
    }

    @Test func theRequestStaysUntilAKeyFrameGoesOut() {
        var s = ViewerState<Int>()
        _ = s.join(1)
        // The encoder was asked for a key frame but dropped it, and only deltas came.
        for _ in 0..<3 {
            let out = s.frame(delta, key: false)
            #expect(out.isEmpty)
            #expect(s.wantKeyFrame)
        }
        let out = s.frame(key, key: true, config: config)
        #expect(types(out[0].messages) == [0, 1])
        #expect(!s.wantKeyFrame)
    }

    @Test func replacedMessageIsTypeThree() {
        var buffer = StreamMessage.encode(.replaced)
        let messages = StreamMessage.decode(&buffer)
        #expect(messages.map(\.type) == [StreamMessageType.replaced.rawValue])
    }

    @Test func configComesBeforeTheFirstKeyFrame() {
        var s = ViewerState<Int>()
        _ = s.join(1)
        // A delta frame before any key frame goes nowhere.
        let early = s.frame(delta, key: false)
        #expect(early.isEmpty)
        let first = s.frame(key, key: true, config: config)
        #expect(first.count == 1)
        #expect(types(first[0].messages) == [0, 1])
        #expect(first[0].messages[0].dropFirst(5) == config.json)
        #expect(first[0].messages[1] == key)
        // After that, frames go out without a config.
        let next = s.frame(delta, key: false)
        #expect(types(next[0].messages) == [2])
        let nextKey = s.frame(key, key: true, config: config)
        #expect(types(nextKey[0].messages) == [1])
    }

    @Test func aJoiningViewerGetsTheStoredConfig() {
        var s = ViewerState<Int>()
        _ = s.join(1)
        _ = s.frame(key, key: true, config: config)
        _ = s.join(2)
        let early = s.frame(delta, key: false)
        #expect(early.isEmpty)
        // A key frame may come without a config. The stored one is sent.
        let out = s.frame(key, key: true)
        #expect(types(out[0].messages) == [0, 1])
        #expect(out[0].messages[0].dropFirst(5) == config.json)
    }

    @Test func aNewConfigRestartsEveryViewer() {
        var s = ViewerState<Int>()
        _ = s.join(1)
        _ = s.frame(key, key: true, config: config)
        let h264 = StreamConfig(codec: "avc1.4d0033", width: 590, height: 1278)
        let out = s.frame(key, key: true, config: h264)
        #expect(types(out[0].messages) == [0, 1])
        #expect(out[0].messages[0].dropFirst(5) == h264.json)
    }

    /// Fills the viewer's backlog: config and key frame, then 14 deltas, 16 pending in all.
    func congested() -> ViewerState<Int> {
        var s = ViewerState<Int>()
        _ = s.join(1)
        _ = s.frame(key, key: true, config: config)
        for _ in 0..<14 {
            let out = s.frame(delta, key: false)
            #expect(out.count == 1)
        }
        #expect(!s.wantKeyFrame)
        return s
    }

    func drain(_ s: inout ViewerState<Int>, _ n: Int) {
        for _ in 0..<n { s.sent(1) }
    }

    @Test func aSlowViewerSkipsToTheNextKeyFrame() {
        var s = congested()
        // More than 15 pending: frames are skipped.
        let skipped = s.frame(delta, key: false)
        #expect(skipped.isEmpty)
        // Once the backlog drains to the resume level, it asks for a key frame.
        drain(&s, 16 - ViewerState<Int>.resumePending)
        #expect(s.wantKeyFrame)
        // Deltas stay skipped while it waits.
        let waiting = s.frame(delta, key: false)
        #expect(waiting.isEmpty)
        // The next key frame comes with the config.
        let resumed = s.frame(key, key: true, config: config)
        #expect(types(resumed[0].messages) == [0, 1])
        #expect(!s.wantKeyFrame)
    }

    @Test func aCongestedViewerGetsNoKeyFrameUntilItDrains() {
        var s = congested()
        // Neither key frames nor requests for them while the backlog is too long.
        for _ in 0..<10 {
            let keyOut = s.frame(key, key: true, config: config)
            #expect(keyOut.isEmpty)
            #expect(!s.wantKeyFrame)
            let deltaOut = s.frame(delta, key: false)
            #expect(deltaOut.isEmpty)
            #expect(!s.wantKeyFrame)
        }
        // Drained to the skip limit, but not to the resume level: still nothing.
        drain(&s, 16 - ViewerState<Int>.maxPending)
        #expect(!s.wantKeyFrame)
        let atLimit = s.frame(key, key: true, config: config)
        #expect(atLimit.isEmpty)
        #expect(!s.wantKeyFrame)
        // At the resume level, it asks once and gets config and key frame.
        drain(&s, ViewerState<Int>.maxPending - ViewerState<Int>.resumePending)
        #expect(s.wantKeyFrame)
        let out = s.frame(key, key: true, config: config)
        #expect(types(out[0].messages) == [0, 1])
        #expect(!s.wantKeyFrame)
        // A link at its limit falls behind again. Draining by two does not bring a new request.
        while true {
            let more = s.frame(delta, key: false)
            if more.isEmpty { break }
        }
        drain(&s, 2)
        #expect(!s.wantKeyFrame)
        let tooSoon = s.frame(key, key: true, config: config)
        #expect(tooSoon.isEmpty)
    }

    @Test func completedSendsKeepAViewerCurrent() {
        var s = ViewerState<Int>()
        _ = s.join(1)
        _ = s.frame(key, key: true, config: config)
        s.sent(1)
        s.sent(1)
        for _ in 0..<100 {
            let out = s.frame(delta, key: false)
            #expect(types(out[0].messages) == [2])
            s.sent(1)
        }
    }

    @Test func leave() {
        var s = ViewerState<Int>()
        _ = s.join(1)
        let left = s.leave(1), leftAgain = s.leave(1)
        #expect(left)
        #expect(!leftAgain)
        let out = s.frame(key, key: true, config: config)
        #expect(out.isEmpty)
        s.sent(1)
        #expect(s.count == 0)
    }
}
