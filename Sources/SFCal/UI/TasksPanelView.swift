import SwiftUI

/// Panel de TAREAS (tecla Y, 16 ago): todas las pendientes de Todoist —incluidas
/// las SIN fecha— agrupadas Vencidas/Hoy/Mañana/Próximas/Después/Sin fecha, con
/// prioridad (color), etiquetas, hora límite y proyecto. Click → detalle editable
/// con descripción. Referencia de diseño: el propio Todoist.
struct TasksPanelView: View {
    @Environment(\.sfcalSnapshotHours) private var snapshotHours
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager
    @State private var selectedId: String?

    private struct Bucket: Identifiable {
        let id: String
        let titulo: String
        let esVencidas: Bool
        let tasks: [TodoTask]
    }

    private func buckets() -> [Bucket] {
        let today = DateKit.startOfDay(Date())
        let tomorrow = DateKit.addDays(today, 1)
        let dayAfter = DateKit.addDays(today, 2)
        let weekOut = DateKit.addDays(today, 8)
        var vencidas: [TodoTask] = [], hoy: [TodoTask] = [], man: [TodoTask] = []
        var prox: [TodoTask] = [], desp: [TodoTask] = [], sin: [TodoTask] = []
        for t in store.allTasks {
            guard let d = t.due else { sin.append(t); continue }
            if d < today { vencidas.append(t) }
            else if d < tomorrow { hoy.append(t) }
            else if d < dayAfter { man.append(t) }
            else if d < weekOut { prox.append(t) }
            else { desp.append(t) }
        }
        return [
            Bucket(id: "v", titulo: "VENCIDAS", esVencidas: true, tasks: vencidas),
            Bucket(id: "h", titulo: "HOY", esVencidas: false, tasks: hoy),
            Bucket(id: "m", titulo: "MAÑANA", esVencidas: false, tasks: man),
            Bucket(id: "p", titulo: "PRÓXIMOS 7 DÍAS", esVencidas: false, tasks: prox),
            Bucket(id: "d", titulo: "DESPUÉS", esVencidas: false, tasks: desp),
            Bucket(id: "s", titulo: "SIN FECHA", esVencidas: false, tasks: sin),
        ].filter { !$0.tasks.isEmpty }
    }

    var body: some View {
        let p = theme.palette
        HStack(spacing: 0) {
            listPane(palette: p)
                .frame(maxWidth: .infinity)
            if let sel = store.allTasks.first(where: { $0.id == selectedId }) {
                Rectangle().fill(p.border).frame(width: 1)
                TaskDetailPane(task: sel) { selectedId = nil }
                    .id(sel.id)
                    .frame(width: 370)
            }
        }
    }

    @ViewBuilder
    private func listPane(palette p: Palette) -> some View {
        let grupos = buckets()
        if snapshotHours != nil {
            VStack(alignment: .leading, spacing: 0) {
                listContent(grupos: grupos, palette: p)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
        } else {
            ScrollView(showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    listContent(grupos: grupos, palette: p)
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func listContent(grupos: [Bucket], palette p: Palette) -> some View {
        if grupos.isEmpty {
            VStack(spacing: 8) {
                Text("🔥")
                    .font(.system(size: 34))
                Text("Cero pendientes. El monje está limpio.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        }
        ForEach(grupos) { g in
            HStack(spacing: 8) {
                Text(g.titulo)
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(g.esVencidas ? p.bad : p.textMuted)
                    .tracking(1)
                Text("\(g.tasks.count)")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(p.textMuted.opacity(0.8))
                Rectangle().fill(p.grid).frame(height: 1)
            }
            .padding(.top, 16)
            .padding(.bottom, 6)
            ForEach(g.tasks) { task in
                taskRow(task, vencida: g.esVencidas, palette: p)
            }
        }
    }

    private func projectName(_ t: TodoTask) -> String {
        guard let pid = t.projectId,
              let proj = store.todoistProjects.first(where: { $0.id == pid }) else {
            return "📥 Bandeja"
        }
        return proj.name
    }

    private func dueLabel(_ t: TodoTask, vencida: Bool) -> String? {
        guard let d = t.due else { return nil }
        if vencida { return "Venció \(DateKit.dayMonth.string(from: d))" }
        let today = DateKit.startOfDay(Date())
        let prefix: String
        if DateKit.isSameDay(d, today) { prefix = "Hoy" }
        else if DateKit.isSameDay(d, DateKit.addDays(today, 1)) { prefix = "Mañana" }
        else { prefix = DateKit.cap(DateKit.agendaDay.string(from: d)) }
        return t.hasTime ? "\(prefix) \(DateKit.timeShort.string(from: d))" : prefix
    }

    private func taskRow(_ task: TodoTask, vencida: Bool, palette p: Palette) -> some View {
        let selected = selectedId == task.id
        return Button(action: {
            withAnimation(.easeOut(duration: 0.12)) {
                selectedId = selected ? nil : task.id
            }
        }) {
            HStack(alignment: .top, spacing: 10) {
                TaskCheckButton(task: task, size: 13)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2.5) {
                    Text(task.content)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.textPrimary)
                        .strikethrough(task.pendingDone, color: p.textMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !task.description.isEmpty {
                        Text(task.description)
                            .font(.system(size: 10.5))
                            .foregroundStyle(p.textMuted)
                            .lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        if let due = dueLabel(task, vencida: vencida) {
                            HStack(spacing: 3) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 8.5))
                                Text(due)
                                    .font(.system(size: 9.5, weight: .bold))
                            }
                            .foregroundStyle(vencida ? p.bad
                                : (task.due.map { DateKit.isToday($0) } == true ? p.ok : p.textSecondary))
                        }
                        if task.hasTime, let dur = task.durationMin {
                            Text("\(dur)m")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(p.textMuted)
                        }
                        ForEach(task.labels, id: \.self) { l in
                            Text("@\(l)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(p.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(p.accent.opacity(0.12)))
                        }
                    }
                }
                Spacer(minLength: 8)
                Text(projectName(task))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(p.textMuted.opacity(0.85))
                    .lineLimit(1)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? p.accent.opacity(p.isDark ? 0.10 : 0.08) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(selected ? p.accent.opacity(0.5) : .clear, lineWidth: 1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(task.pendingDone ? 0.5 : 1)
        .overlay(alignment: .bottom) {
            if !selected {
                Rectangle().fill(p.grid.opacity(0.6)).frame(height: 1).padding(.leading, 33)
            }
        }
    }
}

/// Detalle EDITABLE de la tarea (columna derecha del panel Y), estilo Todoist:
/// título, descripción prominente, fecha/hora/duración, prioridad, etiquetas.
struct TaskDetailPane: View {
    let task: TodoTask
    let onClose: () -> Void

    @EnvironmentObject var store: EventStore
    @EnvironmentObject var theme: ThemeManager

    @State private var content = ""
    @State private var descripcion = ""
    @State private var priorityUI = 4
    @State private var hasDate = true
    @State private var day = Date()
    @State private var withTime = false
    @State private var time = Date()
    @State private var durationMin = 30
    @State private var selectedLabels: Set<String> = []
    @State private var newLabel = ""
    @State private var loaded = false

    private let durations = [15, 30, 45, 60, 90, 120]
    private var apiPriority: Int { 5 - priorityUI }

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(projectName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(p.textMuted)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(p.textMuted)
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            Rectangle().fill(p.border).frame(height: 1)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 9) {
                        TaskCheckButton(task: task, size: 14)
                            .padding(.top, 2)
                        TextField("Tarea", text: $content, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...4)
                            .font(.system(size: 15.5, weight: .bold))
                            .foregroundStyle(p.textPrimary)
                    }
                    TextField("Descripción", text: $descripcion, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...8)
                        .font(.system(size: 12))
                        .foregroundStyle(p.textSecondary)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(p.surface.opacity(p.isDark ? 0.6 : 0.7)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))

                    campo("FECHA", palette: p) {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: $hasDate) {
                                Text("con fecha")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(p.textSecondary)
                            }
                            .toggleStyle(.checkbox)
                            if hasDate {
                                HStack(spacing: 8) {
                                    DatePicker("", selection: $day, displayedComponents: [.date])
                                        .labelsHidden()
                                    Toggle(isOn: $withTime) {
                                        Text("hora")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(p.textSecondary)
                                    }
                                    .toggleStyle(.checkbox)
                                }
                                if withTime {
                                    HStack(spacing: 8) {
                                        DatePicker("", selection: $time, displayedComponents: [.hourAndMinute])
                                            .labelsHidden()
                                        Menu {
                                            ForEach(durations, id: \.self) { d in
                                                Button("\(d) min") { durationMin = d }
                                            }
                                        } label: {
                                            HStack(spacing: 3) {
                                                Image(systemName: "timer").font(.system(size: 9))
                                                Text("\(durationMin)m")
                                                    .font(.system(size: 10.5, weight: .bold))
                                            }
                                            .foregroundStyle(p.textPrimary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 4)
                                            .background(RoundedRectangle(cornerRadius: 6).fill(p.surface))
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border, lineWidth: 1))
                                        }
                                        .menuStyle(.borderlessButton)
                                        .fixedSize()
                                    }
                                }
                            }
                        }
                    }

                    campo("PRIORIDAD", palette: p) {
                        HStack(spacing: 6) {
                            ForEach(1...4, id: \.self) { pr in
                                let on = priorityUI == pr
                                Button(action: { priorityUI = pr }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: pr == 4 ? "flag" : "flag.fill")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(p.priorityColor(5 - pr))
                                        Text("P\(pr)")
                                            .font(.system(size: 10.5, weight: .bold))
                                            .foregroundStyle(on ? p.textPrimary : p.textMuted)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 7)
                                        .fill(on ? p.accent.opacity(0.14) : p.surface))
                                    .overlay(RoundedRectangle(cornerRadius: 7)
                                        .stroke(on ? p.accent.opacity(0.6) : p.border, lineWidth: 1))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    campo("ETIQUETAS", palette: p) {
                        VStack(alignment: .leading, spacing: 6) {
                            FlowLabels(
                                all: Array(Set(store.todoistLabels).union(selectedLabels)).sorted(),
                                selected: $selectedLabels,
                                palette: p)
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
                        }
                    }
                }
                .padding(16)
            }

            Rectangle().fill(p.border).frame(height: 1)
            HStack {
                Button(action: {
                    store.deleteTask(task)
                    onClose()
                }) {
                    Text("Eliminar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.bad)
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: guardar) {
                    Text("Guardar")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Color(hex: "#f7f8f8"))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(p.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(p.surface.opacity(p.isDark ? 0.45 : 0.65))
        .onAppear(perform: loadOnce)
    }

    private var projectName: String {
        guard let pid = task.projectId,
              let proj = store.todoistProjects.first(where: { $0.id == pid }) else {
            return "📥 Bandeja de entrada"
        }
        return proj.name
    }

    private func campo<Content: View>(_ titulo: String, palette p: Palette,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titulo)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(p.textMuted)
                .tracking(0.9)
            content()
        }
    }

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        content = task.content
        descripcion = task.description
        priorityUI = 5 - max(1, min(task.priority, 4))
        selectedLabels = Set(task.labels)
        if let due = task.due {
            hasDate = true
            day = due
            withTime = task.hasTime
            if task.hasTime { time = due }
        } else {
            hasDate = false
        }
        durationMin = task.durationMin ?? 30
    }

    private func guardar() {
        let clean = content.trimmingCharacters(in: .whitespaces)
        var due: Date?
        if hasDate {
            let dayStart = DateKit.startOfDay(day)
            due = withTime
                ? dayStart.addingTimeInterval(DateKit.minutesIntoDay(time) * 60)
                : dayStart
        }
        store.updateTask(task,
                         content: clean.isEmpty ? task.content : clean,
                         priority: apiPriority,
                         due: due,
                         hasTime: hasDate && withTime,
                         durationMin: (hasDate && withTime) ? durationMin : nil,
                         description: descripcion,
                         labels: Array(selectedLabels))
        onClose()
    }
}
