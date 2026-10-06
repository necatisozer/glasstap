import AppKit
import AVFoundation
import GlasstapKit
import Observation
import OSLog

/// The state that the menu shows, and the lifecycle of capture, servers and WDA checks.
@MainActor @Observable
final class AppModel {
    enum CaptureStatus: Equatable {
        case idle
        case waitingForPermission
        case noPermission
        case starting
        case running
        case failed(String)
    }

    private(set) var devices: [ScreenDevice] = []
    private(set) var isSearching = true
    private(set) var selectedDeviceID: String?
    private(set) var captureStatus: CaptureStatus = .idle
    private(set) var fps = 0
    /// What the encoder aims at now. Adaptive bitrate lowers it on a congested link.
    private(set) var encoderTarget: StreamStats?
    private(set) var viewerConnected = false
    /// The managed WDA, or the user's own at the override URL.
    private(set) var wdaStatus = WDAStatus()
    /// The CoreDevice of the selected capture device, with the last good one.
    private(set) var identity = DeviceIdentity()
    /// nil until the first check.
    private(set) var xcodeStatus: XcodeStatus?
    private(set) var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var showWakeHint = false
    private(set) var controlState: ListenerState = .stopped
    private(set) var videoState: ListenerState = .stopped
    private(set) var settings: GlasstapSettings

    /// A new token for each launch, kept in memory only.
    let token = AccessToken.generate()

    @ObservationIgnored private let log = Logger(subsystem: "io.github.necatisozer.glasstap", category: "app")
    @ObservationIgnored private let hub = ViewerHub()
    @ObservationIgnored private let engine: CaptureEngine
    @ObservationIgnored private let watcher = DeviceWatcher()
    @ObservationIgnored private let manager = WDAManager(host: SystemWDAHost())
    @ObservationIgnored private let resolver = DeviceIdentityResolver()
    @ObservationIgnored private let wda: WDAClient
    @ObservationIgnored private var setupTracker = SetupProblemTracker()
    /// Opens the Setup window. The app sets it.
    @ObservationIgnored var showSetup: (() -> Void)?
    @ObservationIgnored private var controlServer: ControlServer?
    @ObservationIgnored private var videoServer: VideoServer?
    /// Each capture start gets a new number, so that late events of an old one are ignored.
    @ObservationIgnored private var captureGeneration = 0
    @ObservationIgnored private var capturingDeviceID: String?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    /// A failed capture is retried once by itself. This is set when that retry has been used.
    @ObservationIgnored private var autoRetryUsed = false
    @ObservationIgnored private var loops: [Task<Void, Never>] = []

    init() {
        settings = SettingsStore.load()
        engine = CaptureEngine(hub: hub)
        // The client follows the manager, so a new WDA address needs no call.
        wda = WDAClient(endpoint: { [manager] in manager.baseURL })
    }

    var selectedDevice: ScreenDevice? { devices.first { $0.id == selectedDeviceID } }

    /// The latest lookup of the selected iPhone. nil while unknown.
    var deviceIdentity: Result<CoreDevice, DeviceProblem>? { identity.result }

    /// The failing checks. The menu and the Setup window show the same list.
    var setupProblems: [SetupProblem] {
        SetupReport.problems(xcode: xcodeStatus, settings: settings, identity: identity, now: resolver.clock.now,
                             cameraDenied: cameraStatus == .denied || cameraStatus == .restricted, wda: wdaStatus.state)
    }

    var viewerURL: URL { ViewerLink.url(controlPort: settings.controlPort, token: token) }

    func start() {
        guard loops.isEmpty else { return }
        writeViewerLink()
        startControlServer()
        startVideoServer()
        watcher.onChange = { [weak self] in self?.devicesChanged() }
        watcher.start()
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        })
        loops.append(Task { [weak self, manager] in
            for await status in await manager.subscribe() { self?.wdaChanged(status) }
        })
        loops.append(Task { [weak self, resolver] in
            for await identity in resolver.updates { self?.identityChanged(identity) }
        })
        // A Setup or Settings window brings the app to the front, often after the user fixed something.
        loops.append(Task { [resolver] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                resolver.recheck()
            }
        })
        updateWDAMode()
        checkSetup()
        watchSetupProblems()
    }

    /// Stops WDA before the app quits. Its test run would otherwise keep the iPhone busy.
    func prepareToQuit() async {
        // Terminal: a call that comes later cannot start WDA again.
        await manager.stop()
    }

    func openViewer() {
        // NSWorkspace passes the link to the browser directly, so the token never shows in a command line.
        NSWorkspace.shared.open(viewerURL)
    }

    /// The file is a convenience: if it cannot be written, the menu still offers the link.
    private func writeViewerLink() {
        do {
            try ViewerLink().write(viewerURL)
        } catch {
            log.error("viewer link file: \(error.localizedDescription, privacy: .public)")
        }
    }

    func copyViewerLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewerURL.absoluteString, forType: .string)
    }

    /// The "Restart Capture" action, shown after a failure.
    func restartCapture() {
        updateCapture(restart: true)
    }

    func selectDevice(_ id: String) {
        guard id != selectedDeviceID, devices.contains(where: { $0.id == id }) else { return }
        selectedDeviceID = id
        updateCapture()
        resolver.select(selectedDevice)
    }

    /// Saves new settings and restarts only what they affect.
    func apply(_ new: GlasstapSettings) {
        guard new != settings else { return }
        let old = settings
        settings = new
        SettingsStore.save(new)
        if new.controlPort != old.controlPort {
            videoServer?.setControlPort(new.controlPort)
            controlServer?.stop()
            startControlServer()
            // The link holds the port.
            writeViewerLink()
        }
        if new.videoPort != old.videoPort {
            controlServer?.setVideoPort(new.videoPort)
            videoServer?.stop()
            startVideoServer()
        }
        updateWDAMode()
        if new.encoder != old.encoder { updateCapture(restart: true) }
    }

    // MARK: - WDA

    /// The "Restart WDA" action.
    func restartWDA() {
        manager.restart()
    }

    private func updateWDAMode() {
        manager.setMode(WDAMode.resolve(settings: settings, identity: identity, now: resolver.clock.now))
    }

    private func wdaChanged(_ status: WDAStatus) {
        log.notice("WDA: \(String(describing: status.state), privacy: .public)")
        wdaStatus = status
    }

    // MARK: - Device identity

    private func identityChanged(_ new: DeviceIdentity) {
        let old = identity.result
        identity = new
        updateWDAMode()
        // The tunnel address changes when the iPhone is plugged in again. Only a changed entry can carry a new one.
        if case let .success(before)? = old, case let .success(after)? = new.result,
           before.udid == after.udid, before != after {
            Task { [manager] in await manager.refreshAddress() }
        }
    }

    // MARK: - Setup

    /// The "Setup…" menu item, and the "Check Again" button.
    func checkSetup() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        resolver.recheck()
        Task { [weak self] in
            let status = await XcodeStatus.check()
            self?.xcodeStatus = status
        }
    }

    /// The "Check Again" button. It also starts a failed WDA again, for example after a sign-in in Xcode.
    func checkAgain() {
        checkSetup()
        if case .failed = wdaStatus.state { manager.restart() }
    }

    func openSetup() {
        checkSetup()
        showSetup?()
    }

    func saveTeamID(_ text: String) -> SettingsProblem? {
        var input = SettingsInput(settings)
        input.teamID = text
        switch input.validate() {
        case let .success(new):
            apply(new)
            return nil
        case let .failure(problem):
            return problem
        }
    }

    /// Opens the Setup window when a check newly fails: at the first launch, because no team is set,
    /// and later when something breaks. A problem that stays does not open it again.
    private func watchSetupProblems() {
        let problems = withObservationTracking { setupProblems } onChange: { [weak self] in
            Task { @MainActor in self?.watchSetupProblems() }
        }
        if !setupTracker.newProblems(in: problems).isEmpty { showSetup?() }
    }

    // MARK: - Servers

    // A stopped listener reports no more states, so the latest state always belongs to the running one.
    private func startControlServer() {
        controlServer = ControlServer(
            port: settings.controlPort, videoPort: settings.videoPort, token: token, wda: wda, hub: hub,
            pageTemplate: Self.viewerPage,
            onState: { [weak self] state in Task { @MainActor in self?.controlState = state } })
        controlServer?.start()
    }

    private func startVideoServer() {
        videoServer = VideoServer(
            port: settings.videoPort, controlPort: settings.controlPort, token: token, hub: hub,
            onState: { [weak self] state in Task { @MainActor in self?.videoState = state } })
        videoServer?.start()
    }

    /// Read once, from the app bundle.
    private static let viewerPage: String? = Bundle.main
        .url(forResource: "index", withExtension: "html")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    // MARK: - Capture

    private func devicesChanged() {
        log.notice("devices: \(self.watcher.devices.map(\.name), privacy: .public), searching: \(self.watcher.isSearching)")
        devices = watcher.devices
        isSearching = watcher.isSearching
        if selectedDevice == nil { selectedDeviceID = devices.first?.id }
        updateCapture()
        resolver.select(selectedDevice)
    }

    /// Starts, restarts or stops the capture to match the selected device.
    private func updateCapture(restart: Bool = false, isAutoRetry: Bool = false) {
        guard restart || selectedDeviceID != capturingDeviceID else { return }
        if !isAutoRetry { autoRetryUsed = false }
        captureGeneration += 1
        wakeTask?.cancel()
        showWakeHint = false
        capturingDeviceID = selectedDeviceID
        guard let id = selectedDeviceID else {
            engine.stop()
            captureStatus = .idle
            return
        }
        // macOS treats the iPhone screen as a camera, so the first capture asks for camera access.
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraStatus = status
        log.notice("camera permission: \(status.rawValue)")
        switch status {
        case .authorized:
            runCapture(id)
        case .notDetermined:
            engine.stop()
            captureStatus = .waitingForPermission
            let generation = captureGeneration
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                guard generation == captureGeneration else { return }
                if granted { runCapture(id) } else { captureStatus = .noPermission }
            }
        default:
            engine.stop()
            captureStatus = .noPermission
        }
    }

    private func runCapture(_ id: String) {
        captureStatus = .starting
        let generation = captureGeneration
        engine.start(deviceID: id, settings: settings.encoder) { [weak self] event in
            Task { @MainActor in self?.captureEvent(event, generation: generation) }
        }
    }

    private func captureEvent(_ event: CaptureEngine.Event, generation: Int) {
        guard generation == captureGeneration else { return }
        log.notice("capture: \(String(describing: event), privacy: .public)")
        switch event {
        case .running:
            captureStatus = .running
            scheduleWakeCheck(generation)
        case let .failed(message):
            captureStatus = .failed(message)
            wakeTask?.cancel()
            // A failure can be passing, such as a device that is still settling after it was plugged in.
            guard !autoRetryUsed else { return }
            autoRetryUsed = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, generation == captureGeneration, case .failed = captureStatus else { return }
                log.notice("capture: retrying once after a failure")
                updateCapture(restart: true, isAutoRetry: true)
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

    private func tick() {
        update(\.fps, engine.takeFrameCount())
        update(\.encoderTarget, hub.stats)
        update(\.viewerConnected, hub.viewerCount > 0)
    }

    /// Sets a property only when the value changes, so that the menu is not redrawn each second for nothing.
    private func update<T: Equatable>(_ property: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: property] != value { self[keyPath: property] = value }
    }
}
