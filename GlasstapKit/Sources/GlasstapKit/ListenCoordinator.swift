import Foundation

/// Owns the two listeners and moves them: to the chosen address while this Mac has it, to
/// 127.0.0.1 while it does not, and to new ports. Each move gets a new token (see `ListenMove`).
/// The app shows the address, the token and the notice only through `onChange`, once both
/// listeners are ready.
@MainActor
public final class ListenCoordinator {
    public struct Ports: Equatable, Sendable {
        public var control: UInt16
        public var video: UInt16

        public init(control: UInt16, video: UInt16) {
            self.control = control
            self.video = video
        }
    }

    /// What the app shows: the address and the token of the links, and why the listeners are not
    /// on the chosen address. The address and the token change only after a move.
    public struct Published: Equatable, Sendable {
        public var address: String
        public var token: AccessToken
        public var notice: String?
    }

    /// Starts both listeners on an address with a token and ports, and waits until both are ready.
    /// Returns nil, or the reason of a failure after it has stopped what it started.
    public typealias Bind = @MainActor (_ address: String, _ token: AccessToken, _ ports: Ports) async -> String?

    public private(set) var published: Published
    public var onChange: (@MainActor (Published) -> Void)?
    /// Each state of each listener. `control` tells which one.
    public var onListenerState: (@MainActor (_ control: Bool, ListenerState) -> Void)?

    private let bind: Bind
    private let stopListeners: @MainActor () -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private var ports: Ports
    private var chosen: String?
    private var available: [String] = []
    /// True while both listeners run on `published.address`.
    private var running = false
    /// A new port makes the next follow move, also to the same address.
    private var restartPending = false
    private var moveTask: Task<Void, Never>?
    /// The address that a move is on its way to.
    private var moveTarget: String?
    /// An address that kept failing, with the addresses of the Mac at that time. A follow tries it
    /// again only when those addresses, the chosen address or the ports change.
    private var failedMove: (target: String, available: [String])?

    public init(ports: Ports, bind: @escaping Bind, stop: @escaping @MainActor () -> Void = {},
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.ports = ports
        self.bind = bind
        stopListeners = stop
        self.sleep = sleep
        published = Published(address: ListenAddress.loopback, token: AccessToken.generate(), notice: nil)
    }

    /// The real listeners: the viewer page and the actions on `ports.control`, the video on `ports.video`.
    public convenience init(ports: Ports, devices: DeviceDirectory, pageTemplate: String?) {
        let pair = ListenerPair(devices: devices, pageTemplate: pageTemplate)
        self.init(ports: ports, bind: { await pair.bind($0, $1, $2) }, stop: { pair.stop() })
        pair.report = { [weak self] control, state in self?.onListenerState?(control, state) }
    }

    /// Moves the listeners if the chosen address, the addresses of this Mac or the ports ask for it.
    /// Call it at launch, after a change in the settings, and when the network changes.
    public func follow(chosen: String, available: [String], ports newPorts: Ports? = nil) {
        if let newPorts, newPorts != ports {
            ports = newPorts
            restartPending = true
            failedMove = nil
        }
        // A new setting may fix a failed move.
        if chosen != self.chosen { failedMove = nil }
        self.chosen = chosen
        self.available = available
        let (desired, gone) = ListenAddress.effective(chosen: chosen, available: available)
        let notice = gone ? "Listening on 127.0.0.1: \(chosen) is not available now" : nil
        if !restartPending {
            if moveTarget == desired { return }
            if moveTarget == nil, running, desired == published.address {
                failedMove = nil
                if published.notice != notice { update { $0.notice = notice } }
                return
            }
            if let failedMove, failedMove.target == desired, failedMove.available == available { return }
        }
        restartPending = false
        move(to: desired, notice: notice)
    }

    /// Stops the listeners and any move. A later follow starts them again.
    public func stop() {
        moveTask?.cancel()
        moveTask = nil
        moveTarget = nil
        running = false
        stopListeners()
    }

    /// Returns when the move on its way, if any, has ended. For tests.
    func settled() async {
        while let task = moveTask {
            await task.value
            if moveTask == task { return }
        }
    }

    private func move(to target: String, notice: String?) {
        let previous = moveTask
        previous?.cancel()
        moveTarget = target
        running = false
        moveTask = Task { [weak self] in
            // One move at a time: the move before stops its listeners first.
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            let ports = ports
            let outcome = await ListenMove.run(to: target, bind: { await self.bind($0, $1, ports) }, sleep: sleep)
            guard !Task.isCancelled else { return }
            moveTarget = nil
            settle(outcome, target: target, notice: notice)
        }
    }

    private func settle(_ outcome: ListenMove.Outcome, target: String, notice: String?) {
        switch outcome {
        case let .moved(address, token):
            running = true
            failedMove = nil
            update { $0 = Published(address: address, token: token, notice: notice) }
        case let .fellBack(token, reason):
            running = true
            failedMove = (target, available)
            update { $0 = Published(address: ListenAddress.loopback, token: token,
                                    notice: "Listening on 127.0.0.1: could not listen on \(target) (\(reason))") }
        case let .failed(reason):
            failedMove = (target, available)
            update { $0.notice = "Could not listen on \(target): \(reason)" }
        case .cancelled:
            break
        }
    }

    private func update(_ change: (inout Published) -> Void) {
        change(&published)
        onChange?(published)
    }
}

/// The two real listeners of the coordinator.
@MainActor
final class ListenerPair {
    private let devices: DeviceDirectory
    private let pageTemplate: String?
    var report: (@MainActor (_ control: Bool, ListenerState) -> Void)?
    private var control: ControlServer?
    private var video: VideoServer?

    init(devices: DeviceDirectory, pageTemplate: String?) {
        self.devices = devices
        self.pageTemplate = pageTemplate
    }

    func stop() {
        control?.stop()
        video?.stop()
        control = nil
        video = nil
    }

    /// Stopping the listeners before closes the open viewers.
    func bind(_ address: String, _ token: AccessToken, _ ports: ListenCoordinator.Ports) async -> String? {
        control?.stop()
        video?.stop()
        let (states, sink) = AsyncStream.makeStream(of: (control: Bool, state: ListenerState).self)
        // A stopped listener reports no more states, so the latest state always belongs to the running one.
        let onState: @Sendable (Bool, ListenerState) -> Void = { [weak self] isControl, state in
            sink.yield((isControl, state))
            Task { @MainActor in self?.report?(isControl, state) }
        }
        let newControl = ControlServer(port: ports.control, address: address, videoPort: ports.video, token: token,
                                       devices: devices, pageTemplate: pageTemplate, onState: { onState(true, $0) })
        let newVideo = VideoServer(port: ports.video, address: address, controlPort: ports.control, token: token,
                                   devices: devices, onState: { onState(false, $0) })
        control = newControl
        video = newVideo
        newControl.start()
        newVideo.start()
        let failure = await ListenMove.waitUntilReady(states)
        sink.finish()
        if failure != nil {
            newControl.stop()
            newVideo.stop()
            // A later move may have started its own listeners already.
            if control === newControl { control = nil }
            if video === newVideo { video = nil }
        }
        return failure
    }
}
