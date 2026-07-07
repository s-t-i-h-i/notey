import SwiftUI
import SwiftData

// Note settings page: rename the note, pick the background pattern and a
// custom paper tint. Changes apply live to the open canvas via `config`.
struct NoteSettingsView: View {
    @Bindable var note: Note
    @Binding var config: CanvasToolConfig

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var title = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if note.kind != .calendar {
                        section("NAZWA NOTATKI") {
                            TextField("Tytuł notatki", text: $title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.navy)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Theme.card)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Theme.border, lineWidth: 1)
                                )
                                .onSubmit(commitTitle)
                        }
                    }

                    if note.kind == .note {
                        section("UKŁAD NOTATKI") {
                            HStack(spacing: 10) {
                                layoutCard(
                                    .pages,
                                    icon: "doc.on.doc",
                                    label: "Kartki",
                                    caption: "Strony jak w zeszycie"
                                )
                                layoutCard(
                                    .infinite,
                                    icon: "infinity",
                                    label: "Nieskończony canvas",
                                    caption: "Jedna wielka przestrzeń"
                                )
                            }
                        }
                    }

                    section("WZÓR TŁA") {
                        HStack(spacing: 10) {
                            patternCard(.blank, icon: "circle", label: "Gładkie")
                            patternCard(.dots, icon: "circle.grid.3x3", label: "Kropki")
                            patternCard(.lines, icon: "line.3.horizontal", label: "Linie")
                            patternCard(.grid, icon: "grid", label: "Kratka")
                        }
                    }

                    section("KOLOR KARTKI") {
                        VStack(alignment: .leading, spacing: 14) {
                            let columns = [GridItem(.adaptive(minimum: 44, maximum: 56), spacing: 10)]
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(Theme.paperColors, id: \.self) { hex in
                                    paperSwatch(hex)
                                }
                            }
                            HStack(spacing: 10) {
                                ColorPicker(
                                    "Własny kolor kartki",
                                    selection: Binding(
                                        get: {
                                            Color(hexString: note.paperColorHex ?? Theme.paperColors[0])
                                        },
                                        set: { newColor in
                                            setPaper(UIColor(newColor).hexString)
                                        }
                                    ),
                                    supportsOpacity: false
                                )
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.navySoft)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("Edycja notatki")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gotowe") {
                        commitTitle()
                        dismiss()
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.navy)
                }
            }
        }
        // Full height right away, so the whole content is visible at once.
        .presentationDetents([.large])
        .onAppear { title = note.title }
    }

    // MARK: Sections

    private func section(_ header: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(header)
                .font(.system(size: 10, weight: .heavy))
                .kerning(1.2)
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private func layoutCard(_ layout: NoteLayout, icon: String, label: String, caption: String) -> some View {
        let active = note.layout == layout
        return Button {
            note.layout = layout
            config.layout = layout
            save()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .bold))
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(active ? Theme.navy : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(active ? Theme.bgDeep : Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(active ? Theme.navy : Theme.border, lineWidth: active ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func patternCard(_ bg: CanvasBackground, icon: String, label: String) -> some View {
        let active = note.background == bg
        return Button {
            note.background = bg
            config.background = bg
            save()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(active ? Theme.navy : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(active ? Theme.bgDeep : Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(active ? Theme.navy : Theme.border, lineWidth: active ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func paperSwatch(_ hex: String) -> some View {
        let current = (note.paperColorHex ?? Theme.paperColors[0]).uppercased()
        let active = current == hex.uppercased()
        return Button {
            setPaper(hex)
        } label: {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(hexString: hex))
                .frame(height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(active ? Theme.navy : Theme.border, lineWidth: active ? 2 : 1)
                )
                .overlay {
                    if active {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.navy)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: Mutations

    private func setPaper(_ hex: String) {
        let normalized = hex.uppercased()
        // The default cream is stored as nil so old notes stay untouched.
        note.paperColorHex = normalized == Theme.paperColors[0].uppercased() ? nil : normalized
        config.paperColorHex = note.paperColorHex
        save()
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != note.title {
            note.title = trimmed
            save()
        }
    }

    private func save() {
        note.updatedAt = .now
        try? context.save()
    }
}
