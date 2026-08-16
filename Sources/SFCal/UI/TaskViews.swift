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
    @EnvironmentObject var appState: AppState
    @State private var showPopover = false

    var body: some View {
        let p = theme.palette
        HStack(spacing: 5) {
            TaskCheckButton(task: task, size: 10.5 * appState.fontScale)
            Text(task.content)
                .font(.system(size: 10.5 * appState.fontScale, weight: .semibold))
                .foregroundStyle(p.textPrimary)
                .strikethrough(task.pendingDone, color: p.textMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let due = task.due, height > 20 {
                Text(DateKit.timeShort.string(from: due))
                    .font(.system(size: 9 * appState.fontScale, weight: .medium, design: .monospaced))
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
        HStack(spacing: 5) {
            TaskCheckButton(task: task, size: compact ? 8 : 9.5)
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
        .onTapGesture { showPopover = true }
        .opacity(task.pendingDone ? 0.55 : 1)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            TaskPopover(task: task) { showPopover = false }
        }
    }
}

/// El circulito que COMPLETA directo (15 ago): un click al
/// círculo = done en Todoist, sin popover. Optimista con rollback + banner, así
/// el click valiente no da miedo. El resto de la tarjeta sigue abriendo el detalle.
struct TaskCheckButton: View {
    let task: TodoTask
    var size: CGFloat = 10

    @EnvironmentObject var store: EventStore
    @EnvironmentObject var theme: ThemeManager
    @State private var hovering = false

    var body: some View {
        let p = theme.palette
        Button(action: { store.completeTask(task) }) {
            Image(systemName: task.pendingDone || hovering ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(p.priorityColor(task.priority))
                .padding(3)   // blanco de click más generoso que el glifo
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Completar en Todoist")
    }
}

/// Composer COMPLETO de tarea → Todoist (tecla R): todo lo que la API v1 permite
/// y usamos — título, descripción, proyecto, prioridad, etiquetas, fecha/hora,
/// duración. Sin hora por default (captura GTD sin fricción); todo lo demás opt-in.
struct TaskCreatePopover: View {
    let draft: TaskDraft

    @EnvironmentObject var store: EventStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    @State private var content = ""
    @State private var descripcion = ""
    @State private var projectId: String?
    @State private var priorityUI = 4          // p4 default (API 1)
    @State private var selectedLabels: Set<String> = []
    @State private var newLabel = ""
    @State private var day = Date()
    @State private var withTime = false
    @State private var time = Date()
    @State private var durationMin = 30
    @State private var loaded = false

    private let durations = [15, 30, 45, 60, 90, 120]

    private var apiPriority: Int { 5 - priorityUI }   // UI p1..p4 → API 4..1

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 12) {
            // Título + descripción
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.priorityColor(apiPriority))
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    TextField("Nueva tarea…", text: $content)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(p.textPrimary)
                        .onSubmit { crear() }
                    TextField("Descripción (opcional)", text: $descripcion, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...3)
                        .font(.system(size: 11.5))
                        .foregroundStyle(p.textSecondary)
                }
            }

            Rectangle().fill(p.border).frame(height: 1)

            // Proyecto + prioridad
            HStack(spacing: 8) {
                menuShell(palette: p) {
                    Menu {
                        Button("📥 Bandeja de entrada") { projectId = nil }
                        Divider()
                        ForEach(store.todoistProjects) { proj in
                            Button(proj.name) { projectId = proj.id }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(projectLabel)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(p.textPrimary)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(p.textMuted)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                menuShell(palette: p) {
                    Menu {
                        ForEach(1...4, id: \.self) { pr in
                            Button {
                                priorityUI = pr
                            } label: {
                                HStack {
                                    Image(systemName: pr == 4 ? "flag" : "flag.fill")
                                    Text("Prioridad \(pr)")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: priorityUI == 4 ? "flag" : "flag.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(p.priorityColor(apiPriority))
                            Text("P\(priorityUI)")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(p.textPrimary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(p.textMuted)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }

            // Fecha + hora + duración
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
                    menuShell(palette: p) {
                        Menu {
                            ForEach(durations, id: \.self) { d in
                                Button("\(d) min") { durationMin = d }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "timer")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(p.textMuted)
                                Text("\(durationMin)m")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(p.textPrimary)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                Spacer(minLength: 0)
            }

            // Etiquetas
            if !store.todoistLabels.isEmpty || !selectedLabels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ETIQUETAS")
                        .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(p.textMuted)
                        .tracking(0.8)
                    FlowLabels(
                        all: Array(Set(store.todoistLabels).union(selectedLabels)).sorted(),
                        selected: $selectedLabels,
                        palette: p)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .font(.system(size: 9))
                    .foregroundStyle(p.textMuted)
                TextField("nueva etiqueta + Enter", text: $newLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(p.textSecondary)
                    .onSubmit {
                        let l = newLabel.trimmingCharacters(in: .whitespaces)
                        if !l.isEmpty { selectedLabels.insert(l) }
                        newLabel = ""
                    }
            }

            Rectangle().fill(p.border).frame(height: 1)

            // Resumen + acciones
            HStack {
                Text(resumen)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(p.textMuted)
                    .lineLimit(2)
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
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Color(hex: "#f7f8f8"))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6.5)
                        .background(Capsule().fill(p.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
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

    private var projectLabel: String {
        if let id = projectId, let proj = store.todoistProjects.first(where: { $0.id == id }) {
            return proj.name
        }
        return "📥 Bandeja de entrada"
    }

    private var resumen: String {
        var parts = ["→ \(projectLabel)", "P\(priorityUI)"]
        parts.append(withTime
            ? "\(DateKit.timeShort.string(from: time)) · \(durationMin)m"
            : DateKit.cap(DateKit.dayMonth.string(from: day)))
        if !selectedLabels.isEmpty { parts.append("@" + selectedLabels.sorted().joined(separator: " @")) }
        parts.append("· se proyecta a Google/Apple")
        return parts.joined(separator: " · ")
    }

    private func menuShell<Content: View>(palette p: Palette, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(p.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.border, lineWidth: 1))
    }

    private func crear() {
        let dayStart = DateKit.startOfDay(day)
        let due = withTime
            ? dayStart.addingTimeInterval(DateKit.minutesIntoDay(time) * 60)
            : dayStart
        store.createTask(TodoNewTask(
            content: content,
            description: descripcion,
            projectId: projectId,
            priority: apiPriority,
            labels: Array(selectedLabels),
            due: due,
            hasTime: withTime,
            durationMin: withTime ? durationMin : nil))
        appState.taskDraft = nil
    }
}

/// Chips de etiquetas en filas (wrap manual simple: filas de a 4).
struct FlowLabels: View {
    let all: [String]
    @Binding var selected: Set<String>
    let palette: Palette

    var body: some View {
        let rows = stride(from: 0, to: all.count, by: 4).map { Array(all[$0..<min($0 + 4, all.count)]) }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { label in
                        let on = selected.contains(label)
                        Button(action: {
                            if on { selected.remove(label) } else { selected.insert(label) }
                        }) {
                            Text("@\(label)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(on ? Color(hex: "#f7f8f8") : palette.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(on ? palette.accent : palette.surface))
                                .overlay(Capsule().stroke(on ? palette.accent : palette.border, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Detalle de tarea = EDITOR (15 ago): título, fecha/hora,
/// duración y prioridad se editan aquí mismo. El círculo completa; Guardar edita;
/// Eliminar borra de Todoist. Todo optimista con rollback.
struct TaskPopover: View {
    let task: TodoTask
    let onClose: () -> Void

    @EnvironmentObject var store: EventStore
    @EnvironmentObject var theme: ThemeManager

    @State private var content = ""
    @State private var priorityUI = 4
    @State private var hasDay = true
    @State private var day = Date()
    @State private var withTime = false
    @State private var time = Date()
    @State private var durationMin = 30
    @State private var loaded = false

    private let durations = [15, 30, 45, 60, 90, 120]
    private var apiPriority: Int { 5 - priorityUI }

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 7) {
                TaskCheckButton(task: task, size: 12.5)
                    .padding(.top, 2)
                TextField("Tarea", text: $content, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(p.textPrimary)
            }

            HStack(spacing: 8) {
                DatePicker("", selection: $day, displayedComponents: [.date])
                    .labelsHidden()
                Toggle(isOn: $withTime) {
                    Text("hora")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(p.textSecondary)
                }
                .toggleStyle(.checkbox)
                if withTime {
                    DatePicker("", selection: $time, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                    Menu {
                        ForEach(durations, id: \.self) { d in
                            Button("\(d) min") { durationMin = d }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "timer")
                                .font(.system(size: 9))
                                .foregroundStyle(p.textMuted)
                            Text("\(durationMin)m")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(p.textPrimary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(p.surface))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border, lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Menu {
                    ForEach(1...4, id: \.self) { pr in
                        Button("Prioridad \(pr)") { priorityUI = pr }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: priorityUI == 4 ? "flag" : "flag.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(p.priorityColor(apiPriority))
                        Text("P\(priorityUI)")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(p.textPrimary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(p.surface))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer(minLength: 0)
            }

            HStack {
                Button(action: {
                    store.deleteTask(task)
                    onClose()
                }) {
                    Text("Eliminar")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(p.bad)
                }
                .buttonStyle(.plain)
                Text("· Todoist manda")
                    .font(.system(size: 9))
                    .foregroundStyle(p.textMuted.opacity(0.8))
                Spacer()
                Button(action: onClose) {
                    Text("Cerrar")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(p.textSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button(action: guardar) {
                    Text("Guardar")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "#f7f8f8"))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 5.5)
                        .background(Capsule().fill(p.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(p.card)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            content = task.content
            priorityUI = 5 - max(1, min(task.priority, 4))
            if let due = task.due {
                day = due
                withTime = task.hasTime
                if task.hasTime { time = due }
            }
            durationMin = task.durationMin ?? 30
        }
    }

    private func guardar() {
        let clean = content.trimmingCharacters(in: .whitespaces)
        let dayStart = DateKit.startOfDay(day)
        let due = withTime
            ? dayStart.addingTimeInterval(DateKit.minutesIntoDay(time) * 60)
            : dayStart
        store.updateTask(task,
                         content: clean.isEmpty ? task.content : clean,
                         priority: apiPriority,
                         due: due,
                         hasTime: withTime,
                         durationMin: withTime ? durationMin : nil)
        onClose()
    }
}
