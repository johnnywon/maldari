import AppKit
import CoreText

/// Single source of the Maldari 말 artwork: the C2 app icon (Dock / `.icns`)
/// and the menu-bar status glyph. NOTE: `Scripts/generate-icon.swift` keeps
/// its own mirrored copy of `appIcon`'s drawing for the standalone `.icns`
/// build (it can't import this module) — keep the two in sync.
enum MaldariIcon {

    // Brand palette (mirrors Theme.limeNS / Theme.cyanNS).
    private static let lime = NSColor(red: 187/255, green: 255/255, blue: 0/255, alpha: 1)
    private static let cyan = NSColor(red: 92/255, green: 224/255, blue: 216/255, alpha: 1)
    private static let ink  = NSColor(red: 9/255, green: 9/255, blue: 16/255, alpha: 1)

    enum MenuBarState { case `default`, live, error }

    /// Raw 말 glyph path at the given em (font point) size, untransformed, plus
    /// its tight bounding box. Uses CoreText so Hangul resolves via the system
    /// Korean face (the base SF font has no 말 glyph of its own).
    private static func rawMal(weight: NSFont.Weight, emSize: CGFloat) -> (CGPath, CGRect) {
        let font = NSFont.systemFont(ofSize: emSize, weight: weight)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "말", attributes: [.font: font]))
        let path = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line)
        for i in 0..<CFArrayGetCount(runs) {
            let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, i), to: CTRun.self)
            let rf = unsafeBitCast(CFDictionaryGetValue(CTRunGetAttributes(run),
                Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()), to: CTFont.self)
            let gc = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: gc)
            var pos = [CGPoint](repeating: .zero, count: gc)
            CTRunGetGlyphs(run, CFRange(location: 0, length: gc), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: gc), &pos)
            for j in 0..<gc {
                if let gp = CTFontCreatePathForGlyph(rf, glyphs[j], nil) {
                    var t = CGAffineTransform(translationX: pos[j].x, y: pos[j].y)
                    if let mp = gp.copy(using: &t) { path.addPath(mp) }
                }
            }
        }
        return (path, path.boundingBoxOfPath)
    }

    /// Centered 말 glyph path sized by **font fraction** of `s` (used for the
    /// app icon, where padding around the glyph is part of the look).
    static func malGlyphPath(in s: CGFloat, weight: NSFont.Weight,
                             fontFraction: CGFloat = 0.54, dy: CGFloat = 0) -> CGPath {
        let (p, b) = rawMal(weight: weight, emSize: s * fontFraction)
        var t = CGAffineTransform(translationX: (s - b.width)/2 - b.minX,
                                  y: (s - b.height)/2 - b.minY + dy)
        return p.copy(using: &t) ?? p
    }

    /// Centered 말 glyph path scaled so its **height fills `heightFraction·s`**
    /// (used for the menu bar, so the glyph matches neighboring bar icons
    /// regardless of the font's natural metrics).
    static func fittedMalPath(in s: CGFloat, weight: NSFont.Weight,
                              heightFraction: CGFloat, dy: CGFloat = 0) -> CGPath {
        let (p, b) = rawMal(weight: weight, emSize: s)
        guard b.height > 0 else { return p }
        let scale = (heightFraction * s) / b.height
        let tx = (s - b.width * scale)/2 - b.minX * scale
        let ty = (s - b.height * scale)/2 - b.minY * scale + dy
        var t = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
        return p.copy(using: &t) ?? p
    }

    /// Full C2 Dock / `.icns` icon: lime→cyan gradient squircle with a dark 말.
    static func appIcon(size s: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let ctx = NSGraphicsContext.current!.cgContext
            let rect = CGRect(x: s*0.04, y: s*0.04, width: s*0.92, height: s*0.92)
            let radius = min(rect.width, rect.height) * 0.225
            let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

            ctx.saveGState(); bg.addClip()
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [lime.cgColor, cyan.cgColor] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.midY),
                                       end: CGPoint(x: rect.maxX, y: rect.midY), options: [])
            }
            if let gl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [NSColor(white: 1, alpha: 0.16).cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 1]) {
                let c = CGPoint(x: rect.midX, y: rect.maxY)
                ctx.drawRadialGradient(gl, startCenter: c, startRadius: 0, endCenter: c, endRadius: s*0.55, options: [])
            }
            ctx.restoreGState()

            ctx.saveGState()
            let bp = NSBezierPath(roundedRect: rect.insetBy(dx: s*0.008, dy: s*0.008), xRadius: radius, yRadius: radius)
            bp.lineWidth = s*0.01
            NSColor(white: 1, alpha: 0.18).setStroke(); bp.stroke()
            ctx.restoreGState()

            ink.setFill()
            ctx.addPath(malGlyphPath(in: s, weight: .heavy, fontFraction: 0.68, dy: -s*0.01))
            ctx.fillPath()
            return true
        }
    }

    /// Menu-bar status glyph. `.default`/`.error` are monochrome **template**
    /// images that auto-tint to the bar; `.live` is a colored lime→cyan glowing
    /// glyph (the "capturing" affordance). The glyph is scaled to fill ~0.9 of
    /// the bar height so it matches neighboring menu-bar icons.
    static func menuBar(_ state: MenuBarState, size s: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let ctx = NSGraphicsContext.current!.cgContext
            let glyph = fittedMalPath(in: s, weight: .heavy, heightFraction: 0.9)
            switch state {
            case .default:
                NSColor.black.setFill(); ctx.addPath(glyph); ctx.fillPath()
            case .error:
                NSColor.black.setFill(); ctx.addPath(glyph); ctx.fillPath()
                let r = s*0.30, bx = s - r*0.55, by = s - r*0.55
                NSBezierPath(ovalIn: CGRect(x: bx - r/2, y: by - r/2, width: r, height: r)).fill()
                ctx.setBlendMode(.clear)
                ctx.fill(CGRect(x: bx - s*0.02, y: by - s*0.06, width: s*0.04, height: s*0.08))
                ctx.fillEllipse(in: CGRect(x: bx - s*0.025, y: by - s*0.10, width: s*0.05, height: s*0.035))
                ctx.setBlendMode(.normal)
            case .live:
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: s*0.16,
                              color: NSColor(red: 0.55, green: 0.95, blue: 0.55, alpha: 0.95).cgColor)
                cyan.setFill(); ctx.addPath(glyph); ctx.fillPath()
                ctx.restoreGState()
                ctx.saveGState(); ctx.addPath(glyph); ctx.clip()
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [lime.cgColor, cyan.cgColor] as CFArray, locations: [0, 1]) {
                    ctx.drawLinearGradient(g, start: CGPoint(x: s*0.1, y: s/2),
                                           end: CGPoint(x: s*0.9, y: s/2), options: [])
                }
                ctx.restoreGState()
            }
            return true
        }
        img.isTemplate = (state != .live)
        return img
    }
}
