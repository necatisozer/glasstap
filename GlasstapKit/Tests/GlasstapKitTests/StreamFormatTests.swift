import Foundation
import Testing
@testable import GlasstapKit

@Suite struct StreamFormatTests {
    @Test func messageLayout() {
        let m = StreamMessage.encode(.keyFrame, Data([0xAA, 0xBB]))
        #expect(Array(m) == [0, 0, 0, 3, 1, 0xAA, 0xBB])
        #expect(Array(StreamMessage.encode(.replaced)) == [0, 0, 0, 1, 3])
    }

    @Test func messageRoundTrip() throws {
        let config = StreamConfig(codec: CodecString.hevc, width: 590, height: 1278)
        let big = Data((0..<70_000).map { UInt8($0 % 251) })
        var stream = StreamMessage.encode(.config, config.json)
            + StreamMessage.encode(.keyFrame, big)
            + StreamMessage.encode(.deltaFrame, Data([1, 2, 3]))
            + StreamMessage.encode(.replaced)
        // Feed it in two pieces, cut inside the key frame, as a socket may deliver it.
        var buffer = Data(stream.prefix(1000))
        stream = Data(stream.dropFirst(1000))
        var messages = StreamMessage.decode(&buffer)
        #expect(messages.map(\.type) == [0])
        buffer.append(stream)
        messages += StreamMessage.decode(&buffer)
        #expect(buffer.isEmpty)
        #expect(messages.map(\.type) == [0, 1, 2, 3])
        #expect(try JSONDecoder().decode(StreamConfig.self, from: messages[0].payload) == config)
        #expect(messages[1].payload == big)
        #expect(messages[2].payload == Data([1, 2, 3]))
        #expect(messages[3].payload.isEmpty)
    }

    @Test func statsMessage() throws {
        let stats = StreamStats(bitrate: 620_000, fps: 15)
        #expect(String(decoding: stats.json, as: UTF8.self) == #"{"bitrate":620000,"fps":15}"#)
        var buffer = StreamMessage.encode(.stats, stats.json)
        let messages = StreamMessage.decode(&buffer)
        #expect(messages.map(\.type) == [4])
        #expect(try JSONDecoder().decode(StreamStats.self, from: messages[0].payload) == stats)
    }

    @Test func configJSON() throws {
        let json = StreamConfig(codec: "avc1.4d0033", width: 590, height: 1278).json
        #expect(String(decoding: json, as: UTF8.self) == #"{"codec":"avc1.4d0033","height":1278,"width":590}"#)
    }

    /// The payload of a frame message built from these length-prefixed NAL units.
    func annexB(_ avcc: [UInt8], sets: [Data] = [], key: Bool = false) -> [UInt8] {
        let message = avcc.withUnsafeBytes { StreamMessage.frame(key: key, parameterSets: sets, lengthPrefixed: $0) }
        return Array(message.dropFirst(5))
    }

    @Test func annexBFromLengthPrefixed() {
        #expect(annexB([0, 0, 0, 2, 0x65, 0x88, 0, 0, 0, 3, 0x41, 0x9A, 0x01])
            == [0, 0, 0, 1, 0x65, 0x88, 0, 0, 0, 1, 0x41, 0x9A, 0x01])
    }

    @Test func annexBStopsAtATruncatedUnit() {
        #expect(annexB([0, 0, 0, 5, 0x65, 0x88, 0, 0, 0]) == [0, 0, 0, 1, 0x65, 0x88, 0, 0, 0])
        #expect(annexB([0, 0]).isEmpty)
    }

    @Test func parameterSetsGoInFront() {
        let sets = [Data([0x40, 1]), Data([0x42, 2]), Data([0x44, 3])]
        #expect(annexB([0, 0, 0, 1, 0x26], sets: sets, key: true)
            == [0, 0, 0, 1, 0x40, 1, 0, 0, 0, 1, 0x42, 2, 0, 0, 0, 1, 0x44, 3, 0, 0, 0, 1, 0x26])
    }

    @Test func bigEndianFromASlice() {
        // Data slices keep their parent's indices. The reader must count from the start of the slice.
        let parent = Data([9, 9, 0, 0, 1, 2, 7])
        #expect(BigEndian.uint32(parent[2...], at: 0) == 0x0102)
        #expect(BigEndian.uint32(parent, at: 1) == 0x09_00_00_01)
    }

    /// The conversion of earlier versions: Annex B first, then a framed copy of it.
    func twoStep(_ avcc: Data, sets: [Data], key: Bool) -> Data {
        var frame = Data()
        for set in sets { frame.append(contentsOf: AnnexB.startCode); frame.append(set) }
        var i = 0
        while i + 4 <= avcc.count {
            let n = Int(avcc[i]) << 24 | Int(avcc[i + 1]) << 16 | Int(avcc[i + 2]) << 8 | Int(avcc[i + 3])
            frame.append(contentsOf: AnnexB.startCode)
            frame.append(avcc[(i + 4)..<min(i + 4 + n, avcc.count)])
            i += 4 + n
        }
        return StreamMessage.encode(key ? .keyFrame : .deltaFrame, frame)
    }

    @Test(arguments: [true, false])
    func singleBufferEqualsTwoSteps(key: Bool) {
        var rng = SystemRandomNumberGenerator()
        var avcc = Data()
        for size in [1, 17, 300, 70_000, 2] {
            withUnsafeBytes(of: UInt32(size).bigEndian) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: (0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) })
        }
        avcc.append(contentsOf: [0, 0, 1, 0, 0xAA])  // a truncated last unit
        let sets = key ? [Data([0x40, 1, 2]), Data([0x42, 3]), Data([0x44, 4])] : []
        let single = avcc.withUnsafeBytes { StreamMessage.frame(key: key, parameterSets: sets, lengthPrefixed: $0) }
        #expect(single == twoStep(avcc, sets: sets, key: key))
    }

    @Test func h264CodecString() {
        #expect(CodecString.h264(sps: Data([0x67, 0x4D, 0x00, 0x33, 0xAB])) == "avc1.4d0033")
        #expect(CodecString.h264(sps: Data([0x67, 0x64, 0x00, 0x1F])) == "avc1.64001f")
        #expect(CodecString.h264(sps: Data([0x67, 0x4D])) == CodecString.h264Fallback)
        #expect(CodecString.h264(sps: nil) == CodecString.h264Fallback)
    }
}
