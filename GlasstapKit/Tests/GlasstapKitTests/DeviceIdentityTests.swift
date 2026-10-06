import Foundation
import os
import Testing
@testable import GlasstapKit

@Suite struct DeviceIdentityTests {
    let phone = CoreDevice(udid: "A", name: "Phone", isPhysical: true, tunnelState: "connected", developerModeStatus: "enabled")

    @Test func aYoungFailureKeepsTheLastGoodDevice() {
        var identity = DeviceIdentity()
        #expect(identity.wdaDevice(at: .zero) == nil)
        identity.record(.success(phone), at: .zero)
        identity.record(.failure(.lookupFailed("timeout")), at: .seconds(1))
        #expect(identity.wdaDevice(at: .seconds(10)) == phone)
        #expect(identity.lastingProblem(at: .seconds(10)) == nil)
        // The time counts from the first failure, not from the latest.
        identity.record(.failure(.notPaired), at: .seconds(12))
        #expect(identity.wdaDevice(at: .seconds(16)) == nil)
        #expect(identity.lastingProblem(at: .seconds(16)) == .notPaired)
        identity.record(.success(phone), at: .seconds(20))
        #expect(identity.problemSince == nil)
        #expect(identity.wdaDevice(at: .seconds(60)) == phone)
    }

    @Test func noGoodDeviceMeansNoWDA() {
        var identity = DeviceIdentity()
        identity.record(.failure(.notPaired), at: .zero)
        #expect(identity.wdaDevice(at: .zero) == nil)
        #expect(identity.lastingProblem(at: .zero) == nil)
    }

    @Test func theModeFollowsSettingsAndIdentity() {
        var settings = GlasstapSettings.defaults
        var identity = DeviceIdentity()
        identity.record(.success(phone), at: .zero)
        #expect(WDAMode.resolve(settings: settings, identity: identity, now: .zero) == .off)
        settings.teamID = "ABCDE12345"
        let managed = WDAMode.managed(WDATarget(udid: "A", signing: settings.wdaSigning!))
        #expect(WDAMode.resolve(settings: settings, identity: identity, now: .zero) == managed)
        identity.record(.failure(.notPaired), at: .seconds(1))
        #expect(WDAMode.resolve(settings: settings, identity: identity, now: .seconds(10)) == managed)
        #expect(WDAMode.resolve(settings: settings, identity: identity, now: .seconds(16)) == .off)
        settings.wdaURLOverride = URL(string: "http://127.0.0.1:8100")
        #expect(WDAMode.resolve(settings: settings, identity: identity, now: .seconds(16)) == .external(settings.wdaURLOverride!))
    }
}

@Suite struct DeviceIdentityResolverTests {
    let screen = ScreenDevice(id: "capture-1", name: "Phone")
    let phone = CoreDevice(udid: "A", name: "Phone", isPhysical: true, tunnelState: "connected", developerModeStatus: "enabled")

    /// A devicectl stand-in that answers from a script and counts the calls.
    final class FakeLookup: @unchecked Sendable {
        let state = OSAllocatedUnfairLock(initialState: (calls: 0, devices: [CoreDevice]()))
        var calls: Int { state.withLock { $0.calls } }
        func set(_ devices: [CoreDevice]) { state.withLock { $0.devices = devices } }
        func callAsFunction() -> [CoreDevice] { state.withLock { s in s.calls += 1; return s.devices } }
    }

    struct Rig {
        let clock = ManualClock()
        let lookup = FakeLookup()
        let resolver: DeviceIdentityResolver
        let latest = OSAllocatedUnfairLock<DeviceIdentity?>(initialState: nil)

        init() {
            let lookup = lookup
            resolver = DeviceIdentityResolver(clock: clock, lookup: { lookup() })
            let updates = resolver.updates
            let latest = latest
            Task { for await identity in updates { latest.withLock { $0 = identity } } }
        }

        var identity: DeviceIdentity? { latest.withLock { $0 } }

        /// Waits for the resolver's next sleep, then moves the clock past it.
        func advance(by duration: Duration) async {
            #expect(await eventually { clock.sleeperCount > 0 })
            clock.advance(by: duration)
        }
    }

    @Test func requestsCloseTogetherGiveOneLookup() async throws {
        let rig = Rig()
        rig.lookup.set([phone])
        rig.resolver.select(screen)
        rig.resolver.recheck()
        rig.resolver.select(screen)
        // The resolver handles the three requests on its own task. Each one replaces the waiting lookup.
        try await Task.sleep(for: .milliseconds(30))
        await rig.advance(by: DeviceIdentityResolver.debounce)
        #expect(await eventually { rig.identity?.result == .success(phone) })
        try await Task.sleep(for: .milliseconds(30))
        #expect(rig.lookup.calls == 1)
        // A success needs no more lookups.
        #expect(rig.clock.sleeperCount == 0)
    }

    @Test func anUnpairedIPhoneIsLookedUpAgainWithGrowingWaits() async throws {
        let rig = Rig()
        rig.resolver.select(screen)
        await rig.advance(by: DeviceIdentityResolver.debounce)
        #expect(await eventually { rig.lookup.calls == 1 })
        // Sleepers now: the retry (5 s) and the end of the grace period (15 s).
        for (delay, calls) in [(5, 2), (10, 3), (30, 4), (60, 5), (60, 6)] {
            await rig.advance(by: .seconds(delay))
            #expect(await eventually { rig.lookup.calls == calls }, "after \(delay) s")
        }
        #expect(rig.identity?.lastingProblem(at: rig.clock.now) == .notPaired)
        rig.lookup.set([phone])
        await rig.advance(by: .seconds(60))
        #expect(await eventually { rig.identity?.result == .success(phone) })
    }

    @Test func problemsThatOnlyTheUserCanFixWaitForAnEvent() async throws {
        let rig = Rig()
        var off = phone
        off.developerModeStatus = "disabled"
        rig.lookup.set([off])
        rig.resolver.select(screen)
        await rig.advance(by: DeviceIdentityResolver.debounce)
        #expect(await eventually { rig.identity?.result == .failure(.developerModeOff("Phone")) })
        // Only the end of the grace period is left. It publishes with no lookup.
        #expect(await eventually { rig.clock.sleeperCount == 1 })
        rig.clock.advance(by: DeviceIdentity.grace)
        #expect(await eventually { rig.identity?.lastingProblem(at: rig.clock.now) == .developerModeOff("Phone") })
        #expect(rig.lookup.calls == 1)
        // Check Again, after the user turned Developer Mode on.
        rig.lookup.set([phone])
        rig.resolver.recheck()
        await rig.advance(by: DeviceIdentityResolver.debounce)
        #expect(await eventually { rig.identity?.result == .success(phone) })
        #expect(rig.lookup.calls == 2)
    }

    @Test func anotherDeviceStartsFromNothing() async throws {
        let rig = Rig()
        rig.lookup.set([phone])
        rig.resolver.select(screen)
        await rig.advance(by: DeviceIdentityResolver.debounce)
        #expect(await eventually { rig.identity?.result == .success(phone) })
        rig.resolver.select(nil)
        #expect(await eventually { rig.identity?.result == nil })
        #expect(rig.identity?.wdaDevice(at: rig.clock.now) == nil)
    }
}
