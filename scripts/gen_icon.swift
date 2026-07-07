// Renders the notey. app icon (1024x1024, no alpha — App Store requirement).
// Usage: swift gen_icon.swift <output.png>
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon-1024.png"

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, 1])!
}

let beige = rgb(0.965, 0.945, 0.906)   // #F6F1E7
let cream = rgb(0.992, 0.984, 0.961)   // #FDFBF5
let navy = rgb(0.122, 0.165, 0.267)    // #1F2A44
let border = rgb(0.894, 0.855, 0.776)  // #E4DAC6
let pink = rgb(0.851, 0.545, 0.639)    // #D98BA3

// Background
ctx.setFillColor(beige)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Cream page card with navy-ish soft border
let page = CGRect(x: 176, y: 160, width: 672, height: 704)
let pagePath = CGPath(roundedRect: page, cornerWidth: 88, cornerHeight: 88, transform: nil)
ctx.addPath(pagePath)
ctx.setFillColor(cream)
ctx.fillPath()
ctx.addPath(pagePath)
ctx.setStrokeColor(border)
ctx.setLineWidth(10)
ctx.strokePath()

// Handwritten navy squiggle (the "n" of notey)
ctx.setStrokeColor(navy)
ctx.setLineWidth(58)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.beginPath()
ctx.move(to: CGPoint(x: 316, y: 380))
ctx.addCurve(
    to: CGPoint(x: 512, y: 620),
    control1: CGPoint(x: 330, y: 560),
    control2: CGPoint(x: 420, y: 660)
)
ctx.addCurve(
    to: CGPoint(x: 640, y: 430),
    control1: CGPoint(x: 590, y: 585),
    control2: CGPoint(x: 610, y: 470)
)
ctx.addCurve(
    to: CGPoint(x: 708, y: 560),
    control1: CGPoint(x: 668, y: 395),
    control2: CGPoint(x: 690, y: 480)
)
ctx.strokePath()

// The single delicate pink accent — a dot like a pen rest
ctx.setFillColor(pink)
ctx.fillEllipse(in: CGRect(x: 664, y: 640, width: 88, height: 88))

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: out) as CFURL
let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
if CGImageDestinationFinalize(dest) {
    print("written: \(out)")
} else {
    print("FAILED")
    exit(1)
}
