import AVFoundation
import Foundation
import Observation
import os

/// Everything of one connected iPhone: its capture, encoder and viewer hub, its identity and its WDA.
/// The app makes one when the capture device appears and stops it when the device goes, so a
/// capture runs only for an iPhone that is there. WDA runs only once devicectl has named the
/// iPhone and a team is set: until then the manager has nothing to do.
@MainActor @Observable
public final class DeviceSession: Identifiable, RoutedSession {
    public enum CaptureStatus: Equatable, Sendable {
        case idle
        case waitingForPermission
        case noPermission
        case starting
        case running
        case failed(String)

        /// One word, for `GET /devices`.
        public var word: String {
            switch self {
            case .idle: "idle"
            case .waitingForPermission: "waiting-for-permission"
            case .noPermission: "no-permission"
            case .starting: "starting"
            case .running: "running"
            case .failed: "failed"
            }
        }
    }

    /// What the session needs from the app.
    public struct Hooks {
        /// Asks for camera access. The app asks once for every session.
        public var requestCameraAccess: @MainActor () async -> Bool
        /// Claims the UDID for this capture device. False if another session holds it.
        public var claimUDID: @MainActor (_ captureID: String, _ udid: String) -> Bool

        public init(requestCameraAccess: @escaping @MainActor () async -> Bool,
                    claimUDID: @escaping @MainActor (String, String) -> Bool) {
            self.requestCameraAccess = requestCameraAccess
            self.claimUDID = claimUDID
        }
    }

    /// The capture `uniqueID`.
    public nonisolated let id: String
    public private(set) var screen: ScreenDevice
    public private(set) var captureStatus: CaptureStatus = .idle
    public private(set) var fps = 0
    /// What the encoder aims at now. Adaptive bitrate lowers it on a congested link.
    public private(set) var encoderTarget: StreamStats?
    public private(set) var viewerConnected = false
    /// The managed WDA, or the user's own at the override URL.
    public private(set) var wdaStatus = WDAStatus()
    /// The CoreDevice of this capture device, with the last good one.
    public private(set) var identity = DeviceIdentity()
    public private(set) var showWakeHint = false

    /// What the listeners read of this iPhone. The session updates it on each change.
    public nonisolated let route: DeviceRoute
    @ObservationIgnored public var hub: ViewerHub { route.hub }
    @ObservationIgnored public var wda: WDAClient { route.client }
    @ObservationIgnored private let engine: CaptureEngine
    @ObservationIgnored private let manager: WDAManager
    @ObservationIgnored private let resolver: DeviceIdentityResolver
    @ObservationIgnored private let hooks: Hooks
    @ObservationIgnored private let log: Logger
    @ObservationIgnored private var settings: GlasstapSettings
    @ObservationIgnored private var sharedName = false
    @ObservationIgnored private var overrideAllowed = true
    @ObservationIgnored private var udidClaimed = true
    /// Each capture start gets a new number, so that late events of an old one are ignored.
    @ObservationIgnored private var captureGeneration = 0
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    /// A failed capture is retried once by itself. This is set when that retry has been used.
    @ObservationIgnored private var autoRetryUsed = false
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var isStopped = false

    public init(screen: ScreenDevice, settings: GlasstapSettings, host: any WDAHost,
                lookup: @escaping @Sendable () async throws -> [CoreDevice], hooks: Hooks) {
        id = screen.id
        self.screen = screen
        self.settings = settings
        self.hooks = hooks
        log = Logger(subsystem: "io.github.necatisozer.glasstap", category: "device")
        let hub = ViewerHub()
        engine = CaptureEngine(hub: hub)
        let manager = WDAManager(host: host)
        self.manager = manager
        // The client follows the manager, so a new WDA address needs no call.
        route = DeviceRoute(captureID: screen.id, name: screen.name, hub: hub, client: WDAClient(endpoint: { manager.baseURL }))
        resolver = DeviceIdentityResolver(lookup: lookup)
    }

    /// The latest lookup. nil while unknown.
    public var deviceIdentity: Result<CoreDevice, DeviceProblem>? { identity.result }

    public var setupDevice: SetupReport.Device {
        SetupReport.Device(id: id, identity: identity, now: resolver.clock.now, wda: wdaStatus.state)
    }

    /// True while the user's WDA URL override is set but more than one iPhone is connected.
    public var overrideIsIdle: Bool { settings.wdaURLOverride != nil && !overrideAllowed }

    public func start() {
        guard loops.isEmpty, !isStopped else { return }
        loops.append(Task { [weak self, manager] in
            for await status in await manager.subscribe() { self?.wdaChanged(status) }
        })
        loops.append(Task { [weak self, resolver] in
            for await identity in resolver.updates { self?.identityChanged(identity) }
        })
        resolver.select(screen, sharedName: sharedName)
        updateWDAMode()
        updateCapture()
    }

    /// Stops the capture, closes the viewers and stops WDA. Returns once the test run has exited.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        loops.forEach { $0.cancel() }
        loops = []
        wakeTask?.cancel()
        captureGeneration += 1
        engine.stop()
        // A viewer that joins from now on gets an answer, not a stream that never starts.
        hub.close()
        resolver.select(nil)
        // Terminal: a later call cannot start WDA again.
        await manager.stop()
    }

    /// A new name for the capture device, or another device with the same name came or went.
    public func setScreen(_ new: ScreenDevice, sharedName shared: Bool) {
        guard new != screen || shared != sharedName else { return }
        screen = new
        sharedName = shared
        route.setName(new.name)
        resolver.select(new, sharedName: shared)
    }

    /// The WDA URL override names one WDA, so it applies only while one iPhone is connected.
    public func setOverrideAllowed(_ allowed: Bool) {
        guard allowed != overrideAllowed else { return }
        overrideAllowed = allowed
        updateWDAMode()
    }

    /// New settings. Only what they affect restarts.
    public func apply(_ new: GlasstapSettings) {
        let old = settings
        settings = new
        updateWDAMode()
        if new.encoder != old.encoder { updateCapture() }
    }

    /// An event that may have fixed a problem: Check Again, or the app becoming active.
    public func recheck() {
        resolver.recheck()
    }

    /// The "Restart WDA" action.
    public func restartWDA() {
        manager.restart()
    }

    /// Part of the "Check Again" button: a failed WDA starts again, for example after a sign-in in Xcode.
    public func restartWDAIfFailed() {
        if case .failed = wdaStatus.state { manager.restart() }
    }

    /// The "Restart Capture" action, shown after a failure.
    public func restartCapture() {
        updateCapture()
    }

    /// Once a second, from the app.
    public func tick() {
        update(\.fps, engine.takeFrameCount())
        update(\.encoderTarget, hub.stats)
        update(\.viewerConnected, hub.viewerCount > 0)
    }

    /// Sets a property only when the value changes, so that the menu is not redrawn each second for nothing.
    private func update<T: Equatable>(_ property: ReferenceWritableKeyPath<DeviceSession, T>, _ value: T) {
        if self[keyPath: property] != value { self[keyPath: property] = value }
    }

    // MARK: - WDA

    private func updateWDAMode() {
        guard !isStopped else { return }
        manager.setMode(WDAMode.resolve(settings: settings, identity: identity, now: resolver.clock.now,
                                        overrideAllowed: overrideAllowed, udidClaimed: udidClaimed))
    }

    private func wdaChanged(_ status: WDAStatus) {
        log.notice("\(self.screen.name, privacy: .public) WDA: \(String(describing: status.state), privacy: .public)")
        wdaStatus = status
        route.setWDA(status.state.word)
    }

    // MARK: - Device identity

    private func identityChanged(_ new: DeviceIdentity) {
        guard !isStopped else { return }
        let old = identity.result
        identity = new
        if case let .success(device)? = new.result {
            udidClaimed = hooks.claimUDID(id, device.udid)
            if !udidClaimed { log.error("\(device.udid, privacy: .public) belongs to another capture device; WDA stays off") }
        }
        updateWDAMode()
        // The tunnel address changes when the iPhone is plugged in again. Only a changed entry can carry a new one.
        if case let .success(before)? = old, case let .success(after)? = new.result,
           before.udid == after.udid, before != after {
            Task { [manager] in await manager.refreshAddress() }
        }
    }

    // MARK: - Capture

    /// Starts or restarts the capture.
    private func updateCapture(isAutoRetry: Bool = false) {
        guard !isStopped else { return }
        if !isAutoRetry { autoRetryUsed = false }
        captureGeneration += 1
        wakeTask?.cancel()
        showWakeHint = false
        // macOS treats the iPhone screen as a camera, so the first capture asks for camera access.
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        log.notice("camera permission: \(status.rawValue)")
        switch status {
        case .authorized:
            runCapture()
        case .notDetermined:
            engine.stop()
            setCaptureStatus(.waitingForPermission)
            let generation = captureGeneration
            Task {
                let granted = await hooks.requestCameraAccess()
                guard generation == captureGeneration else { return }
                if granted { runCapture() } else { setCaptureStatus(.noPermission) }
            }
        default:
            engine.stop()
            setCaptureStatus(.noPermission)
        }
    }

    private func setCaptureStatus(_ status: CaptureStatus) {
        guard status != captureStatus else { return }
        captureStatus = status
        route.setState(status.word)
    }

    private func runCapture() {
        setCaptureStatus(.starting)
        let generation = captureGeneration
        engine.start(deviceID: id, settings: settings.encoder) { [weak self] event in
            Task { @MainActor in self?.captureEvent(event, generation: generation) }
        }
    }

    private func captureEvent(_ event: CaptureEngine.Event, generation: Int) {
        guard generation == captureGeneration else { return }
        log.notice("\(self.screen.name, privacy: .public) capture: \(String(describing: event), privacy: .public)")
        switch event {
        case .running:
            setCaptureStatus(.running)
            scheduleWakeCheck(generation)
        case let .failed(message):
            setCaptureStatus(.failed(message))
            wakeTask?.cancel()
            // A failure can be passing, such as a device that is still settling after it was plugged in.
            guard !autoRetryUsed else { return }
            autoRetryUsed = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, generation == captureGeneration, case .failed = captureStatus else { return }
                log.notice("capture: retrying once after a failure")
                updateCapture(isAutoRetry: true)
            }
        }
    }

    /// The display may be off: WakeCheck presses Home on SpringBoard, or shows a hint until a frame comes.
    private func scheduleWakeCheck(_ generation: Int) {
        wakeTask?.cancel()
        wakeTask = Task { [weak self, manager, engine, wda] in
            await WakeCheck.run(
                statuses: await manager.subscribe(),
                hasFrame: { engine.hasReceivedFrame },
                pressHomeIfSpringBoard: { await wda.wakeIfSpringBoardIsInFront() },
                clock: SystemWDAClock(),
                showHint: { show in
                    await MainActor.run {
                        guard let self, generation == self.captureGeneration else { return }
                        self.showWakeHint = show
                    }
                })
        }
    }
}
