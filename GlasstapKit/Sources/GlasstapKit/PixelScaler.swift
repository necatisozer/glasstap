import CoreVideo
import VideoToolbox

/// Scales one frame to the stream size. The capture output scales every frame after the
/// first; this one scales the first frame, which arrives before the output knows the size.
enum PixelScaler {
    /// `source` itself if it has this size already, else a scaled copy.
    static func fit(_ source: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(source) == width, CVPixelBufferGetHeight(source) == height { return source }
        return scale(source, width: width, height: height)
    }

    static func scale(_ source: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        var created: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created) == noErr,
              let transfer = created else { return nil }
        defer { VTPixelTransferSessionInvalidate(transfer) }
        // IOSurface backing, as the encoder prefers for its input.
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attributes, &output) == kCVReturnSuccess,
              let output,
              VTPixelTransferSessionTransferImage(transfer, from: source, to: output) == noErr
        else { return nil }
        return output
    }
}
