// Renders Udha's app icon into Assets.xcassets/AppIcon.appiconset.
//
//   swift scripts/make-app-icon.swift
//
// The mark is the resting edge overlay's tick chart: three bars, one per
// attention level — a stub for quiet, a mid bar for working, and a tall red one
// for a session that wants you. The Dock icon and the strip on the screen edge
// are therefore the same object, and even at 16pt the red bar still says "one
// of these needs you".
//
// Colours are the design system's: ink #201E1D, paper #F3F2F2, red #EC3013.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:   CGFloat((hex >> 8) & 0xFF) / 255,
            blue:    CGFloat(hex & 0xFF) / 255,
            alpha:   alpha)
}

let ink     = srgb(0x201E1D)
let inkTop  = srgb(0x2C2A28)
let inkBot  = srgb(0x161514)
let paper   = srgb(0xF3F2F2)
let quiet   = srgb(0xF3F2F2, 0.38)
let red     = srgb(0xEC3013)

func render(size: CGFloat) -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: size / canvas, y: size / canvas)
    ctx.setShouldAntialias(true)

    // macOS icon geometry: the art sits inside the canvas with its own margin.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Flat, but not dead flat — a pure #201E1D square reads as a hole in the Dock.
    let gradient = CGGradient(colorsSpace: space,
                              colors: [inkTop, ink, inkBot] as CFArray,
                              locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY),
                           options: [])

    let barWidth: CGFloat = 132
    let gap: CGFloat = 78
    let bars: [(height: CGFloat, color: CGColor)] = [
        (218, quiet),
        (344, paper),
        (486, red),
    ]
    var x = body.midX - (barWidth * 3 + gap * 2) / 2
    for bar in bars {
        ctx.setFillColor(bar.color)
        ctx.fill(CGRect(x: x, y: body.midY - bar.height / 2, width: barWidth, height: bar.height))
        x += barWidth + gap
    }
    ctx.restoreGState()

    // Hairline rim so the silhouette survives on a dark Dock background.
    ctx.addPath(shape)
    ctx.setStrokeColor(srgb(0xF3F2F2, 0.12))
    ctx.setLineWidth(4)
    ctx.strokePath()

    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("cannot write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("finalize failed") }
}

/// (pixel size, filename) for every slot the macOS app-icon set declares.
let slots: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let out = root.appendingPathComponent("Udha.AIDesktop/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

var cache: [Int: CGImage] = [:]
for (px, name) in slots {
    let image = cache[px] ?? render(size: CGFloat(px))
    cache[px] = image
    write(image, to: out.appendingPathComponent(name))
}
print("wrote \(slots.count) icon files to \(out.path)")
