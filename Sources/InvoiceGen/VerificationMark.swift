import SwiftUI
import AppKit
import CoreText

/// The invoice title, solid at the top, combing open into the verification
/// code at its foot.
///
/// The cuts sit exactly on the pattern's *space* columns and widen as they
/// descend, so the ink still standing at the bottom of the letters **is** the
/// bar pattern — the strip below the baseline is the same columns continuing,
/// not a second object parked underneath.
///
/// Drawn as vector paths (Canvas, not a bitmap) so the PDF stays crisp at any
/// zoom and any printer resolution.
struct VerificationMark: View {
    let title: String
    let code: String
    /// The colour the letters are set in.
    let ink: Color
    /// The surface behind the mark — the cuts are painted in it.
    let field: Color
    /// The strip below the baseline.
    let stripTone: Color
    var fontSize: CGFloat = 40
    var tracking: CGFloat = 6
    /// How far up the letters the dissolve reaches, as a fraction of cap
    /// height. At 0.9 the code runs through nearly the whole word, leaving
    /// only the caps solid.
    var fade: CGFloat = 0.90
    /// >1 holds the letters solid for longer before they open up. Raising the
    /// fade without raising this eats the letters: at gamma 1.4 and fade 0.9
    /// the cuts are already wide by mid-letter and INVOICE stops reading, so
    /// the two move together.
    var gamma: CGFloat = 2.0
    var strip: CGFloat = 18
    /// How far the bar columns rise out of the strip and into the word, as a
    /// fraction of the fade height.
    ///
    /// Without this the seam doesn't stitch: the strip carries a bar in every
    /// bar column, but above the baseline only the letters carry ink, so
    /// between the letters a bar appears out of nothing. The risers continue
    /// every column across the join — gap meets gap, bar meets bar — and ramp
    /// from the strip's tone to the letters' ink so the colour doesn't step
    /// either.
    /// When true the mark is exactly the word: the code is cut into the
    /// letterforms and nothing extends past them — no risers standing in the
    /// tracking gaps, no strip below the baseline. Nothing sticks out, and the
    /// price is that it is no longer a valid symbol: Code 128 needs every
    /// column present, and the gaps between letters delete some.
    var containedInLetters: Bool = true
    var riser: CGFloat = 0.45
    /// How far the foot of the bars melts back into the surface, in points.
    /// Without it the mark ends on a ruled edge and reads as a word sitting on
    /// a plinth; with it the object simply stops.
    var meltFoot: CGFloat = 8

    private var font: NSFont { .systemFont(ofSize: fontSize, weight: .medium) }
    private var capHeight: CGFloat { font.capHeight }
    private var geometry: (path: CGPath, width: CGFloat) { Self.glyphPath(title, font: font, tracking: tracking) }

    var height: CGFloat { containedInLetters ? capHeight : capHeight + strip }
    var width: CGFloat { geometry.width }

    var body: some View {
        let modules = Verification.moduleColumns(for: code)
        let word = geometry
        let moduleWidth = word.width / CGFloat(max(1, modules.count))
        let baselineY = capHeight
        let fadeHeight = capHeight * fade

        Canvas { context, _ in
            // Core Text hands back a y-up path; Canvas is y-down.
            var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: baselineY)
            guard let glyphs = word.path.copy(using: &flip) else { return }
            let letters = Path(glyphs)

            // ONE path for the whole mark — letters, risers and strip in a
            // single body — filled from ONE gradient. No part of the object
            // carries a tone of its own, which is what stops it reading as a
            // word parked on top of a barcode.
            let riserHeight = fadeHeight * riser
            var body = letters
            if !containedInLetters {
                for (index, isBar) in modules.enumerated() where isBar {
                    body.addRect(CGRect(x: CGFloat(index) * moduleWidth,
                                        y: baselineY - riserHeight,
                                        width: moduleWidth,
                                        height: riserHeight + strip))
                }
            }
            context.fill(
                body,
                with: .linearGradient(
                    Gradient(colors: [ink, stripTone]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: containedInLetters ? baselineY : baselineY + strip)
                )
            )

            // The dissolve, cut back out of the letters.
            context.drawLayer { layer in
                layer.clip(to: letters)
                for (index, isBar) in modules.enumerated() where !isBar {
                    let centre = (CGFloat(index) + 0.5) * moduleWidth
                    layer.fill(Self.wedge(centre: centre, fullWidth: moduleWidth,
                                          baselineY: baselineY, fadeHeight: fadeHeight,
                                          gamma: gamma),
                               with: .color(field))
                }
            }

            // The foot melts back into the surface, so the mark has no ruled
            // bottom edge to give away where it was pasted on.
            if meltFoot > 0 && !containedInLetters {
                let foot = CGRect(x: -1, y: baselineY + strip - meltFoot,
                                  width: word.width + 2, height: meltFoot + 1)
                context.fill(
                    Path(foot),
                    with: .linearGradient(
                        Gradient(colors: [field.opacity(0), field]),
                        startPoint: CGPoint(x: 0, y: foot.minY),
                        endPoint: CGPoint(x: 0, y: foot.maxY)
                    )
                )
            }
        }
        .frame(width: width, height: height)
        // The mark carries the invoice's identity; make it available to
        // assistive tech and to PDF text extraction as the title it replaces.
        .accessibilityLabel(Text("\(title), verification \(code)"))
    }

    /// One cut: full module width at the baseline, tapering to nothing by the
    /// top of the fade.
    private static func wedge(centre: CGFloat, fullWidth: CGFloat, baselineY: CGFloat,
                              fadeHeight: CGFloat, gamma: CGFloat) -> Path {
        var path = Path()
        let steps = 12
        var right: [CGPoint] = []
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)          // 0 = baseline, 1 = top of fade
            let openness = pow(1 - t, gamma)
            let halfWidth = fullWidth * openness / 2
            let y = baselineY - t * fadeHeight
            if step == 0 {
                path.move(to: CGPoint(x: centre - halfWidth, y: y))
            } else {
                path.addLine(to: CGPoint(x: centre - halfWidth, y: y))
            }
            right.append(CGPoint(x: centre + halfWidth, y: y))
        }
        for point in right.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// The title as outlines, so the dissolve can be clipped to the letterforms.
    static func glyphPath(_ text: String, font: NSFont, tracking: CGFloat) -> (CGPath, CGFloat) {
        let attributed = NSAttributedString(
            string: text, attributes: [.font: font, .kern: tracking]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let combined = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun] ?? []) {
            let attributes = CTRunGetAttributes(run)
            let key = Unmanaged.passUnretained(kCTFontAttributeName).toOpaque()
            guard let raw = CFDictionaryGetValue(attributes, key) else { continue }
            let runFont = unsafeBitCast(raw, to: CTFont.self)
            for index in 0..<CTRunGetGlyphCount(run) {
                var glyph = CGGlyph()
                var position = CGPoint()
                CTRunGetGlyphs(run, CFRangeMake(index, 1), &glyph)
                CTRunGetPositions(run, CFRangeMake(index, 1), &position)
                guard let letter = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
                let move = CGAffineTransform(translationX: position.x, y: position.y)
                combined.addPath(letter, transform: move)
            }
        }
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return (combined, width)
    }
}
