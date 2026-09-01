import Foundation
import AppKit
import CoreGraphics

/// Reads the mark back off a rendered page — our own reader, for our own mark.
///
/// A camera-facing barcode has to survive unknown lighting, unknown angle and
/// unknown scale, which is why the standards demand a 0.70 print contrast. We
/// need none of that: the page is ours, the geometry is ours, and the pattern
/// we expect is derivable from the invoice. So instead of decoding the symbol
/// we *sample* it at a known place, normalise against its own local range, and
/// compare against the pattern the invoice should produce.
///
/// That removes the contrast floor entirely: the bars can be a few percent off
/// the banner colour and still read perfectly, because "dark" is judged
/// relative to the lightest thing in the same strip rather than absolutely.
enum StripeReader {

    /// Where the mark lives, in PDF points from the top-left of the page.
    struct Geometry {
        var x: CGFloat
        var width: CGFloat
        /// Rows to sample, top-down. Several, so a row crossing the title is
        /// not the only chance we get.
        var sampleRows: [CGFloat]
    }

    struct Reading {
        var pattern: [Bool]
        /// How far apart the darkest and lightest samples were, 0…1. Tiny but
        /// non-zero is fine; zero means there was nothing there.
        var separation: Double
        var row: CGFloat
    }

    /// Samples one row and quantises it into `moduleCount` columns.
    static func read(image: CGImage, pageWidth: CGFloat, pageHeight: CGFloat,
                     geometry: Geometry, moduleCount: Int) -> Reading? {
        guard moduleCount > 0 else { return nil }
        let scaleX = CGFloat(image.width) / pageWidth
        let scaleY = CGFloat(image.height) / pageHeight

        guard let data = grey(from: image) else { return nil }
        var best: Reading?

        for row in geometry.sampleRows {
            let y = Int((row * scaleY).rounded())
            guard y >= 0, y < image.height else { continue }

            // Average a few pixel rows so a hairline of anti-aliasing doesn't
            // decide the answer.
            var samples: [Double] = []
            samples.reserveCapacity(moduleCount)
            var minimum = 1.0
            var maximum = 0.0
            for module in 0..<moduleCount {
                let start = geometry.x + geometry.width * CGFloat(module) / CGFloat(moduleCount)
                let end = geometry.x + geometry.width * CGFloat(module + 1) / CGFloat(moduleCount)
                // The middle half of the module only: module edges are where
                // anti-aliasing lives.
                let from = Int(((start * 0.75 + end * 0.25) * scaleX).rounded())
                let to = Int(((start * 0.25 + end * 0.75) * scaleX).rounded())
                guard from <= to, from >= 0, to < image.width else { samples.append(1); continue }

                var total = 0.0
                var count = 0.0
                for py in max(0, y - 1)...min(image.height - 1, y + 1) {
                    for px in from...to {
                        total += data[py * image.width + px]
                        count += 1
                    }
                }
                let value = count > 0 ? total / count : 1
                samples.append(value)
                minimum = min(minimum, value)
                maximum = max(maximum, value)
            }

            let separation = maximum - minimum
            // Anything above pure numerical noise counts; the mark may be only
            // a few percent darker than its surface.
            guard separation > 0.01 else { continue }
            let threshold = (maximum + minimum) / 2
            let pattern = samples.map { $0 < threshold }

            // Prefer the row with the cleanest separation.
            if best == nil || separation > best!.separation {
                best = Reading(pattern: pattern, separation: separation, row: row)
            }
        }
        return best
    }

    /// How well a reading matches the pattern the invoice should have printed.
    /// 1.0 is identical.
    static func agreement(_ reading: [Bool], _ expected: [Bool]) -> Double {
        guard !expected.isEmpty, reading.count == expected.count else { return 0 }
        let matches = zip(reading, expected).reduce(0) { $0 + ($1.0 == $1.1 ? 1 : 0) }
        return Double(matches) / Double(expected.count)
    }

    /// Greyscale samples, 0 = black, 1 = white.
    private static func grey(from image: CGImage) -> [Double]? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels.map { Double($0) / 255.0 }
    }
}
