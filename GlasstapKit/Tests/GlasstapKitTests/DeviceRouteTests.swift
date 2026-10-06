import Foundation
import Network
import os
import Testing
@testable import GlasstapKit

@Suite struct DevicePathTests {
    @Test func pathsWithAndWithoutThePrefix() {
        #expect(DevicePath.parse("/tap") == .route(device: nil, rest: "/tap"))
        #expect(DevicePath.parse("/video") == .route(device: nil, rest: "/video"))
        #expect(DevicePath.parse("/devices") == .list)
        #expect(DevicePath.parse("/devices/00008101-000A1B2C3D4E5F60/tap")
            == .route(device: "00008101-000A1B2C3D4E5F60", rest: "/tap"))
        #expect(DevicePath.parse("/devices/A/video") == .route(device: "A", rest: "/video"))
        // The page encodes a capture id, which can hold any character.
        #expect(DevicePath.parse("/devices/a%2Fb%20c/info") == .route(device: "a/b c", rest: "/info"))
        // A prefix with no id, or nothing after the id, names nothing.
        #expect(DevicePath.parse("/devices/A") == nil)
        #expect(DevicePath.parse("/devices//tap") == nil)
        #expect(DevicePath.parse("/devices/") == nil)
        // Only the exact prefix counts.
        #expect(DevicePath.parse("/devicesX/A/tap") == .route(device: nil, rest: "/devicesX/A/tap"))
    }
}

@Suite struct DeviceRoutingTests {
    let a = DeviceRoute.fake(captureID: "cap-a", udid: "UDID-A", name: "A")
    let b = DeviceRoute.fake(captureID: "cap-b", udid: nil, name: "B")

    func select(_ id: String?, _ routes: [DeviceRoute]) -> String? {
        try? DeviceRouting.select(id, in: routes).get().captureID
    }

    @Test func aPathWithoutThePrefixNeedsExactlyOneIPhone() {
        #expect(DeviceRouting.select(nil, in: []).failure == .noDevice)
        #expect(select(nil, [a]) == "cap-a")
        #expect(DeviceRouting.select(nil, in: [a, b]).failure == .ambiguous(2))
        #expect(RouteError.noDevice.status == 409)
        #expect(RouteError.ambiguous(2).status == 409)
        #expect(RouteError.ambiguous(2).message.contains("/devices"))
    }

    @Test func aPathWithThePrefixNamesOneIPhone() {
        #expect(select("UDID-A", [a, b]) == "cap-a")
        // Until devicectl names the iPhone, its key is the capture id.
        #expect(b.key == "cap-b")
        #expect(select("cap-b", [a, b]) == "cap-b")
        // A page that learned the capture id before the UDID still reaches the iPhone.
        #expect(select("cap-a", [a, b]) == "cap-a")
        #expect(DeviceRouting.select("UDID-X", in: [a, b]).failure == .unknownDevice("UDID-X"))
        #expect(RouteError.unknownDevice("x").status == 404)
        // A name is never an id: an id does not route with only one iPhone either.
        #expect(DeviceRouting.select("A", in: [a]).failure == .unknownDevice("A"))
    }

    @Test func aRouteChangesWithItsSession() throws {
        let route = DeviceRoute.fake(captureID: "cap-c", udid: nil, name: "C")
        let directory = DeviceDirectory([route])
        route.setUDID("UDID-C")
        route.setName("Renamed")
        route.setState("failed")
        route.setWDA("building")
        // The directory holds the handle, so it sees the change with no copy.
        #expect(try directory.route("UDID-C").get() === route)
        #expect(directory.listing == [DeviceRoute.Info(captureID: "cap-c", udid: "UDID-C", name: "Renamed",
                                                       state: "failed", wda: "building")])
    }
}

extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { error } else { nil }
    }
}

@Suite struct DeviceRegistryTests {
    final class Session: RoutedSession {
        let name: String
        let route: DeviceRoute
        init(_ device: ScreenDevice) {
            name = device.name
            route = .fake(captureID: device.id, udid: nil, name: device.name)
        }
    }

    let one = ScreenDevice(id: "cap-1", name: "Phone")
    let two = ScreenDevice(id: "cap-2", name: "Pad")

    @Test func devicesComeAndGo() {
        var registry = DeviceRegistry<Session>()
        var made: [String] = []
        let make: (ScreenDevice) -> Session = { made.append($0.id); return Session($0) }
        var changes = registry.sync([one], make: make)
        #expect(changes.added.map(\.name) == ["Phone"])
        #expect(changes.removed.isEmpty)
        let first = registry.sessions[0]

        changes = registry.sync([one, two], make: make)
        #expect(changes.added.map(\.name) == ["Pad"])
        #expect(changes.removed.isEmpty)
        // A device that stays keeps its session.
        #expect(registry.sessions[0] === first)
        #expect(made == ["cap-1", "cap-2"])
        #expect(registry.routes.map(\.captureID) == ["cap-1", "cap-2"])

        changes = registry.sync([two], make: make)
        #expect(changes.added.isEmpty)
        #expect(changes.removed.count == 1 && changes.removed[0] === first)
        #expect(registry.routes.map(\.captureID) == ["cap-2"])

        changes = registry.sync([], make: make)
        #expect(changes.removed.map(\.name) == ["Pad"])
        #expect(registry.sessions.isEmpty)
    }

    @Test func aRenamedDeviceKeepsItsSessionAndUDID() {
        var registry = DeviceRegistry<Session>()
        _ = registry.sync([one], make: { Session($0) })
        #expect(registry.adopt(udid: "UDID-1", for: "cap-1"))
        let session = registry.sessions[0]
        let changes = registry.sync([ScreenDevice(id: "cap-1", name: "Renamed")], make: { Session($0) })
        #expect(changes.added.isEmpty && changes.removed.isEmpty)
        #expect(registry.sessions[0] === session)
        #expect(registry.screens[0].name == "Renamed")
        #expect(session.route.udid == "UDID-1")
    }

    @Test func theKeyMovesFromTheCaptureIDToTheUDID() throws {
        var registry = DeviceRegistry<Session>()
        _ = registry.sync([one, two], make: { Session($0) })
        #expect(registry.routes.map(\.key) == ["cap-1", "cap-2"])
        #expect(registry.adopt(udid: "UDID-1", for: "cap-1"))
        #expect(registry.routes.map(\.key) == ["UDID-1", "cap-2"])
        #expect(try DeviceRouting.select("UDID-1", in: registry.routes).get().captureID == "cap-1")
        #expect(try DeviceRouting.select("cap-1", in: registry.routes).get().captureID == "cap-1")
        // Adopting again is no change.
        #expect(registry.adopt(udid: "UDID-1", for: "cap-1"))
        // A device that is not there adopts nothing.
        #expect(!registry.adopt(udid: "UDID-9", for: "cap-9"))
    }

    @Test func oneUDIDBelongsToOneSession() {
        var registry = DeviceRegistry<Session>()
        _ = registry.sync([one, two], make: { Session($0) })
        #expect(registry.adopt(udid: "UDID-1", for: "cap-1"))
        // Two WDA test runs on one iPhone conflict, so the second claim fails.
        #expect(!registry.adopt(udid: "UDID-1", for: "cap-2"))
        #expect(registry.sessions[1].route.udid == nil)
        // Once the first session has gone, the UDID is free.
        _ = registry.sync([two], make: { Session($0) })
        #expect(registry.adopt(udid: "UDID-1", for: "cap-2"))
    }

    @Test func duplicateNamesMarkOnlyThoseDevices() {
        var registry = DeviceRegistry<Session>()
        let twin = ScreenDevice(id: "cap-3", name: "Phone")
        _ = registry.sync([one, two, twin], make: { Session($0) })
        #expect(registry.sharesName("cap-1"))
        #expect(!registry.sharesName("cap-2"))
        #expect(registry.sharesName("cap-3"))
        _ = registry.sync([one, two], make: { Session($0) })
        #expect(!registry.sharesName("cap-1"))
    }

    @Test func aRepeatedCaptureIDGetsOneSession() {
        var registry = DeviceRegistry<Session>()
        let changes = registry.sync([one, one], make: { Session($0) })
        #expect(changes.added.count == 1)
        #expect(registry.sessions.count == 1)
    }
}

@Suite struct SharedNameTests {
    let phone = CoreDevice(udid: "A", name: "Phone", isPhysical: true, tunnelState: "connected", developerModeStatus: "enabled")

    @Test func twoCaptureDevicesWithOneNameAreADuplicate() async throws {
        let rig = DeviceIdentityResolverTests.Rig()
        rig.lookup.set([phone])
        rig.resolver.select(ScreenDevice(id: "cap-1", name: "Phone"), sharedName: true)
        await rig.advance(by: DeviceIdentityResolver.debounce)
        // devicectl knows only one "Phone", but it cannot say which capture device it is.
        #expect(await eventually { rig.identity?.result == .failure(.duplicateName("Phone")) })
        #expect(rig.lookup.calls == 0)
        // The user renamed the other one.
        rig.resolver.select(ScreenDevice(id: "cap-1", name: "Phone"), sharedName: false)
        await rig.advance(by: DeviceIdentityResolver.debounce)
        #expect(await eventually { rig.identity?.result == .success(phone) })
    }

    @Test func overrideAndClaimGateTheMode() {
        var settings = GlasstapSettings.defaults
        settings.teamID = "ABCDE12345"
        var identity = DeviceIdentity()
        identity.record(.success(phone), at: .zero)
        let managed = WDAMode.managed(WDATarget(udid: "A", signing: settings.wdaSigning!))
        #expect(WDAMode.resolve(settings: settings, identity: identity, now: .zero, udidClaimed: true) == managed)
        #expect(WDAMode.resolve(settings: settings, identity: identity, now: .zero, udidClaimed: false) == .off)
        let url = URL(string: "http://127.0.0.1:8100")!
        settings.wdaURLOverride = url
        #expect(WDAMode.resolve(settings: settings, identity: identity, now: .zero, overrideAllowed: true) == .external(url))
        // With two iPhones, the one WDA of the override would get the taps of both.
        #expect(WDAMode.resolve(settings: settings, identity: identity, now: .zero, overrideAllowed: false) == .off)
    }

    @Test func concurrentLookupsShareOneCall() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let shared = SharedDeviceLookup(lookup: { [phone] in
            calls.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(100))
            return [phone]
        })
        async let first = shared.devices()
        async let second = shared.devices()
        #expect(try await first == [phone])
        #expect(try await second == [phone])
        #expect(calls.withLock { $0 } == 1)
        // A later call looks again.
        _ = try await shared.devices()
        #expect(calls.withLock { $0 } == 2)
    }
}

/// The control routes with two iPhones, without a socket. WDA is at a closed port, so an action
/// that passes the routing ends in 502.
@Suite struct ControlRoutingTests {
    let token = AccessToken.generate()

    func server(_ devices: DeviceDirectory) -> ControlServer {
        ControlServer(port: 39340, videoPort: 39341, token: token, devices: devices, pageTemplate: nil, onState: { _ in })
    }

    func send(_ server: ControlServer, _ method: String, _ target: String, body: String = "{}",
              token: String? = nil) async -> HTTPResponse {
        var headers = [(name: "Host", value: "127.0.0.1:39340")]
        headers.append(("X-Glasstap", token ?? self.token.value))
        return await server.response(to: HTTPRequest(method: method, target: target, headers: headers, body: Data(body.utf8)))
    }

    func text(_ response: HTTPResponse) -> String { String(decoding: response.body, as: UTF8.self) }

    var two: DeviceDirectory {
        DeviceDirectory([.fake(captureID: "cap-a", udid: "UDID-A", name: "Phone A"),
                         .fake(captureID: "cap-b", udid: nil, name: "Phone B")])
    }

    @Test func pathsWithoutThePrefixWorkWithOneIPhoneOnly() async {
        let one = server(.single())
        #expect(await send(one, "POST", "/tap", body: #"{"x":1,"y":2}"#).status == 502)
        #expect(await send(one, "GET", "/info").status == 502)

        let twoPhones = server(two)
        let tap = await send(twoPhones, "POST", "/tap", body: #"{"x":1,"y":2}"#)
        #expect(tap.status == 409)
        #expect(text(tap).contains("2 iPhones"))
        #expect(await send(twoPhones, "GET", "/info").status == 409)
        #expect(await send(twoPhones, "GET", "/screenshot").status == 409)
        #expect(await send(twoPhones, "POST", "/stats", body: #"{"session":"s","received":0}"#).status == 409)

        let none = server(DeviceDirectory())
        let noPhone = await send(none, "POST", "/home")
        #expect(noPhone.status == 409)
        #expect(text(noPhone) == "No iPhone is connected.")
        // An unknown path is 404 whatever the iPhones.
        #expect(await send(none, "POST", "/reboot").status == 404)
        #expect(await send(twoPhones, "POST", "/reboot").status == 404)
    }

    @Test func pathsWithThePrefixReachThatIPhone() async {
        let s = server(two)
        #expect(await send(s, "POST", "/devices/UDID-A/tap", body: #"{"x":1,"y":2}"#).status == 502)
        #expect(await send(s, "GET", "/devices/cap-b/info").status == 502)
        // The capture id of an iPhone whose UDID is known still works.
        #expect(await send(s, "POST", "/devices/cap-a/home").status == 502)
        #expect(await send(s, "POST", "/devices/UDID-X/tap", body: #"{"x":1,"y":2}"#).status == 404)
        #expect(await send(s, "POST", "/devices/UDID-A/reboot").status == 404)
        #expect(await send(s, "POST", "/devices/UDID-A/tap", body: "nope").status == 400)
        #expect(await send(s, "GET", "/devices/UDID-A").status == 404)
        // The token is still needed.
        #expect(await send(s, "POST", "/devices/UDID-A/tap", body: #"{"x":1,"y":2}"#, token: "wrong").status == 403)
    }

    @Test func theListNeedsTheTokenAndNamesEachIPhone() async throws {
        let s = server(two)
        #expect(await send(s, "GET", "/devices", token: "wrong").status == 403)
        #expect(await send(s, "POST", "/devices").status == 404)
        let response = await send(s, "GET", "/devices")
        #expect(response.status == 200)
        #expect(response.headers.contains { $0.0 == "Content-Type" && $0.1 == "application/json" })
        #expect(text(response) == #"[{"captureID":"cap-a","name":"Phone A","state":"running","udid":"UDID-A","wda":"running"},"#
            + #"{"captureID":"cap-b","name":"Phone B","state":"running","udid":"cap-b","wda":"running"}]"#)
        #expect(text(await send(server(DeviceDirectory()), "GET", "/devices")) == "[]")
    }

    @Test func aReportGoesToItsIPhonesHub() async {
        let hubA = ViewerHub(), hubB = ViewerHub()
        let s = server(DeviceDirectory([.fake(captureID: "cap-a", udid: "UDID-A", name: "A", hub: hubA),
                                        .fake(captureID: "cap-b", udid: "UDID-B", name: "B", hub: hubB)]))
        let session = hubB.join(NWConnection(host: "127.0.0.1", port: 9, using: .tcp))!
        let body = #"{"session":"\#(session)","received":0}"#
        #expect(await send(s, "POST", "/devices/UDID-A/stats", body: body).status == 404)
        #expect(hubB.takeLinkSample()?.feedback == nil)
        #expect(await send(s, "POST", "/devices/UDID-B/stats", body: body).status == 200)
        #expect(hubB.takeLinkSample()?.feedback != nil)
    }
}

/// Each iPhone has its own viewer. A second viewer of one iPhone replaces only that iPhone's viewer.
@Suite(.serialized) struct PerDeviceViewerTests {
    let token = AccessToken.generate()

    /// A raw socket client, so that the test sees every byte, also the short "replaced" message.
    final class Client {
        let fd: Int32

        init(port: UInt16) {
            fd = socket(AF_INET, SOCK_STREAM, 0)
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }

        deinit { close(fd) }

        func get(_ target: String, port: UInt16) {
            let request = "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
            _ = request.withCString { send(fd, $0, strlen($0), 0) }
        }

        /// Everything until the server closes the connection or the timeout passes.
        func readAll() -> Data {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n <= 0 { break }
                data.append(contentsOf: buffer[0..<n])
            }
            return data
        }
    }

    func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aSecondViewerReplacesOnlyItsOwnIPhonesViewer() async throws {
        let port: UInt16 = 39343
        let hubA = ViewerHub(), hubB = ViewerHub()
        let state = OSAllocatedUnfairLock(initialState: ListenerState.stopped)
        let devices = DeviceDirectory([.fake(captureID: "cap-a", udid: "UDID-A", name: "A", hub: hubA),
                                       .fake(captureID: "cap-b", udid: "UDID-B", name: "B", hub: hubB)])
        let server = VideoServer(port: port, controlPort: port - 1, token: token, devices: devices,
                                 onState: { s in state.withLock { $0 = s } })
        server.start()
        defer { server.stop() }
        try await waitFor { state.withLock { $0 } == .ready }

        let a1 = Client(port: port)
        a1.get("/devices/UDID-A/video?token=\(token.value)", port: port)
        try await waitFor { hubA.viewerCount == 1 }
        let b1 = Client(port: port)
        b1.get("/devices/UDID-B/video?token=\(token.value)", port: port)
        try await waitFor { hubB.viewerCount == 1 }
        #expect(hubA.viewerCount == 1 && hubB.viewerCount == 1)

        // The capture id reaches the same hub, and the newer viewer wins.
        let a2 = Client(port: port)
        a2.get("/devices/cap-a/video?token=\(token.value)", port: port)
        let replaced = a1.readAll()
        #expect(String(decoding: replaced, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        #expect(replaced.suffix(5) == StreamMessage.encode(.replaced))
        #expect(hubA.viewerCount == 1)
        #expect(hubB.viewerCount == 1)

        // A path without the prefix is ambiguous with two iPhones, and the viewers stay.
        let plain = Client(port: port)
        plain.get("/video?token=\(token.value)", port: port)
        let answer = String(decoding: plain.readAll(), as: UTF8.self)
        #expect(answer.hasPrefix("HTTP/1.1 409 Conflict"))
        #expect(answer.hasSuffix(RouteError.ambiguous(2).message))
        #expect(hubA.viewerCount == 1 && hubB.viewerCount == 1)

        // An unknown iPhone is 404, and a request without the token learns nothing.
        let unknown = Client(port: port)
        unknown.get("/devices/UDID-X/video?token=\(token.value)", port: port)
        #expect(String(decoding: unknown.readAll(), as: UTF8.self).hasPrefix("HTTP/1.1 404"))
        let noToken = Client(port: port)
        noToken.get("/devices/UDID-X/video", port: port)
        #expect(String(decoding: noToken.readAll(), as: UTF8.self).hasPrefix("HTTP/1.1 403"))
        _ = (a2, b1)
    }

    @Test func aStoppedIPhoneAnswersAtOnce() async throws {
        let port: UInt16 = 39347
        let hub = ViewerHub()
        let state = OSAllocatedUnfairLock(initialState: ListenerState.stopped)
        let server = VideoServer(port: port, controlPort: port - 1, token: token, devices: .single(hub: hub),
                                 onState: { s in state.withLock { $0 = s } })
        server.start()
        defer { server.stop() }
        try await waitFor { state.withLock { $0 } == .ready }
        // The session stopped after the listener looked the iPhone up, but before the viewer joined.
        hub.close()
        let viewer = Client(port: port)
        viewer.get("/devices/UDID-1/video?token=\(token.value)", port: port)
        let answer = String(decoding: viewer.readAll(), as: UTF8.self)
        #expect(answer.hasPrefix("HTTP/1.1 409"))
        #expect(answer.hasSuffix("This iPhone is no longer connected."))
        #expect(hub.viewerCount == 0)
    }

    @Test func theOldPathReachesTheOnlyIPhone() async throws {
        let port: UInt16 = 39345
        let hub = ViewerHub()
        let state = OSAllocatedUnfairLock(initialState: ListenerState.stopped)
        let server = VideoServer(port: port, controlPort: port - 1, token: token, devices: .single(hub: hub),
                                 onState: { s in state.withLock { $0 = s } })
        server.start()
        defer { server.stop() }
        try await waitFor { state.withLock { $0 } == .ready }
        let viewer = Client(port: port)
        viewer.get("/video?token=\(token.value)", port: port)
        try await waitFor { hub.viewerCount == 1 }
        #expect(hub.viewerCount == 1)
        _ = viewer
    }
}
