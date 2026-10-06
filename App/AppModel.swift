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
    private(set) var viewerConnected = false
    /// nil until the first check.
    private(set) var wdaReachable: Bool?
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
    @ObservationIgnored private let wda: WDAClient
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
        let settings = SettingsStore.load()
        self.settings = settings
        wda = WDAClient(baseURL: settings.wdaURL)
        engine = CaptureEngine(hub: hub)
    }

    var selectedDevice: ScreenDevice? { devices.first { $0.id == selectedDeviceID } }

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
        loops.append(Task { [weak self] in
            while !Task.isCancelled, let wda = self?.wda {
                let reachable = await wda.isReachable()
                self?.update(\.wdaReachable, reachable)
                try? await Task.sleep(for: .seconds(5))
            }
        })
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
        if new.wdaURL != old.wdaURL {
            wdaReachable = nil
            Task { [wda] in await wda.setBaseURL(new.wdaURL) }
        }
        if new.encoder != old.encoder { updateCapture(restart: true) }
    }

    // MARK: - Servers

    // A stopped listener reports no more states, so the latest state always belongs to the running one.
    private func startControlServer() {
        controlServer = ControlServer(
            port: settings.controlPort, videoPort: settings.videoPort, token: token, wda: wda,
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

    /// An iPhone with its display off sends no frames. If none comes within 4 s and
    /// SpringBoard is in front, press Home to wake it. In an app, ask the user instead.
    private func scheduleWakeCheck(_ generation: Int) {
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, generation == captureGeneration, !engine.hasReceivedFrame else { return }
            let pressedHome = await wda.wakeIfSpringBoardIsInFront()
            guard !Task.isCancelled, generation == captureGeneration, !engine.hasReceivedFrame else { return }
            showWakeHint = !pressedHome
        }
    }

    private func tick() {
        update(\.fps, engine.takeFrameCount())
        update(\.viewerConnected, hub.viewerCount > 0)
        if showWakeHint && engine.hasReceivedFrame { showWakeHint = false }
    }

    /// Sets a property only when the value changes, so that the menu is not redrawn each second for nothing.
    private func update<T: Equatable>(_ property: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: property] != value { self[keyPath: property] = value }
    }
}
