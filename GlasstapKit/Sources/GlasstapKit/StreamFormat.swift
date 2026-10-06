import Foundation

/// The video stream format, after a plain HTTP 200 header: a sequence of
/// messages, each a 4-byte big-endian length, then 1 type byte, then the payload.
/// The length counts the type byte and the payload. A reader skips a type that it does not know.
/// Type 4 goes only to a viewer that asks for it with `stats=1` in the video URL, because
/// pages before it decode every type other than 0 and 3 as a frame.
public enum StreamMessageType: UInt8, Sendable {
    /// JSON config {"codec": WebCodecs codec string, "width", "height", "session"}.
    /// The viewer names the session when it reports the bytes it has received.
    case config = 0
    /// Key frame, Annex B with the parameter sets in front.
    case keyFrame = 1
    /// Delta frame, Annex B.
    case deltaFrame = 2
    /// A newer viewer took the stream. The server closes this one.
    case replaced = 3
    /// JSON stats {"bitrate": bits per second, "fps"}: the current encoder target.
    /// It comes when the viewer joins and at each change.
    case stats = 4
}

enum BigEndian {
    /// The 4-byte big-endian number that starts `offset` bytes into `bytes`.
    static func uint32<C: RandomAccessCollection>(_ bytes: C, at offset: Int) -> Int where C.Element == UInt8 {
        let start = bytes.index(bytes.startIndex, offsetBy: offset)
        var n = 0
        for b in bytes[start..<bytes.index(start, offsetBy: 4)] { n = n << 8 | Int(b) }
        return n
    }
}

public enum StreamMessage {
    public static func encode(_ type: StreamMessageType, _ payload: Data = Data()) -> Data {
        var d = Data(capacity: payload.count + 5)
        appendHeader(to: &d, payloadCount: payload.count, type: type)
        d.append(payload)
        return d
    }

    private static func appendHeader(to d: inout Data, payloadCount: Int, type: StreamMessageType) {
        withUnsafeBytes(of: UInt32(payloadCount + 1).bigEndian) { d.append(contentsOf: $0) }
        d.append(type.rawValue)
    }

    /// One frame message, built in one buffer: the header, then the parameter sets and the
    /// NAL units as Annex B. VideoToolbox writes NAL units with 4-byte length prefixes;
    /// Annex B needs start codes of the same size in their place.
    static func frame(key: Bool, parameterSets: [Data], lengthPrefixed avcc: UnsafeRawBufferPointer) -> Data {
        let setsCount = parameterSets.reduce(0) { $0 + AnnexB.startCode.count + $1.count }
        var d = Data(capacity: 5 + setsCount + avcc.count)
        appendHeader(to: &d, payloadCount: 0, type: key ? .keyFrame : .deltaFrame)
        for set in parameterSets {
            d.append(contentsOf: AnnexB.startCode)
            d.append(set)
        }
        let total = avcc.count
        var i = 0
        while i + 4 <= total {
            let n = BigEndian.uint32(avcc, at: i)
            d.append(contentsOf: AnnexB.startCode)
            d.append(contentsOf: avcc[(i + 4)..<min(i + 4 + n, total)])
            i += 4 + n
        }
        // The length is known only now.
        withUnsafeBytes(of: UInt32(d.count - 4).bigEndian) { d.replaceSubrange(d.startIndex..<(d.startIndex + 4), with: $0) }
        return d
    }

    /// Splits complete messages off the front of `buffer`, as the viewer page does.
    static func decode(_ buffer: inout Data) -> [(type: UInt8, payload: Data)] {
        var out: [(UInt8, Data)] = []
        while buffer.count >= 5 {
            let s = buffer.startIndex
            let n = BigEndian.uint32(buffer, at: 0)
            guard n >= 1, buffer.count >= 4 + n else { break }
            out.append((buffer[s + 4], Data(buffer[(s + 5)..<(s + 4 + n)])))
            buffer = Data(buffer[(s + 4 + n)...])
        }
        return out
    }
}

/// The payload of a config message.
public struct StreamConfig: Sendable, Equatable, Codable {
    public let codec: String
    public let width: Int
    public let height: Int
    /// The id of one viewer's stream. The JSON leaves it out when it is nil.
    public var session: String?

    public init(codec: String, width: Int, height: Int, session: String? = nil) {
        self.codec = codec
        self.width = width
        self.height = height
        self.session = session
    }

    /// Sorted keys, so that the same config always gives the same bytes.
    public var json: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try! encoder.encode(self)
    }
}

/// The payload of a stats message: what the encoder aims at now. Adaptive bitrate
/// lowers both below the settings while the link to the viewer is congested.
public struct StreamStats: Sendable, Equatable, Codable {
    /// Bits per second.
    public var bitrate: Int
    public var fps: Int

    public init(bitrate: Int, fps: Int) {
        self.bitrate = bitrate
        self.fps = fps
    }

    public var json: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(self)
    }
}

public enum AnnexB {
    public static let startCode: [UInt8] = [0, 0, 0, 1]
}

public enum CodecString {
    public static let hevc = "hev1.1.6.L153.B0"
    public static let h264Fallback = "avc1.4d0033"

    /// The WebCodecs string of an H.264 stream: profile, constraint flags and level from the SPS.
    public static func h264(sps: Data?) -> String {
        guard let sps, sps.count >= 4 else { return h264Fallback }
        let s = sps.startIndex
        return String(format: "avc1.%02x%02x%02x", sps[s + 1], sps[s + 2], sps[s + 3])
    }
}
