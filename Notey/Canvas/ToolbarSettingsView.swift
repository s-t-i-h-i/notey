import SwiftUI
import PencilKit

struct ToolbarSettings: Equatable {
    var showPen: Bool = true
    var showPencil: Bool = true
    var showHighlighter: Bool = true
    var showEraser: Bool = true
    var showLasso: Bool = true
    var showRuler: Bool = true
}


enum ToolbarTool: String, CaseIterable, Identifiable {
    case pen = "Długopis"
    case pencil = "Ołówek"
    case highlighter = "Zakreślacz"
    case eraser = "Gumka"
    case lasso = "Lasso"
    case ruler = "Linijka"

    var id: String { rawValue }
}

struct ToolbarSettingsView: View {
    @AppStorage("toolbar_pen") private var showPen = true
    @AppStorage("toolbar_pencil") private var showPencil = true
    @AppStorage("toolbar_highlighter") private var showHighlighter = true
    @AppStorage("toolbar_eraser") private var showEraser = true
    @AppStorage("toolbar_lasso") private var showLasso = true
    @AppStorage("toolbar_ruler") private var showRuler = true

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Dostępne narzędzia").font(.subheadline)) {
                    Toggle("Długopis", isOn: $showPen)
                    Toggle("Ołówek", isOn: $showPencil)
                    Toggle("Zakreślacz", isOn: $showHighlighter)
                    Toggle("Gumka", isOn: $showEraser)
                    Toggle("Lasso", isOn: $showLasso)
                    Toggle("Linijka", isOn: $showRuler)
                }
            }
            .navigationTitle("Pasek narzędzi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Gotowe") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
