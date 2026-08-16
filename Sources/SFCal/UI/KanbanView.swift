import SwiftUI
import UniformTypeIdentifiers

/// Kanban de FLUJO (tecla K, 16 ago): el estado del tablero vive en Todoist
/// como SECCIONES agregadas por nombre entre proyectos — cero estado local.
/// 💡 Ideas (vivero sin culpa) · 📥 Backlog (sin sección) · 📋 Por hacer ·
/// 🔥 Haciendo (WIP 1, el semáforo grita) · ✅ Hecho hoy (marcador, no archivo).
/// Drag & drop = move/close/reopen REALES por API; el iPhone ve el mismo
/// tablero en la vista Tablero de cada proyecto de Todoist.
struct KanbanView: View {
    @Environment(\.sfcalSnapshotHours) private var snapshotHours
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var theme: ThemeManager
    @State private var targeted: String?

    private struct KColumn: Identifiable {
        let id: String            // clave canónica
        let emoji: String
        let title: String
        let sectionName: String?  // nombre a mover (nil = Backlog/root)
        let isDone: Bool
        var tasks: [TodoTask]
        var wipLimit: Int?
        var softCap: Int?
    }

    private func columns() -> [KColumn] {
        // sección → clave canónica de columna
        var canonById: [String: String] = [:]
        var customTitles: [String: String] = [:]   // canon → display de la 1ª sección
        for s in store.todoistSections {
            let c = TodoSection.canon(s.name)
            canonById[s.id] = c
            if !["por hacer", "haciendo"].contains(c), customTitles[c] == nil {
                customTitles[c] = s.name
            }
        }
        var byColumn: [String: [TodoTask]] = [:]
        for t in store.allTasks {
            let key: String
            if let sid = t.sectionId, let c = canonById[sid] { key = c }
            else { key = "__backlog" }
            byColumn[key, default: []].append(t)
        }
        func sorted(_ ts: [TodoTask]) -> [TodoTask] {
            ts.sorted {
                $0.priority != $1.priority
                    ? $0.priority > $1.priority
                    : ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture)
            }
        }
        // ("Ideas" como columna fija salió del diseño final; si un día
        // existe una sección así en Todoist, aparece sola como columna data-driven)
        var out: [KColumn] = [
            KColumn(id: "__backlog", emoji: "📥", title: "Backlog", sectionName: nil,
                    isDone: false, tasks: sorted(byColumn["__backlog"] ?? []), softCap: 15),
            KColumn(id: "por hacer", emoji: "📋", title: "Por hacer", sectionName: "Por hacer",
                    isDone: false, tasks: sorted(byColumn["por hacer"] ?? [])),
            KColumn(id: "haciendo", emoji: "🔥", title: "Haciendo", sectionName: "Haciendo",
                    isDone: false, tasks: sorted(byColumn["haciendo"] ?? []), wipLimit: 1),
        ]
        // Secciones con otros nombres = columnas data-driven (si tú o tu agente
        // inventan una en Todoist, aparece sola)
        for (canon, title) in customTitles.sorted(by: { $0.value < $1.value }) {
            out.append(KColumn(id: canon, emoji: "▫️", title: title, sectionName: title,
                               isDone: false, tasks: sorted(byColumn[canon] ?? [])))
        }
        out.append(KColumn(id: "__done", emoji: "✅", title: "Hecho hoy", sectionName: nil,
                           isDone: true, tasks: store.doneToday))
        return out
    }

    var body: some View {
        let p = theme.palette
        let cols = columns()
        Group {
            if snapshotHours != nil {
                boardBody(cols, palette: p, colWidth: nil)
            } else {
                // ⚠️ El ScrollView horizontal propone ancho INFINITO: sin ancho fijo
                // por columna, la más cargada se come el tablero y la última queda
                // fuera de pantalla (bug 16 ago). Ancho = partes iguales del viewport,
                // con piso 220 (ahí sí, scrollbar visible).
                GeometryReader { geo in
                    let n = max(cols.count, 1)
                    let w = max(220, (geo.size.width - CGFloat(n - 1) * 10) / CGFloat(n))
                    ScrollView(.horizontal, showsIndicators: true) {
                        boardBody(cols, palette: p, colWidth: w)
                            .frame(minHeight: geo.size.height, alignment: .top)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func boardBody(_ cols: [KColumn], palette p: Palette, colWidth: CGFloat?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(cols) { col in
                if let colWidth {
                    columnView(col, palette: p)
                        .frame(width: colWidth, alignment: .top)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    columnView(col, palette: p)
                        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    // MARK: - Columna

    /// ⚠️ `.dropDestination`/`.draggable` NO se montan en modo snapshot: el
    /// ImageRenderer pinta los contenedores de drop con un artefacto del
    /// sistema (fill amarillo + 🚫 gigante, medido 16 ago).
    @ViewBuilder
    private func columnView(_ col: KColumn, palette p: Palette) -> some View {
        if snapshotHours == nil {
            columnBody(col, palette: p)
                .dropDestination(for: String.self) { ids, _ in
                    handleDrop(ids, into: col)
                } isTargeted: { over in
                    targeted = over ? col.id : (targeted == col.id ? nil : targeted)
                }
        } else {
            columnBody(col, palette: p)
        }
    }

    private func columnBody(_ col: KColumn, palette p: Palette) -> some View {
        let overWip = col.wipLimit.map { col.tasks.count > $0 } ?? false
        let overCap = col.softCap.map { col.tasks.count > $0 } ?? false
        let isTarget = targeted == col.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(col.emoji).font(.system(size: 12))
                Text(col.title.uppercased())
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundStyle(overWip ? p.bad : p.textMuted)
                    .tracking(0.8)
                if overWip, let limit = col.wipLimit {
                    // El comparador GRITA pero no bloquea: tú mandas
                    Text("\(col.tasks.count)/\(limit)")
                        .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Color(hex: "#f7f8f8"))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(p.bad))
                } else {
                    Text("\(col.tasks.count)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(overCap ? p.gold : p.textMuted.opacity(0.8))
                }
                if overCap {
                    Text("triage")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(p.gold)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            columnCards(col, palette: p)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(p.surface.opacity(p.isDark ? 0.55 : 0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isTarget ? p.accent
                            : overWip ? p.bad.opacity(0.55)
                            : p.border,
                            lineWidth: isTarget ? 1.6 : 1))
        )
    }

    @ViewBuilder
    private func columnCards(_ col: KColumn, palette p: Palette) -> some View {
        if snapshotHours != nil {
            VStack(spacing: 6) {
                cardsList(col, palette: p)
                Spacer(minLength: 0)
            }
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    cardsList(col, palette: p)
                    // Zona de drop generosa aunque la columna esté corta
                    Color.clear.frame(height: 120)
                }
            }
        }
    }

    @ViewBuilder
    private func cardsList(_ col: KColumn, palette p: Palette) -> some View {
        if col.tasks.isEmpty {
            RoundedRectangle(cornerRadius: 9)
                .stroke(p.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(height: 54)
                .overlay(
                    Text(col.isDone ? "Nada aún hoy" : "Arrastra aquí")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(p.textMuted.opacity(0.7)))
        }
        ForEach(col.tasks) { task in
            if snapshotHours == nil {
                card(task, done: col.isDone, palette: p)
                    .draggable(task.id)
            } else {
                card(task, done: col.isDone, palette: p)
            }
        }
    }

    // MARK: - Tarjeta (minimalista: título · prioridad · hora · proyecto)

    private func projectBadge(_ t: TodoTask) -> String {
        guard let pid = t.projectId,
              let proj = store.todoistProjects.first(where: { $0.id == pid }) else { return "📥" }
        if let first = proj.name.first, !first.isLetter, !first.isNumber {
            return String(first)
        }
        return "📥"
    }

    private func dueChip(_ t: TodoTask) -> (String, Bool)? {   // (texto, esRojo)
        guard let d = t.due else { return nil }
        let today = DateKit.startOfDay(Date())
        if d < today { return ("venció", true) }
        if DateKit.isToday(d) {
            return (t.hasTime ? DateKit.timeShort.string(from: d) : "hoy", false)
        }
        return (DateKit.dayMonth.string(from: d), false)
    }

    private func card(_ task: TodoTask, done: Bool, palette p: Palette) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if done {
                Button(action: { store.reopenTask(task, toColumn: nil) }) {
                    ZStack {
                        Circle().fill(p.ok)
                        Image(systemName: "checkmark")
                            .font(.system(size: 7.5, weight: .heavy))
                            .foregroundStyle(p.isDark ? Color.black : Color.white)
                    }
                    .frame(width: 13, height: 13)
                    .padding(3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reabrir (regresa al Backlog)")
                .padding(.top, 1)
            } else {
                TaskCheckButton(task: task, size: 13)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(task.content)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(done ? p.textMuted : p.textPrimary)
                    .strikethrough(done, color: p.textMuted.opacity(0.7))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if !done, dueChip(task) != nil || task.hasTime {
                    HStack(spacing: 5) {
                        if let (label, red) = dueChip(task) {
                            HStack(spacing: 3) {
                                Image(systemName: "clock").font(.system(size: 7.5))
                                Text(label).font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(red ? p.bad
                                : (task.due.map { DateKit.isToday($0) } == true ? p.ok : p.textMuted))
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            Text(projectBadge(task))
                .font(.system(size: 10))
                .opacity(done ? 0.5 : 0.9)
                .help(projectName(task))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(p.card)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(p.border, lineWidth: 1))
                .shadow(color: .black.opacity(p.isDark ? 0.25 : 0.07), radius: 3, y: 1))
        .opacity(task.pendingDone ? 0.45 : 1)
        .contentShape(Rectangle())
    }

    private func projectName(_ t: TodoTask) -> String {
        guard let pid = t.projectId,
              let proj = store.todoistProjects.first(where: { $0.id == pid }) else { return "Inbox" }
        return proj.name
    }

    // MARK: - Drop = verbo real en Todoist

    private func handleDrop(_ ids: [String], into col: KColumn) -> Bool {
        targeted = nil
        var acted = false
        for id in ids {
            if let doneTask = store.doneToday.first(where: { $0.id == id }) {
                guard !col.isDone else { continue }
                store.reopenTask(doneTask, toColumn: col.sectionName)
                acted = true
            } else if let task = store.allTasks.first(where: { $0.id == id }) {
                if col.isDone {
                    store.completeTask(task)
                    acted = true
                } else {
                    // Ignorar drop en la columna donde ya está
                    let currentCanon: String
                    if let sid = task.sectionId,
                       let sec = store.todoistSections.first(where: { $0.id == sid }) {
                        currentCanon = TodoSection.canon(sec.name)
                    } else {
                        currentCanon = "__backlog"
                    }
                    guard currentCanon != col.id else { continue }
                    store.moveTask(task, toColumn: col.sectionName)
                    acted = true
                }
            }
        }
        return acted
    }
}
