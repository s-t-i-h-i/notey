import SwiftUI
import SwiftData

// Chrome-style strip of open note tabs. Consecutive tabs sharing a folder form
// a colored "tab group" with the folder-name pill, like Chrome tab groups.
// Tapping the pill collapses/expands the group; tabs can be dragged onto a
// pill to move the note into that folder, or onto the bar background to pull
// it out of its folder.
struct TabsBarView: View {
    let tabs: [Note]
    let activeID: UUID?
    let sidebarHidden: Bool
    let onToggleSidebar: () -> Void
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNew: () -> Void
    let onReorder: (UUID, UUID) -> Void // (dragged, target)
    let onRename: (Note) -> Void
    let onMoveToFolder: (UUID, Folder?) -> Void // (note, target folder / nil = loose)
    let onPasteQuick: (UUID, UUID) -> Void // (quick note, target note)

    @State private var collapsedGroups: Set<UUID> = []

    private struct TabGroup: Identifiable {
        let id = UUID()
        let folder: Folder?
        var notes: [Note]
    }

    private var groups: [TabGroup] {
        var result: [TabGroup] = []
        for note in tabs {
            if var last = result.last, last.folder?.id == note.folder?.id {
                last.notes.append(note)
                result[result.count - 1] = last
            } else {
                result.append(TabGroup(folder: note.folder, notes: [note]))
            }
        }
        return result
    }

    var body: some View {
        HStack(spacing: 0) {
            // Fully hide / bring back the sidebar.
            Button(action: onToggleSidebar) {
                Image(systemName: sidebarHidden ? "sidebar.leading" : "sidebar.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.navySoft)
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .padding(.leading, 6)
            .accessibilityLabel(sidebarHidden ? "Pokaż pasek boczny" : "Ukryj pasek boczny")

            tabsScroller
        }
        // Translucent wash: the watercolor backdrop shows through, the strip
        // only slightly recedes so the cream tabs stay readable.
        .background(
            Theme.navy.opacity(0.06)
                .overlay(
                    Image(uiImage: DecorTexture.linenTile)
                        .resizable(resizingMode: .tile)
                        .opacity(0.3)
                )
                .allowsHitTesting(false)
        )
        // Dropping a tab on the empty bar area pulls the note out of its folder.
        .dropDestination(for: String.self) { items, _ in
            guard let id = draggedNoteID(items) else { return false }
            onMoveToFolder(id, nil)
            return true
        }
    }

    private var tabsScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(groups) { group in
                    if let folder = group.folder {
                        groupPill(folder, count: group.notes.count)
                    }
                    if group.folder.map({ !collapsedGroups.contains($0.id) }) ?? true {
                        ForEach(group.notes) { note in
                            tab(note, groupColor: group.folder.map { Color(hexString: $0.colorHex) })
                        }
                    }
                }

                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.navySoft)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.card))
                        .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                }
                .padding(.leading, 2)

                // Trailing spacer keeps a drop area to pull notes out of folders.
                Color.clear.frame(width: 120, height: 30)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private func draggedNoteID(_ items: [String]) -> UUID? {
        guard let item = items.first else { return nil }
        for prefix in ["tab:", "note:"] where item.hasPrefix(prefix) {
            return UUID(uuidString: String(item.dropFirst(prefix.count)))
        }
        return nil
    }

    // MARK: Folder pill (collapse / expand + drop target)

    private func groupPill(_ folder: Folder, count: Int) -> some View {
        let collapsed = collapsedGroups.contains(folder.id)
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                if collapsed {
                    collapsedGroups.remove(folder.id)
                } else {
                    collapsedGroups.insert(folder.id)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .heavy))
                Text(folder.name)
                    .font(.system(size: 10, weight: .bold))
                    .lineLimit(1)
                if collapsed {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .heavy).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.25)))
                }
            }
            .foregroundStyle(Theme.card)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(hexString: folder.colorHex)))
        }
        .buttonStyle(.plain)
        // Drop a tab (or a note card) here to move the note into this folder.
        .dropDestination(for: String.self) { items, _ in
            guard let id = draggedNoteID(items) else { return false }
            onMoveToFolder(id, folder)
            return true
        }
    }

    // MARK: Single tab

    private func tab(_ note: Note, groupColor: Color?) -> some View {
        let active = note.id == activeID
        return HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.navySoft)
            Text(note.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Theme.navy : Theme.navySoft)
                .lineLimit(1)
                .frame(maxWidth: 130, alignment: .leading)
            Button {
                onClose(note.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(active ? Theme.bgDeep : .clear))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 10,
                bottomLeadingRadius: active ? 0 : 10,
                bottomTrailingRadius: active ? 0 : 10,
                topTrailingRadius: 10
            )
            .fill(active ? Theme.card : Theme.card.opacity(0.55))
        )
        .overlay(alignment: .bottom) {
            if let groupColor {
                groupColor.frame(height: 2.5)
            }
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 10,
                bottomLeadingRadius: active ? 0 : 10,
                bottomTrailingRadius: active ? 0 : 10,
                topTrailingRadius: 10
            )
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect(note.id) }
        .contextMenu {
            Button {
                onRename(note)
            } label: {
                Label("Zmień nazwę", systemImage: "pencil")
            }
            if note.folder != nil {
                Button {
                    onMoveToFolder(note.id, nil)
                } label: {
                    Label("Wyjmij z folderu", systemImage: "tray.and.arrow.up")
                }
            }
            Button(role: .destructive) {
                onClose(note.id)
            } label: {
                Label("Zamknij kartę", systemImage: "xmark")
            }
        }
        .draggable("tab:\(note.id.uuidString)")
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first else { return false }
            // A quick note dropped on a tab pastes its ink into that note.
            if item.hasPrefix("quick:"), let quickID = UUID(uuidString: String(item.dropFirst(6))) {
                onPasteQuick(quickID, note.id)
                return true
            }
            guard let draggedID = draggedNoteID(items), draggedID != note.id else { return false }

            if let targetFolder = note.folder {
                onMoveToFolder(draggedID, targetFolder)
            }
            
            if item.hasPrefix("tab:") {
                onReorder(draggedID, note.id)
            }
            return true
        }
    }
}
