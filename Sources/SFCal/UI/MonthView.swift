import SwiftUI

struct MonthView: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    private let maxPills = 3

    var body: some View {
        let p = theme.palette
        let days = DateKit.monthGrid(appState.focusDate)
        let month = DateKit.cal.component(.month, from: appState.focusDate)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["lun", "mar", "mié", "jue", "vie", "sáb", "dom"], id: \.self) { d in
                    Text(d)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(p.textMuted)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 26)
            Rectangle().fill(p.border).frame(height: 1)
            GeometryReader { geo in
                let cellW = geo.size.width / 7
                let cellH = geo.size.height / 6
                ZStack(alignment: .topLeading) {
                    ForEach(0..<42, id: \.self) { i in
                        let day = days[i]
                        dayCell(day,
                                inMonth: DateKit.cal.component(.month, from: day) == month,
                                palette: p)
                            .frame(width: cellW, height: cellH)
                            .offset(x: CGFloat(i % 7) * cellW, y: CGFloat(i / 7) * cellH)
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date, inMonth: Bool, palette p: Palette) -> some View {
        let today = DateKit.isToday(day)
        let events = store.events(on: day)
        let allDay = events.filter { $0.isAllDay }
        let timed = events.filter { !$0.isAllDay && DateKit.isSameDay($0.start, day) }
        let dayTasks = store.tasksOn(day)
        let taskList = dayTasks.allDay + dayTasks.timed
        let pills = Array((allDay + timed).prefix(maxPills))
        let taskRoom = max(0, maxPills - pills.count)
        let overflow = (allDay.count + timed.count - pills.count) + max(0, taskList.count - taskRoom)

        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                Text(DateKit.dayNum.string(from: day))
                    .font(.system(size: 11.5, weight: today ? .heavy : .semibold))
                    .foregroundStyle(today ? Color(hex: "#f7f8f8") : (inMonth ? p.textSecondary : p.textMuted.opacity(0.4)))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(today ? p.accent : .clear)
                        .shadow(color: today ? p.accent.opacity(0.5) : .clear, radius: 3))
            }
            .padding(.trailing, 4)
            .padding(.top, 3)

            ForEach(pills) { event in
                monthPill(event, timed: !event.isAllDay, palette: p)
            }
            ForEach(taskList.prefix(taskRoom)) { task in
                TaskPill(task: task, compact: true)
                    .padding(.horizontal, 3)
            }
            if overflow > 0 {
                // Best practice de mes (Google): el overflow abre el DÍA completo
                Button(action: {
                    appState.focusDate = day
                    appState.setMode(.day)
                }) {
                    Text("+\(overflow) más")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(p.accent)
                        .padding(.leading, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(inMonth ? Color.clear : p.surface.opacity(p.isDark ? 0.45 : 0.55))
        .overlay(alignment: .bottom) { Rectangle().fill(p.grid).frame(height: 1) }
        .overlay(alignment: .trailing) { Rectangle().fill(p.grid).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            appState.focusDate = day
            appState.setMode(.day)
        }
    }

    private func monthPill(_ event: CalEvent, timed: Bool, palette p: Palette) -> some View {
        let hex = store.calendar(event.calendarId)?.bgColorHex ?? "#8C27F1"
        let color = Color.fromCalendarHex(hex)
        return Button(action: {
            appState.selectedEventId = event.id
            appState.editingEventId = event.id
        }) {
            HStack(spacing: 4) {
                if timed {
                    Text(DateKit.timeShort.string(from: event.start))
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(p.textMuted)
                } else {
                    Circle().fill(color).frame(width: 5, height: 5)
                }
                Text(event.summary)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(timed ? p.textPrimary : Color.eventTitle(hex: hex, dark: p.isDark))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(timed ? Color.clear : color.opacity(p.isDark ? 0.2 : 0.15)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 3)
        .opacity(event.pending ? 0.55 : 1)
        .popover(isPresented: Binding(
            get: { appState.editingEventId == event.id },
            set: { if !$0 { appState.editingEventId = nil } }
        ), arrowEdge: .bottom) {
            EventEditorView(mode: .edit(event))
        }
    }
}
