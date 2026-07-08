import AppKit

// Slowth — a sleepy sloth that saves you from doom-scrolling.
// Generates square PNGs at the given sizes by drawing the sloth face
// programmatically with NSBezierPath (no external assets).

let outDir = CommandLine.arguments.dropFirst().first ?? "."
let sizes = [16, 32, 48, 64, 96, 128, 256, 512, 1024]

private func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r/255, green: g/255, blue: b/255, alpha: a)
}

private func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
}

private func rotated(_ path: NSBezierPath, around point: CGPoint, byDegrees deg: CGFloat) -> NSBezierPath {
    let t = NSAffineTransform()
    t.translateX(by: point.x, yBy: point.y)
    t.rotate(byDegrees: deg)
    t.translateX(by: -point.x, yBy: -point.y)
    let copy = path.copy() as! NSBezierPath
    copy.transform(using: t as AffineTransform)
    return copy
}

func makeIcon(size: Int) -> Data? {
    let dim = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    ) else { return nil }
    rep.size = NSSize(width: dim, height: dim)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: dim, height: dim)
    let radius = dim * 0.225

    // Rounded square bg
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()

    // Background: leafy green gradient (top lighter, bottom deeper) — calm, nature.
    let bg = NSGradient(colors: [
        col(168, 215, 158),
        col(86, 158, 110)
    ])!
    bg.draw(in: rect, angle: 270)

    // Soft top highlight
    let highlight = NSGradient(colors: [
        NSColor(white: 1.0, alpha: 0.18),
        NSColor(white: 1.0, alpha: 0.0)
    ])!
    highlight.draw(in: NSRect(x: 0, y: dim * 0.55, width: dim, height: dim * 0.45), angle: 270)

    // ---- Sloth ----
    // Coordinate origin is bottom-left in AppKit. We design with y upward.

    // Branch: dark wood bar near the top
    let branchH = max(dim * 0.045, 1)
    let branchY = dim * 0.84
    let branchPad = dim * 0.10
    col(80, 55, 38).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: branchPad, y: branchY, width: dim - branchPad * 2, height: branchH),
        xRadius: branchH / 2, yRadius: branchH / 2
    ).fill()

    // Two arms: small claws gripping the branch
    let armW = dim * 0.045
    let armH = dim * 0.13
    let leftArmX = dim * 0.30
    let rightArmX = dim * 0.70 - armW
    col(95, 65, 45).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: leftArmX, y: branchY - armH * 0.55, width: armW, height: armH),
        xRadius: armW / 2, yRadius: armW / 2
    ).fill()
    NSBezierPath(
        roundedRect: NSRect(x: rightArmX, y: branchY - armH * 0.55, width: armW, height: armH),
        xRadius: armW / 2, yRadius: armW / 2
    ).fill()

    // Body (rounded oval, slightly taller than wide), behind face
    let bodyCX = dim * 0.5
    let bodyCY = dim * 0.36
    let bodyRX = dim * 0.30
    let bodyRY = dim * 0.30
    col(150, 110, 75).setFill()
    ellipse(bodyCX, bodyCY, bodyRX, bodyRY).fill()

    // Face (lighter cream oval)
    let faceCX = dim * 0.5
    let faceCY = dim * 0.50
    let faceRX = dim * 0.32
    let faceRY = dim * 0.30
    col(232, 206, 168).setFill()
    ellipse(faceCX, faceCY, faceRX, faceRY).fill()

    // Eye masks: two dark teardrop ovals, slightly tilted outward.
    let maskColor = col(70, 48, 32)
    maskColor.setFill()
    let maskRX = dim * 0.085
    let maskRY = dim * 0.115
    let maskCY = faceCY + dim * 0.02
    let leftMaskCX = faceCX - dim * 0.115
    let rightMaskCX = faceCX + dim * 0.115
    let leftMask = ellipse(leftMaskCX, maskCY, maskRX, maskRY)
    let rightMask = ellipse(rightMaskCX, maskCY, maskRX, maskRY)
    rotated(leftMask, around: CGPoint(x: leftMaskCX, y: maskCY), byDegrees: 18).fill()
    rotated(rightMask, around: CGPoint(x: rightMaskCX, y: maskCY), byDegrees: -18).fill()

    // Eyes: small white sclera with dark pupil — calm, content gaze
    let eyeRX = dim * 0.028
    let eyeRY = dim * 0.034
    let pupilR = dim * 0.018
    let eyeCY = maskCY + dim * 0.005
    NSColor.white.setFill()
    ellipse(leftMaskCX + dim * 0.005, eyeCY, eyeRX, eyeRY).fill()
    ellipse(rightMaskCX - dim * 0.005, eyeCY, eyeRX, eyeRY).fill()
    col(30, 22, 18).setFill()
    ellipse(leftMaskCX + dim * 0.010, eyeCY - dim * 0.002, pupilR, pupilR).fill()
    ellipse(rightMaskCX - dim * 0.010, eyeCY - dim * 0.002, pupilR, pupilR).fill()

    // Nose: small soft triangle/oval below eyes
    col(62, 42, 30).setFill()
    let noseY = faceCY - dim * 0.085
    ellipse(faceCX, noseY, dim * 0.028, dim * 0.022).fill()

    // Mouth: gentle smile (two small arcs from nose corners)
    let mouthY = noseY - dim * 0.045
    let mouthSpan = dim * 0.065
    let mouthDepth = dim * 0.018
    let smile = NSBezierPath()
    smile.move(to: NSPoint(x: faceCX - mouthSpan, y: mouthY + mouthDepth))
    smile.curve(
        to: NSPoint(x: faceCX, y: mouthY - mouthDepth * 0.4),
        controlPoint1: NSPoint(x: faceCX - mouthSpan * 0.5, y: mouthY - mouthDepth),
        controlPoint2: NSPoint(x: faceCX - mouthSpan * 0.2, y: mouthY - mouthDepth * 0.6)
    )
    smile.curve(
        to: NSPoint(x: faceCX + mouthSpan, y: mouthY + mouthDepth),
        controlPoint1: NSPoint(x: faceCX + mouthSpan * 0.2, y: mouthY - mouthDepth * 0.6),
        controlPoint2: NSPoint(x: faceCX + mouthSpan * 0.5, y: mouthY - mouthDepth)
    )
    col(62, 42, 30).setStroke()
    smile.lineWidth = max(dim * 0.012, 1)
    smile.lineCapStyle = .round
    smile.stroke()

    // Tiny cheek blush for charm (skip on smallest sizes for legibility)
    if dim >= 64 {
        col(220, 150, 120, 0.55).setFill()
        ellipse(faceCX - dim * 0.205, faceCY - dim * 0.07, dim * 0.040, dim * 0.022).fill()
        ellipse(faceCX + dim * 0.205, faceCY - dim * 0.07, dim * 0.040, dim * 0.022).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for size in sizes {
    guard let png = makeIcon(size: size) else { continue }
    let path = "\(outDir)/icon-\(size).png"
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
