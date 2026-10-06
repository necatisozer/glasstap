import CoreMedia
import Foundation
import os
import VideoToolbox

/// A real-time VideoToolbox encoder that hands out ready stream messages of Annex B frames.
final class Encoder: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "the encoder failed to start (\(status))" }
    }

    private let session: VTCompressionSession
    private let codec: VideoCodec
    private let onFrame: @Sendable (_ message: Data, _ key: Bool, _ config: StreamConfig?) -> Void
    /// A frame that failed or that VideoToolbox dropped. A key frame may still be owed.
    private let onDrop: @Sendable () -> Void
    private let log = Logger(subsystem: "io.github.necatisozer.glasstap", category: "encoder")

    /// `keyFrameInterval` is the most seconds between two key frames.
    init(settings: EncoderSettings, width: Int, height: Int, keyFrameInterval: Int = 2,
         onDrop: @escaping @Sendable () -> Void = {},
         onFrame: @escaping @Sendable (_ message: Data, _ key: Bool, _ config: StreamConfig?) -> Void) throws {
        codec = settings.codec
        self.onFrame = onFrame
        self.onDrop = onDrop
        let isHEVC = settings.codec == .hevc
        let type = isHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var created: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
            encoderSpecification: lowLatency, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        if status != noErr {
            log.notice("low-latency encoder not available (\(status)), using the default encoder")
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        guard status == noErr, let created else { throw Failure(status: status) }
        session = created
        let profile = isHEVC ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: profile,
            kVTCompressionPropertyKey_AverageBitRate: settings.bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: settings.fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: keyFrameInterval,
        ]
        set(props)
        VTCompressionSessionPrepareToEncodeFrames(created)
        log.info("encoder ready: \(width)x\(height) \(settings.codec.rawValue)")
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyFrame: Bool) {
        let props = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [self] status, flags, sampleBuffer in
            guard status == noErr, !flags.contains(.frameDropped), let sampleBuffer, encoded(sampleBuffer) else {
                return onDrop()
            }
        }
    }

    /// Changes the bitrate of the running session. VideoToolbox applies it from the next frame,
    /// with no new key frame. The expected frame rate stays at the settings even when the capture
    /// sends fewer frames: a lower one makes VideoToolbox spend more bits on each frame, and
    /// the stream then grows (measured: 245 kbit/s at 5 fps against 185 at 30, for 150 kbit/s).
    func setBitrate(_ bitrate: Int) {
        set([kVTCompressionPropertyKey_AverageBitRate: bitrate])
    }

    /// The current value of a number property, for tests.
    func intProperty(_ key: CFString) -> Int? {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: $0)
        }
        guard status == noErr else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private func set(_ props: [CFString: Any]) {
        for (k, v) in props {
            let st = VTSessionSetProperty(session, key: k, value: v as CFTypeRef)
            if st != noErr { log.notice("encoder property \(k as String) not set: \(st)") }
        }
    }

    /// Hands out the frames still in the encoder, then ends the session. A new session for
    /// another size must not get frames of the old one after its own config.
    func invalidate() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    /// Returns false if the sample buffer held no usable frame.
    private func encoded(_ sb: CMSampleBuffer) -> Bool {
        guard let block = CMSampleBufferGetDataBuffer(sb),
              let fmt = CMSampleBufferGetFormatDescription(sb) else { return false }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let key = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        let sets = key ? parameterSets(fmt) : []
        let total = CMBlockBufferGetDataLength(block)
        // Read the encoder's buffer in place when it is in one piece, which it normally is.
        var contiguous = 0
        var pointer: UnsafeMutablePointer<CChar>?
        let message: Data
        if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguous, totalLengthOut: nil,
                                       dataPointerOut: &pointer) == noErr, let pointer, contiguous == total {
            message = StreamMessage.frame(key: key, parameterSets: sets,
                                          lengthPrefixed: UnsafeRawBufferPointer(start: pointer, count: total))
        } else {
            var copy = Data(count: total)
            let status = copy.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!)
            }
            guard status == noErr else { return false }
            message = copy.withUnsafeBytes { StreamMessage.frame(key: key, parameterSets: sets, lengthPrefixed: $0) }
        }
        var config: StreamConfig?
        if key {
            let dims = CMVideoFormatDescriptionGetDimensions(fmt)
            let codecString = codec == .hevc ? CodecString.hevc : CodecString.h264(sps: sets.first)
            config = StreamConfig(codec: codecString, width: Int(dims.width), height: Int(dims.height))
        }
        onFrame(message, key, config)
        return true
    }

    /// VPS, SPS and PPS for H.265; SPS and PPS for H.264.
    private func parameterSets(_ fmt: CMFormatDescription) -> [Data] {
        let isHEVC = codec == .hevc
        var count = 0
        if isHEVC {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            if isHEVC {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            if let ptr { sets.append(Data(bytes: ptr, count: size)) }
        }
        return sets
    }
}
