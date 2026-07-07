import SwiftUI
import SwiftData

@main
struct NoteyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // The beige/navy design is a light theme; ink colors stay WYSIWYG.
                .preferredColorScheme(.light)
                .tint(Theme.navy)
        }
        .modelContainer(for: [Folder.self, Note.self])
    }
}

// MARK: - Store helpers

enum NoteStore {
    /// One calendar note per day — fetch or create.
    @discardableResult
    static func calendarNote(for dateKey: String, in context: ModelContext) -> Note {
        let predicate = #Predicate<Note> { $0.dateKey == dateKey }
        if let existing = try? context.fetch(FetchDescriptor(predicate: predicate)).first {
            return existing
        }
        let note = Note(title: dateKey, kind: .calendar, dateKey: dateKey)
        context.insert(note)
        try? context.save()
        return note
    }

    /// A fresh scratch card for the floating quick-note system (up to
    /// QuickSlot.maxOpen cards float at once; all stay in "Szybkie notatki").
    static func newQuickNote(in context: ModelContext) -> Note {
        let note = Note(title: "Szybka notatka", kind: .quick)
        context.insert(note)
        try? context.save()
        return note
    }

    static func calendarNotesByKey(in context: ModelContext) -> [String: Note] {
        let calendarRaw = NoteKind.calendar.rawValue
        let predicate = #Predicate<Note> { $0.kindRaw == calendarRaw }
        let notes = (try? context.fetch(FetchDescriptor(predicate: predicate))) ?? []
        var map: [String: Note] = [:]
        for n in notes {
            if let key = n.dateKey { map[key] = n }
        }
        return map
    }
}
