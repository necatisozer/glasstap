import AppKit
import AVFoundation
import GlasstapKit
import Network
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
    /// The addresses of this Mac that the Settings window offers.
    private(set) var listenAddresses: [ListenAddress] = []
    /// The address of both listeners: the chosen one, or 127.0.0.1 while the chosen one is gone or
    /// cannot be bound. It changes only once both listeners are ready on the new address.
    private(set) var boundAddress: String
    /// Why the listeners are not on the chosen address, for the menu. nil while they are.
    private(set) var listenNotice: String?
    /// The token of the links, kept in memory only. It is new at each launch and at each move of the
    /// listeners, so that a link to an address or port that the app left is of no use.
    private(set) var token: AccessToken

    @ObservationIgnored private let log = Logger(subsystem: "io.github.necatisozer.glasstap", category: "app")
    @ObservationIgnored private let watcher = DeviceWatcher()
    @ObservationIgnored private let host = SystemWDAHost()
    /// One devicectl call serves every session that looks at the same time.
    @ObservationIgnored private let lookup = SharedDeviceLookup()
    /// What the listeners see of the sessions. It changes when an iPhone comes or goes.
    @ObservationIgnored private let directory = DeviceDirectory()
    /// The two listeners, and their moves between addresses and ports.
    @ObservationIgnored private let listeners: ListenCoordinator
    /// A change of network can add or remove an address of this Mac.
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var setupTracker = SetupProblemTracker()
    /// Opens the Setup window. The app sets it.
    @ObservationIgnored var showSetup: (() -> Void)?
    /// Two sessions that wait for camera access share one request, so macOS asks once.
    @ObservationIgnored private var cameraRequest: Task<Bool, Never>?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []

    /// A change of network can miss an address, so the app also looks this often.
    static let addressPoll: Duration = .seconds(30)

    init() {
        let settings = SettingsStore.load()
        self.settings = settings
        listeners = ListenCoordinator(ports: Self.ports(settings), devices: directory, pageTemplate: Self.viewerPage)
        boundAddress = listeners.published.address
        token = listeners.published.token
    }

    var sessions: [DeviceSession] { registry.sessions }

    /// The failing checks. The menu and the Setup window show the same list.
    var setupProblems: [SetupProblem] {
        SetupReport.problems(xcode: xcodeStatus, settings: settings, devices: sessions.map(\.setupDevice),
                             cameraDenied: cameraStatus == .denied || cameraStatus == .restricted)
    }

    /// The link of the link file and "Copy Viewer Link". The page uses the only iPhone, or asks which one.
    var viewerURL: URL { ViewerLink.url(controlPort: settings.controlPort, token: token, host: boundAddress) }

    /// The id of a session in the paths and links: its UDID once known, its capture id until then.
    func key(of session: DeviceSession) -> String {
        session.route.key
    }

    func start() {
        guard loops.isEmpty else { return }
        listeners.onChange = { [weak self] in self?.listenChanged($0) }
        listeners.onListenerState = { [weak self] control, state in
            if control { self?.controlState = state } else { self?.videoState = state }
        }
        // The listeners start, and the link file is written, once both are ready.
        followListenAddress()
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.followListenAddress() }
        }
        pathMonitor.start(queue: .main)
        watcher.onChange = { [weak self] in self?.devicesChanged() }
        watcher.start()
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.sessions.forEach { $0.tick() }
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.addressPoll)
                self?.followListenAddress()
            }
        })
        // A Setup or Settings window brings the app to the front, often after the user fixed something.
        loops.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                guard let self else { return }
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                sessions.forEach { $0.recheck() }
                followListenAddress()
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
        let url = session.map {
            ViewerLink.url(controlPort: settings.controlPort, token: token, device: key(of: $0), host: boundAddress)
        } ?? viewerURL
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

    /// Saves new settings and restarts only what they affect. A new address or port moves the
    /// listeners, with a new token.
    func apply(_ new: GlasstapSettings) {
        guard new != settings else { return }
        settings = new
        SettingsStore.save(new)
        followListenAddress()
        sessions.forEach { $0.apply(new) }
    }

    // MARK: - Listen address

    private static func ports(_ settings: GlasstapSettings) -> ListenCoordinator.Ports {
        ListenCoordinator.Ports(control: settings.controlPort, video: settings.videoPort)
    }

    /// Lets the listeners follow the settings and the addresses of this Mac.
    private func followListenAddress() {
        let current = ListenAddress.current()
        if current != listenAddresses { listenAddresses = current }
        listeners.follow(chosen: settings.listenAddress, available: current.map(\.address), ports: Self.ports(settings))
    }

    private func listenChanged(_ published: ListenCoordinator.Published) {
        listenNotice = published.notice
        guard published.address != boundAddress || published.token != token else { return }
        log.notice("listening on \(published.address, privacy: .public)")
        boundAddress = published.address
        token = published.token
        // The link holds the address and the token.
        writeViewerLink()
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
        // checkSetup looks each iPhone up again, once.
        checkSetup()
        sessions.forEach { $0.restartWDAIfFailed() }
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

    /// Read once, from the app bundle.
    private static let viewerPage: String? = Bundle.main
        .url(forResource: "index", withExtension: "html")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    // MARK: - Devices

    private func devicesChanged() {
        log.notice("devices: \(self.watcher.devices.map(\.name), privacy: .public), searching: \(self.watcher.isSearching)")
        isSearching = watcher.isSearching
        let changes = registry.sync(watcher.devices) { makeSession($0) }
        // The listeners stop routing to a gone iPhone at once. Its WDA stops in the background:
        // if the iPhone comes back first, the new test run stops the old one before it starts.
        directory.set(registry.routes)
        for session in changes.removed {
            Task { await session.stop() }
        }
        for (session, screen) in zip(registry.sessions, registry.screens) {
            session.setScreen(screen, sharedName: registry.sharesName(screen.id))
            session.setOverrideAllowed(registry.sessions.count == 1)
        }
        changes.added.forEach { $0.start() }
    }

    private func makeSession(_ screen: ScreenDevice) -> DeviceSession {
        DeviceSession(
            screen: screen, settings: settings, host: host, lookup: { [lookup] in try await lookup.devices() },
            hooks: DeviceSession.Hooks(
                requestCameraAccess: { [weak self] in await self?.requestCameraAccess() ?? false },
                claimUDID: { [weak self] captureID, udid in
                    self?.registry.adopt(udid: udid, for: captureID) ?? false
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
