import Accelerate
import CoreVideo
import Darwin
import Foundation

enum ModelImageResizerError: LocalizedError {
    case destinationBufferCreationFailed(CVReturn)
    case unsupportedPixelFormat(OSType)
    case invalidPlaneLayout
    case missingBaseAddress
    case resizeFailed(vImage_Error)
    case colorConversionSetupFailed(vImage_Error)
    case colorConversionFailed(vImage_Error)

    var errorDescription: String? {
        switch self {
        case .destinationBufferCreationFailed(let status):
            return "pixel buffer creation failed (\(status))"
        case .unsupportedPixelFormat(let format):
            return "unsupported source pixel format (\(format))"
        case .invalidPlaneLayout:
            return "source pixel buffer has an invalid NV12 plane layout"
        case .missingBaseAddress:
            return "pixel buffer has no base address"
        case .resizeFailed(let status):
            return "vImage resize failed (\(status))"
        case .colorConversionSetupFailed(let status):
            return "YUV conversion setup failed (\(status))"
        case .colorConversionFailed(let status):
            return "YUV to BGRA conversion failed (\(status))"
        }
    }
}

/// Converts ReplayKit BGRA/NV12 frames to the fixed BGRA input expected by a
/// Core ML image model. Each classifier owns one instance because its input
/// dimensions and scratch buffers may differ.
final class ModelImageResizer {
    let width: Int
    let height: Int

    private let destinationBuffer: CVPixelBuffer
    private let fullRangeConversion: vImage_YpCbCrToARGB
    private let videoRangeConversion: vImage_YpCbCrToARGB
    private var scaledLuma: [UInt8]
    private var scaledChroma: [UInt8]

    init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw ModelImageResizerError.invalidPlaneLayout
        }
        self.width = width
        self.height = height

        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: false,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw ModelImageResizerError.destinationBufferCreationFailed(status)
        }
        destinationBuffer = buffer
        fullRangeConversion = try Self.makeYUVConversion(fullRange: true)
        videoRangeConversion = try Self.makeYUVConversion(fullRange: false)
        scaledLuma = [UInt8](repeating: 0, count: width * height)
        scaledChroma = [UInt8](repeating: 0, count: width * height / 2)
    }

    func resize(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        switch CVPixelBufferGetPixelFormatType(source) {
        case kCVPixelFormatType_32BGRA:
            try resizeBGRA(source)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            try resizeNV12(source, conversion: fullRangeConversion)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            try resizeNV12(source, conversion: videoRangeConversion)
        default:
            throw ModelImageResizerError.unsupportedPixelFormat(
                CVPixelBufferGetPixelFormatType(source)
            )
        }
        return destinationBuffer
    }

    /// Copies the exact BGRA image most recently passed to Core ML. The copy is
    /// intentionally small (the model input size) and safe to encode later on a
    /// background queue after ReplayKit reuses its source pixel buffer.
    func copyCurrentBGRABytes() throws -> (data: Data, bytesPerRow: Int) {
        CVPixelBufferLockBaseAddress(destinationBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(destinationBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(destinationBuffer) else {
            throw ModelImageResizerError.missingBaseAddress
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(destinationBuffer)
        return (
            Data(bytes: baseAddress, count: bytesPerRow * height),
            bytesPerRow
        )
    }

    private func resizeBGRA(_ source: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destinationBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destinationBuffer, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destinationBuffer) else {
            throw ModelImageResizerError.missingBaseAddress
        }

        var sourceImage = vImage_Buffer(
            data: sourceBase,
            height: vImagePixelCount(CVPixelBufferGetHeight(source)),
            width: vImagePixelCount(CVPixelBufferGetWidth(source)),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )
        var destinationImage = vImage_Buffer(
            data: destinationBase,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(destinationBuffer)
        )
        let status = vImageScale_ARGB8888(
            &sourceImage,
            &destinationImage,
            nil,
            vImage_Flags(kvImageHighQualityResampling)
        )
        guard status == kvImageNoError else {
            throw ModelImageResizerError.resizeFailed(status)
        }
    }

    private func resizeNV12(_ source: CVPixelBuffer, conversion: vImage_YpCbCrToARGB) throws {
        guard CVPixelBufferIsPlanar(source), CVPixelBufferGetPlaneCount(source) >= 2 else {
            throw ModelImageResizerError.invalidPlaneLayout
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destinationBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destinationBuffer, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard let sourceLumaBase = CVPixelBufferGetBaseAddressOfPlane(source, 0),
              let sourceChromaBase = CVPixelBufferGetBaseAddressOfPlane(source, 1),
              let destinationBase = CVPixelBufferGetBaseAddress(destinationBuffer) else {
            throw ModelImageResizerError.missingBaseAddress
        }

        var sourceLuma = vImage_Buffer(
            data: sourceLumaBase,
            height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(source, 0)),
            width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(source, 0)),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(source, 0)
        )
        var sourceChroma = vImage_Buffer(
            data: sourceChromaBase,
            height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(source, 1)),
            width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(source, 1)),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(source, 1)
        )
        var destination = vImage_Buffer(
            data: destinationBase,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(destinationBuffer)
        )

        let status = scaledLuma.withUnsafeMutableBytes { lumaBytes -> vImage_Error in
            scaledChroma.withUnsafeMutableBytes { chromaBytes -> vImage_Error in
                guard let lumaBase = lumaBytes.baseAddress,
                      let chromaBase = chromaBytes.baseAddress else {
                    return kvImageNullPointerArgument
                }
                var destinationLuma = vImage_Buffer(
                    data: lumaBase,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var destinationChroma = vImage_Buffer(
                    data: chromaBase,
                    height: vImagePixelCount(height / 2),
                    width: vImagePixelCount(width / 2),
                    rowBytes: width
                )

                let flags = vImage_Flags(kvImageHighQualityResampling)
                let lumaStatus = vImageScale_Planar8(
                    &sourceLuma,
                    &destinationLuma,
                    nil,
                    flags
                )
                guard lumaStatus == kvImageNoError else { return lumaStatus }
                let chromaStatus = vImageScale_CbCr8(
                    &sourceChroma,
                    &destinationChroma,
                    nil,
                    flags
                )
                guard chromaStatus == kvImageNoError else { return chromaStatus }

                var conversion = conversion
                let bgraPermutation: [UInt8] = [3, 2, 1, 0]
                return bgraPermutation.withUnsafeBufferPointer { permutation in
                    vImageConvert_420Yp8_CbCr8ToARGB8888(
                        &destinationLuma,
                        &destinationChroma,
                        &destination,
                        &conversion,
                        permutation.baseAddress!,
                        255,
                        vImage_Flags(kvImageNoFlags)
                    )
                }
            }
        }
        guard status == kvImageNoError else {
            if status == kvImageNullPointerArgument {
                throw ModelImageResizerError.missingBaseAddress
            }
            throw ModelImageResizerError.colorConversionFailed(status)
        }
    }

    private static func makeYUVConversion(fullRange: Bool) throws -> vImage_YpCbCrToARGB {
        var pixelRange = vImage_YpCbCrPixelRange(
            Yp_bias: fullRange ? 0 : 16,
            CbCr_bias: 128,
            YpRangeMax: fullRange ? 255 : 235,
            CbCrRangeMax: fullRange ? 255 : 240,
            YpMax: 255,
            YpMin: 0,
            CbCrMax: 255,
            CbCrMin: 0
        )
        var conversion = vImage_YpCbCrToARGB()
        let status = vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_709_2,
            &pixelRange,
            &conversion,
            kvImage420Yp8_CbCr8,
            kvImageARGB8888,
            vImage_Flags(kvImageNoFlags)
        )
        guard status == kvImageNoError else {
            throw ModelImageResizerError.colorConversionSetupFailed(status)
        }
        return conversion
    }
}

enum RealtimeShieldMemory {
    static var availableMB: Double {
        Double(os_proc_available_memory()) / 1_048_576
    }

    static var currentFootprintMB: Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }
}
