import Foundation
import Network
import os
import Testing
@testable import GlasstapKit

@Suite struct ViewerHubTests {
    @Test func aJoiningViewerAsksForTheLastFrame() {
        let hub = ViewerHub()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        hub.setKeyFrameHandler { calls.withLock { $0 += 1 } }
        hub.join(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
        #expect(calls.withLock { $0 } == 1)
        #expect(hub.isWaitingForKeyFrame)
    }

    @Test func aClosedHubTakesNoViewer() {
        let hub = ViewerHub()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        hub.setKeyFrameHandler { calls.withLock { $0 += 1 } }
        hub.join(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
        hub.close()
        #expect(hub.viewerCount == 0)
        #expect(hub.isClosed)
        #expect(hub.join(NWConnection(host: "127.0.0.1", port: 9, using: .tcp)) == nil)
        #expect(hub.viewerCount == 0)
        // Only the first join asked for a key frame.
        #expect(calls.withLock { $0 } == 1)
    }

    /// A join and a close on two threads: whichever wins, no viewer stays in a closed hub.
    @Test func aJoinThatRacesACloseLeavesNoViewer() {
        for _ in 0..<200 {
            let hub = ViewerHub()
            DispatchQueue.concurrentPerform(iterations: 4) { i in
                if i == 0 { hub.close() } else { hub.join(NWConnection(host: "127.0.0.1", port: 9, using: .tcp)) }
            }
            #expect(hub.viewerCount == 0)
        }
    }
}
