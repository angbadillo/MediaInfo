#!/usr/bin/env swift
// Draws the app icon: a bitrate curve over a film frame, on a dark blue ground.
// Run with `swift Tools/MakeIcon.swift <output-dir>`; produces an .iconset folder.

import AppKit

let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "MediaInfo.iconset")

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func draw(size: CGFloat) -> Data? {
    let scale: CGFloat = size / 1024
    guard let context = CGContext(
        data: nil, width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.scaleBy(x: scale, y: scale)
    let side: CGFloat = 1024
    // Apple leaves a margin around the rounded square; 824pt of art in a 1024pt canvas.
    let inset: CGFloat = 100
    let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let corner: CGFloat = rect.width * 0.2237

    let shape = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Ground
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(srgbRed: 0.16, green: 0.42, blue: 0.92, alpha: 1),
            CGColor(srgbRed: 0.09, green: 0.16, blue: 0.42, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: [])

    // Film sprocket holes down both sides.
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16))
    let holeWidth = rect.width * 0.075
    let holeHeight = rect.height * 0.075
    let holeCount = 5
    let spacing = rect.height / CGFloat(holeCount)
    for index in 0..<holeCount {
        let y = rect.minY + spacing * CGFloat(index) + (spacing - holeHeight) / 2
        for x in [rect.minX + rect.width * 0.055, rect.maxX - rect.width * 0.055 - holeWidth] {
            context.addPath(CGPath(
                roundedRect: CGRect(x: x, y: y, width: holeWidth, height: holeHeight),
                cornerWidth: holeWidth * 0.28, cornerHeight: holeWidth * 0.28, transform: nil))
        }
    }
    context.fillPath()

    // The bitrate curve, the thing the app is actually about.
    let plot = rect.insetBy(dx: rect.width * 0.20, dy: rect.height * 0.28)
    let heights: [CGFloat] = [0.18, 0.34, 0.22, 0.62, 0.86, 0.44, 0.58, 0.30, 0.72, 0.40, 0.24]
    let step = plot.width / CGFloat(heights.count - 1)

    let curve = CGMutablePath()
    for (index, height) in heights.enumerated() {
        let point = CGPoint(x: plot.minX + step * CGFloat(index), y: plot.minY + plot.height * height)
        index == 0 ? curve.move(to: point) : curve.addLine(to: point)
    }

    // Filled area under the curve.
    let area = CGMutablePath()
    area.addPath(curve)
    area.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
    area.addLine(to: CGPoint(x: plot.minX, y: plot.minY))
    area.closeSubpath()
    context.saveGState()
    context.addPath(area)
    context.clip()
    let fade = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.42),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.02),
        ] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        fade,
        start: CGPoint(x: plot.minX, y: plot.maxY),
        end: CGPoint(x: plot.minX, y: plot.minY),
        options: [])
    context.restoreGState()

    context.addPath(curve)
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.97))
    context.setLineWidth(rect.width * 0.045)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.strokePath()

    // Baseline.
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35))
    context.setLineWidth(rect.width * 0.016)
    context.move(to: CGPoint(x: plot.minX, y: plot.minY))
    context.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
    context.strokePath()

    context.restoreGState()

    guard let image = context.makeImage() else { return nil }
    let representation = NSBitmapImageRep(cgImage: image)
    return representation.representation(using: .png, properties: [:])
}

let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let data = draw(size: variant.size) else {
        FileHandle.standardError.write(Data("No se pudo dibujar \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent("\(variant.name).png"))
}
print("Iconset escrito en \(outputDirectory.path)")
