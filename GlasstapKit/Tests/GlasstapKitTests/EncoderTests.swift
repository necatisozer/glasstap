import CoreMedia
import CoreVideo
import Foundation
import os
import Testing
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
}
