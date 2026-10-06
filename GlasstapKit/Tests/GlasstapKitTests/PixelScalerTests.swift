import CoreVideo
import Testing
@testable import GlasstapKit

@Suite struct PixelScalerTests {
    /// A native-size frame in one colour.
    func frame(width: Int, height: Int, format: OSType, fill: UInt8) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        #expect(CVPixelBufferCreate(nil, width, height, format, attributes, &pb) == kCVReturnSuccess)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let planes = max(CVPixelBufferGetPlaneCount(buffer), 1)
        for p in 0..<planes {
            let isPlanar = CVPixelBufferIsPlanar(buffer)
            let base = isPlanar ? CVPixelBufferGetBaseAddressOfPlane(buffer, p) : CVPixelBufferGetBaseAddress(buffer)
            let rows = isPlanar ? CVPixelBufferGetHeightOfPlane(buffer, p) : height
            let stride = isPlanar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, p) : CVPixelBufferGetBytesPerRow(buffer)
            // Luma takes the fill value. Chroma is neutral grey.
            memset(base, Int32(p == 0 || !isPlanar ? fill : 128), rows * stride)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func firstLuma(_ pb: CVPixelBuffer) -> UInt8 {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        return base[row * 100 + 100]
    }

    @Test(arguments: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA])
    func scalesTheFirstFrameToTheStreamSize(format: OSType) throws {
        let native = try frame(width: 1180, height: 2556, format: format, fill: 200)
        let scaled = try #require(PixelScaler.scale(native, width: 590, height: 1278))
        #expect(CVPixelBufferGetWidth(scaled) == 590)
        #expect(CVPixelBufferGetHeight(scaled) == 1278)
        #expect(CVPixelBufferGetPixelFormatType(scaled) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(CVPixelBufferGetIOSurface(scaled) != nil)
        // The picture survives the transfer: not black.
        #expect(firstLuma(scaled) > 100)
    }
}
