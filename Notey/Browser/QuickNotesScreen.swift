import SwiftUI
import SwiftData

// "Szybkie notatki" tab: every scratch card ever written, newest first.
// Cards can be reopened as floating cards or dragged onto an open note's tab
// to paste their ink into that note.
struct QuickNotesScreen: View {
    let openIDs: [UUID]                 // quick notes currently floating
    let onOpenFloating: (Note) -> Void
    let onNew: () -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Note.updatedAt, order: .reverse)])
    private var allNotes: [Note]

    @State private var deletingNote: Note?

    private var quickNotes: [Note] {
        allNotes.filter { $0.kind == .quick }
    }

    private var canOpenMore: Bool {
        openIDs.count < QuickSlot.maxOpen
    }

    private let cardColumns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerRow

                Text("Przeciągnij kartę na zakładkę otwartej notatki, aby wkleić jej treść.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)

                if quickNotes.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: cardColumns, spacing: 12) {
                        ForEach(quickNotes) { note in
                            quickCard(note)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .confirmationDialog(
            "Usunąć szybką notatkę?",
            isPresented: Binding(get: { deletingNote != nil }, set: { if !$0 { deletingNote = nil } }),
            titleVisibility: .visible
        ) {
            Button("Usuń", role: .destructive) {
                if let note = deletingNote {
                    context.delete(note)
                    try? context.save()
                }
                deletingNote = nil
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Text("Szybkie notatki")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.navy)
            Spacer()
            Button(action: onNew) {
                Label("Nowa szybka notatka", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.card)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.navy))
            }
            .disabled(!canOpenMore)
            .opacity(canOpenMore ? 1 : 0.4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.square")
                .font(.system(size: 28))
            Text("Brak szybkich notatek — dodaj pierwszą czarnym uchwytem przy prawej krawędzi")
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        )
    }

    private func quickCard(_ note: Note) -> some View {
        let isOpen = openIDs.contains(note.id)
        return Button {
            if !isOpen, canOpenMore { onOpenFloating(note) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if note.drawing.strokes.isEmpty {
                        Image(systemName: "scribble.variable")
                            .font(.system(size: 26))
                            .foregroundStyle(Theme.border)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        NoteThumbnailView(note: note, fit: .content)
                    }
                }
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .background(Theme.card)
                .clipped()

                Divider().overlay(Theme.border)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.navy)
                        Text(isOpen ? "Otwarta jako pływająca karta" : "Dotknij, aby otworzyć")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if isOpen {
                        Circle().fill(Theme.pink).frame(width: 7, height: 7)
                    }
                }
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .draggable("quick:\(note.id.uuidString)")
        .contextMenu {
            Button {
                if !isOpen, canOpenMore { onOpenFloating(note) }
            } label: {
                Label("Otwórz jako pływającą kartę", systemImage: "macwindow.on.rectangle")
            }
            .disabled(isOpen || !canOpenMore)
            Button(role: .destructive) {
                deletingNote = note
            } label: {
                Label("Usuń", systemImage: "trash")
            }
        }
    }
}
