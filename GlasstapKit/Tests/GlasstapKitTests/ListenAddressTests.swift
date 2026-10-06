import Foundation
import os
import Testing
@testable import GlasstapKit

@Suite struct ListenAddressTests {
    @Test func tailscaleRangesAreMarked() {
        #expect(ListenAddress.classify("100.64.0.1") == .tailscale)
        #expect(ListenAddress.classify("100.101.102.103") == .tailscale)
        #expect(ListenAddress.classify("100.127.255.255") == .tailscale)
        #expect(ListenAddress.classify("100.63.255.255") == .other)
        #expect(ListenAddress.classify("100.128.0.1") == .other)
        #expect(ListenAddress.classify("fd7a:115c:a1e0::1") == .tailscale)
        #expect(ListenAddress.classify("fd7a:115c:a1e0:ab12:4843:cd96:6258:b240") == .tailscale)
        #expect(ListenAddress.classify("fd7a:115c:a1e1::1") == .other)
        #expect(ListenAddress.classify("192.168.1.50") == .other)
        // A CoreDevice tunnel address on a utun interface, as seen on this Mac.
        #expect(ListenAddress.classify("fd11:2233:4455::2") == .other)
    }

    @Test func loopbackLinkLocalAndUnspecifiedAreSkipped() {
        for address in ["127.0.0.1", "127.0.0.2", "::1", "169.254.10.20", "fe80::1", "febf::1", "0.0.0.0", "::",
                        "fe80::c7f:7ae4:5c79:4c7d%en0", "example.com", "1.2.3", ""] {
            #expect(ListenAddress.classify(address) == nil, "\(address)")
        }
        // fec0::/10 is outside fe80::/10.
        #expect(ListenAddress.classify("fec0::1") == .other)
    }

    @Test func iPhoneTunnelsAreNotOffered() {
        // The CoreDevice tunnel of an iPhone, as seen on this Mac.
        #expect(ListenAddress.offerable("fd11:2233:4455::2", interface: "utun6") == nil)
        #expect(ListenAddress.offerable("10.8.0.2", interface: "utun3") == nil)
        // Tailscale also uses a utun interface.
        #expect(ListenAddress.offerable("100.101.102.103", interface: "utun4") == .tailscale)
        #expect(ListenAddress.offerable("fd7a:115c:a1e0::1", interface: "utun4") == .tailscale)
        #expect(ListenAddress.offerable("192.168.1.50", interface: "en0") == .other)
        #expect(ListenAddress.offerable("fe80::1", interface: "en0") == nil)
        #expect(!ListenAddress.current().contains { $0.interface.hasPrefix("utun") && $0.kind != .tailscale })
    }

    @Test func oneTextFormForEachAddress() {
        // Browsers write IPv6 hosts compressed and in lower case, so the checks compare that form.
        #expect(IPLiteral.canonical("fd7a:115c:a1e0:0:0:0:0:1") == "fd7a:115c:a1e0::1")
        #expect(IPLiteral.canonical("FD7A:115C:A1E0::1") == "fd7a:115c:a1e0::1")
        #expect(IPLiteral.canonical("100.64.1.2") == "100.64.1.2")
        #expect(IPLiteral.canonical("fe80::1%en0") == nil)
        #expect(IPLiteral.canonical("[fd7a::1]") == nil)
        #expect(IPLiteral.canonical("localhost") == nil)
        #expect(IPLiteral.urlHost("fd7a:115c:a1e0::1") == "[fd7a:115c:a1e0::1]")
        #expect(IPLiteral.urlHost("100.64.1.2") == "100.64.1.2")
    }

    @Test func theListPutsTailscaleFirst() {
        let sorted = ListenAddress.sort([
            ListenAddress(address: "fd11:2233:4455::2", interface: "utun6", kind: .other),
            ListenAddress(address: "192.168.1.50", interface: "en0", kind: .other),
            ListenAddress(address: "fd7a:115c:a1e0::1", interface: "utun4", kind: .tailscale),
            ListenAddress(address: "100.101.102.103", interface: "utun4", kind: .tailscale),
        ])
        #expect(sorted.map(\.address) == ["100.101.102.103", "fd7a:115c:a1e0::1", "192.168.1.50", "fd11:2233:4455::2"])
    }

    @Test func thisMacsAddressesAreOfferable() {
        // Whatever the interfaces of the Mac that runs the test, none is loopback or link-local.
        for address in ListenAddress.current() {
            #expect(ListenAddress.offerable(address.address, interface: address.interface) == address.kind)
            #expect(IPLiteral.canonical(address.address) == address.address)
            #expect(!address.interface.isEmpty)
        }
    }

    @Test func aMissingAddressFallsBackAndComesBack() {
        #expect(ListenAddress.effective(chosen: "127.0.0.1", available: []) == ("127.0.0.1", false))
        #expect(ListenAddress.effective(chosen: "100.101.102.103", available: ["100.101.102.103"]) == ("100.101.102.103", false))
        // The interface went down.
        #expect(ListenAddress.effective(chosen: "100.101.102.103", available: ["192.168.1.50"]) == ("127.0.0.1", true))
        #expect(ListenAddress.effective(chosen: "100.101.102.103", available: []) == ("127.0.0.1", true))
        // It is up again.
        #expect(ListenAddress.effective(chosen: "100.101.102.103", available: ["192.168.1.50", "100.101.102.103"])
            == ("100.101.102.103", false))
    }
}

@Suite struct ListenAuthTests {
    let token = AccessToken(value: "0123456789abcdef0123456789abcdef")
    let v4 = "100.101.102.103"
    let v6 = "fd7a:115c:a1e0::1"

    func req(_ method: String, _ target: String, _ headers: [(String, String)]) -> HTTPRequest {
        HTTPRequest(method: method, target: target, headers: headers.map { (name: $0.0, value: $0.1) })
    }

    @Test func theChosenAddressPasses() {
        #expect(Auth.isAllowedHost("100.101.102.103:9300", listen: v4))
        #expect(Auth.isAllowedHost("100.101.102.103", listen: v4))
        #expect(Auth.isAllowedHost("[fd7a:115c:a1e0::1]:9300", listen: v6))
        #expect(Auth.isAllowedHost("[fd7a:115c:a1e0::1]", listen: v6))
        #expect(Auth.isAllowedHost("[FD7A:115C:A1E0:0:0:0:0:1]:9300", listen: v6))
        // A tunnel such as ssh -L still uses the loopback names.
        #expect(Auth.isAllowedHost("127.0.0.1:9300", listen: v4))
        #expect(Auth.isAllowedHost("localhost:9300", listen: v6))
    }

    @Test func otherHostsFail() {
        for host in ["100.101.102.104:9300", "192.168.1.50:9300", "evil.example:9300", "[100.101.102.103]:9300",
                     "100.101.102.103.evil.example", "100.101.102.103:", "100.101.102.103:93a0", "", "[::1]:9300"] {
            #expect(!Auth.isAllowedHost(host, listen: v4), "\(host)")
        }
        #expect(!Auth.isAllowedHost(nil, listen: v4))
        for host in ["fd7a:115c:a1e0::1", "fd7a:115c:a1e0::1:9300", "[fd7a:115c:a1e0::2]:9300", "[fd7a:115c:a1e0::1",
                     "[fd7a:115c:a1e0::1]x", "100.101.102.103:9300"] {
            #expect(!Auth.isAllowedHost(host, listen: v6), "\(host)")
        }
    }

    @Test func loopbackModeIsUnchanged() {
        for host in ["192.168.1.50:9300", "100.101.102.103:9300", "[fd7a:115c:a1e0::1]:9300", "[::1]:9300", "[127.0.0.1]:9300"] {
            #expect(!Auth.isAllowedHost(host, listen: "127.0.0.1"), "\(host)")
        }
        #expect(Auth.isAllowedHost("127.0.0.1:9300", listen: "127.0.0.1"))
        #expect(Auth.isAllowedHost("localhost", listen: "127.0.0.1"))
        #expect(Auth.viewerOrigins(controlPort: 9300, listen: "127.0.0.1") == Auth.viewerOrigins(controlPort: 9300))
        #expect(Auth.viewerOrigins(controlPort: 9300) == ["http://127.0.0.1:9300", "http://localhost:9300"])
    }

    @Test func theControlListenerFollowsTheAddress() {
        let host = ("Host", "100.101.102.103:9300"), auth = ("X-Glasstap", token.value)
        #expect(Auth.controlAllows(req("POST", "/tap", [host, auth, ("Origin", "http://100.101.102.103:9300")]), token: token, listen: v4))
        #expect(Auth.controlAllows(req("GET", "/", [host]), token: token, listen: v4))
        #expect(!Auth.controlAllows(req("GET", "/", [host]), token: token))
        #expect(!Auth.controlAllows(req("POST", "/tap", [host, auth, ("Origin", "http://evil.example")]), token: token, listen: v4))
        #expect(!Auth.controlAllows(req("POST", "/tap", [("Host", "evil.example:9300"), auth]), token: token, listen: v4))
        // The token rules stay.
        #expect(!Auth.controlAllows(req("POST", "/tap", [host]), token: token, listen: v4))
        let v6Host = ("Host", "[fd7a:115c:a1e0::1]:9300")
        #expect(Auth.controlAllows(req("POST", "/tap", [v6Host, auth, ("Origin", "http://[fd7a:115c:a1e0::1]:9300")]),
                                   token: token, listen: v6))
    }

    @Test func theViewerOriginsFollowTheAddress() {
        #expect(Auth.viewerOrigins(controlPort: 9300, listen: v4).contains("http://100.101.102.103:9300"))
        #expect(Auth.viewerOrigins(controlPort: 9300, listen: v6).contains("http://[fd7a:115c:a1e0::1]:9300"))
        let origins = Auth.viewerOrigins(controlPort: 9300, listen: v6)
        let good = "/video?token=\(token.value)"
        func check(_ host: String, _ origin: String, listen: String) -> Auth.VideoDecision {
            Auth.video(req("GET", good, [("Host", host), ("Origin", origin)]), token: token,
                       viewerOrigins: Auth.viewerOrigins(controlPort: 9300, listen: listen), listen: listen)
        }
        #expect(check("[fd7a:115c:a1e0::1]:9301", "http://[fd7a:115c:a1e0::1]:9300", listen: v6)
            == .accept(corsOrigin: "http://[fd7a:115c:a1e0::1]:9300"))
        // Another spelling of the same address is the same origin.
        #expect(Auth.video(req("GET", good, [("Host", "[fd7a:115c:a1e0::1]:9301"), ("Origin", "http://[FD7A:115c:a1e0:0::1]:9300")]),
                           token: token, viewerOrigins: origins, listen: v6) == .accept(corsOrigin: "http://[FD7A:115c:a1e0:0::1]:9300"))
        #expect(check("100.101.102.103:9301", "http://100.101.102.103:9300", listen: v4) == .accept(corsOrigin: "http://100.101.102.103:9300"))
        #expect(check("100.101.102.103:9301", "http://100.101.102.104:9300", listen: v4) == .reject(status: 403))
        #expect(check("100.101.102.103:9301", "http://100.101.102.103:9301", listen: v4) == .reject(status: 403))
        #expect(check("evil.example:9301", "http://100.101.102.103:9300", listen: v4) == .reject(status: 403))
        // In loopback mode, the address of the Mac is just another host.
        #expect(check("100.101.102.103:9301", "http://100.101.102.103:9300", listen: "127.0.0.1") == .reject(status: 403))
        #expect(check("127.0.0.1:9301", "http://192.168.1.50:9300", listen: "127.0.0.1") == .reject(status: 403))
    }

    @Test func theLinkUsesTheAddress() {
        #expect(ViewerLink.url(controlPort: 9300, token: token, host: v4).absoluteString
            == "http://100.101.102.103:9300/#token=\(token.value)")
        #expect(ViewerLink.url(controlPort: 9300, token: token, device: "U", host: v6).absoluteString
            == "http://[fd7a:115c:a1e0::1]:9300/#token=\(token.value)&device=U")
    }

    @Test func theSettingTakesOneAddressOfTheMac() throws {
        func validate(_ address: String) -> Result<GlasstapSettings, SettingsProblem> {
            var input = SettingsInput(.defaults)
            input.listenAddress = address
            return input.validate()
        }
        #expect(GlasstapSettings.defaults.listenAddress == "127.0.0.1")
        #expect(try validate(" 100.101.102.103 ").get().listenAddress == "100.101.102.103")
        #expect(try validate("FD7A:115C:A1E0:0::1").get().listenAddress == "fd7a:115c:a1e0::1")
        #expect(try validate("127.0.0.1").get().listenAddress == "127.0.0.1")
        for bad in ["0.0.0.0", "::", "fe80::1", "fe80::1%en0", "169.254.1.1", "127.0.0.2", "::1", "example.com", ""] {
            #expect(throws: SettingsProblem.self, "\(bad)") { try validate(bad).get() }
        }
    }

    /// Settings saved before the listen address existed keep listening on 127.0.0.1.
    @Test func olderSettingsListenOnLoopback() throws {
        let defaults = try #require(UserDefaults(suiteName: "glasstap-tests-\(UUID().uuidString)"))
        let old = #"{"encoder":{"codec":"hevc","width":590,"bitrate":800000,"fps":30},"controlPort":9300,"videoPort":9301,"teamID":"ABCDE12345"}"#
        defaults.set(Data(old.utf8), forKey: SettingsStore.key)
        let loaded = SettingsStore.load(from: defaults)
        #expect(loaded.teamID == "ABCDE12345")
        #expect(loaded.listenAddress == "127.0.0.1")
    }
}

/// The listeners bind to the chosen address only. These run on real sockets, with an address of this Mac.
@Suite(.serialized) struct ListenBindTests {
    @Test func theUnspecifiedAddressIsRefused() {
        #expect(throws: (any Error).self) { try Listener.bind(address: "0.0.0.0", port: 39350) }
        #expect(throws: (any Error).self) { try Listener.bind(address: "::", port: 39350) }
        #expect(throws: (any Error).self) { try Listener.bind(address: "localhost", port: 39350) }
    }

    /// An address that this Mac does not have makes the listener wait. A move must see that at once,
    /// not only when its timeout ends.
    @Test func aMissingAddressReportsWaiting() async throws {
        let state = OSAllocatedUnfairLock(initialState: ListenerState.stopped)
        // 192.0.2.0/24 is for documentation, so no Mac has it.
        let server = ControlServer(port: 39354, address: "192.0.2.1", videoPort: 39355, token: AccessToken.generate(),
                                   devices: .single(), pageTemplate: nil, onState: { s in state.withLock { $0 = s } })
        server.start()
        defer { server.stop() }
        #expect(await eventually(timeout: .seconds(3)) { if case .waiting = state.withLock({ $0 }) { true } else { false } })
    }

    /// Starts both listeners on `address`, as the app does in a move, and waits for them.
    func bindBoth(_ address: String, port: UInt16) async -> String? {
        let (states, sink) = AsyncStream.makeStream(of: (control: Bool, state: ListenerState).self)
        let token = AccessToken.generate()
        let control = ControlServer(port: port, address: address, videoPort: port + 1, token: token, devices: .single(),
                                    pageTemplate: nil, onState: { sink.yield((true, $0)) })
        let video = VideoServer(port: port + 1, address: address, controlPort: port, token: token, devices: .single(),
                                onState: { sink.yield((false, $0)) })
        control.start()
        video.start()
        defer {
            control.stop()
            video.stop()
        }
        return await ListenMove.waitUntilReady(states, timeout: .seconds(3))
    }

    @Test func aMoveWaitsForBothListeners() async throws {
        #expect(await bindBoth("127.0.0.1", port: 39356) == nil)
        let start = ContinuousClock.now
        let missing = await bindBoth("192.0.2.1", port: 39358)
        #expect(missing?.contains("assign requested address") == true)
        // The wait ends at the first report, long before the timeout.
        #expect(ContinuousClock.now - start < .seconds(2))
        if let lan = ListenAddress.current().first(where: { !$0.address.contains(":") })?.address {
            #expect(await bindBoth(lan, port: 39360) == nil)
        }
    }

    @Test func aWaitThatHearsNothingEndsAtTheTimeout() async {
        let (states, sink) = AsyncStream.makeStream(of: (control: Bool, state: ListenerState).self)
        sink.yield((true, .ready))
        let reason = await ListenMove.waitUntilReady(states, timeout: .milliseconds(100))
        #expect(reason?.hasPrefix("The listeners did not start within") == true)
        sink.finish()
    }

    @Test func aListenerOnAnAddressOfTheMacIsNotOnLoopback() async throws {
        // An IPv4 address of this Mac. A Mac with no network has none, and then there is nothing to test.
        guard let address = ListenAddress.current().first(where: { !$0.address.contains(":") })?.address else { return }
        let token = AccessToken.generate()
        let port: UInt16 = 39352
        let state = OSAllocatedUnfairLock(initialState: ListenerState.stopped)
        let server = ControlServer(port: port, address: address, videoPort: port + 1, token: token, devices: .single(),
                                   pageTemplate: "<p>page</p>", onState: { s in state.withLock { $0 = s } })
        server.start()
        defer { server.stop() }
        for _ in 0..<100 where state.withLock({ $0 }) != .ready { try await Task.sleep(for: .milliseconds(20)) }
        #expect(state.withLock { $0 } == .ready)

        let session = URLSession(configuration: .ephemeral)
        var list = URLRequest(url: URL(string: "http://\(address):\(port)/devices")!)
        list.setValue(token.value, forHTTPHeaderField: "X-Glasstap")
        let (_, response) = try await session.data(for: list)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        // Nothing listens on 127.0.0.1 at this port.
        await #expect(throws: (any Error).self) {
            _ = try await session.data(for: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!, timeoutInterval: 3))
        }
        session.invalidateAndCancel()
    }
}

@Suite struct ListenMoveTests {
    let old = AccessToken(value: "0123456789abcdef0123456789abcdef")
    let fresh = AccessToken(value: "fedcba9876543210fedcba9876543210")

    /// A bind that fails a set number of times on each address, and records each try.
    final class Binder: @unchecked Sendable {
        private let state: OSAllocatedUnfairLock<(failures: [String: Int], tries: [String], tokens: [String])>
        init(failures: [String: Int]) { state = OSAllocatedUnfairLock(initialState: (failures, [], [])) }
        var tries: [String] { state.withLock { $0.tries } }
        var tokens: [String] { state.withLock { $0.tokens } }

        func bind(_ address: String, _ token: AccessToken) -> String? {
            state.withLock { s in
                s.tries.append(address)
                s.tokens.append(token.value)
                guard s.failures[address, default: 0] > 0 else { return nil }
                s.failures[address]! -= 1
                return "Can't assign requested address"
            }
        }
    }

    func move(to target: String, _ binder: Binder, sleeps: OSAllocatedUnfairLock<[Duration]>) async -> ListenMove.Outcome {
        await ListenMove.run(to: target, bind: { binder.bind($0, $1) },
                             sleep: { d in sleeps.withLock { $0.append(d) } }, makeToken: { fresh })
    }

    @Test func aMoveGetsANewToken() async {
        let binder = Binder(failures: [:])
        let sleeps = OSAllocatedUnfairLock(initialState: [Duration]())
        let outcome = await move(to: "100.101.102.103", binder, sleeps: sleeps)
        #expect(outcome == .moved(address: "100.101.102.103", token: fresh))
        #expect(outcome != .moved(address: "100.101.102.103", token: old))
        #expect(binder.tokens == [fresh.value])
        #expect(sleeps.withLock { $0 }.isEmpty)
    }

    @Test func aFailedBindIsTriedAgainWithGrowingWaits() async {
        // A new IPv6 address that the system does not let any listener bind yet.
        let binder = Binder(failures: ["fd7a:115c:a1e0::1": 2])
        let sleeps = OSAllocatedUnfairLock(initialState: [Duration]())
        #expect(await move(to: "fd7a:115c:a1e0::1", binder, sleeps: sleeps) == .moved(address: "fd7a:115c:a1e0::1", token: fresh))
        #expect(binder.tries == ["fd7a:115c:a1e0::1", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0::1"])
        #expect(sleeps.withLock { $0 } == [.seconds(1), .seconds(2)])
    }

    @Test func anAddressThatKeepsFailingFallsBackToLoopback() async {
        let binder = Binder(failures: ["100.101.102.103": 99])
        let sleeps = OSAllocatedUnfairLock(initialState: [Duration]())
        let outcome = await move(to: "100.101.102.103", binder, sleeps: sleeps)
        #expect(outcome == .fellBack(token: fresh, reason: "Can't assign requested address"))
        #expect(binder.tries == Array(repeating: "100.101.102.103", count: 4) + ["127.0.0.1"])
        #expect(sleeps.withLock { $0 } == ListenMove.retryDelays)
        // The fallback has a new token too, not the token of the address before.
        #expect(Set(binder.tokens) == [fresh.value])
    }

    @Test func loopbackHasNothingToFallBackTo() async {
        let binder = Binder(failures: ["127.0.0.1": 99])
        let sleeps = OSAllocatedUnfairLock(initialState: [Duration]())
        #expect(await move(to: "127.0.0.1", binder, sleeps: sleeps) == .failed(reason: "Can't assign requested address"))
        #expect(binder.tries.count == 4)
        let both = Binder(failures: ["100.101.102.103": 99, "127.0.0.1": 1])
        #expect(await move(to: "100.101.102.103", both, sleeps: sleeps) == .failed(reason: "Can't assign requested address"))
    }

    @Test func aCancelledMoveStops() async {
        let binder = Binder(failures: ["100.101.102.103": 99])
        let outcome = await ListenMove.run(to: "100.101.102.103", bind: { binder.bind($0, $1) },
                                           sleep: { _ in throw CancellationError() }, makeToken: { fresh })
        #expect(outcome == .cancelled)
        #expect(binder.tries == ["100.101.102.103"])
    }
}
