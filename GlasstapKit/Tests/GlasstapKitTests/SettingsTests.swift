import Foundation
import Testing
@testable import GlasstapKit

@Suite struct SettingsTests {
    func problem(_ change: (inout SettingsInput) -> Void) -> String? {
        var input = SettingsInput(.defaults)
        change(&input)
        if case let .failure(p) = input.validate() { return p.message }
        return nil
    }

    @Test func defaultsRoundTrip() {
        #expect(SettingsInput(.defaults).validate() == .success(.defaults))
        #expect(SettingsInput(.defaults).bitrateKbps == 800)
    }

    @Test func kbitPerSecondBecomesBitPerSecond() throws {
        var input = SettingsInput(.defaults)
        input.bitrateKbps = 1500
        input.wdaURL = " http://127.0.0.1:8200 "
        let settings = try input.validate().get()
        #expect(settings.encoder.bitrate == 1_500_000)
        #expect(settings.wdaURLOverride?.absoluteString == "http://127.0.0.1:8200")
    }

    @Test func eachFieldIsChecked() {
        #expect(problem { $0.width = 100 }?.contains("width") == true)
        #expect(problem { $0.bitrateKbps = 50 }?.contains("bitrate") == true)
        // A huge entry is rejected, not multiplied into an overflow.
        #expect(problem { $0.bitrateKbps = .max }?.contains("bitrate") == true)
        #expect(problem { $0.fps = 0 }?.contains("frame rate") == true)
        #expect(problem { $0.controlPort = 80 }?.contains("port") == true)
        #expect(problem { $0.videoPort = 70_000 }?.contains("port") == true)
        #expect(problem { $0.videoPort = 9300 }?.contains("differ") == true)
        #expect(problem { $0.wdaURL = "ftp://127.0.0.1" }?.contains("WDA URL") == true)
        #expect(problem { $0.wdaURL = "not a url" }?.contains("WDA URL") == true)
        #expect(problem { $0.codec = .h264 } == nil)
        #expect(problem { $0.teamID = "ABCDE1234" }?.contains("team id") == true)
        #expect(problem { $0.teamID = "ABCDE12345\nX = 1" }?.contains("team id") == true)
        #expect(problem { $0.wdaBundlePrefix = "com.example..wda" }?.contains("prefix") == true)
        #expect(problem { $0.wdaBundlePrefix = "com.example wda" }?.contains("prefix") == true)
        #expect(problem { $0.wdaBundlePrefix = "com/../wda" }?.contains("prefix") == true)
    }

    @Test func theWDAFields() throws {
        #expect(GlasstapSettings.defaults.wdaURLOverride == nil)
        #expect(GlasstapSettings.defaults.wdaSigning == nil)
        var input = SettingsInput(.defaults)
        input.teamID = " abcde12345 "
        input.wdaURL = "  "
        let automatic = try input.validate().get()
        #expect(automatic.teamID == "ABCDE12345")
        #expect(automatic.wdaURLOverride == nil)
        #expect(automatic.wdaSigning == WDASigning(teamID: "ABCDE12345", bundlePrefix: "glasstap.wda.abcde12345"))
        input.wdaBundlePrefix = "com.example.my-wda"
        #expect(try input.validate().get().wdaSigning?.runnerBundleID == "com.example.my-wda.xctrunner")
    }

    /// Settings saved before the WDA fields existed keep their values. The old WDA URL pointed at a forwarder, so it goes.
    @Test func olderSettingsStillLoad() throws {
        let defaults = try #require(UserDefaults(suiteName: "glasstap-tests-\(UUID().uuidString)"))
        let old = #"{"encoder":{"codec":"h264","width":700,"bitrate":900000,"fps":25},"controlPort":9400,"videoPort":9401,"wdaURL":"http:\/\/127.0.0.1:8100"}"#
        defaults.set(Data(old.utf8), forKey: SettingsStore.key)
        let loaded = SettingsStore.load(from: defaults)
        #expect(loaded.encoder == EncoderSettings(codec: .h264, width: 700, bitrate: 900_000, fps: 25))
        #expect(loaded.controlPort == 9400)
        #expect(loaded.teamID.isEmpty)
        #expect(loaded.wdaURLOverride == nil)
    }

    @Test func storeSavesAndLoadsOneValue() throws {
        let defaults = try #require(UserDefaults(suiteName: "glasstap-tests-\(UUID().uuidString)"))
        #expect(SettingsStore.load(from: defaults) == .defaults)
        var settings = GlasstapSettings.defaults
        settings.encoder.codec = .h264
        settings.controlPort = 9400
        settings.teamID = "ABCDE12345"
        settings.wdaURLOverride = URL(string: "http://127.0.0.1:8100")
        SettingsStore.save(settings, to: defaults)
        #expect(SettingsStore.load(from: defaults) == settings)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0 == SettingsStore.key }.count == 1)
    }

    @Test func storeFallsBackToDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "glasstap-tests-\(UUID().uuidString)"))
        defaults.set(Data("not json".utf8), forKey: SettingsStore.key)
        #expect(SettingsStore.load(from: defaults) == .defaults)
        // Readable, but invalid: the two ports are the same.
        var bad = GlasstapSettings.defaults
        bad.videoPort = bad.controlPort
        SettingsStore.save(bad, to: defaults)
        #expect(SettingsStore.load(from: defaults) == .defaults)
    }
}
