import SwiftUI

/// Bloque de TAREA (Todoist) en el grid de tiempo: 30 min, lenguaje distinto al
/// de los eventos (punteado + check dorado) para que se lea "pendiente por hacer",
/// no "cita". Completar es un gesto deliberado: popover → botón.
struct TaskBlockView: View {
    let task: TodoTask
    let width: CGFloat
    let height: CGFloat

    @EnvironmentObject var store: EventStore
    @EnvironmentObject var theme: ThemeManager
    @State private var showPopover = false

    var body: some View {
        let p = theme.palette
        HStack(spacing: 5) {
            Image(systemName: task.pendingDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(p.accent)
            Text(task.content)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(p.textPrimary)
                .strikethrough(task.pendingDone, color: p.textMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let due = task.due, height > 20 {
                Text(DateKit.timeShort.string(from: due))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(p.textMuted)
            }
        }
        .padding(.horizontal, 6)
        .frame(width: max(20, width), height: height)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(p.accent.opacity(p.isDark ? 0.07 : 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(p.accent.opacity(0.5),
                                      style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
        )
        .opacity(task.pendingDone ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { showPopover = true }
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            TaskPopover(task: task) { showPopover = false }
        }
    }
}

/// Pill de tarea sin hora (fila all-day / mes).
struct TaskPill: View {
    let task: TodoTask
    var compact = false

    @EnvironmentObject var store: EventStore
    @EnvironmentObject var theme: ThemeManager
    @State private var showPopover = false

    var body: some View {
        let p = theme.palette
        Button(action: { showPopover = true }) {
            HStack(spacing: 5) {
                Image(systemName: task.pendingDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: compact ? 8 : 9.5, weight: .semibold))
                    .foregroundStyle(p.accent)
                Text(task.content)
                    .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
                    .foregroundStyle(p.textPrimary)
                    .strikethrough(task.pendingDone, color: p.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 2 : 3)
            .background(
                RoundedRectangle(cornerRadius: compact ? 4 : 5)
                    .fill(p.accent.opacity(p.isDark ? 0.07 : 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: compact ? 4 : 5)
                            .strokeBorder(p.accent.opacity(0.45),
                                          style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(task.pendingDone ? 0.55 : 1)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            TaskPopover(task: task) { showPopover = false }
        }
    }
}

/// Captura rápida de tarea → Todoist (tecla R). Sin hora por default (GTD sin
/// fricción); la hora es opt-in.
struct TaskCreatePopover: View {
    let draft: TaskDraft

    @EnvironmentObject var store: EventStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    @State private var content = ""
    @State private var day = Date()
    @State private var withTime = false
    @State private var time = Date()
    @State private var loaded = false

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.accent)
                TextField("Nueva tarea…", text: $content)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(p.textPrimary)
                    .onSubmit { crear() }
            }
            HStack(spacing: 10) {
                DatePicker("", selection: $day, displayedComponents: [.date])
                    .labelsHidden()
                Toggle(isOn: $withTime) {
                    Text("con hora")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(p.textSecondary)
                }
                .toggleStyle(.checkbox)
                if withTime {
                    DatePicker("", selection: $time, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text("→ Inbox de Todoist · se proyecta a Google/Apple")
                    .font(.system(size: 9.5))
                    .foregroundStyle(p.textMuted.opacity(0.8))
                Spacer()
                Button(action: { appState.taskDraft = nil }) {
                    Text("Cancelar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.textSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button(action: crear) {
                    Text("Crear")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "#f7f8f8"))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(p.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(p.card)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            content = draft.content
            day = draft.day
            withTime = draft.withTime
            time = draft.time
        }
    }

    private func crear() {
        let dayStart = DateKit.startOfDay(day)
        let due: Date
        if withTime {
            let mins = DateKit.minutesIntoDay(time)
            due = dayStart.addingTimeInterval(mins * 60)
        } else {
            due = dayStart
        }
        store.createTask(content: content, due: due, hasTime: withTime)
        appState.taskDraft = nil
    }
}

struct TaskPopover: View {
    let task: TodoTask
    let onClose: () -> Void

    @EnvironmentObject var store: EventStore
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.accent)
                Text(task.content)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(p.textPrimary)
            }
            HStack(spacing: 5) {
                if let due = task.due {
                    Text(task.hasTime
                         ? "\(DateKit.cap(DateKit.dayMonth.string(from: due))) · \(DateKit.timeShort.string(from: due))"
                         : DateKit.cap(DateKit.dayMonth.string(from: due)))
                }
                Text("· Todoist")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(p.textMuted)

            HStack {
                Text("La tarea vive en Todoist; aquí se espeja")
                    .font(.system(size: 9.5))
                    .foregroundStyle(p.textMuted.opacity(0.8))
                Spacer()
                Button(action: onClose) {
                    Text("Cerrar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.textSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button(action: {
                    store.completeTask(task)
                    onClose()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                        Text("Completar")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(Color(hex: "#f7f8f8"))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(p.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(p.card)
    }
}
