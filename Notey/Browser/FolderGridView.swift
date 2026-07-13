import SwiftUI
import SwiftData

// Google-Drive-style tile view: subfolder cards, then note cards with
// handwriting previews. Everything drag & droppable.
struct FolderGridView: View {
    let folderID: UUID?
    let onOpenFolder: (UUID?) -> Void
    let onOpenNote: (Note) -> Void
    let onCreateNote: (Folder?) -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Folder.order), SortDescriptor(\Folder.name)])
    private var allFolders: [Folder]
    @Query(sort: [SortDescriptor(\Note.updatedAt, order: .reverse)])
    private var allNotes: [Note]

    @State private var renamingFolder: Folder?
    @State private var renamingNote: Note?
    @State private var renameText = ""
    @State private var deletingFolder: Folder?
    @State private var deletingNote: Note?
    @State private var exportURL: URL?

    private var currentFolder: Folder? {
        folderID.flatMap { id in allFolders.first { $0.id == id } }
    }

    private var subfolders: [Folder] {
        allFolders.filter { $0.parent?.id == folderID }
    }

    private var folderNotes: [Note] {
        allNotes.filter { $0.kind == .note && $0.folder?.id == folderID }
    }

    private var path: [Folder] {
        var chain: [Folder] = []
        var cursor = currentFolder
        while let folder = cursor {
            chain.insert(folder, at: 0)
            cursor = folder.parent
        }
        return chain
    }

    private let cardColumns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerRow

                if !subfolders.isEmpty {
                    sectionTitle("Foldery")
                    LazyVGrid(columns: cardColumns, spacing: 12) {
                        ForEach(subfolders) { folder in
                            folderCard(folder)
                        }
                    }
                }

                sectionTitle("Notatki")
                if folderNotes.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: cardColumns, spacing: 12) {
                        ForEach(folderNotes) { note in
                            noteCard(note)
                        }
                    }
                }
            }
            .padding(16)
        }
        .sheet(item: $exportURL) { url in
            ShareSheet(items: [url])
        }
        .alert("Zmień nazwę", isPresented: Binding(
            get: { renamingFolder != nil || renamingNote != nil },
            set: { if !$0 { renamingFolder = nil; renamingNote = nil } }
        )) {
            TextField("Nazwa", text: $renameText)
            Button("Zapisz") {
                let name = renameText.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    renamingFolder?.name = name
                    if let note = renamingNote {
                        note.title = name
                        note.updatedAt = .now
                    }
                    try? context.save()
                }
                renamingFolder = nil
                renamingNote = nil
            }
            Button("Anuluj", role: .cancel) {
                renamingFolder = nil
                renamingNote = nil
            }
        }
        .confirmationDialog(
            deleteMessage,
            isPresented: Binding(
                get: { deletingFolder != nil || deletingNote != nil },
                set: { if !$0 { deletingFolder = nil; deletingNote = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Usuń", role: .destructive) {
                if let folder = deletingFolder { context.delete(folder) }
                if let note = deletingNote { context.delete(note) }
                try? context.save()
                deletingFolder = nil
                deletingNote = nil
            }
        }
    }

    private var deleteMessage: String {
        if let folder = deletingFolder {
            return "Usunąć folder „\(folder.name)”? Notatki trafią do „Wszystkie notatki”."
        }
        if let note = deletingNote {
            return "Usunąć notatkę „\(note.title)”?"
        }
        return ""
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            // Breadcrumbs
            HStack(spacing: 4) {
                Button {
                    onOpenFolder(nil)
                } label: {
                    Text("Wszystkie notatki")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(folderID == nil ? Theme.navy : Theme.textSecondary)
                }
                ForEach(path) { folder in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.border)
                    Button {
                        onOpenFolder(folder.id)
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(hexString: folder.colorHex))
                                .frame(width: 9, height: 9)
                            Text(folder.name)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(folder.id == folderID ? Theme.navy : Theme.textSecondary)
                        }
                    }
                }
            }
            .lineLimit(1)

            Spacer()

            // Advanced export: the whole current folder (with subfolders),
            // or every loose note at the root level.
            Button {
                exportCurrentScope()
            } label: {
                Label("Eksportuj PDF", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.navy)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.card))
                    .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
            }

            Button {
                addFolder()
            } label: {
                Label("Nowy folder", systemImage: "folder.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.navy)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.card))
                    .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
            }

            Button {
                onCreateNote(currentFolder)
            } label: {
                Label("Nowa notatka", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.card)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.navy))
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        HStack(spacing: 10) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .kerning(1.2)
                .foregroundStyle(Theme.textSecondary)
            // Short engraved meander after the label.
            MeanderRule(color: Theme.navy.opacity(0.16))
                .frame(width: 72, height: 8)
        }
    }

    private var emptyState: some View {
        Button {
            onCreateNote(currentFolder)
        } label: {
            VStack(spacing: 22) {
                // Stars hang from the card's top edge, one blushing pink.
                HangingStars(
                    strands: HangingStars.five,
                    color: Theme.navy.opacity(0.72),
                    accentIndex: 3,
                    accentColor: Theme.pink
                )
                .frame(width: 230, height: 100)
                Text("Pusto tutaj — utwórz pierwszą notatkę")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.bottom, 44)
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Theme.navySoft.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Cards

    private func folderCard(_ folder: Folder) -> some View {
        let noteCount = folder.notes.filter { $0.kind == .note }.count
        return Button {
            onOpenFolder(folder.id)
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hexString: folder.colorHex))
                    .frame(width: 42, height: 42)
                    .overlay(
                        Image(systemName: "folder.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.card)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        DepthGlyph(depth: path.count, color: Color(hexString: folder.colorHex))
                        Text(folder.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.navy)
                            .lineLimit(1)
                    }
                    Text("\(noteCount) not. • \(folder.children.count) fold.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .draggable("folder:\(folder.id.uuidString)")
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items, into: folder)
        }
        .contextMenu {
            Button {
                renameText = folder.name
                renamingFolder = folder
            } label: {
                Label("Zmień nazwę", systemImage: "pencil")
            }
            Menu {
                ForEach(Theme.folderColorsNamed, id: \.hex) { item in
                    Button {
                        folder.colorHex = item.hex
                        try? context.save()
                    } label: {
                        Label {
                            Text(item.name)
                        } icon: {
                            Image(uiImage: UIColor.circle(color: UIColor(hexString: item.hex), selected: item.hex == folder.colorHex))
                        }
                    }
                }
            } label: {
                Label("Kolor", systemImage: "paintpalette")
            }
            Button {
                let notes = NoteExporter.notesInSubtree(of: folder)
                exportURL = NoteExporter.exportPDF(notes: notes, title: folder.name)
            } label: {
                Label("Eksportuj folder (PDF)", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                deletingFolder = folder
            } label: {
                Label("Usuń", systemImage: "trash")
            }
        }
    }

    private func noteCard(_ note: Note) -> some View {
        Button {
            onOpenNote(note)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if note.isEmpty {
                        Color.clear
                    } else {
                        NoteThumbnailView(note: note, fit: note.layout == .infinite ? .content : .topThird)
                    }
                }
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .background(Theme.card)
                .clipped()

                Divider().overlay(Theme.border)

                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.waveBlue)
                .clipped()
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .draggable("note:\(note.id.uuidString)")
        .contextMenu {
            Button {
                renameText = note.title
                renamingNote = note
            } label: {
                Label("Zmień nazwę", systemImage: "pencil")
            }
            Button {
                exportURL = NoteExporter.exportPDF(notes: [note], title: note.title)
            } label: {
                Label("Eksportuj PDF", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                deletingNote = note
            } label: {
                Label("Usuń", systemImage: "trash")
            }
        }
    }

    // MARK: Actions

    private func exportCurrentScope() {
        if let folder = currentFolder {
            let notes = NoteExporter.notesInSubtree(of: folder)
            exportURL = NoteExporter.exportPDF(notes: notes, title: folder.name)
        } else {
            let notes = allNotes.filter { $0.kind == .note }
            exportURL = NoteExporter.exportPDF(notes: notes, title: "Wszystkie notatki")
        }
    }

    private func addFolder() {
        let color = Theme.folderColors[allFolders.count % Theme.folderColors.count]
        let folder = Folder(name: "Nowy folder", colorHex: color, parent: currentFolder, order: allFolders.count)
        context.insert(folder)
        try? context.save()
        renameText = folder.name
        renamingFolder = folder
    }

    private func handleDrop(_ items: [String], into target: Folder) -> Bool {
        guard let item = items.first else { return false }
        // Notes arrive from grid cards ("note:") or from the tabs bar ("tab:").
        for prefix in ["note:", "tab:"] where item.hasPrefix(prefix) {
            guard let id = UUID(uuidString: String(item.dropFirst(prefix.count))) else { continue }
            if let note = allNotes.first(where: { $0.id == id }) {
                note.folder = target
                note.updatedAt = .now
                try? context.save()
                return true
            }
        }
        if item.hasPrefix("folder:"), let id = UUID(uuidString: String(item.dropFirst(7))) {
            guard let dragged = allFolders.first(where: { $0.id == id }), dragged.id != target.id else { return false }
            var cursor: Folder? = target
            while let current = cursor {
                if current.id == dragged.id { return false }
                cursor = current.parent
            }
            dragged.parent = target
            try? context.save()
            return true
        }
        return false
    }
}
