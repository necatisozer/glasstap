import AppKit
import AVFoundation
import GlasstapKit
import Observation
import OSLog

/// The state that the menu shows, the listeners, and one session for each connected iPhone.
@MainActor @Observable
final class AppModel {
    /// The sessions of the connected iPhones, in the order of the capture devices.
    private(set) var registry = DeviceRegistry<DeviceSession>()
    private(set) var isSearching = true
    /// nil until the first check.
    private(set) var xcodeStatus: XcodeStatus?
    private(set) var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var controlState: ListenerState = .stopped
    private(set) var videoState: ListenerState = .stopped
    private(set) var settings: GlasstapSettings

    /// A new token for each launch, kept in memory only.
    let token = AccessToken.generate()

    @ObservationIgnored private let log = Logger(subsystem: "io.github.necatisozer.glasstap", category: "app")
    @ObservationIgnored private let watcher = DeviceWatcher()
    @ObservationIgnored private let host = SystemWDAHost()
    /// One devicectl call serves every session that looks at the same time.
    @ObservationIgnored private let lookup = SharedDeviceLookup()
    /// What the listeners see of the sessions. It changes with each session, UDID and state.
    @ObservationIgnored private let directory = DeviceDirectory()
    @ObservationIgnored private var setupTracker = SetupProblemTracker()
    /// Opens the Setup window. The app sets it.
    @ObservationIgnored var showSetup: (() -> Void)?
    @ObservationIgnored private var controlServer: ControlServer?
    @ObservationIgnored private var videoServer: VideoServer?
    /// Two sessions that wait for camera access share one request, so macOS asks once.
    @ObservationIgnored private var cameraRequest: Task<Bool, Never>?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []

    init() {
        settings = SettingsStore.load()
    }

    var sessions: [DeviceSession] { registry.sessions }

    /// The failing checks. The menu and the Setup window show the same list.
    var setupProblems: [SetupProblem] {
        SetupReport.problems(xcode: xcodeStatus, settings: settings, devices: sessions.map(\.setupDevice),
                             cameraDenied: cameraStatus == .denied || cameraStatus == .restricted)
    }

    /// The link of the link file and "Copy Viewer Link". The page uses the only iPhone, or asks which one.
    var viewerURL: URL { ViewerLink.url(controlPort: settings.controlPort, token: token) }

    /// The id of a session in the paths and links: its UDID once known, its capture id until then.
    func key(of session: DeviceSession) -> String {
        registry.entry(captureID: session.id)?.key ?? session.id
    }

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
                self?.sessions.forEach { $0.tick() }
            }
        })
        // A Setup or Settings window brings the app to the front, often after the user fixed something.
        loops.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                self?.sessions.forEach { $0.recheck() }
            }
        })
        checkSetup()
        watchSetupProblems()
    }

    /// Stops WDA on every iPhone before the app quits. A test run would otherwise keep its iPhone busy.
    func prepareToQuit() async {
        // The stops run side by side, because the quit waits a limited time for all of them.
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { await session.stop() }
            }
        }
    }

    /// Opens the page of one iPhone, or with nil, the page that picks one.
    func openViewer(_ session: DeviceSession? = nil) {
        let url = session.map { ViewerLink.url(controlPort: settings.controlPort, token: token, device: key(of: $0)) } ?? viewerURL
        // NSWorkspace passes the link to the browser directly, so the token never shows in a command line.
        NSWorkspace.shared.open(url)
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
        sessions.forEach { $0.apply(new) }
    }

    // MARK: - Setup

    /// The "Setup…" menu item, and the "Check Again" button.
    func checkSetup() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        sessions.forEach { $0.recheck() }
        Task { [weak self] in
            let status = await XcodeStatus.check()
            self?.xcodeStatus = status
        }
    }

    /// The "Check Again" button. It also starts a failed WDA again, for example after a sign-in in Xcode.
    func checkAgain() {
        checkSetup()
        sessions.forEach { $0.checkAgain() }
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
            port: settings.controlPort, videoPort: settings.videoPort, token: token, devices: directory,
            pageTemplate: Self.viewerPage,
            onState: { [weak self] state in Task { @MainActor in self?.controlState = state } })
        controlServer?.start()
    }

    private func startVideoServer() {
        videoServer = VideoServer(
            port: settings.videoPort, controlPort: settings.controlPort, token: token, devices: directory,
            onState: { [weak self] state in Task { @MainActor in self?.videoState = state } })
        videoServer?.start()
    }

    /// Read once, from the app bundle.
    private static let viewerPage: String? = Bundle.main
        .url(forResource: "index", withExtension: "html")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// Copies what the listeners need of each session.
    private func publishDirectory() {
        directory.set(registry.entries.map { entry in
            DeviceRoute(captureID: entry.captureID, udid: entry.udid, name: entry.name,
                        state: entry.session.captureStatus.word, wda: entry.session.wdaStatus.state.word,
                        hub: entry.session.hub, client: entry.session.wda)
        })
    }

    // MARK: - Devices

    private func devicesChanged() {
        log.notice("devices: \(self.watcher.devices.map(\.name), privacy: .public), searching: \(self.watcher.isSearching)")
        isSearching = watcher.isSearching
        let changes = registry.sync(watcher.devices) { makeSession($0) }
        // The listeners stop routing to a gone iPhone at once. Its WDA stops in the background:
        // if the iPhone comes back first, the new test run stops the old one before it starts.
        publishDirectory()
        for session in changes.removed {
            Task { await session.stop() }
        }
        for entry in registry.entries {
            entry.session.setScreen(entry.screen, sharedName: registry.sharesName(entry.captureID))
            entry.session.setOverrideAllowed(registry.entries.count == 1)
        }
        changes.added.forEach { $0.start() }
    }

    private func makeSession(_ screen: ScreenDevice) -> DeviceSession {
        DeviceSession(
            screen: screen, settings: settings, host: host, lookup: { [lookup] in try await lookup.devices() },
            hooks: DeviceSession.Hooks(
                requestCameraAccess: { [weak self] in await self?.requestCameraAccess() ?? false },
                claimUDID: { [weak self] captureID, udid in
                    guard let self else { return false }
                    let claimed = registry.adopt(udid: udid, for: captureID)
                    publishDirectory()
                    return claimed
                },
                changed: { [weak self] in
                    self?.cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    self?.publishDirectory()
                }))
    }

    private func requestCameraAccess() async -> Bool {
        if let cameraRequest { return await cameraRequest.value }
        let request = Task { await AVCaptureDevice.requestAccess(for: .video) }
        cameraRequest = request
        let granted = await request.value
        cameraRequest = nil
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        return granted
    }
}
