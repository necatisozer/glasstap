// iPhone screen capture and hardware video encoder.
//
// Runs on the Mac that has the iPhone on USB, as the app bundle
// iPhoneCapture.app, because the camera permission (TCC) needs a desktop
// session. It captures the iPhone screen, encodes it with VideoToolbox, and
// serves the stream to the newest client that asks for 127.0.0.1:<port>/video.
//
// Options: --codec hevc|h264  --width <px>  --bitrate <bit/s>  --fps <n>  --port <n>
//
// Stream format, after a plain HTTP 200 header: a sequence of messages, each
// a 4-byte big-endian length, then 1 type byte, then the payload.
//   type 0: JSON config {"codec": WebCodecs codec string, "width", "height"}
//   type 1: key frame, Annex B with the parameter sets in front
//   type 2: delta frame, Annex B
//   type 3: a newer viewer took the stream. The server closes this one.
import AVFoundation
import CoreMediaIO
import Network
import VideoToolbox

setvbuf(stdout, nil, _IOLBF, 0)

var codec = "hevc"
var targetWidth = 590
var bitrate = 800_000
var fps = 30
var port: UInt16 = 9170
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    let v = args.next() ?? ""
    switch a {
    case "--codec": codec = v
    case "--width": targetWidth = Int(v) ?? targetWidth
    case "--bitrate": bitrate = Int(v) ?? bitrate
    case "--fps": fps = Int(v) ?? fps
    case "--port": port = UInt16(v) ?? port
    default: print("unknown option", a)
    }
}
let isHEVC = codec == "hevc"
print("codec \(codec), width \(targetWidth), bitrate \(bitrate), fps \(fps), port \(port)")

// MARK: - Clients (all state below is touched only on netQueue)

let netQueue = DispatchQueue(label: "net")
// A client more than this many frames behind skips to the next key frame.
let maxPending = 15

final class Client {
    let conn: NWConnection
    var active = false
    var needKey = true
    var pending = 0
    init(_ conn: NWConnection) { self.conn = conn }
}

var clients: [ObjectIdentifier: Client] = [:]
var configMessage: Data?
var wantKeyFrame = true

func message(_ type: UInt8, _ payload: Data) -> Data {
    var d = Data(capacity: payload.count + 5)
    var n = UInt32(payload.count + 1).bigEndian
    withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
    d.append(type)
    d.append(payload)
    return d
}

func drop(_ c: Client) {
    if clients.removeValue(forKey: ObjectIdentifier(c)) != nil {
        c.conn.cancel()
        print("client left, \(clients.count) connected")
    }
}

func send(_ c: Client, _ data: Data) {
    c.pending += 1
    c.conn.send(content: data, completion: .contentProcessed { err in
        netQueue.async {
            c.pending -= 1
            if err != nil { drop(c) }
        }
    })
}

func broadcast(_ frame: Data, key: Bool) {
    netQueue.async {
        let msg = message(key ? 1 : 2, frame)
        for c in clients.values where c.active {
            if c.needKey {
                guard key, let cfg = configMessage else { continue }
                c.needKey = false
                send(c, cfg)
            } else if c.pending > maxPending {
                c.needKey = true
                wantKeyFrame = true
                continue
            }
            send(c, msg)
        }
    }
}

/// The token that phone-remote writes for each run. Read on each request, so a new run needs no restart.
func readToken() -> String? {
    let path = NSHomeDirectory() + "/.tapstream/token"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
}

let viewerOrigins: Set<String> = ["http://127.0.0.1:9300", "http://localhost:9300"]

/// The value of one HTTP request header, matched without regard to case.
func httpHeader(_ name: String, in request: String) -> String? {
    for line in request.split(separator: "\r\n").dropFirst() {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2, parts[0].lowercased() == name {
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

func startServer() {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    // Bind to loopback only. The stream has no authentication.
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    let listener = try! NWListener(using: params)
    listener.newConnectionHandler = { conn in
        let c = Client(conn)
        clients[ObjectIdentifier(c)] = c
        conn.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: drop(c)
            default: break
            }
        }
        conn.start(queue: netQueue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            guard let data else { return drop(c) }
            let request = String(decoding: data, as: UTF8.self)
            func reject(_ status: String) {
                let text = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: text.data(using: .utf8), completion: .contentProcessed { _ in drop(c) })
            }
            // Reject DNS rebinding: a foreign site name that points at 127.0.0.1.
            let host = httpHeader("host", in: request)?.split(separator: ":").first.map(String.init) ?? ""
            guard host == "127.0.0.1" || host == "localhost" else { return reject("403 Forbidden") }
            // Serve only /video, so that stray requests from other pages
            // cannot take the stream from the viewer.
            guard request.hasPrefix("GET /video") else { return reject("404 Not Found") }
            // Require the token that phone-remote wrote, so that other local users cannot read the screen.
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let token = URLComponents(string: target)?.queryItems?.first { $0.name == "token" }?.value
            guard let expected = readToken(), token == expected else { return reject("403 Forbidden") }
            // Only the viewer page may read the stream. "*" would let any website read the screen.
            // A request from another website must not take the stream either, so refuse it.
            // Browsers send Sec-Fetch-Site even where they send no Origin (for <img> or <video>).
            var cors = ""
            if let origin = httpHeader("origin", in: request) {
                guard viewerOrigins.contains(origin) else { return reject("403 Forbidden") }
                cors = "Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\n"
            } else if httpHeader("sec-fetch-site", in: request) == "cross-site" {
                return reject("403 Forbidden")
            }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                + "Cache-Control: no-store\r\n\(cors)Connection: close\r\n\r\n"
            conn.send(content: header.data(using: .utf8), completion: .contentProcessed { _ in })
            // Keep only the newest viewer. All viewers share one SSH connection,
            // so a viewer that stops reading would stall the others.
            // Tell the old viewer, so that it stops and does not take the stream back.
            for old in clients.values where old !== c {
                clients.removeValue(forKey: ObjectIdentifier(old))
                old.conn.send(content: message(3, Data()), completion: .contentProcessed { _ in old.conn.cancel() })
            }
            c.active = true
            wantKeyFrame = true
            print("client joined, \(clients.count) connected")
        }
    }
    listener.stateUpdateHandler = { state in
        if case .failed(let e) = state { print("listener failed:", e); exit(1) }
        if case .ready = state { print("serving on 127.0.0.1:\(port)") }
    }
    listener.start(queue: netQueue)
}

// MARK: - Encoder

var session: VTCompressionSession?

func makeEncoder(width: Int, height: Int) {
    let type = isHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
    let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
    var status = VTCompressionSessionCreate(
        allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
        encoderSpecification: lowLatency, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    if status != noErr {
        print("low-latency encoder not available (\(status)), using the default encoder")
        status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    }
    guard status == noErr, let s = session else { print("encoder failed:", status); exit(1) }
    let profile = isHEVC ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel
    let props: [CFString: Any] = [
        kVTCompressionPropertyKey_RealTime: true,
        kVTCompressionPropertyKey_AllowFrameReordering: false,
        kVTCompressionPropertyKey_ProfileLevel: profile,
        kVTCompressionPropertyKey_AverageBitRate: bitrate,
        kVTCompressionPropertyKey_ExpectedFrameRate: fps,
        kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
    ]
    for (k, v) in props {
        let st = VTSessionSetProperty(s, key: k, value: v as CFTypeRef)
        if st != noErr { print("encoder property \(k) not set: \(st)") }
    }
    VTCompressionSessionPrepareToEncodeFrames(s)
    print("encoder ready: \(width)x\(height)")
}

let startCode: [UInt8] = [0, 0, 0, 1]

func parameterSets(_ fmt: CMFormatDescription) -> Data {
    var out = Data()
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
        if let ptr {
            out.append(contentsOf: startCode)
            out.append(ptr, count: size)
        }
    }
    return out
}

func codecString(_ fmt: CMFormatDescription) -> String {
    if isHEVC { return "hev1.1.6.L153.B0" }
    var ptr: UnsafePointer<UInt8>?
    var size = 0
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        fmt, parameterSetIndex: 0, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
    guard let sps = ptr, size >= 4 else { return "avc1.4d0033" }
    return String(format: "avc1.%02x%02x%02x", sps[1], sps[2], sps[3])
}

func encoded(_ sb: CMSampleBuffer) {
    guard let block = CMSampleBufferGetDataBuffer(sb),
          let fmt = CMSampleBufferGetFormatDescription(sb) else { return }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
    let key = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    let total = CMBlockBufferGetDataLength(block)
    var avcc = Data(count: total)
    avcc.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!) }
    var frame = key ? parameterSets(fmt) : Data()
    // VideoToolbox writes 4-byte length prefixes. Annex B needs start codes.
    var i = 0
    while i + 4 <= total {
        let n = Int(avcc[i]) << 24 | Int(avcc[i + 1]) << 16 | Int(avcc[i + 2]) << 8 | Int(avcc[i + 3])
        frame.append(contentsOf: startCode)
        frame.append(avcc.subdata(in: (i + 4)..<min(i + 4 + n, total)))
        i += 4 + n
    }
    if key {
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        let cfg = "{\"codec\":\"\(codecString(fmt))\",\"width\":\(dims.width),\"height\":\(dims.height)}"
        netQueue.async { configMessage = message(0, cfg.data(using: .utf8)!) }
    }
    broadcast(frame, key: key)
}

// MARK: - Capture

final class Capture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let output = AVCaptureVideoDataOutput()
    let queue = DispatchQueue(label: "capture")
    var scaled = false
    var lastEncode = CMTime.invalid
    // The capture device sends frames only while the screen changes. Keep the
    // last frame, so that a viewer who joins on a still screen gets a picture.
    var lastFrame: CVPixelBuffer?
    var idleTimer: DispatchSourceTimer?

    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if !scaled {
            // Let the capture pipeline scale the frames to the target size.
            let th = Int((Double(h) * Double(targetWidth) / Double(w) / 2).rounded()) * 2
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: targetWidth,
                kCVPixelBufferHeightKey as String: th,
            ]
            makeEncoder(width: targetWidth, height: th)
            scaled = true
            startIdleKeyFrames()
            return
        }
        lastFrame = pb
        encode(pb)
    }

    func encode(_ pb: CVPixelBuffer) {
        // Use one clock for every frame, because the idle timer re-encodes old frames.
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        if lastEncode.isValid, (pts - lastEncode).seconds < 0.9 / Double(fps) { return }
        lastEncode = pts
        var force = false
        netQueue.sync {
            force = wantKeyFrame
            wantKeyFrame = false
        }
        let props = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(
            session!, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { status, _, sb in
            if status == noErr, let sb { encoded(sb) }
        }
    }

    // If a viewer waits for a key frame and the screen is still, encode the last frame again.
    func startIdleKeyFrames() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [self] in
            guard let pb = lastFrame else { return }
            var waiting = false
            netQueue.sync { waiting = wantKeyFrame }
            if waiting { encode(pb) }
        }
        timer.resume()
        idleTimer = timer
    }
}

func findDevice() -> AVCaptureDevice? {
    // iOS screen devices stay hidden until the process opts in.
    var prop = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var allow: UInt32 = 1
    CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    // The device can take several seconds to appear.
    for _ in 0..<20 {
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .muxed, position: .unspecified
        ).devices.first { $0.modelID == "iOS Device" }
        if let found { return found }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }
    return nil
}

if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
    print("waiting for camera permission: click Allow for iPhone Capture on this Mac's screen")
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { _ in sem.signal() }
    while sem.wait(timeout: .now() + 0.2) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
}
guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
    print("error: no camera permission. Allow iPhone Capture in System Settings > Privacy & Security > Camera.")
    exit(1)
}
guard let device = findDevice() else { print("error: no iPhone screen device found. Is the iPhone on USB and unlocked?"); exit(1) }
print("device:", device.localizedName)

startServer()
let capture = Capture()
let captureSession = AVCaptureSession()
do { captureSession.addInput(try AVCaptureDeviceInput(device: device)) } catch { print("error: input:", error); exit(1) }
capture.output.alwaysDiscardsLateVideoFrames = true
capture.output.setSampleBufferDelegate(capture, queue: capture.queue)
captureSession.addOutput(capture.output)
captureSession.startRunning()
print("capture running")
RunLoop.main.run()
