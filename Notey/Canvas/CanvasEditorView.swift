import SwiftUI
import SwiftData
import PencilKit
import PhotosUI

// Full-page handwriting editor: native PencilKit ink (PKToolPicker) + photos,
// a slim app-level top bar, autosave into SwiftData.
struct CanvasEditorView: View {
    let note: Note
    // Set to this note's id to open the note menu right after the editor
    // appears (used when a brand-new note is created).
    var autoOpenSettingsID: Binding<UUID?>? = nil
    // Injected by ContentView so quick notes can paste into the open canvas;
    // standalone embeds (calendar) fall back to their own proxy.
    var externalProxy: CanvasProxy? = nil

    @Environment(\.modelContext) private var context
    @State private var config = CanvasToolConfig()
    @StateObject private var ownProxy = CanvasProxy()
    @State private var selection: SelectedElement?
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showSettings = false
    @State private var isNewNote = false
    @State private var pdfURL: URL?
    @State private var saveTask: Task<Void, Never>?
    @State private var pageCount: Int = 1
    // Decoded custom page template, delivered to the canvas.
    @State private var customTemplate: UIImage?
    // Auto-straighten hand-drawn shapes (draw & hold). Persists across notes.
    @AppStorage("shapeDetectionEnabled") private var shapeDetection = true
    // Developer mode (DEBUG builds): draw with a finger/mouse so the ink and
    // shape-snap pipeline can be tested on the Simulator, which has no Pencil.
    @AppStorage("devFingerDrawing") private var devFingerDrawing = false

    private var proxy: CanvasProxy { externalProxy ?? ownProxy }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            DrawingCanvas(
                initialDrawing: note.drawing,
                initialElements: note.elements,
                config: config,
                showsToolPicker: true,
                shapeDetection: shapeDetection,
                devFingerDrawing: devFingerDrawing,
                customTemplateImage: customTemplate,
                proxy: proxy,
                onChange: { drawing, elements in
                    scheduleSave(drawing: drawing, elements: elements)
                },
                onSelection: { selection = $0 }
            )
            .ignoresSafeArea(.container, edges: .bottom)
            // A quick note dragged from its floating card lands here — the
            // ink is pasted right where it was dropped.
            .dropDestination(for: String.self) { items, location in
                pasteQuickNote(items, at: location)
            }

            // Top-right cluster: note menu, pages, shape snapping, photo, PDF.
            VStack {
                HStack {
                    Spacer()
                    topCluster
                        .padding(.trailing, 12)
                        .padding(.top, 8)
                }
                Spacer()
            }
        }
        .onAppear {
            config.background = note.background
            config.paperColorHex = note.paperColorHex
            config.layout = note.layout
            config.orientation = note.orientation
            config.template = note.template
            refreshCustomTemplate()
            pageCount = max(1, note.elements.pages ?? 1)
            if autoOpenSettingsID?.wrappedValue == note.id {
                autoOpenSettingsID?.wrappedValue = nil
                isNewNote = true
                showSettings = true
            }
        }
        // The settings sheet mutates the note; mirror the new values into the
        // live canvas config and (re)decode the custom template image.
        .onChange(of: note.orientationRaw) { _, _ in config.orientation = note.orientation }
        .onChange(of: note.templateRaw) { _, _ in
            config.template = note.template
            refreshCustomTemplate()
        }
        .onChange(of: note.templateData) { _, _ in refreshCustomTemplate() }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    proxy.addImage(image)
                }
                photoItem = nil
            }
        }
        .sheet(item: $pdfURL) { url in
            ShareSheet(items: [url])
        }
        .sheet(isPresented: $showSettings) {
            NoteSettingsView(note: note, config: $config, isNewNote: isNewNote)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                proxy.addImage(image)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Quick note paste (drag & drop onto the canvas)

    private func pasteQuickNote(_ items: [String], at location: CGPoint) -> Bool {
        guard let item = items.first, item.hasPrefix("quick:"),
              let id = UUID(uuidString: String(item.dropFirst(6)))
        else { return false }
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
        guard let quick = try? context.fetch(descriptor).first, !quick.drawing.strokes.isEmpty else {
            return false
        }
        proxy.pasteDrawing(quick.drawing, atViewPoint: location)
        return true
    }

    // MARK: Custom template

    private func refreshCustomTemplate() {
        if note.template == .custom, let data = note.templateData, let image = UIImage(data: data) {
            customTemplate = image
            config.customTemplateKey = String(data.count)
        } else {
            customTemplate = nil
            config.customTemplateKey = nil
        }
    }

    // MARK: Persistence (debounced)

    private func scheduleSave(drawing: PKDrawing, elements: CanvasElements) {
        saveTask?.cancel()
        let drawingData = drawing.dataRepresentation()
        let elementsData = (try? JSONEncoder().encode(elements)) ?? Data()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            note.drawingData = drawingData
            note.elementsData = elementsData
            note.updatedAt = .now
            try? context.save()
        }
    }

    // MARK: Top bar (app-level actions; the ink tools live in the PKToolPicker)

    private var topCluster: some View {
        HStack(spacing: 4) {
            Button {
                isNewNote = false
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(Theme.navySoft)
            }
            .help("Nazwa, układ, tło i kolor kartki")

            if config.layout == .pages {
                Divider().frame(height: 20)
                pagesControl
            }

            Divider().frame(height: 20)

            // Auto-straighten shapes (draw & hold).
            Button {
                shapeDetection.toggle()
            } label: {
                Image(systemName: "scribble.variable")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(shapeDetection ? Theme.pink : Theme.navySoft)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(shapeDetection ? Theme.pinkSoft : .clear)
                    )
            }
            .help("Automatyczne prostowanie kształtów (narysuj i przytrzymaj)")

            #if DEBUG
            // Developer: finger/mouse drawing for Simulator testing.
            Button {
                devFingerDrawing.toggle()
            } label: {
                Image(systemName: "hand.draw")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(devFingerDrawing ? Theme.pink : Theme.navySoft)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(devFingerDrawing ? Theme.pinkSoft : .clear)
                    )
            }
            .help("Tryb deweloperski: rysowanie palcem/myszą (test w symulatorze)")
            #endif

            imageMenu

            // Delete the selected photo (PencilKit ink is erased with the
            // native eraser instead).
            if selection != nil {
                Button {
                    proxy.deleteSelected()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(Theme.pink)
                }
                .help("Usuń zaznaczone zdjęcie")
            }

            Menu {
                Button(role: .destructive) {
                    proxy.clearAll()
                } label: {
                    Label("Wyczyść całą stronę", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 34)
                    .foregroundStyle(Theme.navySoft)
            }

            Divider().frame(height: 20)

            Button {
                pdfURL = proxy.exportPDF(title: note.title)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                    Text("PDF")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.card)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.navy, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(6)
        .background(floatingBackground)
    }

    private var imageMenu: some View {
        Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showCamera = true
                } label: {
                    Label("Zrób zdjęcie", systemImage: "camera")
                }
            }
            Button {
                showPhotoPicker = true
            } label: {
                Label("Z biblioteki zdjęć", systemImage: "photo.on.rectangle")
            }
            Button {
                if let image = UIPasteboard.general.image {
                    proxy.addImage(image)
                }
            } label: {
                Label("Wklej ze schowka", systemImage: "doc.on.clipboard")
            }
        } label: {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(Theme.navySoft)
        }
        .help("Wstaw zdjęcie")
    }

    // MARK: Pages control (inside the top cluster)

    private var pagesControl: some View {
        HStack(spacing: 0) {
            Button {
                proxy.removePage()
                pageCount = max(1, pageCount - 1)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(pageCount > 1 ? Theme.navySoft : Theme.navySoft.opacity(0.3))
                    .frame(width: 28, height: 30)
            }
            .disabled(pageCount <= 1)

            Text(pagesLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.navySoft)
                .padding(.horizontal, 2)

            Button {
                proxy.addPage()
                pageCount += 1
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.navySoft)
                    .frame(width: 28, height: 30)
            }
        }
    }

    private var pagesLabel: String {
        switch pageCount {
        case 1: return "1 kartka"
        case 2...4: return "\(pageCount) kartki"
        default: return "\(pageCount) kartek"
        }
    }

    // MARK: Pieces

    private var floatingBackground: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.border, lineWidth: 1))
            .shadow(color: Theme.navy.opacity(0.10), radius: 12, y: 4)
    }
}

// MARK: - Share sheet

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Camera capture straight onto the canvas

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
