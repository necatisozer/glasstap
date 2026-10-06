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
    private var onEvent: (@Sendable (Event) -> Void)?
    private var scaled = false
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
                scaled = false
                lastEncode = .invalid
                lastFrame = nil
                frameNotEncoded = false
                flushScheduled = false
                run += 1
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
            encoder?.invalidate()
            encoder = nil
            lastFrame = nil
            frameNotEncoded = false
            run += 1
        }
    }

    public func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard o === output, let output, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        counters.withLock { $0.receivedFrame = true }
        if !scaled {
            // Let the capture pipeline scale the frames to the target size.
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let targetWidth = settings.width / 2 * 2
            let th = Int((Double(h) * Double(targetWidth) / Double(w) / 2).rounded()) * 2
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: targetWidth,
                kCVPixelBufferHeightKey as String: th,
            ]
            do {
                encoder = try Encoder(
                    settings: settings, width: targetWidth, height: th,
                    onDrop: { [weak self] in self?.encodeLastFrameForKeyFrame() }
                ) { [hub] message, key, config in
                    hub.broadcast(message, key: key, config: config)
                }
            } catch {
                log.error("\(String(describing: error))")
                onEvent?(.failed(String(describing: error)))
                return
            }
            scaled = true
            // This frame still has the native size. Scale it here, so that a viewer who
            // joins on a still screen gets a picture before the screen changes.
            if let first = PixelScaler.scale(pb, width: targetWidth, height: th) {
                newest(first)
            } else {
                log.error("the first frame could not be scaled")
            }
            return
        }
        newest(pb)
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
        let wait = 0.9 / Double(settings.fps) - (CMClockGetTime(CMClockGetHostTimeClock()) - lastEncode).seconds
        let run = run
        queue.asyncAfter(deadline: .now() + max(wait, 0.001)) { [weak self] in
            guard let self, run == self.run else { return }
            flushScheduled = false
            if frameNotEncoded, let pb = lastFrame { newest(pb) }
        }
    }

    /// Returns false if the frame rate held the frame back.
    private func encode(_ pb: CVPixelBuffer) -> Bool {
        guard let encoder else { return false }
        // Use one clock for every frame, because the last frame is encoded again for a new viewer.
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        if lastEncode.isValid, (pts - lastEncode).seconds < 0.9 / Double(settings.fps) { return false }
        lastEncode = pts
        counters.withLock { $0.frames += 1 }
        // With nobody watching, keep the frame only. A viewer that joins asks for a key
        // frame, and then the last frame is encoded.
        guard hub.viewerCount > 0 else { return true }
        // The request is cleared only when a key frame reaches the viewers, so a dropped one is asked for again.
        encoder.encode(pb, pts: pts, forceKeyFrame: hub.isWaitingForKeyFrame)
        return true
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
