import UIKit
import PencilKit

// PDF export: single notes, multi-page notes, or whole folder subtrees.
// Every stacked page of every note becomes one PDF page (1000x1400 pt);
// infinite-canvas notes are scaled to fit a single page.
@MainActor
enum NoteExporter {

    typealias NotePayload = (
        drawing: PKDrawing,
        elements: CanvasElements,
        paperHex: String?,
        layout: NoteLayout,
        orientation: PageOrientation,
        template: PageTemplate,
        customImage: UIImage?
    )

    /// All regular notes of a folder and its subfolders (depth-first).
    static func notesInSubtree(of folder: Folder) -> [Note] {
        var result = folder.notes
            .filter { $0.kind == .note }
            .sorted { $0.updatedAt > $1.updatedAt }
        let children = folder.children.sorted {
            ($0.order, $0.name) < ($1.order, $1.name)
        }
        for child in children {
            result += notesInSubtree(of: child)
        }
        return result
    }

    static func exportPDF(notes: [Note], title: String) -> URL? {
        exportPDF(
            pages: notes.map {
                (
                    $0.drawing,
                    $0.elements,
                    $0.paperColorHex,
                    $0.layout,
                    $0.orientation,
                    $0.template,
                    $0.templateData.flatMap(UIImage.init(data:))
                )
            },
            title: title
        )
    }

    static func exportPDF(pages payloads: [NotePayload], title: String) -> URL? {
        guard !payloads.isEmpty else { return nil }
        // Each page declares its own media box, so mixed orientations render
        // correctly; this is only the default for the first beginPage.
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: CanvasPage.size))

        let data = renderer.pdfData { ctx in
            for payload in payloads {
                let pageSize = payload.layout == .pages
                    ? CanvasPage.size(for: payload.orientation)
                    : CanvasPage.size
                let pageRect = CGRect(origin: .zero, size: pageSize)
                // Decode each image once per note, not once per page.
                var decoded: [UUID: UIImage] = [:]
                for element in payload.elements.images {
                    decoded[element.id] = UIImage(data: element.imageData)
                }
                let paper = payload.paperHex.map { UIColor(hexString: $0) } ?? UIColor(Theme.card)

                if payload.layout == .infinite {
                    ctx.beginPage(withBounds: pageRect, pageInfo: [:])
                    let cg = ctx.cgContext
                    paper.setFill()
                    cg.fill(pageRect)

                    // Fit the used part of the huge sheet onto one page.
                    var union: CGRect = .null
                    if !payload.drawing.strokes.isEmpty { union = union.union(payload.drawing.bounds) }
                    for i in payload.elements.images { union = union.union(i.frame) }
                    for a in payload.elements.annotations { union = union.union(a.frame) }
                    let region = union.isNull ? pageRect : union.insetBy(dx: -40, dy: -40)
                    let scale = min(pageRect.width / region.width, pageRect.height / region.height, 1)

                    cg.saveGState()
                    cg.translateBy(
                        x: (pageRect.width - region.width * scale) / 2 - region.minX * scale,
                        y: (pageRect.height - region.height * scale) / 2 - region.minY * scale
                    )
                    cg.scaleBy(x: scale, y: scale)
                    drawContent(
                        in: cg,
                        inkRegion: region,
                        elements: payload.elements,
                        drawing: payload.drawing,
                        decodedImages: decoded
                    )
                    cg.restoreGState()
                    continue
                }

                let pages = max(1, payload.elements.pages ?? 1)
                for pageIndex in 0..<pages {
                    ctx.beginPage(withBounds: pageRect, pageInfo: [:])
                    let cg = ctx.cgContext
                    paper.setFill()
                    cg.fill(pageRect)
                    // Decorative template under the writing, in page coords.
                    PageTemplateRenderer.draw(
                        payload.template,
                        pageSize: pageSize,
                        custom: payload.customImage,
                        in: cg
                    )

                    let sourceRect = CGRect(
                        x: 0,
                        y: CGFloat(pageIndex) * (pageSize.height + CanvasPage.gap),
                        width: pageSize.width,
                        height: pageSize.height
                    )
                    cg.saveGState()
                    cg.translateBy(x: 0, y: -sourceRect.minY)
                    drawContent(
                        in: cg,
                        inkRegion: sourceRect,
                        elements: payload.elements,
                        drawing: payload.drawing,
                        decodedImages: decoded
                    )
                    cg.restoreGState()
                }
            }
        }

        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let safe = title.components(separatedBy: forbidden).joined()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safe.isEmpty ? "notey-eksport" : safe)
            .appendingPathExtension("pdf")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Canvas z-order: photos, annotation cards, then all ink on top.
    private static func drawContent(
        in cg: CGContext,
        inkRegion: CGRect,
        elements: CanvasElements,
        drawing: PKDrawing,
        decodedImages: [UUID: UIImage]
    ) {
        for element in elements.images {
            decodedImages[element.id]?.draw(in: element.frame)
        }
        for annotation in elements.annotations {
            let card = UIBezierPath(roundedRect: annotation.frame, cornerRadius: 12)
            UIColor(hexString: annotation.colorHex).setFill()
            card.fill()
        }
        if !drawing.strokes.isEmpty {
            let ink = drawing.image(from: inkRegion, scale: 2)
            ink.draw(in: inkRegion)
        }
    }
}
