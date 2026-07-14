#!/usr/bin/env swift
//
// Renders the Relay .app icon into an .iconset directory.
//
//   swift scripts/render_icon.swift <output.iconset>
//
// The mark is the Relay double chevron (»): white base chevron + amber accent chevron
// on a dark macOS "squircle". Drawn vectorially at every icon size for crisp edges.
// Called by scripts/make_appicon.sh, which then runs `iconutil` to pack the .icns.

import AppKit

let master: CGFloat = 1024

func drawIcon(size: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: size / master, y: size / master)   // author everything in 1024 space

    // macOS Big Sur icon grid: rounded body inset from the 1024 canvas.
    let inset: CGFloat = 100
    let body = CGRect(x: inset, y: inset, width: master - 2 * inset, height: master - 2 * inset)
    let radius: CGFloat = 185.4
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Dark background, subtle top-lit gradient.
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0x1b/255, green: 0x1f/255, blue: 0x27/255, alpha: 1),   // top
        CGColor(red: 0x0a/255, green: 0x0c/255, blue: 0x10/255, alpha: 1),   // bottom
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 512, y: master - inset),
                           end: CGPoint(x: 512, y: inset), options: [])
    ctx.restoreGState()

    // Hairline top-edge highlight so the tile reads as a real icon.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
    ctx.setLineWidth(2)
    ctx.strokePath()
    ctx.restoreGState()

    // Double chevron, centered. Geometry mirrors ChevronMark.swift.
    let h = (master - 2 * inset) * 0.40
    let arm = h * 0.46
    let step = h * 0.34
    let lw = h * 0.15
    let x0 = 512 - (step + arm) / 2
    let midY: CGFloat = 512
    let topY = 512 - h / 2
    let botY = 512 + h / 2

    func chevron(x: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: x, y: topY))
        ctx.addLine(to: CGPoint(x: x + arm, y: midY))
        ctx.addLine(to: CGPoint(x: x, y: botY))
        ctx.strokePath()
        ctx.restoreGState()
    }

    chevron(x: x0, color: CGColor(red: 1, green: 1, blue: 1, alpha: 1))                        // base
    chevron(x: x0 + step, color: CGColor(red: 1, green: 0x9e/255, blue: 0x2e/255, alpha: 1))   // accent

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode \(path)\n".utf8)); exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: path))
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: render_icon.swift <output.iconset>\n".utf8)); exit(2)
}
let outDir = CommandLine.arguments[1]

// name → pixel size for a standard macOS .iconset.
let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in variants {
    writePNG(drawIcon(size: px), to: "\(outDir)/\(name)")
}
print("rendered \(variants.count) icon sizes into \(outDir)")
