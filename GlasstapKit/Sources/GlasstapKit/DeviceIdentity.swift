import Foundation

/// The CoreDevice of the selected capture device, over time. One failed devicectl lookup must not
/// stop a healthy WDA, so the last good device stays in use until a failure has lasted.
/// Times are the `now` of the resolver's clock.
public struct DeviceIdentity: Sendable {
    /// A freshly plugged iPhone reports "not paired" until its tunnel is up. A failure counts after this long.
    public static let grace: Duration = .seconds(15)

    /// The latest lookup. nil until the first one.
    public private(set) var result: Result<CoreDevice, DeviceProblem>?
    public private(set) var problemSince: Duration?
    private var lastGood: CoreDevice?

    public init() {}

    public mutating func record(_ new: Result<CoreDevice, DeviceProblem>, at now: Duration) {
        result = new
        switch new {
        case let .success(device):
            lastGood = device
            problemSince = nil
        case .failure:
            problemSince = problemSince ?? now
        }
    }

    /// The device that WDA runs for: the current one, or the last good one while a failure is young.
    public func wdaDevice(at now: Duration) -> CoreDevice? {
        switch result {
        case let .success(device)?: device
        case .failure?: lastingProblem(at: now) == nil ? lastGood : nil
        case nil: nil
        }
    }

    /// The problem, once it has lasted for the grace period.
    public func lastingProblem(at now: Duration) -> DeviceProblem? {
        guard case let .failure(problem)? = result, let problemSince, now - problemSince >= Self.grace else { return nil }
        return problem
    }
}

/// Finds the CoreDevice of the selected capture device, and looks again when that can help.
public actor DeviceIdentityResolver {
    /// The waits between lookups while the iPhone is not paired or devicectl fails.
    public static let retryDelays: [Duration] = [.seconds(5), .seconds(10), .seconds(30), .seconds(60)]
    /// Requests that come this close together give one lookup, as at launch.
    public static let debounce: Duration = .milliseconds(300)

    /// Every change, and the moment when a failure becomes lasting.
    public nonisolated let updates: AsyncStream<DeviceIdentity>
    public nonisolated let clock: any WDAClock
    private let sink: AsyncStream<DeviceIdentity>.Continuation
    private let commands: AsyncStream<Command>.Continuation
    private let lookup: @Sendable () async throws -> [CoreDevice]
    private var identity = DeviceIdentity()
    private var device: ScreenDevice?
    private var failedLookups = 0
    private var lookupTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?

    private enum Command {
        case select(ScreenDevice?)
        case recheck
    }

    public init(clock: any WDAClock = SystemWDAClock(),
                lookup: @escaping @Sendable () async throws -> [CoreDevice] = { try await Devicectl.listDevices() }) {
        self.clock = clock
        self.lookup = lookup
        (updates, sink) = AsyncStream.makeStream(of: DeviceIdentity.self, bufferingPolicy: .bufferingNewest(16))
        let (commandStream, commands) = AsyncStream.makeStream(of: Command.self)
        self.commands = commands
        Task { [weak self] in
            for await command in commandStream { await self?.handle(command) }
        }
    }

    /// The selected capture device, or nil. Calls take effect in their order.
    public nonisolated func select(_ device: ScreenDevice?) {
        commands.yield(.select(device))
    }

    /// An event that may have fixed a problem: Check Again, or the app becoming active.
    public nonisolated func recheck() {
        commands.yield(.recheck)
    }

    private func handle(_ command: Command) {
        switch command {
        case let .select(new):
            // Another device, or none: nothing of the old one stays.
            if new?.id != device?.id {
                identity = DeviceIdentity()
                graceTask?.cancel()
                sink.yield(identity)
            }
            device = new
        case .recheck:
            break
        }
        failedLookups = 0
        scheduleLookup(after: Self.debounce)
    }

    private func scheduleLookup(after delay: Duration) {
        lookupTask?.cancel()
        guard let device else { return lookupTask = nil }
        lookupTask = Task { [clock] in
            do { try await clock.sleep(for: delay) } catch { return }
            await self.lookUp(device)
        }
    }

    private func lookUp(_ device: ScreenDevice) async {
        let result: Result<CoreDevice, DeviceProblem>
        do {
            result = Devicectl.match(captureName: device.name, in: try await lookup())
        } catch {
            result = .failure(.lookupFailed(String(describing: error)))
        }
        guard !Task.isCancelled, device == self.device else { return }
        let wasFailing = identity.problemSince != nil
        identity.record(result, at: clock.now)
        sink.yield(identity)
        guard case let .failure(problem) = result else {
            failedLookups = 0
            graceTask?.cancel()
            return
        }
        if !wasFailing { scheduleGraceEnd() }
        // Only the user can fix these. A lookup would find the same until an event says otherwise.
        if case .developerModeOff = problem { return }
        if case .duplicateName = problem { return }
        let delays = Self.retryDelays
        scheduleLookup(after: delays[min(failedLookups, delays.count - 1)])
        failedLookups += 1
    }

    /// The failure becomes lasting with no new lookup, so the consumers hear of it at that moment.
    private func scheduleGraceEnd() {
        graceTask?.cancel()
        graceTask = Task { [clock] in
            do { try await clock.sleep(for: DeviceIdentity.grace) } catch { return }
            self.publishCurrent()
        }
    }

    private func publishCurrent() {
        sink.yield(identity)
    }
}

extension WDAMode {
    /// What WDA to run: the user's own at the override URL, or the managed one once a team is set
    /// and the iPhone is known, or none.
    public static func resolve(settings: GlasstapSettings, identity: DeviceIdentity, now: Duration) -> WDAMode {
        if let url = settings.wdaURLOverride { return .external(url) }
        guard let signing = settings.wdaSigning, let device = identity.wdaDevice(at: now) else { return .off }
        return .managed(WDATarget(udid: device.udid, signing: signing))
    }
}
