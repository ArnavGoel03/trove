// icon-source.swift — emit a 1024×1024 PNG of the Trove app icon.
//   usage:  swift icon-source.swift /path/to/icon-1024.png

import AppKit
import CoreGraphics

let outPath = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// ---------- Squircle background with diagonal gradient ----------
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let cornerRadius: CGFloat = size * 0.2237  // standard macOS Big Sur squircle ratio
let squircle = NSBezierPath(roundedRect: NSRectFromCGRect(rect),
                            xRadius: cornerRadius,
                            yRadius: cornerRadius)
ctx.saveGState()
squircle.addClip()

// Brand gradient: deep indigo → cyan-blue
let colors: [CGColor] = [
    CGColor(srgbRed: 0.10, green: 0.20, blue: 0.65, alpha: 1.0),
    CGColor(srgbRed: 0.30, green: 0.55, blue: 1.00, alpha: 1.0),
]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: size),
                       end:   CGPoint(x: size, y: 0),
                       options: [])

// ---------- Foreground: a stacked-cards motif (the Stage metaphor) ----------
// Three offset rounded rects, each slightly bigger and brighter, evoking
// "collect multiple things into one place."
let cardCount = 3
let cardW: CGFloat = size * 0.58
let cardH: CGFloat = size * 0.40
let cardR: CGFloat = size * 0.048
let centerX = size / 2
let centerY = size / 2 + size * 0.02
let stackOffset: CGFloat = size * 0.045

for i in 0..<cardCount {
    let i_f = CGFloat(i)
    let inset = CGFloat(cardCount - 1 - i)  // largest card is "front" (i=cardCount-1)
    let alpha: CGFloat = 0.55 + 0.20 * (i_f / CGFloat(cardCount - 1))
    let yOff = stackOffset * (CGFloat(cardCount - 1 - i)) - stackOffset * 1.2
    let xOff = stackOffset * 0.55 * (CGFloat(cardCount - 1 - i))

    let w = cardW - inset * size * 0.025
    let h = cardH - inset * size * 0.018
    let cardRect = CGRect(
        x: centerX - w/2 - xOff,
        y: centerY - h/2 + yOff,
        width: w, height: h
    )
    // soft shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                  blur: size * 0.025,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22))
    let p = NSBezierPath(roundedRect: NSRectFromCGRect(cardRect),
                         xRadius: cardR, yRadius: cardR)
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha).setFill()
    p.fill()
    ctx.restoreGState()
}

// ---------- Subtle inner highlight along the top of the squircle ----------
ctx.saveGState()
let highlightPath = NSBezierPath(roundedRect: NSRectFromCGRect(rect.insetBy(dx: 6, dy: 6)),
                                 xRadius: cornerRadius - 6,
                                 yRadius: cornerRadius - 6)
highlightPath.addClip()
let highlightGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: [
                                       CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
                                       CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
                                   ] as CFArray,
                                   locations: [0, 0.35])!
ctx.drawLinearGradient(highlightGradient,
                       start: CGPoint(x: 0, y: size),
                       end:   CGPoint(x: 0, y: size * 0.55),
                       options: [])
ctx.restoreGState()

ctx.restoreGState()
image.unlockFocus()

// ---------- Encode and save ----------
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("encode failed\n".data(using: .utf8)!)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath)")
} catch {
    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
