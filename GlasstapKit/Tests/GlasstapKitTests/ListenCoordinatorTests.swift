import Foundation
import os
import Testing
@testable import GlasstapKit

@MainActor @Suite struct ListenCoordinatorTests {
    let ports = ListenCoordinator.Ports(control: 9300, video: 9301)
    let tailscale = "100.101.102.103"

    /// A bind that fails on the addresses in `failing`, and records each try.
    @MainActor final class FakeBind {
        var failing: Set<String> = []
        var tries: [(address: String, ports: ListenCoordinator.Ports)] = []
        /// While set, a bind waits for `release()`.
        var hold = false
        private var held: [CheckedContinuation<Void, Never>] = []

        func bind(_ address: String, _ ports: ListenCoordinator.Ports) async -> String? {
            tries.append((address, ports))
            if hold { await withCheckedContinuation { held.append($0) } }
            return failing.contains(address) ? "Can't assign requested address" : nil
        }

        func release() {
            hold = false
            held.forEach { $0.resume() }
            held = []
        }
    }

    func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    func coordinator(_ fake: FakeBind) -> ListenCoordinator {
        ListenCoordinator(ports: ports, bind: { address, _, ports in await fake.bind(address, ports) }, sleep: { _ in })
    }

    @Test func aFollowThatChangesNothingDoesNotMove() async {
        let fake = FakeBind()
        let c = coordinator(fake)
        c.follow(chosen: tailscale, available: [tailscale])
        await c.settled()
        #expect(fake.tries.map(\.address) == [tailscale])
        #expect(c.published.address == tailscale)
        #expect(c.published.notice == nil)
        c.follow(chosen: tailscale, available: [tailscale, "192.168.1.50"])
        await c.settled()
        #expect(fake.tries.count == 1)
    }

    @Test func goneAndBackEachMoveWithANewToken() async {
        let fake = FakeBind()
        let c = coordinator(fake)
        var seen: [ListenCoordinator.Published] = []
        c.onChange = { seen.append($0) }
        c.follow(chosen: tailscale, available: [tailscale])
        await c.settled()
        c.follow(chosen: tailscale, available: [])
        await c.settled()
        #expect(c.published.address == "127.0.0.1")
        #expect(c.published.notice == "Listening on 127.0.0.1: \(tailscale) is not available now")
        c.follow(chosen: tailscale, available: [tailscale])
        await c.settled()
        #expect(fake.tries.map(\.address) == [tailscale, "127.0.0.1", tailscale])
        #expect(seen.map(\.address) == [tailscale, "127.0.0.1", tailscale])
        #expect(Set(seen.map(\.token.value)).count == 3)
        #expect(c.published.notice == nil)
    }

    @Test func aFollowDuringAMoveToTheSameAddressWaitsForIt() async {
        let fake = FakeBind()
        fake.hold = true
        let c = coordinator(fake)
        c.follow(chosen: tailscale, available: [tailscale])
        await waitFor { fake.tries.count == 1 }
        c.follow(chosen: tailscale, available: [tailscale])
        c.follow(chosen: tailscale, available: [tailscale, "192.168.1.50"])
        fake.release()
        await c.settled()
        #expect(fake.tries.count == 1)
        // The address and the token show only once the listeners are ready.
        #expect(c.published.address == tailscale)
    }

    @Test func nothingShowsBeforeTheListenersAreReady() async {
        let fake = FakeBind()
        fake.hold = true
        let c = coordinator(fake)
        let before = c.published
        c.follow(chosen: tailscale, available: [tailscale])
        await waitFor { fake.tries.count == 1 }
        #expect(c.published == before)
        fake.release()
        await c.settled()
        #expect(c.published.address == tailscale)
        #expect(c.published.token != before.token)
    }

    @Test func aFailedAddressIsTriedAgainOnlyAfterAChange() async {
        let fake = FakeBind()
        fake.failing = [tailscale]
        let c = coordinator(fake)
        c.follow(chosen: tailscale, available: [tailscale])
        await c.settled()
        // Four tries, then 127.0.0.1.
        #expect(fake.tries.map(\.address) == Array(repeating: tailscale, count: 4) + ["127.0.0.1"])
        #expect(c.published.address == "127.0.0.1")
        #expect(c.published.notice?.hasPrefix("Listening on 127.0.0.1: could not listen on \(tailscale)") == true)
        // The same addresses: no new try, as the network poll finds nothing new.
        c.follow(chosen: tailscale, available: [tailscale])
        await c.settled()
        #expect(fake.tries.count == 5)
        // Another address came up: try again.
        fake.failing = []
        c.follow(chosen: tailscale, available: [tailscale, "192.168.1.50"])
        await c.settled()
        #expect(fake.tries.count == 6)
        #expect(c.published.address == tailscale)
        #expect(c.published.notice == nil)
    }

    @Test func aNewSettingTriesAFailedAddressAgain() async {
        let fake = FakeBind()
        fake.failing = [tailscale]
        let c = coordinator(fake)
        c.follow(chosen: tailscale, available: [tailscale, "192.168.1.50"])
        await c.settled()
        let tries = fake.tries.count
        c.follow(chosen: "192.168.1.50", available: [tailscale, "192.168.1.50"])
        await c.settled()
        #expect(fake.tries.count == tries + 1)
        #expect(c.published.address == "192.168.1.50")
        // Back to the failing one: a change of setting, so it is tried again.
        c.follow(chosen: tailscale, available: [tailscale, "192.168.1.50"])
        await c.settled()
        #expect(fake.tries.count == tries + 1 + 5)
    }

    @Test func newPortsMoveToTheSameAddressWithANewToken() async {
        let fake = FakeBind()
        let c = coordinator(fake)
        c.follow(chosen: "127.0.0.1", available: [])
        await c.settled()
        let first = c.published.token
        let newPorts = ListenCoordinator.Ports(control: 9400, video: 9401)
        c.follow(chosen: "127.0.0.1", available: [], ports: newPorts)
        await c.settled()
        #expect(fake.tries.map(\.address) == ["127.0.0.1", "127.0.0.1"])
        #expect(fake.tries.last?.ports == newPorts)
        #expect(c.published.token != first)
        // The same ports again change nothing.
        c.follow(chosen: "127.0.0.1", available: [], ports: newPorts)
        await c.settled()
        #expect(fake.tries.count == 2)
    }

    @Test func whenNothingCanListenOnlyAChangeTriesAgain() async {
        let fake = FakeBind()
        fake.failing = ["127.0.0.1"]
        let c = coordinator(fake)
        let before = c.published
        c.follow(chosen: "127.0.0.1", available: [])
        await c.settled()
        #expect(fake.tries.count == 4)
        #expect(c.published.address == before.address && c.published.token == before.token)
        #expect(c.published.notice?.hasPrefix("Could not listen on 127.0.0.1") == true)
        c.follow(chosen: "127.0.0.1", available: [])
        await c.settled()
        #expect(fake.tries.count == 4)
        // A new port, for example after the user picked a free one.
        fake.failing = []
        c.follow(chosen: "127.0.0.1", available: [], ports: ListenCoordinator.Ports(control: 9500, video: 9501))
        await c.settled()
        #expect(fake.tries.count == 5)
        #expect(c.published.notice == nil)
    }
}

/// The coordinator with the real listeners, on loopback ports.
@MainActor @Suite(.serialized) struct ListenCoordinatorSocketTests {
    @Test func theListenersMoveToNewPorts() async throws {
        let first = ListenCoordinator.Ports(control: 39370, video: 39371)
        let c = ListenCoordinator(ports: first, devices: .single(), pageTemplate: "<p>__VIDEO_PORT__</p>")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        c.follow(chosen: "127.0.0.1", available: [])
        await c.settled()
        #expect(c.published.notice == nil)
        let (page, _) = try await session.data(for: URLRequest(url: URL(string: "http://127.0.0.1:39370/")!))
        #expect(String(decoding: page, as: UTF8.self) == "<p>39371</p>")
        let token = c.published.token

        c.follow(chosen: "127.0.0.1", available: [], ports: ListenCoordinator.Ports(control: 39372, video: 39373))
        await c.settled()
        #expect(c.published.token != token)
        let (moved, _) = try await session.data(for: URLRequest(url: URL(string: "http://127.0.0.1:39372/")!))
        #expect(String(decoding: moved, as: UTF8.self) == "<p>39373</p>")
        await #expect(throws: (any Error).self) {
            _ = try await session.data(for: URLRequest(url: URL(string: "http://127.0.0.1:39370/")!, timeoutInterval: 3))
        }
        // The old token does not work on the new listener.
        var list = URLRequest(url: URL(string: "http://127.0.0.1:39372/devices")!)
        list.setValue(token.value, forHTTPHeaderField: "X-Glasstap")
        #expect((try await session.data(for: list).1 as? HTTPURLResponse)?.statusCode == 403)
        list.setValue(c.published.token.value, forHTTPHeaderField: "X-Glasstap")
        #expect((try await session.data(for: list).1 as? HTTPURLResponse)?.statusCode == 200)
        c.stop()
    }
}
