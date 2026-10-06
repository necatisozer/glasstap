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
}
