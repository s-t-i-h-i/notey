import SwiftUI
import SwiftData
import PencilKit
import PhotosUI

// Full-page handwriting editor: PencilKit ink + images + annotations,
// floating beige/navy toolbars, autosave into SwiftData.
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
    // Tool whose options popover (opened via long-press) is showing.
    @State private var optionsTool: EditorTool?
    @State private var pdfURL: URL?
    @State private var saveTask: Task<Void, Never>?
    @State private var pageCount: Int = 1

    private var proxy: CanvasProxy { externalProxy ?? ownProxy }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            DrawingCanvas(
                initialDrawing: note.drawing,
                initialElements: note.elements,
                config: config,
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

            // Left floating tool strip
            HStack {
                toolStrip
                    .padding(.leading, 12)
                Spacer()
            }

            // Top-right cluster: input mode, note menu, pages, export
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
            pageCount = max(1, note.elements.pages ?? 1)
            if autoOpenSettingsID?.wrappedValue == note.id {
                autoOpenSettingsID?.wrappedValue = nil
                showSettings = true
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    proxy.addImage(image)
                    config.tool = .objects
                }
                photoItem = nil
            }
        }
        .sheet(item: $pdfURL) { url in
            ShareSheet(items: [url])
        }
        .sheet(isPresented: $showSettings) {
            NoteSettingsView(note: note, config: $config)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                proxy.addImage(image)
                config.tool = .objects
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

    // MARK: Toolbars

    private var toolStrip: some View {
        VStack(spacing: 4) {
            toolButton(.pen, icon: config.penStyle.icon, label: "Pióro")
            toolButton(.marker, icon: "highlighter", label: "Zakreślacz")
            toolButton(.eraser, icon: config.eraserMode.icon, label: "Gumka")
            toolButton(.lasso, icon: "lasso", label: "Lasso")
            toolButton(.objects, icon: "hand.point.up.left", label: "Obiekty")
            toolButton(.annotation, icon: "app.fill", label: "Adnotacja")

            imageMenu

            Divider().frame(width: 26)

            iconButton("arrow.uturn.backward", label: "Cofnij") { proxy.undo() }
            iconButton("arrow.uturn.forward", label: "Ponów") { proxy.redo() }
            iconButton("trash", label: "Wyczyść", danger: true) {
                if selection != nil { proxy.deleteSelected() } else { proxy.clearAll() }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
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
                    config.tool = .objects
                }
            } label: {
                Label("Wklej ze schowka", systemImage: "doc.on.clipboard")
            }
        } label: {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
                .foregroundStyle(Theme.navySoft)
        }
    }

    private var topCluster: some View {
        HStack(spacing: 4) {
            Button {
                config.fingerDraws.toggle()
            } label: {
                Image(systemName: config.fingerDraws ? "hand.draw" : "applepencil.tip")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(Theme.navySoft)
            }
            .help(config.fingerDraws ? "Rysuje palec i Pencil" : "Rysuje tylko Pencil")

            Button {
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

    // MARK: Tool options (popover on long-press of a toolbar button)

    private func hasOptions(_ tool: EditorTool) -> Bool {
        switch tool {
        case .pen, .marker, .eraser, .annotation: return true
        case .lasso, .objects: return false
        }
    }

    @ViewBuilder
    private func toolOptions(_ tool: EditorTool) -> some View {
        switch tool {
        case .pen:
            penDock
        case .marker:
            markerDock
        case .eraser:
            eraserDock
        case .annotation:
            HStack(spacing: 12) {
                Text("Kolor")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                colorRow(Theme.annotationColors, selected: config.annotationColor, square: true) {
                    config.annotationColor = $0
                }
            }
        case .lasso, .objects:
            EmptyView()
        }
    }

    private var penDock: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(PenStyle.allCases) { style in
                    dockChip(icon: style.icon, label: style.label, active: config.penStyle == style) {
                        config.penStyle = style
                    }
                }
            }
            HStack(spacing: 12) {
                widthSlider(value: $config.penWidth, range: 1...20)
                Divider().frame(height: 22)
                colorRow(Theme.inkColors, selected: config.penColor) { config.penColor = $0 }
                customColorWell(color: $config.penColor)
            }
        }
    }

    private var markerDock: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(MarkerStyle.allCases) { style in
                    dockChip(
                        icon: style == .classic ? "highlighter" : "drop.halffull",
                        label: style.label,
                        active: config.markerStyle == style
                    ) {
                        config.markerStyle = style
                    }
                }
            }
            HStack(spacing: 12) {
                widthSlider(value: $config.markerWidth, range: 6...44)
                Divider().frame(height: 22)
                colorRow(Theme.markerColors, selected: config.markerColor) { config.markerColor = $0 }
                customColorWell(color: $config.markerColor)
            }
        }
    }

    private var eraserDock: some View {
        HStack(spacing: 10) {
            ForEach(EraserMode.allCases) { mode in
                dockChip(icon: mode.icon, label: mode.label, active: config.eraserMode == mode) {
                    config.eraserMode = mode
                }
            }
            if config.eraserMode == .point {
                Divider().frame(height: 26)
                widthSlider(value: $config.eraserWidth, range: 6...80)
            }
        }
    }

    // MARK: Pieces

    private var floatingBackground: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.border, lineWidth: 1))
            .shadow(color: Theme.navy.opacity(0.10), radius: 12, y: 4)
    }

    // Tap selects the tool; holding the button opens its options (colors,
    // widths, styles) in a popover next to the strip.
    private func toolButton(_ tool: EditorTool, icon: String, label: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .medium))
            .frame(width: 40, height: 40)
            .foregroundStyle(config.tool == tool ? Theme.pink : Theme.navySoft)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(config.tool == tool ? Theme.pinkSoft : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                // Second tap on the active tool also opens its options.
                if config.tool == tool, hasOptions(tool) {
                    optionsTool = tool
                } else {
                    config.tool = tool
                }
            }
            .onLongPressGesture(minimumDuration: 0.35) {
                config.tool = tool
                if hasOptions(tool) {
                    optionsTool = tool
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            .popover(
                isPresented: Binding(
                    get: { optionsTool == tool },
                    set: { if !$0 { optionsTool = nil } }
                ),
                arrowEdge: .leading
            ) {
                toolOptions(tool)
                    .padding(16)
                    .presentationCompactAdaptation(.popover)
            }
            .accessibilityLabel(label)
    }

    private func iconButton(_ icon: String, label: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 40, height: 40)
                .foregroundStyle(danger ? Theme.pink : Theme.navySoft)
        }
        .accessibilityLabel(label)
    }

    private func dockChip(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 8, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? Theme.pink : Theme.navySoft)
            .frame(width: 58, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(active ? Theme.pinkSoft : .clear)
            )
        }
        .accessibilityLabel(label)
    }

    private func customColorWell(color: Binding<UIColor>) -> some View {
        ColorPicker(
            "",
            selection: Binding(
                get: { Color(uiColor: color.wrappedValue) },
                set: { color.wrappedValue = UIColor($0) }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
        .frame(width: 30)
        .accessibilityLabel("Własny kolor")
    }

    private func colorRow(
        _ colors: [UIColor],
        selected: UIColor,
        square: Bool = false,
        pick: @escaping (UIColor) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Button {
                    pick(color)
                } label: {
                    RoundedRectangle(cornerRadius: square ? 6 : 11)
                        .fill(Color(uiColor: color))
                        .frame(width: 22, height: 22)
                        .overlay(
                            RoundedRectangle(cornerRadius: square ? 6 : 11)
                                .stroke(
                                    selected == color ? Theme.navy : Theme.border,
                                    lineWidth: selected == color ? 2 : 1
                                )
                        )
                }
            }
        }
    }

    private func widthSlider(value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        HStack(spacing: 8) {
            Text("Grubość")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Slider(value: value, in: range)
                .frame(width: 130)
                .tint(Theme.navy)
        }
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
