import AVFoundation
import CoreMedia
import Foundation
import os

/// Captures the iPhone screen and feeds the encoder, which feeds the viewer hub.
public final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case running
        case failed(String)
    }

    private struct Counters {
        var frames = 0
        var receivedFrame = false
    }

    private let hub: ViewerHub
    private let log = Logger(subsystem: "io.github.necatisozer.glasstap", category: "capture")
    /// Starts and stops the session. `startRunning` blocks, so it stays off the main thread.
    private let sessionQueue = DispatchQueue(label: "glasstap.capture-session")
    /// The sample buffer delegate and the encoder input.
    private let queue = DispatchQueue(label: "glasstap.capture")
    private let counters = OSAllocatedUnfairLock(initialState: Counters())

    // Touched only on `sessionQueue`.
    private var session: AVCaptureSession?
    private var runtimeObserver: (any NSObjectProtocol)?

    // Touched only on `queue`.
    private var output: AVCaptureVideoDataOutput?
    private var settings = GlasstapSettings.defaults.encoder
    /// Lowers the bitrate, then the size, while the link to the viewer is congested.
    private lazy var rate = RateAdapter(
        hub: hub, queue: queue,
        configured: StreamStats(bitrate: settings.bitrate, fps: settings.fps), width: settings.width
    ) { [weak self] change in self?.rateChanged(change) }
    /// The screen's size, from its first frame. The stream keeps its aspect ratio at every size.
    private var nativeSize: (width: Int, height: Int)?
    /// The size of the encoder's frames.
    private var encoderSize: (width: Int, height: Int)?
    /// A new encoder session starts with a key frame, so that viewers can decode its new size.
    private var forceKeyFrame = false
    /// Key frames that the encoder dropped since the last one came out, and the time before which
    /// the capture does not try again. At a starved bitrate, an immediate retry is dropped again.
    private var keyFrameDrops = 0
    private var keyRetryNotBefore = CMTime.invalid
    private var onEvent: (@Sendable (Event) -> Void)?
    private var encoder: Encoder?
    private var lastEncode = CMTime.invalid
    // The capture device sends frames only while the screen changes. Keep the
    // last frame, so that a viewer who joins on a still screen gets a picture.
    private var lastFrame: CVPixelBuffer?
    /// The newest frame arrived inside the frame-rate window and still waits to be encoded.
    private var frameNotEncoded = false
    private var flushScheduled = false
    /// Changes at each start and stop, so that a delayed flush of an old run does nothing.
    private var run = 0

    public init(hub: ViewerHub) {
        self.hub = hub
        super.init()
        hub.setKeyFrameHandler { [weak self] in self?.encodeLastFrameForKeyFrame() }
        // At once, so that the new viewer's first stats are the settings, not the old viewer's target.
        hub.setJoinHandler { [weak self] in
            guard let self else { return }
            queue.sync {
                self.rate.viewerJoined()
                self.hub.setStats(self.rate.target)
            }
        }
    }

    /// True once the device has sent a frame since the last start. A display that is off sends none.
    public var hasReceivedFrame: Bool { counters.withLock { $0.receivedFrame } }

    /// The frames encoded since the last call.
    public func takeFrameCount() -> Int {
        counters.withLock { c in
            defer { c.frames = 0 }
            return c.frames
        }
    }

    /// Starts the capture of the device with this `uniqueID`, or restarts it with new settings.
    public func start(deviceID: String, settings: EncoderSettings, onEvent: @escaping @Sendable (Event) -> Void) {
        sessionQueue.async { [self] in
            stopSession()
            counters.withLock { $0 = Counters() }
            // Look the device up the way it was found, in case a direct lookup misses screen devices.
            let found = DeviceWatcher.discover().first { $0.uniqueID == deviceID }
            guard let device = found ?? AVCaptureDevice(uniqueID: deviceID) else {
                return onEvent(.failed("The iPhone screen device is gone."))
            }
            let session = AVCaptureSession()
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { return onEvent(.failed("The capture cannot use this device.")) }
                session.addInput(input)
            } catch {
                return onEvent(.failed(error.localizedDescription))
            }
            guard session.canAddOutput(output) else { return onEvent(.failed("The capture cannot add a video output.")) }
            queue.sync {
                self.output = output
                self.settings = settings
                self.onEvent = onEvent
                resetRun()
            }
            output.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(output)
            runtimeObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
            ) { note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                onEvent(.failed(error?.localizedDescription ?? "The capture stopped."))
            }
            session.startRunning()
            self.session = session
            log.info("capture running: \(device.localizedName)")
            onEvent(.running)
        }
    }

    public func stop() {
        sessionQueue.async { [self] in stopSession() }
    }

    /// Runs on `sessionQueue`.
    private func stopSession() {
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
        runtimeObserver = nil
        session?.stopRunning()
        session = nil
        queue.sync {
            output?.setSampleBufferDelegate(nil, queue: nil)
            output = nil
            onEvent = nil
            resetRun()
        }
    }

    /// Forgets the encoder and the frames of a run, at each start and stop. A lowered target ends
    /// with the run: the viewers and the next run see the settings. Runs on `queue`.
    private func resetRun() {
        encoder?.invalidate()
        encoder = nil
        nativeSize = nil
        encoderSize = nil
        forceKeyFrame = false
        keyFrameDrops = 0
        keyRetryNotBefore = .invalid
        lastEncode = .invalid
        lastFrame = nil
        frameNotEncoded = false
        flushScheduled = false
        run += 1
        rate.configure(StreamStats(bitrate: settings.bitrate, fps: settings.fps), width: settings.width)
        hub.setStats(rate.target)
    }

    public func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard o === output, let output, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        counters.withLock { $0.receivedFrame = true }
        if encoderSize == nil {
            nativeSize = (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
            guard makeEncoder(for: rate.size, output: output) else { return }
        }
        // The first frame, and the frames just after a size change, may still have another size.
        // `encode` scales them, so that a viewer who joins on a still screen gets a picture at once.
        newest(pb)
    }

    /// Creates the encoder for `size`, and lets the capture pipeline scale the frames to it.
    /// Runs on `queue`. Returns false if the encoder could not start.
    private func makeEncoder(for size: BitrateController.Rung, output: AVCaptureVideoDataOutput) -> Bool {
        guard let nativeSize else { return false }
        let width = size.width
        let height = Int((Double(nativeSize.height) * Double(width) / Double(nativeSize.width) / 2).rounded()) * 2
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        encoder?.invalidate()
        encoder = nil
        var encoderSettings = settings
        encoderSettings.bitrate = rate.target.bitrate
        do {
            encoder = try Encoder(
                settings: encoderSettings, width: width, height: height, keyFrameInterval: size.keyFrameInterval,
                onDrop: { [weak self] in self?.encoderDropped() }
            ) { [hub, weak self] message, key, config in
                hub.broadcast(message, key: key, config: config)
                if key { self?.keyFrameEncoded() }
            }
        } catch {
            log.error("\(String(describing: error))")
            onEvent?(.failed(String(describing: error)))
            return false
        }
        encoderSize = (width, height)
        forceKeyFrame = true
        return true
    }

    /// Keeps the newest frame and encodes it, now or as soon as the frame rate allows.
    private func newest(_ pb: CVPixelBuffer) {
        lastFrame = pb
        frameNotEncoded = !encode(pb)
        if frameNotEncoded { scheduleFlush() }
    }

    /// The device sends nothing more on a still screen, so a frame held back by the
    /// frame rate would never go out. Encode it when the window has passed.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let sinceLast = lastEncode.isValid ? (now - lastEncode).seconds : .infinity
        var wait = 0.9 / Double(settings.fps) - sinceLast
        if keyRetryNotBefore.isValid { wait = max(wait, (keyRetryNotBefore - now).seconds) }
        let run = run
        queue.asyncAfter(deadline: .now() + max(wait, 0.001)) { [weak self] in
            guard let self, run == self.run else { return }
            flushScheduled = false
            if frameNotEncoded, let pb = lastFrame { newest(pb) }
        }
    }

    /// Returns false if the frame rate, or the wait after a dropped key frame, held the frame back.
    private func encode(_ pb: CVPixelBuffer) -> Bool {
        guard let encoder, let size = encoderSize else { return false }
        // Use one clock for every frame, because the last frame is encoded again for a new viewer.
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        if lastEncode.isValid, (pts - lastEncode).seconds < 0.9 / Double(settings.fps) { return false }
        if keyRetryNotBefore.isValid, pts < keyRetryNotBefore, hub.isWaitingForKeyFrame { return false }
        lastEncode = pts
        counters.withLock { $0.frames += 1 }
        // With nobody watching, keep the frame only. A viewer that joins asks for a key
        // frame, and then the last frame is encoded.
        guard hub.viewerCount > 0 else { return true }
        rate.start()
        // The first frame, and the frames just after a size change, may have another size.
        guard let frame = PixelScaler.fit(pb, width: size.width, height: size.height) else {
            log.error("a frame could not be scaled")
            return true
        }
        // Keep the scaled frame, so that a retry or a new viewer does not scale it again.
        if frame !== pb, pb === lastFrame { lastFrame = frame }
        // The request is cleared only when a key frame reaches the viewers, so a dropped one is asked for again.
        encoder.encode(frame, pts: pts, forceKeyFrame: hub.isWaitingForKeyFrame || forceKeyFrame)
        forceKeyFrame = false
        return true
    }

    /// Runs on `queue`, as the encoder and the frame-rate limit do.
    private func rateChanged(_ change: BitrateController.Change) {
        let t = change.target
        hub.setStats(t)
        log.info("target \(t.bitrate / 1000) kbit/s, \(change.size.width) px: \(change.reason, privacy: .public)")
        guard let output, let current = encoderSize, change.size.width != current.width else {
            encoder?.setBitrate(t.bitrate)
            return
        }
        // Another size needs a new session. Its first frame is a key frame with a new config,
        // and the viewers make a new decoder for it. The screen may be still, so encode the last frame now.
        guard makeEncoder(for: change.size, output: output) else { return }
        if let pb = lastFrame { newest(pb) }
    }

    /// The encoder dropped a frame. If a viewer waits for a key frame, the flush tries the last frame
    /// again after a wait, not at once: at a starved bitrate, the encoder can drop the forced key frame
    /// again and again. The waits are 250 ms, 500 ms, 1 s, then 2 s.
    private func encoderDropped() {
        queue.async { [self] in
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            // A try is already waiting.
            if keyRetryNotBefore.isValid, now < keyRetryNotBefore { return }
            guard hub.isWaitingForKeyFrame, lastFrame != nil else { return }
            keyFrameDrops += 1
            let delay = Self.keyRetryDelay(afterDrops: keyFrameDrops)
            if keyFrameDrops == 1 {
                log.notice("the encoder dropped a key frame; trying again after \(delay.milliseconds) ms, at most every 2 s")
            }
            keyRetryNotBefore = now + CMTime(value: delay.milliseconds, timescale: 1000)
            frameNotEncoded = true
            scheduleFlush()
        }
    }

    /// The wait before the next try after `drops` dropped key frames in a row.
    static func keyRetryDelay(afterDrops drops: Int) -> Duration {
        min(.milliseconds(250) * (1 << min(max(drops - 1, 0), 4)), .seconds(2))
    }

    private func keyFrameEncoded() {
        queue.async { [self] in
            keyFrameDrops = 0
            keyRetryNotBefore = .invalid
        }
    }

    /// A viewer waits for a key frame, or the frame for it was dropped. The screen may be
    /// still and send nothing, so encode the last frame again.
    private func encodeLastFrameForKeyFrame() {
        queue.async { [self] in
            guard hub.isWaitingForKeyFrame, let pb = lastFrame else { return }
            newest(pb)
        }
    }
}
