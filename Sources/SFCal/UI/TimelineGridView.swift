import SwiftUI

/// Grid de tiempo compartido por las vistas Día y Semana.
struct TimelineGridView: View {
    let days: [Date]

    @Environment(\.sfcalSnapshotHours) private var snapshotHours
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    private let hourHeight: CGFloat = 60
    private let gutter: CGFloat = 56

    @State private var ghost: GhostDraft?

    struct GhostDraft: Equatable {
        var dayIndex: Int
        var startMin: Double
        var endMin: Double
    }

    var body: some View {
        let p = theme.palette
        VStack(spacing: 0) {
            DayHeaderRow(days: days, gutter: gutter)
            AllDayRow(days: days, gutter: gutter)
            Rectangle().fill(p.border).frame(height: 1)
            if let hours = snapshotHours {
                grid(hourLo: hours.lowerBound, hourHi: hours.upperBound)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: true) {
                        grid(hourLo: 0, hourHi: 24)
                    }
                    .onAppear {
                        // Un tick de delay: si se pide antes de que el layout exista, no scrollea
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(80))
                            let target = max(0, Int(DateKit.minutesIntoDay(Date()) / 60) - 2)
                            proxy.scrollTo("hora-\(target)", anchor: .top)
                        }
                    }
                }
            }
        }
        .onChange(of: appState.draft) { _, newValue in
            if newValue == nil { ghost = nil }
        }
    }

    private func grid(hourLo: Double, hourHi: Double) -> some View {
        let totalHeight = CGFloat(hourHi - hourLo) * hourHeight
        return GeometryReader { geo in
            let colWidth = max(40, (geo.size.width - gutter) / CGFloat(days.count))
            ZStack(alignment: .topLeading) {
                // Anchors de scroll con posición de LAYOUT real (offset no mueve el layout,
                // por eso scrollTo sobre las líneas aterrizaba siempre en 00)
                VStack(spacing: 0) {
                    ForEach(Int(hourLo)..<Int(hourHi), id: \.self) { h in
                        Color.clear
                            .frame(height: hourHeight)
                            .id("hora-\(h)")
                    }
                }
                .allowsHitTesting(false)
                backgroundLayer(colWidth: colWidth, hourLo: hourLo, hourHi: hourHi)
                gridLines(colWidth: colWidth, hourLo: hourLo, hourHi: hourHi, width: geo.size.width)
                eventsLayer(colWidth: colWidth, hourLo: hourLo, hourHi: hourHi)
                nowLine(colWidth: colWidth, hourLo: hourLo, hourHi: hourHi, width: geo.size.width)
                ghostLayer(colWidth: colWidth, hourLo: hourLo)
            }
        }
        .frame(height: totalHeight)
    }

    // MARK: - Capas

    private func gridLines(colWidth: CGFloat, hourLo: Double, hourHi: Double, width: CGFloat) -> some View {
        let p = theme.palette
        return ZStack(alignment: .topLeading) {
            ForEach(Int(hourLo)...Int(hourHi), id: \.self) { h in
                let y = (CGFloat(h) - hourLo) * hourHeight
                Rectangle()
                    .fill(p.grid)
                    .frame(width: max(0, width - gutter), height: 1)
                    .offset(x: gutter, y: y)
                if h < Int(hourHi) {
                    Text(String(format: "%02d", h))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(p.textSecondary.opacity(0.75))
                        .frame(width: gutter - 14, alignment: .trailing)
                        .offset(x: 0, y: y - 6.5)
                }
            }
            ForEach(0...days.count, id: \.self) { i in
                Rectangle()
                    .fill(p.grid.opacity(i == 0 ? 1 : 0.8))
                    .frame(width: 1)
                    .offset(x: gutter + CGFloat(i) * colWidth)
            }
            if let todayIdx = days.firstIndex(where: { DateKit.isToday($0) }), days.count > 1 {
                Rectangle()
                    .fill(p.accent.opacity(p.isDark ? 0.045 : 0.05))
                    .frame(width: colWidth)
                    .offset(x: gutter + CGFloat(todayIdx) * colWidth)
            }
        }
        .allowsHitTesting(false)
    }

    private func backgroundLayer(colWidth: CGFloat, hourLo: Double, hourHi: Double) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { v in
                        createDraft(at: v.location, colWidth: colWidth, hourLo: hourLo, durationMin: 60)
                    }
                    .exclusively(before: SpatialTapGesture().onEnded { _ in
                        appState.selectedEventId = nil
                        appState.editingEventId = nil
                    })
            )
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        guard v.startLocation.x >= gutter else { return }
                        let day = clampInt(Int((v.startLocation.x - gutter) / colWidth), 0, days.count - 1)
                        let m0 = snap15((Double(v.startLocation.y) / hourHeight + hourLo) * 60)
                        let m1 = snap15((Double(v.location.y) / hourHeight + hourLo) * 60)
                        ghost = GhostDraft(
                            dayIndex: day,
                            startMin: min(m0, m1),
                            endMin: max(max(m0, m1), min(m0, m1) + 15))
                    }
                    .onEnded { _ in
                        guard let g = ghost, let cal = store.defaultWritableCalendar else { ghost = nil; return }
                        let dayStart = days[g.dayIndex]
                        let start = dayStart.addingTimeInterval(g.startMin * 60)
                        let end = dayStart.addingTimeInterval(g.endMin * 60)
                        appState.draft = DraftEvent(start: start, end: end, calendarId: cal.id)
                    }
            )
    }

    private func eventsLayer(colWidth: CGFloat, hourLo: Double, hourHi: Double) -> some View {
        ForEach(Array(days.enumerated()), id: \.offset) { dayIdx, day in
            let events = store.events(on: day).filter { !$0.isAllDay }
            let timedTasks = store.tasksOn(day).timed
            let dayStart = day
            let dayEnd = DateKit.addDays(day, 1)
            // Tareas con hora entran al MISMO layout de solapamiento que los eventos
            // (span de 30 min): ciudadanas de primera, cero colisiones visuales
            let items = events.map {
                LayoutItem(id: $0.id, start: max($0.start, dayStart), end: min($0.end, dayEnd))
            } + timedTasks.compactMap { t -> LayoutItem? in
                guard let due = t.due else { return nil }
                return LayoutItem(id: "task-\(t.id)", start: due, end: due.addingTimeInterval(1800))
            }
            let positions = OverlapLayout.layout(items)
            ForEach(timedTasks) { task in
                if let due = task.due, let pos = positions["task-\(task.id)"] {
                    let y = (DateKit.minutesIntoDay(due) / 60 - hourLo) * hourHeight
                    let h: CGFloat = 26
                    let subW = (colWidth - 4) / CGFloat(pos.columnCount)
                    let x = gutter + CGFloat(dayIdx) * colWidth + 2 + CGFloat(pos.column) * subW
                    if y + h > 0 && y < (hourHi - hourLo) * hourHeight {
                        TaskBlockView(task: task, width: subW - 2, height: h)
                            .offset(x: x, y: y)
                            .zIndex(40)
                    }
                }
            }
            ForEach(events) { event in
                if let pos = positions[event.id] {
                    let clampedStart = max(event.start, dayStart)
                    let clampedEnd = min(event.end, dayEnd)
                    let startH = DateKit.minutesIntoDay(clampedStart) / 60
                    let durH = max(clampedEnd.timeIntervalSince(clampedStart) / 3600, 1.0 / 3)
                    let y = (startH - hourLo) * hourHeight
                    let h = max(20, durH * hourHeight - 1)
                    let subW = (colWidth - 4) / CGFloat(pos.columnCount)
                    let x = gutter + CGFloat(dayIdx) * colWidth + 2 + CGFloat(pos.column) * subW
                    if y + h > 0 && y < (hourHi - hourLo) * hourHeight {
                        EventBlockView(
                            event: event,
                            colorHex: store.calendar(event.calendarId)?.bgColorHex ?? "#8C27F1",
                            width: subW - 2,
                            baseHeight: h,
                            colWidth: colWidth,
                            hourHeight: hourHeight,
                            dayIndex: dayIdx,
                            dayCount: days.count,
                            onMove: { ev, dayDelta, minDelta in
                                let movedStart = DateKit.cal.date(
                                    byAdding: .minute, value: minDelta,
                                    to: DateKit.addDays(ev.start, dayDelta)) ?? ev.start
                                store.moveEvent(ev, newStart: movedStart,
                                                newEnd: movedStart.addingTimeInterval(ev.duration))
                            },
                            onResize: { ev, minDelta in
                                let newEnd = DateKit.cal.date(byAdding: .minute, value: minDelta, to: ev.end) ?? ev.end
                                let clampedNewEnd = max(ev.start.addingTimeInterval(15 * 60), newEnd)
                                store.moveEvent(ev, newStart: ev.start, newEnd: clampedNewEnd)
                            }
                        )
                        .offset(x: x, y: y)
                    }
                }
            }
        }
    }

    private func nowLine(colWidth: CGFloat, hourLo: Double, hourHi: Double, width: CGFloat) -> some View {
        let p = theme.palette
        return TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let now = ctx.date
            let y = (DateKit.minutesIntoDay(now) / 60 - hourLo) * hourHeight
            if y >= 0, y <= (hourHi - hourLo) * hourHeight {
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(p.gold.opacity(0.28))
                        .frame(width: max(0, width - gutter), height: 1)
                        .offset(x: gutter, y: y)
                    if let todayIdx = days.firstIndex(where: { DateKit.isToday($0) }) {
                        Rectangle()
                            .fill(p.gold)
                            .frame(width: colWidth, height: 2)
                            .offset(x: gutter + CGFloat(todayIdx) * colWidth, y: y - 0.5)
                        Circle()
                            .fill(p.gold)
                            .frame(width: 7, height: 7)
                            .offset(x: gutter + CGFloat(todayIdx) * colWidth - 3.5, y: y - 3)
                    }
                    Text(DateKit.timeShort.string(from: now))
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(p.gold)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 3).fill(p.bg))
                        .frame(width: gutter - 10, alignment: .trailing)
                        .offset(x: 0, y: y - 7)
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func ghostLayer(colWidth: CGFloat, hourLo: Double) -> some View {
        let p = theme.palette
        if let g = ghost {
            let y = (g.startMin / 60 - hourLo) * hourHeight
            let h = max(16, (g.endMin - g.startMin) / 60 * hourHeight)
            RoundedRectangle(cornerRadius: 6)
                .fill(p.accent.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(p.accent, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                .overlay(alignment: .topLeading) {
                    Text("\(minLabel(g.startMin)) – \(minLabel(g.endMin))")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(p.textPrimary)
                        .padding(5)
                }
                .frame(width: colWidth - 6, height: h)
                .offset(x: gutter + CGFloat(g.dayIndex) * colWidth + 2, y: y)
                .allowsHitTesting(false)
                // El editor del draft vive en el overlay central de RootView;
                // aquí solo queda el fantasma visual del rango arrastrado
        }
    }

    // MARK: - Helpers

    private func createDraft(at point: CGPoint, colWidth: CGFloat, hourLo: Double, durationMin: Double) {
        guard point.x >= gutter, let cal = store.defaultWritableCalendar else { return }
        let day = clampInt(Int((point.x - gutter) / colWidth), 0, days.count - 1)
        let startMin = snap15((Double(point.y) / hourHeight + hourLo) * 60)
        ghost = GhostDraft(dayIndex: day, startMin: startMin, endMin: startMin + durationMin)
        let dayStart = days[day]
        appState.draft = DraftEvent(
            start: dayStart.addingTimeInterval(startMin * 60),
            end: dayStart.addingTimeInterval((startMin + durationMin) * 60),
            calendarId: cal.id)
    }

    private func minLabel(_ m: Double) -> String {
        String(format: "%02d:%02d", Int(m) / 60, Int(m) % 60)
    }
}

func snap15(_ minutes: Double) -> Double {
    (minutes / 15).rounded() * 15
}

func clampInt(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
    min(max(v, lo), max(lo, hi))
}

// MARK: - Header de días

struct DayHeaderRow: View {
    let days: [Date]
    let gutter: CGFloat
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        let p = theme.palette
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter)
            ForEach(days, id: \.self) { day in
                let today = DateKit.isToday(day)
                Button(action: {
                    appState.focusDate = day
                    appState.setMode(.day)
                }) {
                    HStack(spacing: 6) {
                        Text(DateKit.weekdayShort.string(from: day).replacingOccurrences(of: ".", with: ""))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(today ? p.textPrimary : p.textMuted)
                        Text(DateKit.dayNum.string(from: day))
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(today ? Color(hex: "#09090b") : p.textSecondary)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(today ? p.gold : .clear))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 42)
    }
}

// MARK: - Fila all-day

struct AllDayRow: View {
    let days: [Date]
    let gutter: CGFloat
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    private let maxPills = 3

    var body: some View {
        let p = theme.palette
        let byDay: [[CalEvent]] = days.map { day in
            store.events(on: day).filter { $0.isAllDay }
        }
        let tasksByDay: [[TodoTask]] = days.map { store.tasksOn($0).allDay }
        if byDay.contains(where: { !$0.isEmpty }) || tasksByDay.contains(where: { !$0.isEmpty }) {
            HStack(alignment: .top, spacing: 0) {
                Text("día")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(p.textMuted)
                    .frame(width: gutter - 14, alignment: .trailing)
                    .padding(.top, 5)
                    .padding(.trailing, 14)
                ForEach(Array(days.enumerated()), id: \.offset) { i, _ in
                    let eventCount = min(byDay[i].count, maxPills)
                    let taskRoom = max(0, maxPills - eventCount)
                    let overflow = (byDay[i].count - eventCount) + max(0, tasksByDay[i].count - taskRoom)
                    VStack(spacing: 2) {
                        ForEach(byDay[i].prefix(maxPills)) { event in
                            allDayPill(event, palette: p)
                        }
                        ForEach(tasksByDay[i].prefix(taskRoom)) { task in
                            TaskPill(task: task)
                        }
                        if overflow > 0 {
                            Text("+\(overflow) más")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(p.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 6)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 2)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func allDayPill(_ event: CalEvent, palette p: Palette) -> some View {
        let hex = store.calendar(event.calendarId)?.bgColorHex ?? "#8C27F1"
        let color = Color.fromCalendarHex(hex)
        let selected = appState.selectedEventId == event.id
        return Button(action: {
            appState.selectedEventId = event.id
            appState.editingEventId = event.id
        }) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(event.summary)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.eventTitle(hex: hex, dark: p.isDark))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(color.opacity(p.isDark ? 0.22 : 0.16))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(selected ? p.accent : .clear, lineWidth: 1.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(event.pending ? 0.55 : 1)
        .popover(isPresented: editingBinding(event.id), arrowEdge: .bottom) {
            EventEditorView(mode: .edit(event))
        }
    }

    private func editingBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { appState.editingEventId == id },
                set: { if !$0 { appState.editingEventId = nil } })
    }
}

// MARK: - Bloque de evento

struct EventBlockView: View {
    let event: CalEvent
    let colorHex: String
    let width: CGFloat
    let baseHeight: CGFloat
    let colWidth: CGFloat
    let hourHeight: CGFloat
    let dayIndex: Int
    let dayCount: Int
    let onMove: (CalEvent, Int, Int) -> Void
    let onResize: (CalEvent, Int) -> Void

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    @State private var dragTranslation: CGSize = .zero
    @State private var isDragging = false
    @State private var resizeTranslation: CGFloat = 0
    @State private var isResizing = false

    private var color: Color { Color(hex: colorHex) }

    private var snappedDayDelta: Int {
        guard isDragging else { return 0 }
        let raw = Int((dragTranslation.width / colWidth).rounded())
        return clampInt(raw, -dayIndex, dayCount - 1 - dayIndex)
    }

    private var snappedMinuteDelta: Int {
        guard isDragging else { return 0 }
        return Int(((Double(dragTranslation.height) / Double(hourHeight)) * 60 / 15).rounded()) * 15
    }

    private var snappedResizeMinutes: Int {
        guard isResizing else { return 0 }
        return Int(((Double(resizeTranslation) / Double(hourHeight)) * 60 / 15).rounded()) * 15
    }

    var body: some View {
        let p = theme.palette
        let selected = appState.selectedEventId == event.id
        let previewHeight = max(18, baseHeight + CGFloat(snappedResizeMinutes) / 60 * hourHeight)
        let active = isDragging || isResizing

        content(palette: p, selected: selected, height: previewHeight)
            .frame(width: max(20, width), height: previewHeight, alignment: .top)
            .offset(x: CGFloat(snappedDayDelta) * colWidth,
                    y: CGFloat(snappedMinuteDelta) / 60 * hourHeight)
            .zIndex(active ? 100 : (selected ? 50 : 0))
            .shadow(color: .black.opacity(active ? 0.35 : 0), radius: 10, y: 4)
            .opacity(event.pending ? 0.55 : 1)
            .onTapGesture {
                appState.selectedEventId = event.id
                appState.editingEventId = event.id
            }
            .gesture(moveGesture)
            .overlay(alignment: .bottom) {
                Color.clear
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .gesture(resizeGesture)
            }
            .popover(isPresented: editingBinding, arrowEdge: .trailing) {
                EventEditorView(mode: .edit(event))
            }
            .animation(.easeOut(duration: 0.1), value: snappedDayDelta)
            .animation(.easeOut(duration: 0.1), value: snappedMinuteDelta)
    }

    private func content(palette p: Palette, selected: Bool, height: CGFloat) -> some View {
        let titleColor = Color.eventTitle(hex: colorHex, dark: p.isDark)
        let compact = height < 34
        return HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3)
                .padding(.vertical, 2)
            if compact {
                // Variante de una línea para bloques cortos: "Título  HH:mm"
                HStack(spacing: 5) {
                    Text(displayTitle)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    Text(DateKit.timeShort.string(from: event.start))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(p.textMuted)
                        .lineLimit(1)
                }
                .padding(.leading, 5)
                .padding(.trailing, 4)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(height > 46 ? 2 : 1)
                    Text(timeLabel)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(p.textSecondary.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.leading, 5)
                .padding(.trailing, 4)
                .padding(.top, 3.5)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: compact ? .center : .top)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(p.isDark ? 0.11 : 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selected ? p.accent : color.opacity(0.28),
                                lineWidth: selected ? 1.4 : 1))
        )
        .contentShape(Rectangle())
    }

    private var displayTitle: String { event.summary }

    private var timeLabel: String {
        let previewStart = DateKit.cal.date(
            byAdding: .minute, value: snappedMinuteDelta,
            to: DateKit.addDays(event.start, snappedDayDelta)) ?? event.start
        let previewEnd = isResizing
            ? (DateKit.cal.date(byAdding: .minute, value: snappedResizeMinutes, to: event.end) ?? event.end)
            : previewStart.addingTimeInterval(event.duration)
        return "\(DateKit.timeShort.string(from: previewStart)) – \(DateKit.timeShort.string(from: previewEnd))"
    }

    private var editingBinding: Binding<Bool> {
        Binding(get: { appState.editingEventId == event.id },
                set: { if !$0 { appState.editingEventId = nil } })
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { v in
                guard !event.pending else { return }
                isDragging = true
                dragTranslation = v.translation
                appState.selectedEventId = event.id
            }
            .onEnded { _ in
                let dayDelta = snappedDayDelta
                let minDelta = snappedMinuteDelta
                isDragging = false
                dragTranslation = .zero
                if dayDelta != 0 || minDelta != 0 {
                    onMove(event, dayDelta, minDelta)
                }
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                guard !event.pending else { return }
                isResizing = true
                resizeTranslation = v.translation.height
            }
            .onEnded { _ in
                let delta = snappedResizeMinutes
                isResizing = false
                resizeTranslation = 0
                if delta != 0 { onResize(event, delta) }
            }
    }
}
