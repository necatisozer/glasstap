import Foundation

/// The tick of adaptive bitrate: every 250 ms while a viewer watches, it measures the link
/// and feeds `BitrateController`. It stops when no viewer is left, and when no frame went out
/// since the last tick while the target is at the settings: then there is nothing to measure or to raise. It runs on the caller's queue, so that the caller applies
/// each change on the queue that also encodes, with no actor hop per frame.
final class RateAdapter: @unchecked Sendable {
    static let interval: DispatchTimeInterval = .milliseconds(250)

    private let hub: ViewerHub
    private let queue: DispatchQueue
    /// Called on `queue` with each change of the target.
    private let onChange: (BitrateController.Change) -> Void
    private let epoch = ContinuousClock.now

    // Touched only on `queue`.
    private var controller: BitrateController
    private var timer: DispatchSourceTimer?
    /// A frame went out since the last tick.
    private var framesFlow = false

    /// `width` is the width in the settings, the top of the size ladder.
    init(hub: ViewerHub, queue: DispatchQueue, configured: StreamStats, width: Int = 590,
         onChange: @escaping (BitrateController.Change) -> Void) {
        self.hub = hub
        self.queue = queue
        self.onChange = onChange
        controller = BitrateController(configured: configured, width: width)
    }

    /// Call on `queue`.
    var target: StreamStats { controller.target }
    /// The size of the stream now. Call on `queue`.
    var size: BitrateController.Rung { controller.size }

    /// New settings. The target starts again at them. Call on `queue`.
    func configure(_ configured: StreamStats, width: Int) {
        stop()
        controller = BitrateController(configured: configured, width: width)
    }

    /// Starts to measure, or keeps measuring. Call it on `queue` for each frame that goes to a viewer.
    func start() {
        framesFlow = true
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// A new viewer starts from the settings, because it may have another link. Call on `queue`.
    func viewerJoined() {
        if let change = controller.reset(.newViewer) { onChange(change) }
    }

    /// Call on `queue`.
    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let atSettings = controller.target == controller.configured && controller.rung == 0
        if !framesFlow && atSettings { return stop() }
        framesFlow = false
        guard let sample = hub.takeLinkSample() else {
            stop()
            if let change = controller.reset() { onChange(change) }
            return
        }
        if let change = controller.tick(sample, now: ContinuousClock.now - epoch) { onChange(change) }
    }
}
