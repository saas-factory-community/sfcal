import SwiftUI

/// Vista AGENDA: lista vertical por día (eventos + tareas) desde focusDate.
struct AgendaView: View {
    @Environment(\.sfcalSnapshotHours) private var snapshotHours
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    private let horizon = 45

    var body: some View {
        let p = theme.palette
        let start = DateKit.startOfDay(appState.focusDate)
        // ScrollView/LazyVStack no materializan bajo ImageRenderer (gotcha conocido):
        // en modo snapshot se pinta plano con horizonte corto
        if snapshotHours != nil {
            VStack(alignment: .leading, spacing: 0) {
                agendaContent(days: (0..<8).map { DateKit.addDays(start, $0) }, palette: p)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
        } else {
            ScrollView(showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    agendaContent(days: (0..<horizon).map { DateKit.addDays(start, $0) }, palette: p)
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func agendaContent(days: [Date], palette p: Palette) -> some View {
        ForEach(days, id: \.self) { day in
            let events = store.events(on: day)
            let dayTasks = store.tasksOn(day)
            let tasks = dayTasks.allDay + dayTasks.timed
            if !events.isEmpty || !tasks.isEmpty {
                daySection(day, events: events, tasks: tasks, palette: p)
            }
        }
    }

    private func daySection(_ day: Date, events: [CalEvent], tasks: [TodoTask], palette p: Palette) -> some View {
        let today = DateKit.isToday(day)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(DateKit.dayNum.string(from: day))
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(today ? Color(hex: "#f7f8f8") : p.textPrimary)
                    .frame(width: 27, height: 27)
                    .background(Circle().fill(today ? p.accent : p.card)
                        .shadow(color: today ? p.accent.opacity(0.5) : .clear, radius: 3))
                Text(DateKit.cap(DateKit.agendaDay.string(from: day)))
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(today ? p.accent : p.textSecondary)
                if today {
                    Text("HOY")
                        .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(p.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(p.accent.opacity(0.15)))
                }
                Spacer()
            }
            .padding(.top, 14)
            .padding(.bottom, 4)

            ForEach(events.filter(\.isAllDay)) { event in
                agendaEventRow(event, timeLabel: "todo el día", palette: p)
            }
            ForEach(tasks) { task in
                agendaTaskRow(task, palette: p)
            }
            ForEach(events.filter { !$0.isAllDay }) { event in
                agendaEventRow(
                    event,
                    timeLabel: "\(DateKit.timeShort.string(from: event.start)) – \(DateKit.timeShort.string(from: event.end))",
                    palette: p)
            }
            Rectangle().fill(p.grid).frame(height: 1).padding(.top, 10)
        }
    }

    private func agendaEventRow(_ event: CalEvent, timeLabel: String, palette p: Palette) -> some View {
        let hex = store.calendar(event.calendarId)?.bgColorHex ?? "#8C27F1"
        return Button(action: { appState.editingEventId = event.id }) {
            HStack(spacing: 10) {
                Text(timeLabel)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(p.textMuted)
                    .frame(width: 96, alignment: .trailing)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.fromCalendarHex(hex))
                    .frame(width: 3, height: 16)
                Text(event.summary)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.eventTitle(hex: hex, dark: p.isDark))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(store.calendar(event.calendarId)?.summary ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(p.textMuted.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(event.pending ? 0.55 : 1)
        .popover(isPresented: Binding(
            get: { appState.editingEventId == event.id },
            set: { if !$0 { appState.editingEventId = nil } }
        ), arrowEdge: .bottom) {
            EventEditorView(mode: .edit(event))
        }
    }

    private func agendaTaskRow(_ task: TodoTask, palette p: Palette) -> some View {
        HStack(spacing: 10) {
            Text(task.hasTime && task.due != nil ? DateKit.timeShort.string(from: task.due!) : "tarea")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(p.textMuted)
                .frame(width: 96, alignment: .trailing)
            TaskPill(task: task)
                .frame(maxWidth: 460, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
