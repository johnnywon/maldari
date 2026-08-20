#!/usr/bin/env swift
// Renders the eight Stream Deck key faces (listen, subtitles, input, presentation —
// each an on/off or mic/system pair) at 288x288 (2x the deck's native 144x144).
//
// The 말 glyph drawing below is a THIRD copy of the same CoreText path-extraction
// code in Translator/Translator/MaldariIcon.swift and Scripts/generate-icon.swift.
// A standalone `swift` script cannot import the app module, so there is no shared
// home for this logic to live in — hence the duplication. If the glyph treatment
// (font, weight, path extraction) ever changes, all three copies must change together.
//
// Usage:  swift Scripts/generate-streamdeck-icons.swift [output-dir]
//         (defaults to ../assets/streamdeck, i.e. the committed set at the repo root)
//
// Unlike generate-icon.swift, whose output is a build artifact, these PNGs ARE
// committed: they are dragged onto Stream Deck keys by hand, so they need to exist
// without anyone running Swift first. Re-run this after changing a face and commit
// the result alongside the change.

import AppKit
import CoreText
import Foundation

// MARK: - Palette (matches Translator/Translator/Theme.swift and MaldariIcon.swift)

let lime  = NSColor(red: 187/255, green: 255/255, blue: 0/255,   alpha: 1)
let cyan  = NSColor(red: 92/255,  green: 224/255, blue: 216/255, alpha: 1)
let keyBG = NSColor(red: 14/255,  green: 14/255,  blue: 20/255,  alpha: 1)
let grey  = NSColor(red: 52/255,  green: 60/255,  blue: 70/255,  alpha: 1)
let pale  = NSColor(red: 201/255, green: 206/255, blue: 214/255, alpha: 1)

let S: CGFloat = 288

// MARK: - Shared helpers

/// Extracts a fillable CGPath for a string, using CoreText glyph-path extraction
/// (not NSString.draw) so Hangul resolves through the system Korean face rather
/// than silently falling back to a missing-glyph box. Path origin is the string's
/// own baseline/origin; caller centers it via `bounds`.
func glyphPath(_ text: String, fontSize: CGFloat, weight: NSFont.Weight = .heavy) -> (path: CGPath, bounds: CGRect) {
    let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let path = CGMutablePath()
    let runs = CTLineGetGlyphRuns(line)
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
                var transform = CGAffineTransform(translationX: positions[j].x, y: positions[j].y)
                if let moved = gp.copy(using: &transform) { path.addPath(moved) }
            }
        }
    }
    return (path, bounds)
}

/// Fills the full-bleed key background. No rounded corners — the Stream Deck
/// hardware masks its own key shape, so a rounded-rect here would just show as
/// a dark ring around the visible face.
func fillKeyBackground(_ ctx: CGContext) {
    keyBG.setFill()
    ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
}

/// Strokes a single arrow: a line from `from` to `to` with a filled triangular
/// head at the `to` end.
func drawArrowSegment(_ ctx: CGContext, from: CGPoint, to: CGPoint, color: NSColor,
                      lineWidth: CGFloat, headLen: CGFloat, headWidth: CGFloat) {
    ctx.saveGState()
    color.setStroke()
    let line = CGMutablePath()
    line.move(to: from)
    line.addLine(to: to)
    ctx.addPath(line)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.strokePath()

    let dx = to.x - from.x, dy = to.y - from.y
    let len = max(sqrt(dx * dx + dy * dy), 0.0001)
    let ux = dx / len, uy = dy / len
    let back = CGPoint(x: to.x - headLen * ux, y: to.y - headLen * uy)
    let left = CGPoint(x: back.x - headWidth * uy, y: back.y + headWidth * ux)
    let right = CGPoint(x: back.x + headWidth * uy, y: back.y - headWidth * ux)
    let head = CGMutablePath()
    head.move(to: to)
    head.addLine(to: left)
    head.addLine(to: right)
    head.closeSubpath()
    color.setFill()
    ctx.addPath(head)
    ctx.fillPath()
    ctx.restoreGState()
}

/// Draws a compact horizontal double-arrow (⇄-style: one arrow right on top,
/// one arrow left below) — a small subordinate status marker in the key's
/// bottom band, well clear of the main glyph, that tells the operator the
/// input key cycles through faces rather than toggling between two.
func drawSwapArrows(_ ctx: CGContext, center: CGPoint, color: NSColor) {
    let armLen = S * 0.10
    let offsetY = S * 0.026
    let lineWidth = S * 0.020
    let headLen = S * 0.032
    let headWidth = S * 0.028

    drawArrowSegment(ctx,
        from: CGPoint(x: center.x - armLen, y: center.y + offsetY),
        to: CGPoint(x: center.x + armLen * 0.4, y: center.y + offsetY),
        color: color, lineWidth: lineWidth, headLen: headLen, headWidth: headWidth)
    drawArrowSegment(ctx,
        from: CGPoint(x: center.x + armLen, y: center.y - offsetY),
        to: CGPoint(x: center.x - armLen * 0.4, y: center.y - offsetY),
        color: color, lineWidth: lineWidth, headLen: headLen, headWidth: headWidth)
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

// MARK: - Face 1: listen (말)

func renderListen(active: Bool) -> NSImage {
    let color = active ? lime : grey
    return NSImage(size: NSSize(width: S, height: S), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        fillKeyBackground(ctx)

        if active {
            ctx.saveGState()
            let c = CGPoint(x: S / 2, y: S / 2)
            if let halo = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [lime.withAlphaComponent(0.38).cgColor, lime.withAlphaComponent(0).cgColor] as CFArray,
                locations: [0, 1]) {
                ctx.drawRadialGradient(halo, startCenter: c, startRadius: 0, endCenter: c, endRadius: S * 0.48, options: [])
            }
            ctx.restoreGState()
        }

        let (path, bounds) = glyphPath("말", fontSize: S * 0.60)
        let tx = (S - bounds.width) / 2 - bounds.minX
        let ty = (S - bounds.height) / 2 - bounds.minY
        ctx.saveGState()
        ctx.translateBy(x: tx, y: ty)
        color.setFill()
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        return true
    }
}

// MARK: - Face 2: subtitles (screen outline + two caption bars)

func renderSubtitles(active: Bool) -> NSImage {
    let color = active ? cyan : grey
    return NSImage(size: NSSize(width: S, height: S), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        fillKeyBackground(ctx)

        let screen = CGRect(x: S * 0.18, y: S * 0.28, width: S * 0.64, height: S * 0.50)
        let screenPath = NSBezierPath(roundedRect: screen, xRadius: S * 0.05, yRadius: S * 0.05)
        screenPath.lineWidth = S * 0.035
        color.setStroke()
        screenPath.stroke()

        // Long caption bar over a shorter one, both inside the screen.
        let longBar = CGRect(x: S * 0.30, y: S * 0.475, width: S * 0.40, height: S * 0.065)
        let shortBar = CGRect(x: S * 0.30, y: S * 0.355, width: S * 0.24, height: S * 0.065)
        color.setFill()
        NSBezierPath(roundedRect: longBar, xRadius: S * 0.03, yRadius: S * 0.03).fill()
        NSBezierPath(roundedRect: shortBar, xRadius: S * 0.03, yRadius: S * 0.03).fill()
        return true
    }
}

// MARK: - Face 3: input (mic / system), with a lime double-arrow "cycles" marker
//
// Both faces are sized so the main glyph's bounding box is comparable in area
// to the subtitle/presentation screens (roughly half the key's width and
// height), so all four keys read as one family at a glance. The swap-arrows
// marker sits in a bottom band well clear of the glyph on both faces, at an
// identical position, so the pair reads as the same key in two states.

func renderInputMic() -> NSImage {
    NSImage(size: NSSize(width: S, height: S), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        fillKeyBackground(ctx)

        let cx = S / 2
        // Capsule body.
        let capsule = CGRect(x: cx - S * 0.12, y: S * 0.50, width: S * 0.24, height: S * 0.36)
        let capsulePath = NSBezierPath(roundedRect: capsule, xRadius: S * 0.12, yRadius: S * 0.12)
        pale.setFill()
        capsulePath.fill()

        // Cradle arc beneath the capsule.
        let cradleCenter = CGPoint(x: cx, y: capsule.minY)
        let cradleRadius = S * 0.24
        let cradle = CGMutablePath()
        cradle.addArc(center: cradleCenter, radius: cradleRadius, startAngle: .pi * 1.05, endAngle: .pi * 1.95, clockwise: false)
        ctx.saveGState()
        pale.setStroke()
        ctx.addPath(cradle)
        ctx.setLineWidth(S * 0.032)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()

        // Short stem below the cradle.
        let stemTop = CGPoint(x: cx, y: cradleCenter.y - cradleRadius)
        let stemBottom = CGPoint(x: cx, y: stemTop.y - S * 0.04)
        let stem = CGMutablePath()
        stem.move(to: stemTop)
        stem.addLine(to: stemBottom)
        ctx.saveGState()
        pale.setStroke()
        ctx.addPath(stem)
        ctx.setLineWidth(S * 0.032)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()

        drawSwapArrows(ctx, center: CGPoint(x: cx, y: S * 0.095), color: lime)
        return true
    }
}

func renderInputSystem() -> NSImage {
    NSImage(size: NSSize(width: S, height: S), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        fillKeyBackground(ctx)

        let cx = S * 0.51
        let cy = S * 0.60
        // Speaker: box + flared cone, one closed path.
        let speaker = CGMutablePath()
        speaker.move(to: CGPoint(x: cx - S * 0.272, y: cy + S * 0.102))
        speaker.addLine(to: CGPoint(x: cx - S * 0.034, y: cy + S * 0.102))
        speaker.addLine(to: CGPoint(x: cx + S * 0.238, y: cy + S * 0.272))
        speaker.addLine(to: CGPoint(x: cx + S * 0.238, y: cy - S * 0.272))
        speaker.addLine(to: CGPoint(x: cx - S * 0.034, y: cy - S * 0.102))
        speaker.addLine(to: CGPoint(x: cx - S * 0.272, y: cy - S * 0.102))
        speaker.closeSubpath()
        pale.setFill()
        ctx.addPath(speaker)
        ctx.fillPath()

        // One sound arc to the right of the cone.
        let arc = CGMutablePath()
        arc.addArc(center: CGPoint(x: cx + S * 0.238, y: cy), radius: S * 0.19,
                   startAngle: -.pi * 0.22, endAngle: .pi * 0.22, clockwise: false)
        ctx.saveGState()
        pale.setStroke()
        ctx.addPath(arc)
        ctx.setLineWidth(S * 0.030)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()

        drawSwapArrows(ctx, center: CGPoint(x: S / 2, y: S * 0.095), color: lime)
        return true
    }
}

// MARK: - Face 4: presentation (filled screen + stand / outline pair)

func renderPresentation(active: Bool) -> NSImage {
    let color = active ? lime : grey
    return NSImage(size: NSSize(width: S, height: S), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        fillKeyBackground(ctx)

        let screen = CGRect(x: S * 0.18, y: S * 0.34, width: S * 0.64, height: S * 0.44)
        let screenPath = NSBezierPath(roundedRect: screen, xRadius: S * 0.045, yRadius: S * 0.045)
        let stand = CGRect(x: S / 2 - S * 0.09, y: S * 0.22, width: S * 0.18, height: S * 0.08)
        let standPath = NSBezierPath(roundedRect: stand, xRadius: S * 0.015, yRadius: S * 0.015)

        if active {
            color.setFill()
            screenPath.fill()
            standPath.fill()
        } else {
            screenPath.lineWidth = S * 0.035
            standPath.lineWidth = S * 0.03
            color.setStroke()
            screenPath.stroke()
            standPath.stroke()
        }
        return true
    }
}

// MARK: - main

let args = CommandLine.arguments
let outDir = args.count >= 2 ? args[1] : "../assets/streamdeck"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let plan: [(name: String, image: NSImage)] = [
    ("listen-on.png",       renderListen(active: true)),
    ("listen-off.png",      renderListen(active: false)),
    ("subtitles-on.png",    renderSubtitles(active: true)),
    ("subtitles-off.png",   renderSubtitles(active: false)),
    ("input-mic.png",       renderInputMic()),
    ("input-system.png",    renderInputSystem()),
    ("presentation-on.png", renderPresentation(active: true)),
    ("presentation-off.png", renderPresentation(active: false)),
]

for entry in plan {
    writePNG(entry.image, to: "\(outDir)/\(entry.name)")
    print("wrote \(entry.name)")
}
