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
        #expect(settings.wdaURL.absoluteString == "http://127.0.0.1:8200")
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
    }

    @Test func storeSavesAndLoadsOneValue() throws {
        let defaults = try #require(UserDefaults(suiteName: "glasstap-tests-\(UUID().uuidString)"))
        #expect(SettingsStore.load(from: defaults) == .defaults)
        var settings = GlasstapSettings.defaults
        settings.encoder.codec = .h264
        settings.controlPort = 9400
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
