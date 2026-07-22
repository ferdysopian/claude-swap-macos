#!/usr/bin/env swift
//
//  generate_app_icon.swift
//  One-off tool: renders the Claude Swap placeholder AppIcon at every size
//  macOS needs, using the same violet identity as the in-app DesignSystem
//  (not derived from any Anthropic asset). Run with:
//    swift scripts/generate_app_icon.swift
//

import AppKit
import CoreGraphics

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "ClaudeSwap/Resources/Assets.xcassets/AppIcon.appiconset")

/// Renders the icon directly into a bitmap sized in exact device pixels
/// (never dependent on the current screen's backing scale factor, unlike
/// `NSImage.lockFocus`, which would double everything on a Retina display).
func renderIcon(pixels: Int) -> NSBitmapImageRep? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        return nil
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let cg = context.cgContext
    let side = CGFloat(pixels)
    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    let cornerRadius = side * 0.22

    cg.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
    cg.clip()

    let colors = [
        CGColor(red: 0x6C / 255.0, green: 0x5C / 255.0, blue: 0xE7 / 255.0, alpha: 1),
        CGColor(red: 0x00 / 255.0, green: 0xB8 / 255.0, blue: 0xD9 / 255.0, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: side), end: CGPoint(x: side, y: 0), options: [])
    }

    let symbolConfig = NSImage.SymbolConfiguration(pointSize: side * 0.52, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig)?.tinted(white: 1.0) {
        let symbolSize = symbol.size
        let origin = CGPoint(x: (side - symbolSize.width) / 2, y: (side - symbolSize.height) / 2)
        NSGraphicsContext.current = context
        symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    context.flushGraphics()
    return bitmap
}

extension NSImage {
    /// Flattens a (possibly multi-color, e.g. SF Symbol) image to a single
    /// flat white silhouette so it reads clearly against the icon gradient.
    func tinted(white: CGFloat) -> NSImage {
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        NSColor(white: white, alpha: 1.0).set()
        NSRect(origin: .zero, size: size).fill()
        draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1.0)
        tinted.unlockFocus()
        return tinted
    }
}

try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

for entry in sizes {
    guard let bitmap = renderIcon(pixels: entry.pixels),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Failed to render \(entry.name)\n".data(using: .utf8)!)
        continue
    }
    let url = outputDir.appendingPathComponent("\(entry.name).png")
    try? png.write(to: url)
    print("Wrote \(url.path) (\(entry.pixels)x\(entry.pixels))")
}
