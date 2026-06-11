#!/usr/bin/env swift
// Renders the Translator app icon at all sizes required for a macOS .icns
// bundle. Shares the drawing code with Translator/AppIcon.swift — keep the
// two in sync if you tweak the aesthetic.
//
// Usage:  swift Scripts/generate-icon.swift <output-iconset-dir>

import AppKit
import CoreText
import Foundation

func generateIcon(size: CGFloat) -> NSImage {
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let ctx = NSGraphicsContext.current!.cgContext
        let s = size

        // Background: dark rounded rect
        let bgRect = rect.insetBy(dx: s * 0.04, dy: s * 0.04)
        let cornerRadius = s * 0.22
        let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(red: 12/255, green: 12/255, blue: 22/255, alpha: 1).setFill()
        bgPath.fill()

        // Inner glow
        ctx.saveGState()
        bgPath.addClip()
        let glowCenter = CGPoint(x: s * 0.5, y: s * 0.65)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(red: 187/255, green: 255/255, blue: 0/255, alpha: 0.08).cgColor,
                NSColor.clear.cgColor,
            ] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawRadialGradient(gradient, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: s * 0.5, options: [])
        }
        ctx.restoreGState()

        // Border
        let borderRect = bgRect.insetBy(dx: s * 0.008, dy: s * 0.008)
        let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: cornerRadius - s * 0.008, yRadius: cornerRadius - s * 0.008)
        borderPath.lineWidth = s * 0.012
        NSColor(red: 187/255, green: 255/255, blue: 0/255, alpha: 0.3).setStroke()
        borderPath.stroke()

        // Corner accent marks
        let markLen = s * 0.08
        let markThick = s * 0.012
        let markInset = s * 0.08
        let markColor = NSColor(red: 187/255, green: 255/255, blue: 0/255, alpha: 0.5)
        markColor.setFill()
        NSBezierPath(rect: CGRect(x: markInset, y: s - markInset - markThick, width: markLen, height: markThick)).fill()
        NSBezierPath(rect: CGRect(x: markInset, y: s - markInset - markLen, width: markThick, height: markLen)).fill()
        NSBezierPath(rect: CGRect(x: s - markInset - markLen, y: s - markInset - markThick, width: markLen, height: markThick)).fill()
        NSBezierPath(rect: CGRect(x: s - markInset - markThick, y: s - markInset - markLen, width: markThick, height: markLen)).fill()
        NSBezierPath(rect: CGRect(x: markInset, y: markInset, width: markLen, height: markThick)).fill()
        NSBezierPath(rect: CGRect(x: markInset, y: markInset, width: markThick, height: markLen)).fill()
        NSBezierPath(rect: CGRect(x: s - markInset - markLen, y: markInset, width: markLen, height: markThick)).fill()
        NSBezierPath(rect: CGRect(x: s - markInset - markThick, y: markInset, width: markThick, height: markLen)).fill()

        // Top accent gradient bar
        let barHeight = s * 0.008
        let barY = s - markInset - s * 0.002
        let barRect = CGRect(x: markInset + markLen + s * 0.02, y: barY, width: s - 2 * (markInset + markLen + s * 0.02), height: barHeight)
        ctx.saveGState()
        if let barGrad = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(red: 187/255, green: 255/255, blue: 0/255, alpha: 0.6).cgColor,
                NSColor(red: 92/255, green: 224/255, blue: 216/255, alpha: 0.6).cgColor,
            ] as CFArray,
            locations: [0, 1]
        ) {
            ctx.clip(to: barRect)
            ctx.drawLinearGradient(barGrad, start: CGPoint(x: barRect.minX, y: 0), end: CGPoint(x: barRect.maxX, y: 0), options: [])
        }
        ctx.restoreGState()

        // "T" letter with gradient
        let fontSize = s * 0.48
        let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        let tStr = "T"
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let tSize = (tStr as NSString).size(withAttributes: attrs)
        let tX = (s - tSize.width) / 2
        let tY = (s - tSize.height) / 2 - s * 0.02

        ctx.saveGState()
        let textPath = CGMutablePath()
        let attrString = NSAttributedString(string: tStr, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attrString)
        let runs = CTLineGetGlyphRuns(line)
        for i in 0..<CFArrayGetCount(runs) {
            let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, i), to: CTRun.self)
            let runFont = unsafeBitCast(
                CFDictionaryGetValue(CTRunGetAttributes(run), Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()),
                to: CTFont.self
            )
            let glyphCount = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            CTRunGetGlyphs(run, CFRange(location: 0, length: glyphCount), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: glyphCount), &positions)
            for j in 0..<glyphCount {
                if let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[j], nil) {
                    var transform = CGAffineTransform(translationX: tX + positions[j].x, y: tY + positions[j].y)
                    if let movedPath = glyphPath.copy(using: &transform) {
                        textPath.addPath(movedPath)
                    }
                }
            }
        }
        ctx.addPath(textPath)
        ctx.clip()

        if let textGrad = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(red: 187/255, green: 255/255, blue: 0/255, alpha: 1).cgColor,
                NSColor(red: 140/255, green: 240/255, blue: 100/255, alpha: 1).cgColor,
                NSColor(red: 92/255, green: 224/255, blue: 216/255, alpha: 1).cgColor,
            ] as CFArray,
            locations: [0, 0.5, 1]
        ) {
            ctx.drawLinearGradient(textGrad, start: CGPoint(x: s * 0.3, y: tY + tSize.height), end: CGPoint(x: s * 0.7, y: tY), options: [])
        }
        ctx.restoreGState()

        // Letter glow
        ctx.saveGState()
        let glowRect = CGRect(x: tX - s * 0.05, y: tY - s * 0.05, width: tSize.width + s * 0.1, height: tSize.height + s * 0.1)
        if let letterGlow = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(red: 187/255, green: 255/255, blue: 0/255, alpha: 0.12).cgColor,
                NSColor.clear.cgColor,
            ] as CFArray,
            locations: [0, 1]
        ) {
            let center = CGPoint(x: glowRect.midX, y: glowRect.midY)
            ctx.drawRadialGradient(letterGlow, startCenter: center, startRadius: 0, endCenter: center, endRadius: s * 0.3, options: [])
        }
        ctx.restoreGState()

        // Equalizer bars
        let barWidths: [CGFloat] = [0.015, 0.015, 0.015, 0.015, 0.015]
        let barHeights: [CGFloat] = [0.06, 0.1, 0.045, 0.085, 0.03]
        let barSpacing = s * 0.025
        let totalBarsWidth = CGFloat(barWidths.count) * s * 0.015 + CGFloat(barWidths.count - 1) * barSpacing
        var barX = (s - totalBarsWidth) / 2
        let barsBaseY = s * 0.14
        for i in 0..<barWidths.count {
            let bw = s * barWidths[i]
            let bh = s * barHeights[i]
            let barPath = NSBezierPath(roundedRect: CGRect(x: barX, y: barsBaseY, width: bw, height: bh), xRadius: bw/2, yRadius: bw/2)
            NSColor(red: 92/255, green: 224/255, blue: 216/255, alpha: 0.6).setFill()
            barPath.fill()
            barX += bw + barSpacing
        }
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
