import CoreVideo
import Foundation

// Cheap, resolution-independent heuristic for "does this frame look like
// YouTube Shorts" — NOT machine learning. The Broadcast Upload Extension
// process has a hard ~50MB memory ceiling, which rules out Vision/CoreML/
// CIContext, so this samples a handful of raw pixel-buffer bytes instead.
//
// This is deliberately brittle: sample points are fractions of frame
// width/height (not absolute pixels) so it's at least resolution-independent
// across device sizes, but it WILL drift whenever YouTube reshuffles its
// Shorts UI, and it hasn't been tuned against light/dark mode or locale
// variants. Expected to need empirical retuning after shipping — not an
// attempt at high-precision detection.
enum ShortsHeuristics {
    /// Process roughly every Nth video frame (~twice a second at 30fps) —
    /// keeps the common (non-sampled) frame essentially free.
    static let sampleEveryNFrames = 15
    /// Don't re-fire a detection more often than this even if every sampled
    /// frame still looks like Shorts.
    static let minRedetectionInterval: TimeInterval = 4

    // YouTube Shorts keeps a persistent vertical rail of rounded icon
    // buttons (like/comment/share/remix) along the right edge of the frame.
    private static let iconRailPoints: [(x: CGFloat, y: CGFloat)] = [
        (0.92, 0.35), (0.92, 0.50), (0.92, 0.62), (0.92, 0.75)
    ]
    // A full-width near-black band top and bottom usually means a normal
    // landscape video is playing (letterboxed), not a full-bleed vertical
    // Shorts clip — used as a negative signal to suppress false positives.
    private static let letterboxScanRowsY: [CGFloat] = [0.03, 0.97]

    static func looksLikeShorts(_ pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 1, height > 1 else { return false }

        for fy in letterboxScanRowsY {
            let y = min(max(Int(fy * CGFloat(height)), 0), height - 1)
            if isUniformDarkRow(base: base, width: width, bytesPerRow: bytesPerRow, y: y) {
                return false
            }
        }

        let samples = iconRailPoints.map { point -> Pixel in
            let x = min(max(Int(point.x * CGFloat(width)), 0), width - 1)
            let y = min(max(Int(point.y * CGFloat(height)), 0), height - 1)
            return readPixel(base: base, bytesPerRow: bytesPerRow, x: x, y: y)
        }
        return hasConsistentIconRail(samples)
    }

    private struct Pixel {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    private static func readPixel(base: UnsafeMutableRawPointer, bytesPerRow: Int, x: Int, y: Int) -> Pixel {
        // Screen-capture sample buffers are typically BGRA.
        let offset = y * bytesPerRow + x * 4
        let ptr = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        return Pixel(r: ptr[2], g: ptr[1], b: ptr[0])
    }

    private static func luminance(_ p: Pixel) -> Double {
        0.299 * Double(p.r) + 0.587 * Double(p.g) + 0.114 * Double(p.b)
    }

    private static func isUniformDarkRow(base: UnsafeMutableRawPointer, width: Int, bytesPerRow: Int, y: Int) -> Bool {
        var maxLuma = 0.0
        var x = 0
        let step = max(width / 8, 1)
        while x < width {
            let p = readPixel(base: base, bytesPerRow: bytesPerRow, x: x, y: y)
            maxLuma = max(maxLuma, luminance(p))
            x += step
        }
        return maxLuma < 18
    }

    private static func hasConsistentIconRail(_ samples: [Pixel]) -> Bool {
        guard samples.count == iconRailPoints.count else { return false }
        // The icon rail sits on a translucent dark scrim over the video, so
        // look for consistently darker-than-midtone samples rather than an
        // exact color match (which varies with whatever video is behind it).
        let lumas = samples.map(luminance)
        guard let minLuma = lumas.min(), let maxLuma = lumas.max() else { return false }
        let allDarkish = lumas.allSatisfy { $0 < 140 }
        let variance = maxLuma - minLuma
        return allDarkish && variance < 60
    }
}
