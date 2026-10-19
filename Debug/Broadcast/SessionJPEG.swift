#if DEBUG
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Called only by the bounded utility writer, never on the inference callback.
enum SessionJPEG {
    static func encode(_ buffer: CVPixelBuffer, orientation: UInt32?) throws -> Data {
        try autoreleasepool {
            let context = CIContext(options: [.cacheIntermediates: false])
            defer { context.clearCaches() }
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cgImage = context.createCGImage(image, from: image.extent) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
            if let orientation { properties[kCGImagePropertyOrientation] = orientation }
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            return data as Data
        }
    }
}
#endif
