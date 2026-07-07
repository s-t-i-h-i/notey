import SwiftUI
import UIKit

// Decorative motifs for the beige & navy "Greek" look: hanging stars on
// threads, curling wave scrolls, a meander (Greek key) band and a faint
// linen-paper weave. All vector / generated — they tint with the theme and
// stay crisp at any size. Purely ornamental: no hit testing, hidden from
// accessibility.

// MARK: - Five-pointed star (point up)

struct StarShape: Shape {
    var innerRatio: CGFloat = 0.42

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        var path = Path()
        for i in 0..<10 {
            let angle = CGFloat(i) * .pi / 5 - .pi / 2
            let radius = i.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Stars dangling on threads from the top edge

struct HangingStars: View {
    struct Strand {
        var x: CGFloat      // horizontal position, 0...1 of the width
        var drop: CGFloat   // how far down the star reaches, 0...1 of the height
        var size: CGFloat   // star diameter as a fraction of the height
        var tilt: CGFloat   // degrees
    }

    var strands: [Strand]
    var color: Color = Theme.navy
    var accentIndex: Int? = nil
    var accentColor: Color = Theme.pink
    var lineWidth: CGFloat = 1

    static let five: [Strand] = [
        .init(x: 0.08, drop: 0.56, size: 0.24, tilt: -12),
        .init(x: 0.30, drop: 0.94, size: 0.27, tilt: 9),
        .init(x: 0.52, drop: 0.68, size: 0.25, tilt: -7),
        .init(x: 0.73, drop: 0.84, size: 0.27, tilt: 14),
        .init(x: 0.92, drop: 0.42, size: 0.24, tilt: -10),
    ]

    static let three: [Strand] = [
        .init(x: 0.16, drop: 0.62, size: 0.30, tilt: -11),
        .init(x: 0.54, drop: 0.98, size: 0.34, tilt: 8),
        .init(x: 0.88, drop: 0.46, size: 0.28, tilt: -8),
    ]

    var body: some View {
        Canvas { context, size in
            for (index, strand) in strands.enumerated() {
                let x = strand.x * size.width
                let side = strand.size * size.height
                let stringEnd = max(0, strand.drop * size.height - side)
                let tone = index == accentIndex ? accentColor : color

                var thread = Path()
                thread.move(to: CGPoint(x: x, y: 0))
                thread.addLine(to: CGPoint(x: x, y: stringEnd))
                context.stroke(thread, with: .color(tone.opacity(0.75)), lineWidth: lineWidth)

                let rect = CGRect(x: x - side / 2, y: stringEnd, width: side, height: side)
                let rotation = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                    .rotated(by: strand.tilt * .pi / 180)
                    .translatedBy(x: -rect.midX, y: -rect.midY)
                let star = StarShape().path(in: rect).applying(rotation)
                context.fill(star, with: .color(tone))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Curling wave scroll (line-art crests, like the wave artwork)

struct WaveScroll: View {
    var color: Color = Theme.navy.opacity(0.16)
    var lineWidth: CGFloat = 1.3

    var body: some View {
        Canvas { context, size in
            let h = size.height
            // Waves overlap like the artwork: each crest rises out from
            // under the previous curl.
            let waveWidth = h * 1.5
            let stride = h * 1.05
            guard stride > 0, size.width >= waveWidth else { return }
            let count = Int((size.width - waveWidth) / stride) + 1
            let width = waveWidth + CGFloat(count - 1) * stride
            let startX = (size.width - width) / 2
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

            for i in 0..<count {
                let x0 = startX + CGFloat(i) * stride
                var path = Path()
                // Swell from the trough up and over the crest…
                let crest = CGPoint(x: x0 + waveWidth * 0.86, y: h * 0.10)
                path.move(to: CGPoint(x: x0, y: h * 0.86))
                path.addCurve(
                    to: crest,
                    control1: CGPoint(x: x0 + waveWidth * 0.52, y: h * 1.02),
                    control2: CGPoint(x: x0 + waveWidth * 0.72, y: h * 0.04)
                )
                // …then break forward and curl into an open spiral.
                let center = CGPoint(x: x0 + waveWidth * 0.70, y: h * 0.44)
                var radius = hypot(crest.x - center.x, crest.y - center.y)
                var angle = atan2(crest.y - center.y, crest.x - center.x)
                let steps = 24
                let shrink = pow(0.34, 1 / CGFloat(steps))
                for _ in 0..<steps {
                    angle += .pi * 1.3 / CGFloat(steps)
                    radius *= shrink
                    path.addLine(to: CGPoint(
                        x: center.x + cos(angle) * radius,
                        y: center.y + sin(angle) * radius
                    ))
                }
                context.stroke(path, with: .color(color), style: style)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Meander (Greek key): spiral hooks over a baseline

struct MeanderRule: View {
    var color: Color = Theme.navy.opacity(0.2)
    var lineWidth: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            let top = lineWidth / 2
            let bottom = size.height - lineWidth / 2
            let span = bottom - top
            let unit = size.height
            guard unit > 0, size.width >= unit else { return }
            let count = Int(size.width / unit)
            let width = CGFloat(count) * unit
            let startX = (size.width - width) / 2
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .butt, lineJoin: .miter)

            var path = Path()
            path.move(to: CGPoint(x: startX, y: bottom))
            path.addLine(to: CGPoint(x: startX + width, y: bottom))
            for i in 0..<count {
                let x = startX + CGFloat(i) * unit + unit * 0.14
                let w = unit * 0.62
                path.move(to: CGPoint(x: x, y: bottom))
                path.addLine(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x + w, y: top))
                path.addLine(to: CGPoint(x: x + w, y: top + span * 0.62))
                path.addLine(to: CGPoint(x: x + w * 0.42, y: top + span * 0.62))
                path.addLine(to: CGPoint(x: x + w * 0.42, y: top + span * 0.32))
                path.addLine(to: CGPoint(x: x + w * 0.74, y: top + span * 0.32))
            }
            context.stroke(path, with: .color(color), style: style)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// A hairline divider with a small meander band engraved in the middle.
struct GreekDivider: View {
    var lineColor: Color = Theme.border
    var ornamentColor: Color = Theme.navy.opacity(0.24)

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Rectangle().fill(lineColor).frame(height: 1)
            MeanderRule(color: ornamentColor)
                .frame(width: 126, height: 8)
            Rectangle().fill(lineColor).frame(height: 1)
        }
        .padding(.vertical, 2)
        .accessibilityHidden(true)
    }
}

// MARK: - Linen-paper weave (generated tile, laid over beige backgrounds)

enum DecorTexture {
    static let linenTile: UIImage = {
        let side: CGFloat = 128
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { rendererContext in
            let ctx = rendererContext.cgContext
            var seed: UInt64 = 0x5DEECE66D
            func random() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat((seed >> 33) % 1_000_000) / 1_000_000
            }
            // Vertical threads dominate, like the linen swatch.
            var x: CGFloat = 0
            while x < side {
                ctx.setFillColor(UIColor(white: 0.24, alpha: 0.035 + 0.05 * random()).cgColor)
                ctx.fill(CGRect(x: x, y: 0, width: 0.9, height: side))
                x += 2.2 + random() * 2.4
            }
            var y: CGFloat = 0
            while y < side {
                ctx.setFillColor(UIColor(white: 0.30, alpha: 0.02 + 0.04 * random()).cgColor)
                ctx.fill(CGRect(x: 0, y: y, width: side, height: 0.8))
                y += 3.4 + random() * 3.2
            }
            // A few darker flecks of handmade paper.
            for _ in 0..<22 {
                ctx.setFillColor(UIColor(white: 0.22, alpha: 0.05 + 0.05 * random()).cgColor)
                let d = 1.0 + random() * 1.2
                ctx.fillEllipse(in: CGRect(x: random() * side, y: random() * side, width: d, height: d))
            }
        }
    }()
}

struct LinenBackground: View {
    var base: Color = Theme.bg
    var intensity: Double = 0.45

    var body: some View {
        base
            .overlay(
                Image(uiImage: DecorTexture.linenTile)
                    .resizable(resizingMode: .tile)
                    .opacity(intensity)
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
