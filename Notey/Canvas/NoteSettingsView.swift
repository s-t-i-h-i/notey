import SwiftUI
import SwiftData
import PhotosUI

// Note settings page: rename the note, pick the layout, page orientation, a
// decorative template, the background pattern and a custom paper tint. Changes
// apply live to the open canvas via `config`.
struct NoteSettingsView: View {
    @Bindable var note: Note
    @Binding var config: CanvasToolConfig
    var isNewNote: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var title = ""
    @State private var templateItem: PhotosPickerItem?

    // Templates and orientation apply to real kartka pages only.
    private var showsPageOptions: Bool {
        note.kind == .note && note.layout == .pages
    }

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

                    if isNewNote && note.kind == .note {
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

                    if showsPageOptions {
                        section("ORIENTACJA KARTKI") {
                            HStack(spacing: 10) {
                                orientationCard(
                                    .portrait,
                                    icon: "rectangle.portrait",
                                    label: "Pionowo"
                                )
                                orientationCard(
                                    .landscape,
                                    icon: "rectangle",
                                    label: "Poziomo"
                                )
                            }
                        }

                        section("SZABLON KARTKI") {
                            templatePicker
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
        .onChange(of: templateItem) { _, item in
            guard let item else { return }
            Task { await loadCustomTemplate(item) }
        }
    }

    // MARK: Template picker

    private var templatePicker: some View {
        VStack(spacing: 10) {
            let builtIn: [(PageTemplate, String)] = [
                (.none, "circle.slash"),
                (.meander, "square.grid.3x3.topleft.filled"),
                (.waves, "water.waves"),
                (.stars, "sparkles"),
            ]
            HStack(spacing: 10) {
                ForEach(builtIn, id: \.0) { template, icon in
                    templateCard(template, icon: icon)
                }
            }
            // Upload / replace a custom template image.
            PhotosPicker(selection: $templateItem, matching: .images) {
                HStack(spacing: 10) {
                    if note.template == .custom, let data = note.templateData,
                       let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 40, height: 40)
                            .foregroundStyle(Theme.navySoft)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(note.template == .custom ? "Zmień własny szablon" : "Prześlij własny szablon")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.navy)
                        Text("Twój obraz jako delikatne tło kartki")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if note.template == .custom {
                        Button {
                            setTemplate(.none)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(note.template == .custom ? Theme.bgDeep : Theme.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(note.template == .custom ? Theme.navy : Theme.border,
                                lineWidth: note.template == .custom ? 1.5 : 1)
                )
            }
            .buttonStyle(.plain)
        }
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

    private func orientationCard(_ orientation: PageOrientation, icon: String, label: String) -> some View {
        let active = note.orientation == orientation
        return Button {
            setOrientation(orientation)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .bold))
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

    // A mini page showing the actual ornament (built-in templates only).
    private func templateCard(_ template: PageTemplate, icon: String) -> some View {
        let active = note.template == template
        return Button {
            setTemplate(template)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(hexString: note.paperColorHex ?? Theme.paperColors[0]))
                    if let preview = PageTemplateRenderer.image(
                        for: template,
                        pageSize: CGSize(width: 200, height: 280),
                        custom: nil
                    ) {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                    } else if template == .none {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .light))
                            .foregroundStyle(Theme.textSecondary.opacity(0.5))
                    }
                }
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.border, lineWidth: 0.5)
                )
                Text(template.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(active ? Theme.navy : Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(8)
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

    private func setOrientation(_ orientation: PageOrientation) {
        note.orientation = orientation
        config.orientation = orientation
        save()
    }

    private func setTemplate(_ template: PageTemplate) {
        note.template = template
        if template != .custom {
            note.templateData = nil
        }
        config.template = template
        save()
    }

    /// Downscale the picked image to page proportions and store it as the
    /// note's custom template.
    private func loadCustomTemplate(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        let maxDim: CGFloat = 1400
        let scale = min(1, maxDim / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        let stored = resized.jpegData(compressionQuality: 0.8) ?? data
        await MainActor.run {
            note.templateData = stored
            note.template = .custom
            config.template = .custom
            templateItem = nil
            save()
        }
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
