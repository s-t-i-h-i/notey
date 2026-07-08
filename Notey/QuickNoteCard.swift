import SwiftUI
import SwiftData
import PencilKit

// MARK: - Anchors (top edge + corners) the quick note can be pinned to

enum QuickNoteAnchor: String, CaseIterable, Codable {
    case topLeading, top, topTrailing, bottomLeading, bottomTrailing

    func center(in size: CGSize, cardSize: CGSize) -> CGPoint {
        let margin: CGFloat = 22
        let halfW = cardSize.width / 2
        let halfH = cardSize.height / 2
        switch self {
        case .topLeading: return CGPoint(x: margin + halfW, y: margin + halfH)
        case .top: return CGPoint(x: size.width / 2, y: margin + halfH)
        case .topTrailing: return CGPoint(x: size.width - margin - halfW, y: margin + halfH)
        case .bottomLeading: return CGPoint(x: margin + halfW, y: size.height - margin - halfH)
        case .bottomTrailing: return CGPoint(x: size.width - margin - halfW, y: size.height - margin - halfH)
        }
    }

    static func nearest(to point: CGPoint, in size: CGSize, cardSize: CGSize) -> QuickNoteAnchor {
        allCases.min { a, b in
            let pa = a.center(in: size, cardSize: cardSize)
            let pb = b.center(in: size, cardSize: cardSize)
            return hypot(point.x - pa.x, point.y - pa.y) < hypot(point.x - pb.x, point.y - pb.y)
        } ?? .topTrailing
    }
}

// MARK: - Floating slot state (persisted as JSON in AppStorage)

// One floating quick note: either a full card at an anchor, or — after being
// "thrown off screen" — a small tab docked to the left/right edge.
struct QuickSlot: Codable, Equatable, Identifiable {
    var id: UUID                 // the quick note's id
    var anchor: QuickNoteAnchor = .topTrailing
    var docked: Bool = false
    var dockTrailing: Bool = true       // which edge the tab sits on
    var dockFraction: Double = 0.3      // vertical position (0..1)
    var pinned: Bool = false            // pushpin pressed → shrunk & pinned in place

    static let maxOpen = 3

    private enum CodingKeys: String, CodingKey {
        case id, anchor, docked, dockTrailing, dockFraction, pinned
    }

    init(id: UUID,
         anchor: QuickNoteAnchor = .topTrailing,
         docked: Bool = false,
         dockTrailing: Bool = true,
         dockFraction: Double = 0.3,
         pinned: Bool = false) {
        self.id = id
        self.anchor = anchor
        self.docked = docked
        self.dockTrailing = dockTrailing
        self.dockFraction = dockFraction
        self.pinned = pinned
    }

    // Tolerate slots persisted before a field was added (e.g. `pinned`), so an
    // app update never drops the user's floating quick notes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        anchor = try c.decodeIfPresent(QuickNoteAnchor.self, forKey: .anchor) ?? .topTrailing
        docked = try c.decodeIfPresent(Bool.self, forKey: .docked) ?? false
        dockTrailing = try c.decodeIfPresent(Bool.self, forKey: .dockTrailing) ?? true
        dockFraction = try c.decodeIfPresent(Double.self, forKey: .dockFraction) ?? 0.3
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    static func decode(_ raw: String) -> [QuickSlot] {
        guard let data = raw.data(using: .utf8),
              let slots = try? JSONDecoder().decode([QuickSlot].self, from: data)
        else { return [] }
        return slots
    }

    static func encode(_ slots: [QuickSlot]) -> String {
        guard let data = try? JSONEncoder().encode(slots) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Floating quick note: a small ruled paper card, nothing else

struct QuickNoteCard: View {
    let note: Note
    var isPinned: Bool = false
    var onTogglePin: () -> Void = {}
    let onClose: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void

    @Environment(\.modelContext) private var context
    @State private var eraserActive = false
    @State private var clearToken = 0
    @State private var saveTask: Task<Void, Never>?

    static let size = CGSize(width: 320, height: 360)
    // How much the card shrinks once pinned (kept large enough to stay legible).
    static let pinnedScale: CGFloat = 0.52

    var body: some View {
        ZStack(alignment: .top) {
            paper

            VStack(spacing: 0) {
                header
                QuickPadCanvas(
                    initialDrawing: note.drawing,
                    eraser: eraserActive,
                    clearToken: clearToken,
                    onChange: scheduleSave
                )
            }

            // Tiny tool row, tucked into the bottom corners. Hidden while pinned
            // — a pinned card is a minimized sticky; unpin it to edit.
            if !isPinned {
                VStack {
                    Spacer()
                    HStack(spacing: 2) {
                        pasteHandle
                        Spacer()
                        miniTool("pencil.tip", active: !eraserActive) { eraserActive = false }
                        miniTool("eraser", active: eraserActive) { eraserActive = true }
                        miniTool("trash", active: false) {
                            clearToken += 1
                            scheduleSave(PKDrawing())
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
        // 3D pushpin poking above the top edge — tap to pin (shrink) / unpin.
        .overlay(alignment: .top) {
            Button(action: onTogglePin) {
                Pushpin(pressed: isPinned)
                    .frame(width: 40, height: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(y: -18)
            .accessibilityLabel(isPinned
                ? "Odepnij szybką notatkę"
                : "Przypnij i zmniejsz szybką notatkę")
        }
    }

    // MARK: Paper (ruled index card)

    private var paper: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.card))
            // Red headline rule under the header strip.
            var rule = Path()
            rule.move(to: CGPoint(x: 0, y: 34))
            rule.addLine(to: CGPoint(x: size.width, y: 34))
            ctx.stroke(rule, with: .color(Theme.pink.opacity(0.55)), lineWidth: 1.2)
            // Faint ruled lines.
            var lines = Path()
            var y: CGFloat = 62
            while y < size.height - 8 {
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
                y += 26
            }
            ctx.stroke(lines, with: .color(Color(hex: 0xBFD0DE).opacity(0.55)), lineWidth: 1)
            // A tiny star charm dangling from the top edge.
            let charmX = size.width - 46
            var thread = Path()
            thread.move(to: CGPoint(x: charmX, y: 0))
            thread.addLine(to: CGPoint(x: charmX, y: 13))
            ctx.stroke(thread, with: .color(Theme.navy.opacity(0.4)), lineWidth: 1)
            let charmRect = CGRect(x: charmX - 5.5, y: 13, width: 11, height: 11)
            let tilt = CGAffineTransform(translationX: charmRect.midX, y: charmRect.midY)
                .rotated(by: -10 * .pi / 180)
                .translatedBy(x: -charmRect.midX, y: -charmRect.midY)
            ctx.fill(StarShape().path(in: charmRect).applying(tilt), with: .color(Theme.navy.opacity(0.55)))
        }
        .allowsHitTesting(false)
    }

    // MARK: Header (drag area + close)

    private var header: some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.border)
                .padding(.leading, 10)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .padding(.trailing, 4)
        }
        .frame(height: 34)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { onDragChanged($0.translation) }
                .onEnded { onDragEnded($0.translation) }
        )
    }

    // Grab this handle and drop it onto an open note (canvas or its tab) to
    // paste the card's ink there.
    private var pasteHandle: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 11, weight: .medium))
            Text("Wklej do notatki")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.card.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .draggable("quick:\(note.id.uuidString)")
        .accessibilityLabel("Przeciągnij, aby wkleić do notatki")
    }

    private func miniTool(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? Theme.pink : Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(active ? Theme.pinkSoft : Theme.card.opacity(0.85))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Persistence

    private func scheduleSave(_ drawing: PKDrawing) {
        saveTask?.cancel()
        let cropped = drawing.cropped(to: CGRect(origin: .zero, size: Self.size))
        let data = cropped.dataRepresentation()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            note.drawingData = data
            note.updatedAt = .now
            try? context.save()
        }
    }
}

extension PKDrawing {
    func cropped(to bounds: CGRect) -> PKDrawing {
        var newStrokes: [PKStroke] = []
        for stroke in self.strokes {
            if bounds.contains(stroke.renderBounds) {
                newStrokes.append(stroke)
                continue
            }
            var currentPoints: [PKStrokePoint] = []
            for point in stroke.path {
                let loc = point.location.applying(stroke.transform)
                if bounds.contains(loc) {
                    currentPoints.append(point)
                } else {
                    if currentPoints.count > 1 {
                        let newPath = PKStrokePath(controlPoints: currentPoints, creationDate: stroke.path.creationDate)
                        let newStroke = PKStroke(ink: stroke.ink, path: newPath, transform: stroke.transform, mask: stroke.mask)
                        newStrokes.append(newStroke)
                    }
                    currentPoints = []
                }
            }
            if currentPoints.count > 1 {
                let newPath = PKStrokePath(controlPoints: currentPoints, creationDate: stroke.path.creationDate)
                let newStroke = PKStroke(ink: stroke.ink, path: newPath, transform: stroke.transform, mask: stroke.mask)
                newStrokes.append(newStroke)
            }
        }
        return PKDrawing(strokes: newStrokes)
    }
}

// MARK: - 3D pushpin

// A glossy thumbtack that sits on the top edge of a quick note. `pressed`
// (= the note is pinned) sinks it into the paper; released it lifts and tilts.
private struct Pushpin: View {
    var pressed: Bool

    private let headLight = Color(hex: 0xF29AA9)
    private let headBase  = Color(hex: 0xD9536B)
    private let headDark  = Color(hex: 0x9E2E45)

    var body: some View {
        VStack(spacing: -3) {
            // Domed head with a specular highlight for volume.
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [headLight, headBase, headDark],
                            center: UnitPoint(x: 0.34, y: 0.30),
                            startRadius: 0.5,
                            endRadius: 16
                        )
                    )
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, headDark.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Circle().stroke(headDark.opacity(0.55), lineWidth: 0.5)
                Ellipse()
                    .fill(.white.opacity(0.8))
                    .frame(width: 7, height: 5)
                    .blur(radius: 1)
                    .offset(x: -4, y: -5)
            }
            .frame(width: 22, height: 22)

            // Metallic needle tapering to a point.
            NeedleShape()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xF2F2F2), Color(hex: 0x9AA0A6), Color(hex: 0x5F646A)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 6, height: 13)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(pressed ? 0.18 : 0.32),
                radius: pressed ? 1.5 : 4,
                x: 0, y: pressed ? 1 : 3)
        .rotationEffect(.degrees(pressed ? 0 : -9))
        .offset(y: pressed ? 4 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pressed)
    }
}

private struct NeedleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Bare PencilKit pad (1:1 scale, no zoom, no chrome)

private struct QuickPadCanvas: UIViewRepresentable {
    let initialDrawing: PKDrawing
    var eraser: Bool
    var clearToken: Int
    let onChange: (PKDrawing) -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = initialDrawing
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.clipsToBounds = true
        // Pencil-only writing throughout the app.
        canvas.drawingPolicy = .pencilOnly
        canvas.delegate = context.coordinator
        context.coordinator.onChange = onChange
        applyTool(canvas)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.onChange = onChange
        applyTool(canvas)
        if context.coordinator.clearToken != clearToken {
            context.coordinator.clearToken = clearToken
            canvas.drawing = PKDrawing()
        }
    }

    private func applyTool(_ canvas: PKCanvasView) {
        canvas.tool = eraser
            ? PKEraserTool(.vector)
            : PKInkingTool(.pen, color: Theme.inkColors[0], width: 3)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onChange: ((PKDrawing) -> Void)?
        var clearToken = 0

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onChange?(canvasView.drawing)
        }
    }
}
