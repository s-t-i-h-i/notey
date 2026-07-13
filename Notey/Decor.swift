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

    /// Thread + star outline per strand — shared with the page-template
    /// renderer so canvas templates match the SwiftUI decorations exactly.
    static func geometry(for strands: [Strand], in size: CGSize) -> [(thread: Path, star: Path)] {
        strands.map { strand in
            let x = strand.x * size.width
            let side = strand.size * size.height
            let stringEnd = max(0, strand.drop * size.height - side)

            var thread = Path()
            thread.move(to: CGPoint(x: x, y: 0))
            thread.addLine(to: CGPoint(x: x, y: stringEnd))

            let rect = CGRect(x: x - side / 2, y: stringEnd, width: side, height: side)
            let rotation = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .rotated(by: strand.tilt * .pi / 180)
                .translatedBy(x: -rect.midX, y: -rect.midY)
            let star = StarShape().path(in: rect).applying(rotation)
            return (thread, star)
        }
    }

    var body: some View {
        Canvas { context, size in
            for (index, piece) in Self.geometry(for: strands, in: size).enumerated() {
                let tone = index == accentIndex ? accentColor : color
                context.stroke(piece.thread, with: .color(tone.opacity(0.75)), lineWidth: lineWidth)
                context.fill(piece.star, with: .color(tone))
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

    /// The whole band as one path — shared with the page-template renderer.
    static func path(in size: CGSize) -> Path {
        var path = Path()
        let h = size.height
        // Waves overlap like the artwork: each crest rises out from
        // under the previous curl.
        let waveWidth = h * 1.5
        let stride = h * 1.05
        guard stride > 0, size.width >= waveWidth else { return path }
        let count = Int((size.width - waveWidth) / stride) + 1
        let width = waveWidth + CGFloat(count - 1) * stride
        let startX = (size.width - width) / 2

        for i in 0..<count {
            let x0 = startX + CGFloat(i) * stride
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
        }
        return path
    }

    var body: some View {
        Canvas { context, size in
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            context.stroke(Self.path(in: size), with: .color(color), style: style)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Meander (Greek key): spiral hooks over a baseline

struct MeanderRule: View {
    var color: Color = Theme.navy.opacity(0.2)
    var lineWidth: CGFloat = 1

    static func path(in size: CGSize, lineWidth: CGFloat = 1) -> Path {
        var path = Path()
        let top = lineWidth / 2
        let bottom = size.height - lineWidth / 2
        let span = bottom - top
        let unit = size.height
        guard unit > 0, size.width >= unit else { return path }
        let count = Int(size.width / unit)
        let width = CGFloat(count) * unit
        let startX = (size.width - width) / 2

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
        return path
    }

    var body: some View {
        Canvas { context, size in
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .butt, lineJoin: .miter)
            context.stroke(Self.path(in: size, lineWidth: lineWidth), with: .color(color), style: style)
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

// MARK: - Photographic backdrops (watercolor sky + misty sidebar paper)

// The two photo textures are treated as *materials*, not pictures: they are
// aspect-filled edge to edge, veiled so cards and navy text keep contrast,
// and re-unified with the paper aesthetic by tiling the same linen weave
// used everywhere else on top. Both are static full-bleed layers behind
// scrolling content (content moves, the wash stays — like a painted desk).

/// Watercolor-sky wash (asset `bckgrd`): white clouds fading into blue.
/// Used behind every browsing surface — note grids, calendar, editor desk.
struct WatercolorBackdrop: View {
    /// Extra white veil, for surfaces that want a quieter wash.
    var veil: Double = 0

    var body: some View {
        Color.clear
            .overlay(
                Image("bckgrd")
                    .resizable()
                    .scaledToFill()
            )
            .overlay(Color.white.opacity(veil))
            .overlay(
                Image(uiImage: DecorTexture.linenTile)
                    .resizable(resizingMode: .tile)
                    .opacity(0.3)
            )
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Misty gray paper (asset `sidebar-texture`) for the sidebar: a sheet of
/// textured paper lying over the watercolor desk. A soft shaded trailing
/// edge makes it read as a physical layer rather than a pasted image.
struct SidebarBackdrop: View {
    var body: some View {
        Color.clear
            .overlay(
                Image("sidebar-texture")
                    .resizable()
                    .scaledToFill()
            )
            .overlay(Color.white.opacity(0.24))
            .overlay(
                Image(uiImage: DecorTexture.linenTile)
                    .resizable(resizingMode: .tile)
                    .opacity(0.3)
            )
            .overlay(alignment: .trailing) {
                // Shadowed fold where the paper meets the watercolor desk.
                LinearGradient(
                    colors: [.clear, Theme.navy.opacity(0.08)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 16)
            }
            .overlay(alignment: .trailing) {
                Theme.navy.opacity(0.12).frame(width: 1)
            }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Page templates (decorative background printed on kartka pages)

// Renders a PageTemplate into a full page so the live canvas, PDF export and
// thumbnails all draw the same delicate ornament under the handwriting. Navy
// ink at low opacity keeps writing perfectly legible. The `custom` case draws
// a user-supplied image, faded, filling the page.
enum PageTemplateRenderer {
    private static var ink: UIColor { UIColor(Theme.navy) }

    /// A page-sized image, or nil when there is nothing to draw. Used by the
    /// canvas page cards (set as CALayer contents).
    static func image(for template: PageTemplate, pageSize: CGSize, custom: UIImage?) -> UIImage? {
        guard template != .none, pageSize.width > 1, pageSize.height > 1 else { return nil }
        if template == .custom, custom == nil { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        return UIGraphicsImageRenderer(size: pageSize, format: format).image { ctx in
            draw(template, pageSize: pageSize, custom: custom, in: ctx.cgContext)
        }
    }

    /// Draws the template directly into a context already set up in page
    /// coordinates (PDF export / thumbnails).
    static func draw(_ template: PageTemplate, pageSize: CGSize, custom: UIImage?, in cg: CGContext) {
        switch template {
        case .none:
            return

        case .custom:
            guard let custom else { return }
            let target = CGRect(origin: .zero, size: pageSize)
            cg.saveGState()
            cg.clip(to: target)
            cg.setAlpha(0.16)
            custom.draw(in: aspectFill(custom.size, into: target))
            cg.restoreGState()

        case .meander:
            let margin = pageSize.width * 0.06
            let band = CGSize(width: pageSize.width - margin * 2,
                              height: max(18, pageSize.width * 0.03))
            let ribbon = MeanderRule.path(in: band, lineWidth: 2)
            // Top band.
            stroke(ribbon, offset: CGPoint(x: margin, y: margin),
                   lineWidth: 2, color: ink.withAlphaComponent(0.2), in: cg)
            // Bottom band, mirrored vertically so the hooks point inward.
            cg.saveGState()
            cg.translateBy(x: margin, y: pageSize.height - margin)
            cg.scaleBy(x: 1, y: -1)
            addPath(ribbon, lineWidth: 2, color: ink.withAlphaComponent(0.2), in: cg)
            cg.restoreGState()

        case .waves:
            let band = CGSize(width: pageSize.width,
                              height: max(60, pageSize.width * 0.11))
            let waves = WaveScroll.path(in: band)
            stroke(waves, offset: CGPoint(x: 0, y: pageSize.height - band.height),
                   lineWidth: 2.2, color: ink.withAlphaComponent(0.16), in: cg)

        case .stars:
            let band = CGSize(width: pageSize.width * 0.9, height: pageSize.width * 0.2)
            let originX = pageSize.width * 0.05
            for (i, piece) in HangingStars.geometry(for: HangingStars.five, in: band).enumerated() {
                let thread = piece.thread.applying(.init(translationX: originX, y: 0))
                let star = piece.star.applying(.init(translationX: originX, y: 0))
                addPath(thread, lineWidth: 1.6, color: ink.withAlphaComponent(0.4), in: cg)
                let starColor = (i == 3 ? UIColor(Theme.pink) : ink).withAlphaComponent(i == 3 ? 0.55 : 0.42)
                cg.addPath(star.cgPath)
                cg.setFillColor(starColor.cgColor)
                cg.fillPath()
            }
        }
    }

    // MARK: Helpers

    private static func aspectFill(_ imageSize: CGSize, into rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    private static func stroke(_ path: Path, offset: CGPoint, lineWidth: CGFloat, color: UIColor, in cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: offset.x, y: offset.y)
        addPath(path, lineWidth: lineWidth, color: color, in: cg)
        cg.restoreGState()
    }

    private static func addPath(_ path: Path, lineWidth: CGFloat, color: UIColor, in cg: CGContext) {
        cg.addPath(path.cgPath)
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(lineWidth)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.strokePath()
    }
}
