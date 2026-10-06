import CoreMedia
import CoreVideo
import Foundation
import os
import Testing
import VideoToolbox
@testable import GlasstapKit

/// The real VideoToolbox encoder on a synthetic frame. No capture device is involved.
@Suite struct EncoderTests {
    @Test(arguments: [VideoCodec.hevc, .h264])
    func encodesAScaledFirstFrameAsAKeyFrame(codec: VideoCodec) async throws {
        var native: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        #expect(CVPixelBufferCreate(nil, 1180, 2556, kCVPixelFormatType_32BGRA, attributes, &native) == kCVReturnSuccess)
        let source = try #require(native)
        let first = try #require(PixelScaler.scale(source, width: 590, height: 1278))

        let frames = OSAllocatedUnfairLock(initialState: [(message: Data, key: Bool, config: StreamConfig?)]())
        let settings = EncoderSettings(codec: codec, width: 590, bitrate: 800_000, fps: 30)
        let encoder = try Encoder(settings: settings, width: 590, height: 1278) { frame, key, config in
            frames.withLock { $0.append((frame, key, config)) }
        }
        defer { encoder.invalidate() }
        encoder.encode(first, pts: CMClockGetTime(CMClockGetHostTimeClock()), forceKeyFrame: true)
        for _ in 0..<250 where frames.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(20)) }

        let out = try #require(frames.withLock { $0.first })
        #expect(out.key)
        let config = try #require(out.config)
        #expect(config.width == 590)
        #expect(config.height == 1278)
        #expect(config.codec.hasPrefix(codec == .hevc ? "hev1." : "avc1."))
        // Annex B with the parameter sets first: a VPS for H.265, an SPS for H.264.
        // One whole stream message: the length covers the rest, and the type says key frame.
        var buffer = out.message
        let decoded = StreamMessage.decode(&buffer)
        #expect(buffer.isEmpty)
        #expect(decoded.map(\.type) == [StreamMessageType.keyFrame.rawValue])
        let frame = try #require(decoded.first).payload
        #expect(Array(frame.prefix(4)) == AnnexB.startCode)
        let nalType = codec == .hevc ? (frame[4] >> 1) & 0x3F : frame[4] & 0x1F
        #expect(nalType == (codec == .hevc ? 32 : 7))
    }

    /// A frame of one grey level. VideoToolbox drops a frame identical to the one before.
    func greyFrame(_ luma: Int32) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        #expect(CVPixelBufferCreate(nil, 590, 1278, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                    attributes, &created) == kCVReturnSuccess)
        let pb = try #require(created)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        for (plane, value) in [(0, luma), (1, 128)] {
            memset(CVPixelBufferGetBaseAddressOfPlane(pb, plane), value,
                   CVPixelBufferGetBytesPerRowOfPlane(pb, plane) * CVPixelBufferGetHeightOfPlane(pb, plane))
        }
        return pb
    }

    @Test(arguments: [VideoCodec.hevc, .h264])
    func aNewRateNeedsNoKeyFrame(codec: VideoCodec) async throws {
        let keys = OSAllocatedUnfairLock(initialState: [Bool]())
        let settings = EncoderSettings(codec: codec, width: 590, bitrate: 800_000, fps: 30)
        let encoder = try Encoder(settings: settings, width: 590, height: 1278) { _, key, _ in
            keys.withLock { $0.append(key) }
        }
        defer { encoder.invalidate() }
        let clock = CMClockGetHostTimeClock()
        // The encoder may drop a frame or two after the first key frame, so send several.
        for i in 0..<12 {
            if i == 6 {
                encoder.setBitrate(300_000)
                #expect(encoder.intProperty(kVTCompressionPropertyKey_AverageBitRate) == 300_000)
            }
            encoder.encode(try greyFrame(Int32(20 + i * 15)), pts: CMClockGetTime(clock), forceKeyFrame: i == 0)
            try await Task.sleep(for: .milliseconds(40))
        }
        for _ in 0..<50 where keys.withLock({ $0.count }) < 10 { try await Task.sleep(for: .milliseconds(20)) }
        let out = keys.withLock { $0 }
        #expect(out.count >= 10)
        #expect(out.first == true)
        #expect(!out.dropFirst().contains(true))
    }

    /// A lower expected frame rate makes VideoToolbox spend more bits on each frame, so the stream
    /// grows when the capture sends fewer frames. A new bitrate must leave it at the settings.
    @Test func aNewBitrateKeepsTheExpectedFrameRate() throws {
        let settings = EncoderSettings(codec: .hevc, width: 590, bitrate: 800_000, fps: 30)
        let encoder = try Encoder(settings: settings, width: 590, height: 1278) { _, _, _ in }
        defer { encoder.invalidate() }
        encoder.setBitrate(300_000)
        #expect(encoder.intProperty(kVTCompressionPropertyKey_AverageBitRate) == 300_000)
        #expect(encoder.intProperty(kVTCompressionPropertyKey_ExpectedFrameRate) == 30)
    }

    /// A smaller size is a new session, as the capture makes it: its first frame is a key frame,
    /// and the viewer gets the new config before it.
    @Test func aNewSizeComesWithANewConfigAndAKeyFrame() async throws {
        var native: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        #expect(CVPixelBufferCreate(nil, 590, 1278, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                    attributes, &native) == kCVReturnSuccess)
        let frame = try #require(native)
        let out = OSAllocatedUnfairLock(initialState: [(message: Data, key: Bool, config: StreamConfig?)]())
        let settings = EncoderSettings(codec: .hevc, width: 590, bitrate: 250_000, fps: 30)
        func encoder(width: Int, height: Int) throws -> Encoder {
            try Encoder(settings: settings, width: width, height: height, keyFrameInterval: 4) { m, key, config in
                out.withLock { $0.append((m, key, config)) }
            }
        }
        var state = ViewerState<Int>()
        _ = state.join(1)
        let clock = CMClockGetHostTimeClock()
        func next() async throws -> [UInt8] {
            let count = out.withLock { $0.count }
            for _ in 0..<250 where out.withLock({ $0.count }) == count { try await Task.sleep(for: .milliseconds(20)) }
            let e = try #require(out.withLock { $0.last })
            return try #require(state.frame(e.message, key: e.key, config: e.config).first).messages.map { $0[$0.startIndex + 4] }
        }
        let full = try encoder(width: 590, height: 1278)
        full.encode(frame, pts: CMClockGetTime(clock), forceKeyFrame: true)
        #expect(try await next() == [0, 1])
        full.invalidate()

        let small = try encoder(width: 392, height: 850)
        defer { small.invalidate() }
        // The frame still has the old size, as the capture's frames have just after the change.
        small.encode(try #require(PixelScaler.fit(frame, width: 392, height: 850)), pts: CMClockGetTime(clock), forceKeyFrame: true)
        #expect(try await next() == [0, 1])
        let config = try #require(out.withLock { $0.last?.config })
        #expect(config.width == 392 && config.height == 850)
        #expect(PixelScaler.fit(frame, width: 590, height: 1278) === frame)
    }
}
