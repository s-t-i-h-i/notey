import SwiftUI
import SwiftData

enum Route: Hashable {
    case calendar
    case allNotes
    case quickNotes
    case folder(UUID)
}

// Beige sidebar: calendar entry, "all notes", and the folder tree with
// colors, subfolders, context menus and drag & drop targets.
struct SidebarView: View {
    @Binding var route: Route
    let onSelect: () -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Folder.order), SortDescriptor(\Folder.name)])
    private var folders: [Folder]
    @Query private var notes: [Note]

    @State private var expanded: Set<UUID> = []
    @State private var renamingFolder: Folder?
    @State private var renameText = ""
    @State private var deletingFolder: Folder?
    @State private var exportURL: URL?

    private var rootFolders: [Folder] {
        folders.filter { $0.parent == nil }
    }

    private var looseNotesCount: Int {
        notes.filter { $0.kind == .note && $0.folder == nil }.count
    }

    private var quickNotesCount: Int {
        notes.filter { $0.kind == .quick }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                // The pink dot is one of the few pink accents in the app.
                HStack(alignment: .top, spacing: 8) {
                    (Text("notey").foregroundColor(Theme.navy)
                        + Text(".").foregroundColor(Theme.pink))
                        .font(.system(size: 22, weight: .heavy))
                        .padding(.top, 10)
                    Spacer()
                    // Stars on threads, hanging from the top edge.
                    HangingStars(strands: HangingStars.three, color: Theme.navy.opacity(0.72))
                        .frame(width: 72, height: 44)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

                navRow(
                    icon: "calendar",
                    label: "Kalendarz",
                    active: route == .calendar
                ) {
                    route = .calendar
                    onSelect()
                }

                navRow(
                    icon: "tray.full",
                    label: "Wszystkie notatki",
                    count: looseNotesCount,
                    active: route == .allNotes
                ) {
                    route = .allNotes
                    onSelect()
                }
                .dropDestination(for: String.self) { items, _ in
                    handleDrop(items, into: nil)
                }

                navRow(
                    icon: "bolt.square",
                    label: "Szybkie notatki",
                    count: quickNotesCount,
                    active: route == .quickNotes
                ) {
                    route = .quickNotes
                    onSelect()
                }

                HStack(spacing: 10) {
                    Text("FOLDERY")
                        .font(.system(size: 10, weight: .heavy))
                        .kerning(1.2)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    // Expand / collapse the whole tree.
                    Button {
                        expanded = Set(folders.filter { !$0.children.isEmpty }.map(\.id))
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.navySoft)
                    }
                    .accessibilityLabel("Rozwiń wszystkie foldery")
                    Button {
                        expanded.removeAll()
                    } label: {
                        Image(systemName: "chevron.up.circle")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.navySoft)
                    }
                    .accessibilityLabel("Zwiń wszystkie foldery")
                    Button {
                        addFolder(parent: nil)
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.navySoft)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 6)

                if rootFolders.isEmpty {
                    Button {
                        addFolder(parent: nil)
                    } label: {
                        Label("Utwórz pierwszy folder", systemImage: "plus")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            )
                    }
                    .padding(.horizontal, 12)
                }

                ForEach(rootFolders) { folder in
                    folderRows(folder, depth: 0)
                }

                Spacer(minLength: 30)
            }
            .padding(.horizontal, 6)
        }

        // Wave scroll footer — a quiet nod to the Greek waves artwork.
        WaveScroll(color: Theme.navy.opacity(0.18), lineWidth: 1.5)
            .frame(height: 30)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .background(LinenBackground())
        .alert("Zmień nazwę folderu", isPresented: Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )) {
            TextField("Nazwa", text: $renameText)
            Button("Zapisz") {
                if let folder = renamingFolder, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    folder.name = renameText.trimmingCharacters(in: .whitespaces)
                    try? context.save()
                }
                renamingFolder = nil
            }
            Button("Anuluj", role: .cancel) { renamingFolder = nil }
        }
        .sheet(item: $exportURL) { url in
            ShareSheet(items: [url])
        }
        .confirmationDialog(
            "Usunąć folder „\(deletingFolder?.name ?? "")”? Notatki trafią do „Wszystkie notatki”.",
            isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
            titleVisibility: .visible
        ) {
            Button("Usuń folder", role: .destructive) {
                if let folder = deletingFolder {
                    if case .folder(let id) = route, id == folder.id { route = .allNotes }
                    context.delete(folder)
                    try? context.save()
                }
                deletingFolder = nil
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func folderRows(_ folder: Folder, depth: Int) -> AnyView {
        AnyView(
            VStack(spacing: 2) {
                folderRow(folder, depth: depth)
                if expanded.contains(folder.id) {
                    ForEach(folder.children.sorted { ($0.order, $0.name) < ($1.order, $1.name) }) { child in
                        folderRows(child, depth: depth + 1)
                    }
                }
            }
        )
    }

    private func folderRow(_ folder: Folder, depth: Int) -> some View {
        let isActive = route == .folder(folder.id)
        let noteCount = folder.notes.filter { $0.kind == .note }.count

        return HStack(spacing: 6) {
            Button {
                if expanded.contains(folder.id) { expanded.remove(folder.id) } else { expanded.insert(folder.id) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .rotationEffect(.degrees(expanded.contains(folder.id) ? 90 : 0))
                    .frame(width: 16, height: 16)
                    .opacity(folder.children.isEmpty ? 0 : 1)
            }
            .buttonStyle(.plain)

            // Depth marker: star → circle → dot → small dot.
            DepthGlyph(depth: depth, color: Color(hexString: folder.colorHex))
                .frame(width: 15)

            Text(folder.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Theme.navy : Theme.navySoft)
                .lineLimit(1)

            Spacer()

            if noteCount > 0 {
                Text("\(noteCount)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 7)
        .padding(.leading, 8 + CGFloat(depth) * 16)
        .padding(.trailing, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Theme.bgDeep : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            route = .folder(folder.id)
            onSelect()
        }
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
            Button {
                addFolder(parent: folder)
            } label: {
                Label("Dodaj podfolder", systemImage: "folder.badge.plus")
            }
            Menu {
                ForEach(Theme.folderColors, id: \.self) { hex in
                    Button {
                        folder.colorHex = hex
                        try? context.save()
                    } label: {
                        Label(hex == folder.colorHex ? "Wybrany" : "Kolor", systemImage: "circle.fill")
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
                Label("Usuń folder", systemImage: "trash")
            }
        }
    }

    private func navRow(
        icon: String,
        label: String,
        count: Int? = nil,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.navy)
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.navy)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? Theme.bgDeep : .clear))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    // MARK: Actions

    private func addFolder(parent: Folder?) {
        let color = Theme.folderColors[folders.count % Theme.folderColors.count]
        let folder = Folder(name: "Nowy folder", colorHex: color, parent: parent, order: folders.count)
        context.insert(folder)
        try? context.save()
        if let parent { expanded.insert(parent.id) }
        renameText = folder.name
        renamingFolder = folder
    }

    // MARK: Drop handling

    private func handleDrop(_ items: [String], into target: Folder?) -> Bool {
        guard let item = items.first else { return false }
        // Notes arrive from grid cards ("note:") or from the tabs bar ("tab:").
        for prefix in ["note:", "tab:"] where item.hasPrefix(prefix) {
            guard let id = UUID(uuidString: String(item.dropFirst(prefix.count))) else { continue }
            if let note = notes.first(where: { $0.id == id }) {
                note.folder = target
                note.updatedAt = .now
                try? context.save()
                return true
            }
        }
        if item.hasPrefix("folder:"), let id = UUID(uuidString: String(item.dropFirst(7))) {
            guard let dragged = folders.first(where: { $0.id == id }) else { return false }
            // No cycles: a folder cannot move into itself or its own subtree.
            var cursor = target
            while let current = cursor {
                if current.id == dragged.id { return false }
                cursor = current.parent
            }
            dragged.parent = target
            try? context.save()
            if let target { expanded.insert(target.id) }
            return true
        }
        return false
    }
}

// MARK: - Folder depth marker: star → circle → dot → small dot

struct DepthGlyph: View {
    let depth: Int
    let color: Color

    var body: some View {
        switch depth {
        case 0:
            Image(systemName: "star.fill")
                .font(.system(size: 11))
                .foregroundStyle(color)
        case 1:
            Image(systemName: "circle")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
        case 2:
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        default:
            Circle()
                .fill(color)
                .frame(width: 4.5, height: 4.5)
        }
    }
}
