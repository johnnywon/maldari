#!/usr/bin/env swift
// Renders the Maldari app icon (direction "C2": lime→cyan gradient squircle
// with a dark 말) at all sizes required for a macOS .icns bundle. Shares the
// look with Translator/MaldariIcon.swift — keep the two in sync if you tweak
// the aesthetic.
//
// Usage:  swift Scripts/generate-icon.swift <output.iconset-dir>

import AppKit
import CoreText
import Foundation

func generateIcon(size: CGFloat) -> NSImage {
    let lime = NSColor(red: 187/255, green: 255/255, blue: 0/255, alpha: 1)
    let cyan = NSColor(red: 92/255, green: 224/255, blue: 216/255, alpha: 1)
    let ink  = NSColor(red: 9/255, green: 9/255, blue: 16/255, alpha: 1)
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        let s = size
        let rect = CGRect(x: s*0.04, y: s*0.04, width: s*0.92, height: s*0.92)
        let radius = min(rect.width, rect.height) * 0.225
        let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        // lime→cyan gradient background
        ctx.saveGState(); bg.addClip()
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [lime.cgColor, cyan.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.midY),
                                   end: CGPoint(x: rect.maxX, y: rect.midY), options: [])
        }
        // soft white top highlight
        if let gl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor(white: 1, alpha: 0.16).cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 1]) {
            let c = CGPoint(x: rect.midX, y: rect.maxY)
            ctx.drawRadialGradient(gl, startCenter: c, startRadius: 0, endCenter: c, endRadius: s*0.55, options: [])
        }
        ctx.restoreGState()

        // faint white hairline border
        ctx.saveGState()
        let bp = NSBezierPath(roundedRect: rect.insetBy(dx: s*0.008, dy: s*0.008), xRadius: radius, yRadius: radius)
        bp.lineWidth = s*0.01
        NSColor(white: 1, alpha: 0.18).setStroke(); bp.stroke()
        ctx.restoreGState()

        // 말 glyph (CoreText so Hangul resolves via the system Korean face)
        let font = NSFont.systemFont(ofSize: s * 0.54, weight: .heavy)
        let lineCT = CTLineCreateWithAttributedString(NSAttributedString(string: "말", attributes: [.font: font]))
        let b = CTLineGetBoundsWithOptions(lineCT, .useGlyphPathBounds)
        let tx = (s - b.width) / 2 - b.minX
        let ty = (s - b.height) / 2 - b.minY - s*0.01
        let textPath = CGMutablePath()
        let runs = CTLineGetGlyphRuns(lineCT)
        for i in 0..<CFArrayGetCount(runs) {
            let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, i), to: CTRun.self)
            let rf = unsafeBitCast(CFDictionaryGetValue(CTRunGetAttributes(run),
                Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()), to: CTFont.self)
            let gc = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: gc)
            var positions = [CGPoint](repeating: .zero, count: gc)
            CTRunGetGlyphs(run, CFRange(location: 0, length: gc), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: gc), &positions)
            for j in 0..<gc {
                if let gp = CTFontCreatePathForGlyph(rf, glyphs[j], nil) {
                    var transform = CGAffineTransform(translationX: tx + positions[j].x, y: ty + positions[j].y)
                    if let moved = gp.copy(using: &transform) { textPath.addPath(moved) }
                }
            }
        }
        ink.setFill(); ctx.addPath(textPath); ctx.fillPath()
        return true
    }
}

func writePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Failed to encode \(path)\n".data(using: .utf8)!)
        return
    }
    try? png.write(to: URL(fileURLWithPath: path))
}

// ---- main ----

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: generate-icon.swift <output.iconset-dir>")
    exit(1)
}

let outDir = args[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let plan: [(px: CGFloat, name: String)] = [
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

for entry in plan {
    let img = generateIcon(size: entry.px)
    writePNG(img, to: "\(outDir)/\(entry.name)")
    print("wrote \(entry.name) (\(Int(entry.px))px)")
}
