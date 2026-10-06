import Foundation
import Testing
@testable import GlasstapKit

/// Fixtures are real devicectl output with every id, serial, hostname and address replaced.
/// A text fixture, line by line.
func fixtureLines(_ name: String) throws -> [String] {
    String(decoding: try fixture(name), as: UTF8.self).split(separator: "\n").map(String.init)
}

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct DevicectlTests {
    /// The name of the second iPhone in the fixture. It has a curly apostrophe (U+2019), as iOS writes it.
    let curlyName = "Someone\u{2019}s iPhone"

    @Test func parsesTheDeviceList() throws {
        let devices = try Devicectl.parseDeviceList(try fixture("devicectl-list.json"))
        #expect(devices.count == 6)
        #expect(devices.filter(\.isPhysical).count == 2)
        let wired = try #require(devices.first { $0.udid == "00008101-000A1B2C3D4E5F60" })
        #expect(wired == CoreDevice(udid: "00008101-000A1B2C3D4E5F60", name: "Test iPhone 12 Pro", isPhysical: true,
                                    tunnelState: "connected", transportType: "wired", pairingState: "paired",
                                    developerModeStatus: "enabled", osVersion: "26.5", tunnelIPAddress: "fd00:3333:4444::1"))
        let away = try #require(devices.first { $0.udid == "00008110-0001A2B3C4D5E6F7" })
        #expect(away.name == curlyName)
        #expect(away.tunnelState == "disconnected")
        #expect(away.transportType == "localNetwork")
        #expect(away.tunnelIPAddress == nil)
        let simulator = try #require(devices.first { !$0.isPhysical })
        #expect(simulator.developerModeStatus == nil)
    }

    @Test func parsesTheDeviceDetails() throws {
        let device = try Devicectl.parseDeviceDetails(try fixture("devicectl-info-details.json"))
        #expect(device.udid == "00008101-000A1B2C3D4E5F60")
        #expect(device.tunnelIPAddress == "fd00:1111:2222::1")
        #expect(device.tunnelState == "connected")
        #expect(device.osMajorVersion == 26)
    }

    /// devicectl marks the old fields as deprecated. Without them, the `properties` dictionary must give the same values.
    @Test func readsThePropertiesDictionaryWhenTheDeprecatedFieldsAreGone() throws {
        func withoutDeprecatedFields(_ data: Data, devices: Bool) throws -> Data {
            var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var result = try #require(json["result"] as? [String: Any])
            let strip: ([String: Any]) -> [String: Any] = { device in
                device.filter { !["hardwareProperties", "deviceProperties", "connectionProperties"].contains($0.key) }
            }
            if devices {
                result["devices"] = try #require(result["devices"] as? [[String: Any]]).map(strip)
            } else {
                result = strip(result)
            }
            json["result"] = result
            return try JSONSerialization.data(withJSONObject: json)
        }
        let details = try fixture("devicectl-info-details.json")
        #expect(try Devicectl.parseDeviceDetails(try withoutDeprecatedFields(details, devices: false))
            == Devicectl.parseDeviceDetails(details))
        let list = try fixture("devicectl-list.json")
        let fromProperties = try Devicectl.parseDeviceList(try withoutDeprecatedFields(list, devices: true))
        let fromDeprecated = try Devicectl.parseDeviceList(list)
        #expect(fromProperties == fromDeprecated)
    }

    @Test func aFailedOutcomeIsAnError() {
        let failed = Data(#"{"info":{"outcome":"failed"},"error":{}}"#.utf8)
        #expect(throws: Devicectl.ParseError.self) { try Devicectl.parseDeviceList(failed) }
        #expect(throws: Devicectl.ParseError.self) { try Devicectl.parseDeviceDetails(Data("not json".utf8)) }
    }

    // MARK: - Matching the capture name

    func device(_ name: String, udid: String, tunnel: String = "connected", transport: String = "localNetwork",
                pairing: String = "paired", developerMode: String = "enabled", physical: Bool = true) -> CoreDevice {
        CoreDevice(udid: udid, name: name, isPhysical: physical, tunnelState: tunnel, transportType: transport,
                   pairingState: pairing, developerModeStatus: developerMode)
    }

    @Test func aUniqueNameGivesTheUDID() throws {
        let devices = try Devicectl.parseDeviceList(try fixture("devicectl-list.json"))
        #expect(try Devicectl.match(captureName: "Test iPhone 12 Pro", in: devices).get().udid == "00008101-000A1B2C3D4E5F60")
    }

    @Test func noReachableDeviceOfThatName() throws {
        let devices = try Devicectl.parseDeviceList(try fixture("devicectl-list.json"))
        // In the fixture, this iPhone is not connected.
        #expect(Devicectl.match(captureName: curlyName, in: devices) == .failure(.notPaired))
        #expect(Devicectl.match(captureName: "Another iPhone", in: devices) == .failure(.notPaired))
        // A simulator never matches.
        #expect(Devicectl.match(captureName: "iPhone 17", in: devices) == .failure(.notPaired))
    }

    @Test func theNameMustMatchExactly() {
        let devices = [device(curlyName, udid: "A")]
        #expect(Devicectl.match(captureName: curlyName, in: devices) == .success(devices[0]))
        // A straight apostrophe is another character.
        #expect(Devicectl.match(captureName: "Someone's iPhone", in: devices) == .failure(.notPaired))
        #expect(Devicectl.match(captureName: "someone\u{2019}s iphone", in: devices) == .failure(.notPaired))
        #expect(Devicectl.match(captureName: curlyName + " ", in: devices) == .failure(.notPaired))
    }

    @Test func connectableCountsAndDisconnectedDoesNot() {
        #expect(Devicectl.match(captureName: "P", in: [device("P", udid: "A", tunnel: "connectable")]).map(\.udid) == .success("A"))
        #expect(Devicectl.match(captureName: "P", in: [device("P", udid: "A", tunnel: "disconnected")]) == .failure(.notPaired))
    }

    @Test func aPairedIPhoneOnUSBCountsWhileItsTunnelIsDown() {
        let idle = device("P", udid: "A", tunnel: "disconnected", transport: "wired")
        #expect(Devicectl.match(captureName: "P", in: [idle]).map(\.udid) == .success("A"))
        // An iPhone that does not trust this Mac yet needs the user first.
        let untrusted = device("P", udid: "A", tunnel: "disconnected", transport: "wired", pairing: "unpaired")
        #expect(Devicectl.match(captureName: "P", in: [untrusted]) == .failure(.notPaired))
    }

    @Test func duplicateNamesAskForARename() {
        let devices = [device("Phone", udid: "A"), device("Phone", udid: "B"), device("Other", udid: "C")]
        let result = Devicectl.match(captureName: "Phone", in: devices)
        #expect(result == .failure(.duplicateName("Phone")))
        #expect(DeviceProblem.duplicateName("Phone").message
            == "Two iPhones are named Phone. Rename one in Settings > General > About.")
        // A disconnected namesake is no conflict.
        let one = [device("Phone", udid: "A"), device("Phone", udid: "B", tunnel: "disconnected")]
        #expect(Devicectl.match(captureName: "Phone", in: one).map(\.udid) == .success("A"))
    }

    @Test func developerModeMustBeOn() {
        let devices = [device("Phone", udid: "A", developerMode: "disabled")]
        #expect(Devicectl.match(captureName: "Phone", in: devices) == .failure(.developerModeOff("Phone")))
    }

    @Test func wdaURLFromTheTunnelAddress() {
        #expect(Devicectl.wdaURL(tunnelAddress: "fd00:1111:2222::1")?.absoluteString == "http://[fd00:1111:2222::1]:8100")
        #expect(Devicectl.wdaURL(tunnelAddress: "fd00::1", port: 8200)?.port == 8200)
        #expect(Devicectl.wdaURL(tunnelAddress: "192.0.2.1")?.absoluteString == "http://192.0.2.1:8100")
        #expect(Devicectl.wdaURL(tunnelAddress: "fe80::1%en0") == nil)
        #expect(Devicectl.wdaURL(tunnelAddress: "fd00::1]/evil") == nil)
        #expect(Devicectl.wdaURL(tunnelAddress: "") == nil)
    }
}
