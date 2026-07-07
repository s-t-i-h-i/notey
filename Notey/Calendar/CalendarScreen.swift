import SwiftUI
import SwiftData
import PencilKit

enum CalendarMode: String, CaseIterable, Identifiable {
    case day = "Dzień"
    case month = "Miesiąc"
    case year = "Rok"
    var id: String { rawValue }
}

private struct DayKey: Identifiable {
    let key: String
    var id: String { key }
}

// The calendar is one big handwritten note: every day is a canvas you can
// write on directly — month and week tiles are live.
struct CalendarScreen: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Note> { $0.kindRaw == "calendar" })
    private var calendarNotes: [Note]

    @State private var mode: CalendarMode = .month
    @State private var date: Date = .now
    @State private var expandedDay: DayKey?
    // Bumped when the enlarged day editor closes, so the live month/week
    // tiles reload the freshly saved ink (they capture the drawing once).
    @State private var tileRefresh = 0
    // Shared ink config for month/week tiles. Finger scrolls, Pencil writes
    // (toggleable) so the big scrolling grid stays navigable.
    @State private var inkConfig = CanvasToolConfig(
        tool: .pen,
        penWidth: 3,
        fingerDraws: false,
        background: .blank
    )

    private var notesByKey: [String: Note] {
        var map: [String: Note] = [:]
        for n in calendarNotes {
            if let key = n.dateKey { map[key] = n }
        }
        return map
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)

            switch mode {
            case .month:
                MonthGridView(
                    date: date,
                    notesByKey: notesByKey,
                    config: $inkConfig
                ) { key in
                    NoteStore.calendarNote(for: key, in: context)
                    expandedDay = DayKey(key: key)
                }
                .id(tileRefresh)
            case .day:
                DayView(dateKey: DateUtils.dateKey(date))
            case .year:
                YearView(date: date, notesByKey: notesByKey) { newMode, newDate in
                    mode = newMode
                    date = newDate
                }
            }
        }
        .background(Theme.bg)
        .fullScreenCover(item: $expandedDay, onDismiss: { tileRefresh += 1 }) { day in
            DayEditorModal(dateKey: day.key)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { navigate(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(Theme.navySoft)
            }
            Button { navigate(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(Theme.navySoft)
            }
            Button {
                date = .now
            } label: {
                Text("Dzisiaj")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.navy)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.bgDeep))
            }

            Text(title)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Theme.navy)
                .padding(.leading, 4)

            Spacer()

            Picker("Widok", selection: $mode) {
                ForEach(CalendarMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.card)
    }

    private var title: String {
        switch mode {
        case .day: return DateUtils.dayTitle(date)
        case .month: return DateUtils.monthTitle(date)
        case .year: return String(DateUtils.year(date))
        }
    }

    private func navigate(_ dir: Int) {
        switch mode {
        case .day: date = DateUtils.addDays(date, dir)
        case .month: date = DateUtils.addMonths(date, dir)
        case .year: date = DateUtils.addYears(date, dir)
        }
    }
}

// MARK: - Shared ink tool row for live month/week tiles

private struct CalendarToolRow: View {
    @Binding var config: CanvasToolConfig

    var body: some View {
        HStack(spacing: 10) {
            ForEach(
                [(EditorTool.pen, "pencil.tip"), (.marker, "highlighter"), (.eraser, "eraser")],
                id: \.0
            ) { tool, icon in
                Button {
                    config.tool = tool
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(config.tool == tool ? Theme.pink : Theme.navySoft)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(config.tool == tool ? Theme.pinkSoft : .clear)
                        )
                }
            }
            Divider().frame(height: 20)
            ForEach(Array(Theme.inkColors.enumerated()), id: \.offset) { _, color in
                Button {
                    config.penColor = color
                    config.markerColor = color.withAlphaComponent(1)
                } label: {
                    Circle()
                        .fill(Color(uiColor: color))
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle().stroke(
                                config.penColor == color ? Theme.navy : Theme.border,
                                lineWidth: config.penColor == color ? 2 : 1
                            )
                        )
                }
            }
            Divider().frame(height: 20)
            Button {
                config.fingerDraws.toggle()
            } label: {
                Image(systemName: config.fingerDraws ? "hand.draw" : "applepencil.tip")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(Theme.navySoft)
            }
            .help(config.fingerDraws ? "Rysuje palec i Pencil" : "Rysuje tylko Pencil")

            Spacer()
            Text(config.fingerDraws
                 ? "Palec pisze — wyłącz, aby przewijać palcem"
                 : "Pisz bezpośrednio po dniach (Pencil)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
    }
}

// MARK: - Live day canvas (creates the day note lazily on first ink)

private struct CalendarDayCanvas: View {
    let dateKey: String
    let note: Note?
    var config: CanvasToolConfig

    @Environment(\.modelContext) private var context
    @StateObject private var proxy = CanvasProxy()
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        DrawingCanvas(
            initialDrawing: note?.drawing ?? PKDrawing(),
            initialElements: note?.elements ?? CanvasElements(),
            config: config,
            compact: true,
            proxy: proxy,
            onChange: { drawing, elements in
                saveTask?.cancel()
                let drawingData = drawing.dataRepresentation()
                let elementsData = (try? JSONEncoder().encode(elements)) ?? Data()
                saveTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard !Task.isCancelled else { return }
                    let target = note ?? NoteStore.calendarNote(for: dateKey, in: context)
                    target.drawingData = drawingData
                    target.elementsData = elementsData
                    target.updatedAt = .now
                    try? context.save()
                }
            },
            onSelection: { _ in }
        )
        .id(dateKey)
    }
}

// MARK: - Month: big live tiles — write without opening the day

private struct MonthGridView: View {
    let date: Date
    let notesByKey: [String: Note]
    @Binding var config: CanvasToolConfig
    let onExpand: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            let days = DateUtils.monthGrid(for: date)
            // Generous tiles: at least 230pt wide and ~3 rows on screen; the
            // grid scrolls in both directions when it outgrows the window.
            let tileWidth = max(230, (geo.size.width - 24 - 6 * 8) / 7)
            let gridWidth = tileWidth * 7 + 6 * 8
            let tileHeight = max(186, (geo.size.height - 130) / 3.3)
            let columns = Array(repeating: GridItem(.fixed(tileWidth), spacing: 8), count: 7)

            VStack(spacing: 0) {
                CalendarToolRow(config: $config)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(DateUtils.weekdays, id: \.self) { w in
                                Text(w.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: tileWidth)
                            }
                        }
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(days, id: \.self) { day in
                                MonthDayTile(
                                    day: day,
                                    inMonth: DateUtils.month(day) == DateUtils.month(date),
                                    note: notesByKey[DateUtils.dateKey(day)],
                                    config: config,
                                    height: tileHeight,
                                    onExpand: { onExpand(DateUtils.dateKey(day)) }
                                )
                            }
                        }
                    }
                    .frame(width: gridWidth)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
        }
    }
}

private struct MonthDayTile: View {
    let day: Date
    let inMonth: Bool
    let note: Note?
    let config: CanvasToolConfig
    let height: CGFloat
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onExpand) {
                HStack {
                    Text("\(DateUtils.day(day))")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(
                            DateUtils.isToday(day)
                                ? Theme.card
                                : (inMonth ? Theme.navy : Theme.textSecondary.opacity(0.5))
                        )
                        .frame(minWidth: 22, minHeight: 22)
                        .background(
                            // The delicate pink accent: today only.
                            Circle().fill(DateUtils.isToday(day) ? Theme.pink : .clear)
                        )
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.border)

            CalendarDayCanvas(
                dateKey: DateUtils.dateKey(day),
                note: note,
                config: config
            )
            .opacity(inMonth ? 1 : 0.55)
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(inMonth ? Theme.card : Theme.bgDeep.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(DateUtils.isToday(day) ? Theme.pink.opacity(0.7) : Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Day

private struct DayView: View {
    let dateKey: String
    @Environment(\.modelContext) private var context
    @State private var note: Note?

    var body: some View {
        Group {
            if let note {
                CanvasEditorView(note: note)
                    .id(note.id)
            } else {
                Theme.bg
            }
        }
        .onAppear { note = NoteStore.calendarNote(for: dateKey, in: context) }
        .onChange(of: dateKey) { _, newKey in
            note = NoteStore.calendarNote(for: newKey, in: context)
        }
    }
}

// MARK: - Day modal (enlarged tile)

private struct DayEditorModal: View {
    let dateKey: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var note: Note?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(DateUtils.dayTitle(DateUtils.date(fromKey: dateKey)))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.navy)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(Theme.navySoft)
                        .background(Circle().fill(Theme.bgDeep))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.card)

            Divider().overlay(Theme.border)

            if let note {
                CanvasEditorView(note: note)
                    .id(note.id)
            } else {
                Theme.bg
            }
        }
        .background(Theme.bg)
        .onAppear { note = NoteStore.calendarNote(for: dateKey, in: context) }
    }
}

// MARK: - Year: 12 compact months, days with ink get a navy tint

private struct YearView: View {
    let date: Date
    let notesByKey: [String: Note]
    let onNavigate: (CalendarMode, Date) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(1...12, id: \.self) { month in
                    miniMonth(month)
                }
            }
            .padding(14)
        }
    }

    private func miniMonth(_ month: Int) -> some View {
        let first = DateUtils.firstOfMonth(year: DateUtils.year(date), month: month)
        let days = DateUtils.monthGrid(for: first)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                onNavigate(.month, first)
            } label: {
                Text(DateUtils.months[month - 1])
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.navy)
            }
            .buttonStyle(.plain)

            let mini = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: mini, spacing: 2) {
                ForEach(DateUtils.weekdays, id: \.self) { w in
                    Text(String(w.prefix(1)))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                ForEach(days, id: \.self) { day in
                    let inMonth = DateUtils.month(day) == month
                    let hasInk = !(notesByKey[DateUtils.dateKey(day)]?.isEmpty ?? true)
                    Button {
                        onNavigate(.day, day)
                    } label: {
                        Text("\(DateUtils.day(day))")
                            .font(.system(size: 10, weight: hasInk ? .bold : .regular))
                            .foregroundStyle(
                                !inMonth ? .clear
                                    : DateUtils.isToday(day) ? Theme.card
                                    : hasInk ? Theme.card
                                    : Theme.navySoft
                            )
                            .frame(maxWidth: .infinity, minHeight: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 5).fill(
                                    !inMonth ? .clear
                                        : DateUtils.isToday(day) ? Theme.pink
                                        : hasInk ? Theme.navy.opacity(0.75)
                                        : .clear
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!inMonth)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
    }
}
