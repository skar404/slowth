#if DEBUG
import XCTest
import CoreVideo
import ImageIO
@testable import CascadeRuntime

final class SessionPNGTests: XCTestCase {
    func testPNGRoundTripPreservesOpaquePixelPattern() throws {
        var buffer: CVPixelBuffer?
        let width = 64, height = 48
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        var expected = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let values: [UInt8] = [UInt8(x * 4), UInt8(y * 5), UInt8((x ^ y) * 3), 255]
            for c in 0..<4 { base[y * stride + x * 4 + c] = values[c]; expected[(y * width + x) * 4 + c] = values[c] }
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let encoded = try SessionPNG.encode(pixels, orientation: nil)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var decoded = [UInt8](repeating: 0, count: expected.count)
        let color = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        try decoded.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: color, bitmapInfo: bitmap))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        XCTAssertEqual(decoded, expected)
    }

    func testFullResolutionPNGWithOrientation() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 480,
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 255, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let data = try SessionPNG.encode(pixels, orientation: 6)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 640)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 480)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int, 6)
    }
}
#endif
