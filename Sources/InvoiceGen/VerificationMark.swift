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
    /// How far up the letters the dissolve reaches, as a fraction of cap height.
    var fade: CGFloat = 0.60
    /// >1 holds the letters solid for longer before they open up. At 1.0 the
    /// taper starts eating the letters immediately and INVOICE stops reading.
    var gamma: CGFloat = 1.4
    var strip: CGFloat = 22

    private var font: NSFont { .systemFont(ofSize: fontSize, weight: .medium) }
    private var capHeight: CGFloat { font.capHeight }
    private var geometry: (path: CGPath, width: CGFloat) { Self.glyphPath(title, font: font, tracking: tracking) }

    var height: CGFloat { capHeight + strip }
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

            context.fill(letters, with: .color(ink))

            // The dissolve, clipped to the letters.
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

            // The same columns, continuing below the baseline.
            if strip > 0 {
                for (index, isBar) in modules.enumerated() where isBar {
                    let rect = CGRect(x: CGFloat(index) * moduleWidth, y: baselineY,
                                      width: moduleWidth, height: strip)
                    context.fill(Path(rect), with: .color(stripTone))
                }
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
