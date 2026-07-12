import UIKit
import SwiftUI
import PencilKit

// Renders note previews (page-fit for calendar tiles, content-fit for cards).
enum NoteThumbnail {
    private static let cache = NSCache<NSString, UIImage>()

    enum Fit {
        case page     // scale the whole logical page into the target
        case width    // fill the tile width, top-aligned crop (calendar tiles)
        case content  // zoom to whatever was drawn
        case topThird // top 1/3 of the page
    }

    private static func fitTag(_ fit: Fit) -> String {
        switch fit {
        case .page: return "p"
        case .width: return "w"
        case .content: return "c"
        case .topThird: return "t"
        }
    }

    static func image(for note: Note, size: CGSize, fit: Fit) -> UIImage {
        let key = "\(note.id.uuidString)-\(note.updatedAt.timeIntervalSince1970)-\(Int(size.width))x\(Int(size.height))-\(fitTag(fit))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let drawing = note.drawing
        let elements = note.elements
        let paper = note.paperColorHex.map { UIColor(hexString: $0) } ?? UIColor(Theme.card)
        let pageSize = note.layout == .pages
            ? CanvasPage.size(for: note.orientation)
            : CanvasPage.size
        let page = CGRect(origin: .zero, size: pageSize)
        let templateImage: UIImage? = note.layout == .pages
            ? note.template == .custom
                ? note.templateData.flatMap(UIImage.init(data:))
                : nil
            : nil

        // Region to display
        var region = page
        switch fit {
        case .page:
            break
        case .width:
            // Show the top slice of page 1 at full width — writing stays
            // readable in small month/week tiles instead of letterboxing.
            let sliceHeight = min(page.height, page.width * size.height / max(1, size.width))
            region = CGRect(x: 0, y: 0, width: page.width, height: sliceHeight)
        case .topThird:
            region = CGRect(x: 0, y: 0, width: page.width, height: page.height / 3.0)
        case .content:
            var union: CGRect = .null
            if !drawing.strokes.isEmpty { union = union.union(drawing.bounds) }
            for i in elements.images { union = union.union(i.frame) }
            if !union.isNull {
                region = union.insetBy(dx: -40, dy: -40)
            }
        }

        let scale: CGFloat
        if fit == .topThird {
            scale = max(size.width / region.width, size.height / region.height)
        } else {
            scale = min(size.width / region.width, size.height / region.height, 1.2)
        }
        
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let c = ctx.cgContext
            paper.setFill()
            c.fill(CGRect(origin: .zero, size: size))

            let tx = (size.width - region.width * scale) / 2 - region.minX * scale
            let ty = fit == .topThird ? -region.minY * scale : (size.height - region.height * scale) / 2 - region.minY * scale
            c.translateBy(x: tx, y: ty)
            c.scaleBy(x: scale, y: scale)

            // Decorative template first (page coords), under everything else.
            if note.layout == .pages, note.template != .none {
                PageTemplateRenderer.draw(
                    note.template,
                    pageSize: pageSize,
                    custom: templateImage,
                    in: c
                )
            }

            // Canvas z-order: photos, then all ink on top.
            for element in elements.images {
                if let uiImage = UIImage(data: element.imageData) {
                    uiImage.draw(in: element.frame)
                }
            }
            if !drawing.strokes.isEmpty {
                let inkRegion = fit == .content ? region : page
                let ink = drawing.image(from: inkRegion, scale: max(0.5, scale))
                ink.draw(in: inkRegion)
            }
        }
        cache.setObject(img, forKey: key)
        return img
    }
}

// SwiftUI wrapper that re-renders when the note changes.
struct NoteThumbnailView: View {
    let note: Note
    var fit: NoteThumbnail.Fit = .page

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > 1, geo.size.height > 1 {
                Image(
                    uiImage: NoteThumbnail.image(
                        for: note,
                        size: CGSize(width: geo.size.width, height: geo.size.height),
                        fit: fit
                    )
                )
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
        }
    }
}
