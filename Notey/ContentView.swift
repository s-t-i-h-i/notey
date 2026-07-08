import SwiftUI
import SwiftData
import PencilKit

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query private var allNotes: [Note]

    @State private var route: Route = .allNotes
    @State private var activeNoteID: UUID?
    @State private var openTabIDs: [UUID] = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var renamingNote: Note?
    @State private var renameText = ""
    @State private var restoredTabs = false
    // Floating quick notes: up to QuickSlot.maxOpen cards / edge tabs.
    @State private var quickSlots: [QuickSlot] = []
    @State private var quickDrags: [UUID: CGSize] = [:]
    @State private var draggingQuickID: UUID?
    // Shared with the open canvas so quick notes can paste into it.
    @StateObject private var canvasProxy = CanvasProxy()
    // Freshly created note whose menu should open automatically.
    @State private var autoOpenSettingsID: UUID?
    // Visual offset for the quick note handle when dragging it.
    @State private var handleDragOffset: CGFloat = 0

    @AppStorage("notey.openTabs") private var persistedTabs = ""
    @AppStorage("notey.quick.slots") private var quickSlotsRaw = ""

    private var openTabs: [Note] {
        openTabIDs.compactMap { id in allNotes.first { $0.id == id } }
    }

    private var activeNote: Note? {
        activeNoteID.flatMap { id in allNotes.first { $0.id == id } }
    }

    private var sidebarHidden: Bool {
        columnVisibility == .detailOnly
    }

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(route: $route) {
                    activeNoteID = nil
                }
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
                .toolbar(.hidden, for: .navigationBar)
            } detail: {
                VStack(spacing: 0) {
                    TabsBarView(
                        tabs: openTabs,
                        activeID: activeNoteID,
                        sidebarHidden: sidebarHidden,
                        onToggleSidebar: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                                columnVisibility = sidebarHidden ? .all : .detailOnly
                            }
                        },
                        onSelect: { id in activeNoteID = id },
                        onClose: closeTab,
                        onNew: newNote,
                        onReorder: reorderTab,
                        onRename: { note in
                            renameText = note.title
                            renamingNote = note
                        },
                        onMoveToFolder: moveNote,
                        onPasteQuick: pasteQuick
                    )
                    Divider().overlay(Theme.border)

                    if let note = activeNote {
                        CanvasEditorView(
                            note: note,
                            autoOpenSettingsID: $autoOpenSettingsID,
                            externalProxy: canvasProxy
                        )
                        .id(note.id)
                    } else {
                        switch route {
                        case .calendar:
                            CalendarScreen()
                        case .quickNotes:
                            QuickNotesScreen(
                                openIDs: quickSlots.map(\.id),
                                onOpenFloating: openFloatingQuickNote,
                                onNew: addQuickNote
                            )
                        case .allNotes:
                            FolderGridView(
                                folderID: nil,
                                onOpenFolder: { id in route = id.map { .folder($0) } ?? .allNotes },
                                onOpenNote: openNote,
                                onCreateNote: { folder in createNote(in: folder) }
                            )
                        case .folder(let id):
                            FolderGridView(
                                folderID: id,
                                onOpenFolder: { newID in route = newID.map { .folder($0) } ?? .allNotes },
                                onOpenNote: openNote,
                                onCreateNote: { folder in createNote(in: folder) }
                            )
                        }
                    }
                }
                .background(Theme.bg)
                .toolbar(.hidden, for: .navigationBar)
            }
            .navigationSplitViewStyle(.balanced)

            quickNoteLayer
        }
        .onAppear(perform: restoreTabs)
        .onChange(of: openTabIDs) { _, ids in
            persistedTabs = ids.map(\.uuidString).joined(separator: ",")
        }
        .onChange(of: quickSlots) { _, slots in
            quickSlotsRaw = QuickSlot.encode(slots)
        }
        .alert("Zmień nazwę notatki", isPresented: Binding(
            get: { renamingNote != nil },
            set: { if !$0 { renamingNote = nil } }
        )) {
            TextField("Tytuł", text: $renameText)
            Button("Zapisz") {
                if let note = renamingNote {
                    let title = renameText.trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty {
                        note.title = title
                        note.updatedAt = .now
                        try? context.save()
                    }
                }
                renamingNote = nil
            }
            Button("Anuluj", role: .cancel) { renamingNote = nil }
        }
    }

    // MARK: Quick notes — floating paper cards; each can be thrown to a screen
    // edge, where it collapses into a small tab (swipe inward to reopen).

    @ViewBuilder
    private var quickNoteLayer: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(quickSlots.enumerated()), id: \.element.id) { index, slot in
                    if let note = allNotes.first(where: { $0.id == slot.id }) {
                        if slot.docked {
                            dockedTab(slot, in: geo.size)
                        } else {
                            floatingCard(slot, note: note, stackIndex: index, in: geo.size)
                        }
                    }
                }

                if quickSlots.count < QuickSlot.maxOpen {
                    quickNoteHandle
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: quickSlots)
    }

    private func floatingCard(_ slot: QuickSlot, note: Note, stackIndex: Int, in size: CGSize) -> some View {
        // Cards sharing an anchor cascade slightly so all stay grabbable.
        let base = slot.anchor.center(in: size, cardSize: QuickNoteCard.size)
        let cascade = CGFloat(stackIndex) * 16
        let drag = quickDrags[slot.id] ?? .zero
        return QuickNoteCard(
            note: note,
            isPinned: slot.pinned,
            onTogglePin: { togglePin(slot.id) },
            onClose: { closeQuickSlot(slot.id) },
            onDragChanged: {
                quickDrags[slot.id] = $0
                draggingQuickID = slot.id
            },
            onDragEnded: { translation in
                draggingQuickID = nil
                let center = CGPoint(
                    x: base.x + cascade + translation.width,
                    y: base.y + cascade + translation.height
                )
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    settleCard(slot.id, at: center, in: size)
                    quickDrags[slot.id] = .zero
                }
            }
        )
        // Pinned cards shrink around their own center, staying in place.
        .scaleEffect(slot.pinned ? QuickNoteCard.pinnedScale : 1, anchor: .center)
        .position(x: base.x + cascade + drag.width, y: base.y + cascade + drag.height)
        .zIndex(draggingQuickID == slot.id ? 10 : Double(stackIndex))
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    /// Thrown past a side edge → dock as a small tab there; otherwise snap to
    /// the nearest anchor.
    private func settleCard(_ id: UUID, at center: CGPoint, in size: CGSize) {
        guard let index = quickSlots.firstIndex(where: { $0.id == id }) else { return }
        if center.x > size.width - 60 || center.x < 60 {
            quickSlots[index].docked = true
            quickSlots[index].dockTrailing = center.x > size.width / 2
            quickSlots[index].dockFraction = min(0.9, max(0.08, center.y / max(1, size.height)))
        } else {
            quickSlots[index].anchor = QuickNoteAnchor.nearest(
                to: center, in: size, cardSize: QuickNoteCard.size
            )
        }
    }

    // Pushpin tapped: shrink & pin in place, or restore. Persists via the
    // quickSlots → AppStorage onChange, so it survives app restarts.
    private func togglePin(_ id: UUID) {
        guard let index = quickSlots.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            quickSlots[index].pinned.toggle()
        }
    }

    // Small edge tab of a docked quick note: tap or swipe inward to reopen.
    private func dockedTab(_ slot: QuickSlot, in size: CGSize) -> some View {
        let trailing = slot.dockTrailing
        return Image(systemName: "note.text")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 64)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: trailing ? 10 : 0,
                    bottomLeadingRadius: trailing ? 10 : 0,
                    bottomTrailingRadius: trailing ? 0 : 10,
                    topTrailingRadius: trailing ? 0 : 10
                )
                .fill(Theme.navy.opacity(0.92))
            )
            .shadow(color: Theme.navy.opacity(0.25), radius: 6, x: trailing ? -2 : 2)
            .contentShape(Rectangle())
            .onTapGesture { undock(slot.id, in: size) }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onEnded { value in
                        let inward = trailing ? -value.translation.width : value.translation.width
                        if inward > 24 { undock(slot.id, in: size) }
                    }
            )
            .position(
                x: trailing ? size.width - 13 : 13,
                y: max(50, min(size.height - 50, slot.dockFraction * size.height))
            )
            .transition(.move(edge: trailing ? .trailing : .leading).combined(with: .opacity))
            .accessibilityLabel("Wysuń szybką notatkę")
    }

    private func undock(_ id: UUID, in size: CGSize) {
        guard let index = quickSlots.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            quickSlots[index].docked = false
            // Reappear on the same side the tab was docked.
            let top = quickSlots[index].dockFraction < 0.5
            quickSlots[index].anchor = quickSlots[index].dockTrailing
                ? (top ? .topTrailing : .bottomTrailing)
                : (top ? .topLeading : .bottomLeading)
        }
    }

    private var quickNoteHandle: some View {
        Image(systemName: "square.and.pencil")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 88)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                    .fill(Theme.navy)
            )
            .shadow(color: Theme.navy.opacity(0.3), radius: 6, x: -2)
            .contentShape(Rectangle())
            .offset(x: handleDragOffset)
            .onTapGesture {
                addQuickNote()
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if value.translation.width < 0 {
                            handleDragOffset = value.translation.width * 0.7
                        }
                    }
                    .onEnded { value in
                        if value.translation.width < -30 {
                            addQuickNote()
                        }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            handleDragOffset = 0
                        }
                    }
            )
            .accessibilityLabel("Nowa szybka notatka")
    }

    private func addQuickNote() {
        guard quickSlots.count < QuickSlot.maxOpen else { return }
        let note = NoteStore.newQuickNote(in: context)
        openFloatingQuickNote(note)
    }

    private func openFloatingQuickNote(_ note: Note) {
        guard quickSlots.count < QuickSlot.maxOpen,
              !quickSlots.contains(where: { $0.id == note.id })
        else { return }
        quickSlots.append(QuickSlot(id: note.id))
    }

    /// Closing the card keeps the note in "Szybkie notatki" — unless it is
    /// still empty, then it is discarded.
    private func closeQuickSlot(_ id: UUID) {
        quickSlots.removeAll { $0.id == id }
        if let note = allNotes.first(where: { $0.id == id }),
           note.kind == .quick, note.drawing.strokes.isEmpty {
            context.delete(note)
            try? context.save()
        }
    }

    /// Paste a quick note's ink into a target note (drop on its tab). If the
    /// note is open in the editor, paste live through the canvas; otherwise
    /// merge into the stored drawing, below the existing content.
    private func pasteQuick(_ quickID: UUID, into targetID: UUID) {
        guard let quick = allNotes.first(where: { $0.id == quickID }),
              let target = allNotes.first(where: { $0.id == targetID })
        else { return }
        let quickDrawing = quick.drawing
        guard !quickDrawing.strokes.isEmpty else { return }

        if targetID == activeNoteID {
            canvasProxy.pasteDrawing(quickDrawing)
            return
        }

        var union: CGRect = .null
        let targetDrawing = target.drawing
        if !targetDrawing.strokes.isEmpty { union = union.union(targetDrawing.bounds) }
        for image in target.elements.images { union = union.union(image.frame) }
        for annotation in target.elements.annotations { union = union.union(annotation.frame) }
        let origin = union.isNull ? CGPoint(x: 80, y: 80) : CGPoint(x: 80, y: union.maxY + 40)

        let bounds = quickDrawing.bounds
        let moved = quickDrawing.transformed(
            using: CGAffineTransform(translationX: origin.x - bounds.minX, y: origin.y - bounds.minY)
        )
        target.drawing = targetDrawing.appending(moved)
        target.updatedAt = .now
        try? context.save()
    }

    // MARK: Tabs

    private func restoreTabs() {
        guard !restoredTabs else { return }
        restoredTabs = true
        let ids = persistedTabs.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        openTabIDs = ids.filter { id in allNotes.contains { $0.id == id } }
        // Floating quick notes survive restarts; drop slots of deleted notes.
        quickSlots = QuickSlot.decode(quickSlotsRaw).filter { slot in
            allNotes.contains { $0.id == slot.id }
        }
    }

    private func openNote(_ note: Note) {
        if !openTabIDs.contains(note.id) {
            openTabIDs.append(note.id)
        }
        activeNoteID = note.id
    }

    private func closeTab(_ id: UUID) {
        guard let idx = openTabIDs.firstIndex(of: id) else { return }
        let closedNote = allNotes.first { $0.id == id }
        openTabIDs.remove(at: idx)
        if activeNoteID == id {
            if let neighbor = openTabIDs[safe: min(idx, openTabIDs.count - 1)] {
                activeNoteID = neighbor
            } else {
                activeNoteID = nil
                if let folder = closedNote?.folder {
                    route = .folder(folder.id)
                } else if route == .calendar || route == .quickNotes {
                    // stay where the user was browsing
                } else {
                    route = .allNotes
                }
            }
        }
    }

    private func newNote() {
        createNote(in: nil)
    }

    // Every fresh note opens with its menu (name, layout, background, paper).
    private func createNote(in folder: Folder?) {
        let note = Note(title: "Nowa notatka", folder: folder)
        context.insert(note)
        try? context.save()
        autoOpenSettingsID = note.id
        openNote(note)
    }

    private func reorderTab(_ draggedID: UUID, before targetID: UUID) {
        guard let from = openTabIDs.firstIndex(of: draggedID),
              openTabIDs.contains(targetID)
        else { return }
        openTabIDs.remove(at: from)
        let to = openTabIDs.firstIndex(of: targetID) ?? openTabIDs.endIndex
        openTabIDs.insert(draggedID, at: to)
    }

    private func moveNote(_ noteID: UUID, to folder: Folder?) {
        guard let note = allNotes.first(where: { $0.id == noteID }) else { return }
        guard note.folder?.id != folder?.id else { return }
        note.folder = folder
        note.updatedAt = .now
        try? context.save()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
