import Foundation
import SwiftData
import PencilKit

// MARK: - SwiftData models

@Model
final class Folder {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String
    var order: Int
    var createdAt: Date

    var parent: Folder?
    @Relationship(deleteRule: .cascade, inverse: \Folder.parent)
    var children: [Folder] = []

    @Relationship(deleteRule: .nullify, inverse: \Note.folder)
    var notes: [Note] = []

    init(name: String, colorHex: String, parent: Folder? = nil, order: Int = 0) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.parent = parent
        self.order = order
        self.createdAt = .now
    }
}

enum NoteKind: String, Codable {
    case note
    case calendar
    // Single global scratchpad opened from the black edge tab.
    case quick
}

enum CanvasBackground: String, Codable, CaseIterable {
    case blank, dots, lines, grid
}

enum NoteLayout: String, Codable {
    // Stacked A4-like pages ("kartki").
    case pages
    // One huge free canvas without page borders.
    case infinite
}

@Model
final class Note {
    @Attribute(.unique) var id: UUID
    var title: String
    var kindRaw: String
    // "yyyy-MM-dd" — one calendar note per day
    var dateKey: String?
    var folder: Folder?
    @Attribute(.externalStorage) var drawingData: Data
    @Attribute(.externalStorage) var elementsData: Data
    var backgroundRaw: String
    var layoutRaw: String = NoteLayout.pages.rawValue
    // Custom paper tint (hex). nil = default cream card.
    var paperColorHex: String?
    var createdAt: Date
    var updatedAt: Date

    init(title: String, kind: NoteKind = .note, dateKey: String? = nil, folder: Folder? = nil) {
        self.id = UUID()
        self.title = title
        self.kindRaw = kind.rawValue
        self.dateKey = dateKey
        self.folder = folder
        self.drawingData = Data()
        self.elementsData = Data()
        self.backgroundRaw = (kind == .calendar ? CanvasBackground.blank : .dots).rawValue
        self.createdAt = .now
        self.updatedAt = .now
    }

    var kind: NoteKind { NoteKind(rawValue: kindRaw) ?? .note }

    var background: CanvasBackground {
        get { CanvasBackground(rawValue: backgroundRaw) ?? .dots }
        set { backgroundRaw = newValue.rawValue }
    }

    var layout: NoteLayout {
        get { NoteLayout(rawValue: layoutRaw) ?? .pages }
        set { layoutRaw = newValue.rawValue }
    }

    var drawing: PKDrawing {
        get { (try? PKDrawing(data: drawingData)) ?? PKDrawing() }
        set { drawingData = newValue.dataRepresentation() }
    }

    var elements: CanvasElements {
        get { (try? JSONDecoder().decode(CanvasElements.self, from: elementsData)) ?? CanvasElements() }
        set { elementsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var isEmpty: Bool {
        drawing.strokes.isEmpty && elements.images.isEmpty && elements.annotations.isEmpty
    }
}

// MARK: - Canvas element payloads (stored as JSON on the note)

struct CanvasElements: Codable, Equatable {
    var images: [ImageElement] = []
    var annotations: [AnnotationElement] = []
    // Stacked pages of the note (nil = 1). Extra pages are added with the
    // "+" button in calendar notes.
    var pages: Int?
}

struct ImageElement: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var imageData: Data

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.origin.x; y = newValue.origin.y; w = newValue.width; h = newValue.height }
    }
}

struct AnnotationElement: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var colorHex: String
    // Legacy field kept only so old notes still decode.
    var createdAt: Double?
    // Fingerprints (randomSeed-pointCount) of strokes written on top of this
    // annotation. This is the ONLY attachment rule: a stroke belongs to the
    // annotation iff it first appeared on it. Fingerprints survive the
    // PKDrawing serialization round-trip, so text still travels with the
    // annotation after the note is closed and reopened.
    var strokeKeys: [String]?

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.origin.x; y = newValue.origin.y; w = newValue.width; h = newValue.height }
    }
}

// MARK: - Logical page

enum CanvasPage {
    // Portrait page used by all notes; mini views scale it down uniformly.
    static let size = CGSize(width: 1000, height: 1400)
    // Vertical gap between stacked pages of a multi-page note.
    static let gap: CGFloat = 28
    // "Infinite canvas" sheet: this is only the STARTING window (56-aligned
    // so pattern-preserving shifts stay pixel-exact). The canvas grows without
    // bound — whenever the viewport or the ink nears an edge, the sheet is
    // extended in that direction (see CanvasContainer.ensureInfiniteRunway).
    static let infiniteSize = CGSize(width: 89_600, height: 89_600)
    // Minimum empty space kept between content/viewport and every sheet edge
    // of an infinite note; growth tops it up to 1.5x.
    static let infiniteRunway: CGFloat = 30_000

    static func totalSize(pages: Int) -> CGSize {
        let n = CGFloat(max(1, pages))
        return CGSize(width: size.width, height: size.height * n + gap * (n - 1))
    }
}

extension PKStroke {
    /// Stable stroke identity that survives PKDrawing (de)serialization —
    /// used to remember which strokes were written on an annotation.
    var fingerprint: String { "\(randomSeed)-\(path.count)" }
}
