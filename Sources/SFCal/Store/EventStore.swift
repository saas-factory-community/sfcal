import Foundation
import SwiftUI

enum SyncHealth: Equatable {
    case syncing
    case ok(Date)
    case error(String)

    var isError: Bool { if case .error = self { return true }; return false }
}

@MainActor
final class EventStore: ObservableObject {
    @Published var calendars: [CalendarInfo] = []
    @Published var eventsByCalendar: [String: [CalEvent]] = [:]
    @Published var hiddenCalendarIds: Set<String> = []
    @Published var health: SyncHealth = .syncing
    @Published var lastSyncAt: Date?
    @Published var banner: String?
    @Published var tasks: [TodoTask] = []
    @Published var allTasks: [TodoTask] = []   // TODAS las activas (incl. sin fecha) — panel Y
    @Published var todoistProjects: [TodoProject] = []
    @Published var todoistSections: [TodoSection] = []   // columnas del Kanban (K)
    @Published var doneToday: [TodoTask] = []            // completadas HOY — marcador, no archivo
    @Published var todoistLabels: [String] = []
    @Published var todoistError = false
    @Published var todoistVisible: Bool {
        didSet { UserDefaults.standard.set(todoistVisible, forKey: "sfcal.todoist.visible") }
    }

    let accounts: [CalAccount]
    let todoistAvailable: Bool
    private let todoist: TodoistClient?
    private var taskMirror: TaskMirror?
    private var todoistTick = 0
    // La API v1 de Todoist NO persiste duration (verificado 15 ago): la duración
    // vive LOCAL — dimensiona el bloque y el espejo proyecta el largo real a Google.
    private var localDurations: [String: Int] =
        (UserDefaults.standard.dictionary(forKey: "sfcal.task.durations") as? [String: Int]) ?? [:]
    private var clients: [String: GCalClient] = [:]
    private var syncTokens: [String: String] = [:]
    private var pollTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?

    var windowFrom: Date { DateKit.addDays(DateKit.startOfDay(Date()), -90) }
    var windowTo: Date { DateKit.addDays(DateKit.startOfDay(Date()), 400) }

    init() {
        var accts: [CalAccount] = []
        var cls: [String: GCalClient] = [:]
        // Cuentas por DESCUBRIMIENTO: cada ~/.sfcal/token-<etiqueta>.json es una
        // cuenta ("personal" primero si existe, luego alfabético). Cero hardcode.
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sfcal")
        let labels = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("token-") && $0.hasSuffix(".json") }
            .map { String($0.dropFirst("token-".count).dropLast(".json".count)) }
            .sorted { a, b in
                if a == "personal" { return true }
                if b == "personal" { return false }
                return a < b
            }
        for label in labels {
            if let session = OAuthSession(label: label) {
                accts.append(CalAccount(id: label, email: session.email))
                cls[label] = GCalClient(auth: session, accountId: label)
            }
        }
        accounts = accts
        clients = cls
        todoist = TodoistClient()
        todoistAvailable = todoist != nil
        todoistVisible = UserDefaults.standard.object(forKey: "sfcal.todoist.visible") as? Bool ?? true
        // Espejo de UNA vía Todoist → Google: principio de la casa, TODO sincronizado
        // (Google → Apple/iPhone). Cuenta "personal" preferida; si no, la primera.
        if todoist != nil {
            if let mirrorClient = cls["personal"] ?? accts.first.flatMap({ cls[$0.id] }) {
                taskMirror = TaskMirror(client: mirrorClient)
            }
        }
        if let c = DiskCache.load() {
            calendars = c.calendars
            eventsByCalendar = c.events
            syncTokens = c.syncTokens
            hiddenCalendarIds = c.hiddenCalendarIds
            if c.savedAt > .distantPast {
                lastSyncAt = c.savedAt
                health = .ok(c.savedAt)
            }
        }
    }

    // MARK: - Lectura para las vistas

    var visibleCalendars: [CalendarInfo] {
        calendars.filter { !hiddenCalendarIds.contains($0.id) }
    }

    func calendar(_ id: String) -> CalendarInfo? {
        calendars.first { $0.id == id }
    }

    func events(on day: Date, includeObjetivos: Bool = false) -> [CalEvent] {
        let dayStart = DateKit.startOfDay(day)
        let dayEnd = DateKit.addDays(dayStart, 1)
        var out: [CalEvent] = []
        for cal in visibleCalendars where includeObjetivos || !cal.isObjetivo {
            for e in eventsByCalendar[cal.id] ?? [] where e.start < dayEnd && e.end > dayStart {
                out.append(e)
            }
        }
        return out.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
    }

    /// Hitos: eventos all-day de los calendarios "Objetivo ..." que cubren `day`.
    func objetivos(covering day: Date) -> [(nivel: String, evento: CalEvent)] {
        let dayStart = DateKit.startOfDay(day)
        let dayEnd = DateKit.addDays(dayStart, 1)
        var out: [(String, CalEvent)] = []
        for cal in calendars where cal.isObjetivo && !hiddenCalendarIds.contains(cal.id) {
            let nivel = cal.summary.lowercased().contains("semana") ? "SEMANA"
                : cal.summary.lowercased().contains("mes") ? "MES" : "DÍA"
            for e in eventsByCalendar[cal.id] ?? [] where e.start < dayEnd && e.end > dayStart {
                out.append((nivel, e))
            }
        }
        let order = ["MES": 0, "SEMANA": 1, "DÍA": 2]
        return out.sorted { (order[$0.0] ?? 9) < (order[$1.0] ?? 9) }
    }

    func toggleCalendar(_ id: String) {
        if hiddenCalendarIds.contains(id) { hiddenCalendarIds.remove(id) }
        else { hiddenCalendarIds.insert(id) }
        persist()
    }

    var defaultWritableCalendar: CalendarInfo? {
        if let saved = UserDefaults.standard.string(forKey: "sfcal.defaultCalendar"),
           let cal = calendar(saved), cal.canWrite {
            return cal
        }
        return calendars.first { $0.isPrimary && $0.canWrite }
            ?? calendars.first { $0.canWrite }
    }

    // MARK: - Ciclo de sync

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.refreshCalendars()
            await self?.syncTodoist()
            while let self, !Task.isCancelled {
                await self.syncAll()
                self.todoistTick += 1
                if self.todoistTick % 3 == 0 { await self.syncTodoist() }   // ~30s
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - Todoist (espejo de LA pluma de tareas)

    func syncTodoist() async {
        guard let todoist else { return }
        // Metadata (proyectos/etiquetas) para el composer: al arranque y luego cada ~5 min
        if todoistProjects.isEmpty || todoistTick % 30 == 0 {
            if let p = try? await todoist.projects() { todoistProjects = p }
            if let l = try? await todoist.labelNames() { todoistLabels = l }
        }
        // Tablero K: secciones (columnas) + completadas de hoy, cada ciclo — son
        // 2 requests baratos y el tablero es espejo de OTRA pluma (tu agente/iPhone)
        if let s = try? await todoist.sections() { todoistSections = s }
        if let done = try? await todoist.completedToday() { doneToday = done }
        do {
            let all = try await todoist.activeTasks()
            allTasks = all.sorted {
                ($0.due ?? .distantFuture) != ($1.due ?? .distantFuture)
                    ? ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture)
                    : $0.priority > $1.priority
            }
            let from = windowFrom
            let to = windowTo
            let pendingIds = Set(tasks.filter(\.pendingDone).map(\.id))
            var fetched = all
                .filter { t in
                    guard let d = t.due else { return false }
                    return d >= from && d <= to && !pendingIds.contains(t.id)
                }
                .sorted { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
            // Re-aplicar duraciones locales (la API no las devuelve) y podar huérfanas
            for i in fetched.indices where fetched[i].durationMin == nil {
                fetched[i].durationMin = localDurations[fetched[i].id]
            }
            let liveIds = Set(fetched.map(\.id))
            localDurations = localDurations.filter { liveIds.contains($0.key) }
            UserDefaults.standard.set(localDurations, forKey: "sfcal.task.durations")
            tasks = fetched
            todoistError = false
            await taskMirror?.reconcile(tasks: tasks, from: from, to: to)
        } catch {
            todoistError = true   // sensor visible en el sidebar; se conserva lo último leído
        }
    }

    func tasksOn(_ day: Date) -> (timed: [TodoTask], allDay: [TodoTask]) {
        guard todoistVisible else { return ([], []) }
        let s = DateKit.startOfDay(day)
        let e = DateKit.addDays(s, 1)
        let dayTasks = tasks.filter { t in
            guard let d = t.due else { return false }
            return d >= s && d < e
        }
        return (dayTasks.filter(\.hasTime), dayTasks.filter { !$0.hasTime })
    }

    var tasksDueToday: Int {
        tasksOn(Date()).timed.count + tasksOn(Date()).allDay.count
    }

    /// Captura desde sfcal (tecla R): crea en Todoist (LA pluma de tareas) con el
    /// set completo. Optimista; el espejo a Google la proyecta al confirmar.
    func createTask(_ nt: TodoNewTask) {
        guard let todoist else { return }
        var draft = nt
        draft.content = nt.content.trimmingCharacters(in: .whitespaces)
        guard !draft.content.isEmpty else { return }
        let temp = TodoTask(id: "tmp-\(UUID().uuidString)", content: draft.content,
                            due: draft.due, hasTime: draft.hasTime,
                            priority: draft.priority, durationMin: draft.durationMin)
        tasks.append(temp)
        tasks.sort { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
        Task {
            do {
                var real = try await todoist.create(draft)
                if real.durationMin == nil, draft.hasTime, let dur = draft.durationMin {
                    real.durationMin = dur
                    localDurations[real.id] = dur
                    UserDefaults.standard.set(localDurations, forKey: "sfcal.task.durations")
                }
                tasks.removeAll { $0.id == temp.id }
                if let d = real.due, d >= windowFrom, d <= windowTo {
                    tasks.append(real)
                    tasks.sort { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
                }
                showBanner("✓ \"\(draft.content)\" creada en Todoist")
                await taskMirror?.reconcile(tasks: tasks, from: windowFrom, to: windowTo)
            } catch {
                tasks.removeAll { $0.id == temp.id }
                showBanner("Todoist rechazó crear \"\(draft.content)\": \(error)")
            }
        }
    }

    /// Edición optimista de tarea (título, prioridad, fecha/hora, duración local).
    func updateTask(_ task: TodoTask, content: String, priority: Int,
                    due: Date?, hasTime: Bool, durationMin: Int?,
                    description: String? = nil, labels: [String]? = nil) {
        guard let todoist, !task.pendingDone else { return }
        let idx = tasks.firstIndex(where: { $0.id == task.id })
        let original = idx.map { tasks[$0] } ?? task
        var optimistic = original
        optimistic.content = content
        optimistic.priority = priority
        optimistic.due = due
        optimistic.hasTime = hasTime
        optimistic.durationMin = hasTime ? durationMin : nil
        if let description { optimistic.description = description }
        if let labels { optimistic.labels = labels }
        if let idx { tasks[idx] = optimistic }
        if let ai = allTasks.firstIndex(where: { $0.id == task.id }) { allTasks[ai] = optimistic }
        tasks.sort { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
        if hasTime, let dur = durationMin { localDurations[task.id] = dur }
        else { localDurations.removeValue(forKey: task.id) }
        UserDefaults.standard.set(localDurations, forKey: "sfcal.task.durations")
        Task {
            do {
                var real = try await todoist.update(
                    taskId: task.id, content: content, priority: priority,
                    due: due, hasTime: hasTime, description: description, labels: labels)
                if real.durationMin == nil { real.durationMin = localDurations[task.id] }
                if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i] = real }
                if let ai = allTasks.firstIndex(where: { $0.id == task.id }) { allTasks[ai] = real }
                tasks.sort { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
                showBanner("✓ \"\(content)\" actualizada en Todoist")
                await taskMirror?.reconcile(tasks: tasks, from: windowFrom, to: windowTo)
            } catch {
                if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i] = original }
                if let ai = allTasks.firstIndex(where: { $0.id == task.id }) { allTasks[ai] = original }
                showBanner("Todoist rechazó el cambio en \"\(content)\": \(error)")
            }
        }
    }

    func deleteTask(_ task: TodoTask) {
        guard let todoist, !task.pendingDone else { return }
        let original = task
        tasks.removeAll { $0.id == task.id }
        allTasks.removeAll { $0.id == task.id }
        Task {
            do {
                try await todoist.delete(taskId: task.id)
                allTasks.removeAll { $0.id == task.id }
                showBanner("\"\(task.content)\" eliminada de Todoist")
                await taskMirror?.reconcile(tasks: tasks, from: windowFrom, to: windowTo)
            } catch {
                tasks.append(original)
                tasks.sort { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
                showBanner("Todoist rechazó eliminar \"\(task.content)\": \(error)")
            }
        }
    }

    func completeTask(_ task: TodoTask) {
        guard let todoist, !task.pendingDone else { return }
        // Una sin-fecha vive solo en allTasks (bug 16 ago: el guard sobre `tasks`
        // hacía imposible completarla desde el panel Y / Kanban)
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) { tasks[idx].pendingDone = true }
        if let idx = allTasks.firstIndex(where: { $0.id == task.id }) { allTasks[idx].pendingDone = true }
        Task {
            do {
                try await todoist.close(taskId: task.id)
                tasks.removeAll { $0.id == task.id }
                allTasks.removeAll { $0.id == task.id }
                doneToday.insert(task, at: 0)   // al marcador del día, optimista
                showBanner("✓ \"\(task.content)\" completada en Todoist")
            } catch {
                if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[i].pendingDone = false
                }
                if let i = allTasks.firstIndex(where: { $0.id == task.id }) {
                    allTasks[i].pendingDone = false
                }
                showBanner("Todoist rechazó completar \"\(task.content)\": \(error)")
            }
        }
    }

    // MARK: - Kanban (tecla K): el estado del tablero VIVE en Todoist (secciones)

    /// Mueve una tarea a la columna `display` (sección del MISMO nombre en su
    /// proyecto, creada on-demand) o al Backlog (`nil` = root del proyecto).
    /// Optimista cuando la sección ya existe (lookup local, cero red).
    func moveTask(_ task: TodoTask, toColumn display: String?) {
        guard let todoist, !task.pendingDone else { return }
        let original = task.sectionId
        func apply(_ sid: String?) {
            if let i = allTasks.firstIndex(where: { $0.id == task.id }) { allTasks[i].sectionId = sid }
            if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i].sectionId = sid }
        }
        guard let display else {
            guard let pid = task.projectId else { return }
            apply(nil)
            Task {
                do { try await todoist.move(taskId: task.id, toProjectRoot: pid) }
                catch {
                    apply(original)
                    showBanner("Todoist rechazó mover \"\(task.content)\": \(error)")
                }
            }
            return
        }
        let canon = TodoSection.canon(display)
        if let sec = todoistSections.first(where: {
            $0.projectId == task.projectId && TodoSection.canon($0.name) == canon
        }) {
            apply(sec.id)
            Task {
                do { try await todoist.move(taskId: task.id, toSection: sec.id) }
                catch {
                    apply(original)
                    showBanner("Todoist rechazó mover \"\(task.content)\": \(error)")
                }
            }
        } else {
            guard let pid = task.projectId else { return }
            Task {
                do {
                    let sec = try await todoist.createSection(name: display, projectId: pid)
                    todoistSections.append(sec)
                    apply(sec.id)
                    try await todoist.move(taskId: task.id, toSection: sec.id)
                } catch {
                    apply(original)
                    showBanner("Todoist rechazó mover \"\(task.content)\": \(error)")
                }
            }
        }
    }

    /// Saca una tarea de "Hecho hoy" (drag fuera): reopen + move a la columna
    /// destino. El rollback la regresa al marcador.
    func reopenTask(_ task: TodoTask, toColumn display: String?) {
        guard let todoist else { return }
        doneToday.removeAll { $0.id == task.id }
        var revived = task
        revived.pendingDone = false
        allTasks.append(revived)
        Task {
            do {
                try await todoist.reopen(taskId: task.id)
                moveTask(revived, toColumn: display)
                showBanner("↩︎ \"\(task.content)\" reabierta")
                await syncTodoist()
            } catch {
                allTasks.removeAll { $0.id == task.id }
                doneToday.insert(task, at: 0)
                showBanner("Todoist rechazó reabrir \"\(task.content)\": \(error)")
            }
        }
    }

    func refreshCalendars() async {
        var merged: [CalendarInfo] = []
        var anyError: String?
        for account in accounts {
            guard let client = clients[account.id] else { continue }
            do {
                let items = try await client.calendarList()
                // El calendario-proyección NO se pinta en sfcal (las tareas ya son
                // nativas aquí); existe para Google/Apple.
                for it in items where it.hidden != true && (it.summary ?? "") != TaskMirror.marker {
                    let isPrimary = it.primary ?? false
                    let name = isPrimary
                        ? (account.id == "personal" ? "Personal" : "Principal")
                        : (it.summaryOverride ?? it.summary ?? it.id)
                    merged.append(CalendarInfo(
                        id: it.id,
                        accountId: account.id,
                        summary: name,
                        bgColorHex: it.backgroundColor ?? "#8C27F1",
                        fgColorHex: it.foregroundColor ?? "#ffffff",
                        accessRole: it.accessRole ?? "reader",
                        isPrimary: it.primary ?? false
                    ))
                }
            } catch {
                anyError = "\(account.email): \(error)"
            }
        }
        if !merged.isEmpty {
            merged.sort { a, b in
                if a.accountId != b.accountId { return a.accountId < b.accountId }
                if a.isPrimary != b.isPrimary { return a.isPrimary }
                return a.summary.localizedCaseInsensitiveCompare(b.summary) == .orderedAscending
            }
            calendars = merged
        }
        if let anyError { health = .error(anyError) }
    }

    func syncAll() async {
        guard !calendars.isEmpty else { await refreshCalendars(); return }
        var failures: [String] = []
        await withTaskGroup(of: (String, Result<([GEvent], String?, Bool), Error>).self) { group in
            for cal in calendars {
                guard let client = clients[cal.accountId] else { continue }
                let token = syncTokens[cal.id]
                let from = windowFrom, to = windowTo
                group.addTask {
                    do {
                        if let token {
                            let (evs, newTok) = try await client.delta(calendarId: cal.id, syncToken: token)
                            return (cal.id, .success((evs, newTok, true)))
                        } else {
                            let (evs, newTok) = try await client.windowEvents(calendarId: cal.id, from: from, to: to)
                            return (cal.id, .success((evs, newTok, false)))
                        }
                    } catch {
                        return (cal.id, .failure(error))
                    }
                }
            }
            for await (calId, result) in group {
                guard let cal = calendar(calId) else { continue }
                switch result {
                case .success(let (gevents, newToken, isDelta)):
                    if isDelta {
                        let current = eventsByCalendar[calId] ?? []
                        if !gevents.isEmpty {
                            eventsByCalendar[calId] = SyncMerge.apply(
                                current: current, delta: gevents,
                                calendarId: calId, accountId: cal.accountId)
                        }
                    } else {
                        eventsByCalendar[calId] = gevents
                            .compactMap { $0.toCalEvent(calendarId: calId, accountId: cal.accountId) }
                            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
                    }
                    if let newToken { syncTokens[calId] = newToken }
                case .failure(let error):
                    if case SFError.gone = error {
                        syncTokens[calId] = nil   // proximo ciclo re-fetchea la ventana completa
                    } else {
                        failures.append("\(cal.summary): \(error)")
                    }
                }
            }
        }
        if failures.isEmpty {
            let now = Date()
            lastSyncAt = now
            health = .ok(now)
        } else {
            health = .error(failures.joined(separator: " · "))
        }
        persist()
    }

    private func persist() {
        var state = CacheState()
        state.calendars = calendars
        state.events = eventsByCalendar
        state.syncTokens = syncTokens
        state.hiddenCalendarIds = hiddenCalendarIds
        state.savedAt = lastSyncAt ?? .distantPast
        let snapshot = state
        Task.detached(priority: .utility) { DiskCache.save(snapshot) }
    }

    func showBanner(_ text: String) {
        banner = text
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self?.banner = nil }
        }
    }

    // MARK: - Escritura optimista (el cambio se pinta al instante; si Google
    // rechaza, se revierte VISIBLEMENTE con banner)

    private func upsertLocal(_ event: CalEvent) {
        var list = eventsByCalendar[event.calendarId] ?? []
        list.removeAll { $0.id == event.id }
        list.append(event)
        list.sort { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
        eventsByCalendar[event.calendarId] = list
    }

    private func removeLocal(_ event: CalEvent) {
        eventsByCalendar[event.calendarId]?.removeAll { $0.id == event.id }
    }

    private func timeBody(start: Date, end: Date, isAllDay: Bool) -> [String: Any] {
        if isAllDay {
            return [
                "start": ["date": GDate.formatDay(start)],
                "end": ["date": GDate.formatDay(max(end, DateKit.addDays(start, 1)))],
            ]
        }
        let tz = TimeZone.current.identifier
        return [
            "start": ["dateTime": GDate.format(start), "timeZone": tz],
            "end": ["dateTime": GDate.format(end), "timeZone": tz],
        ]
    }

    func createEvent(calendarId: String, title: String, start: Date, end: Date, isAllDay: Bool,
                     description: String = "", location: String = "",
                     recurrence: [String] = [], attendees: [String] = []) {
        guard let cal = calendar(calendarId), let client = clients[cal.accountId] else { return }
        let tempId = "tmp-\(UUID().uuidString)"
        var draft = CalEvent(
            id: tempId, calendarId: calendarId, accountId: cal.accountId,
            summary: title.isEmpty ? "(sin título)" : title,
            start: start, end: end, isAllDay: isAllDay, status: "confirmed",
            notes: description.isEmpty ? nil : description,
            location: location.isEmpty ? nil : location)
        draft.pending = true
        upsertLocal(draft)
        UserDefaults.standard.set(calendarId, forKey: "sfcal.defaultCalendar")
        Task {
            var body = timeBody(start: start, end: end, isAllDay: isAllDay)
            body["summary"] = draft.summary
            if !description.isEmpty { body["description"] = description }
            if !location.isEmpty { body["location"] = location }
            if !recurrence.isEmpty { body["recurrence"] = recurrence }
            if !attendees.isEmpty { body["attendees"] = attendees.map { ["email": $0] } }
            do {
                let g = try await client.insert(calendarId: calendarId, body: body)
                removeLocal(draft)
                if let real = g.toCalEvent(calendarId: calendarId, accountId: cal.accountId) {
                    upsertLocal(real)
                }
                if !recurrence.isEmpty {
                    // La serie expande instancias que este insert no devuelve: sync ya
                    requestSyncNow()
                }
            } catch {
                removeLocal(draft)
                showBanner("No se pudo crear \"\(draft.summary)\": \(error)")
            }
        }
    }

    func requestSyncNow() {
        Task { await syncAll() }
    }

    func moveEvent(_ event: CalEvent, newStart: Date, newEnd: Date) {
        guard !event.pending, let client = clients[event.accountId] else { return }
        let original = event
        var moved = event
        moved.start = newStart
        moved.end = newEnd
        moved.pending = true
        upsertLocal(moved)
        Task {
            do {
                let g = try await client.patch(
                    calendarId: event.calendarId, eventId: event.id,
                    body: timeBody(start: newStart, end: newEnd, isAllDay: event.isAllDay))
                removeLocal(moved)
                if let real = g.toCalEvent(calendarId: event.calendarId, accountId: event.accountId) {
                    upsertLocal(real)
                }
            } catch {
                upsertLocal(original)
                showBanner("Google rechazó mover \"\(event.summary)\": \(error)")
            }
        }
    }

    func updateEvent(_ event: CalEvent, title: String, start: Date, end: Date, calendarId: String,
                     description: String? = nil, location: String? = nil) {
        guard !event.pending, let client = clients[event.accountId] else { return }
        let original = event
        let targetCalendarChanged = calendarId != event.calendarId

        var updated = event
        updated.summary = title
        updated.start = start
        updated.end = end
        if let description { updated.notes = description.isEmpty ? nil : description }
        if let location { updated.location = location.isEmpty ? nil : location }
        updated.pending = true
        removeLocal(original)
        updated.calendarId = targetCalendarChanged ? calendarId : event.calendarId
        upsertLocal(updated)
        Task {
            do {
                var currentCalId = event.calendarId
                if targetCalendarChanged {
                    _ = try await client.move(
                        calendarId: event.calendarId, eventId: event.id, destination: calendarId)
                    currentCalId = calendarId
                }
                var body = timeBody(start: start, end: end, isAllDay: event.isAllDay)
                body["summary"] = title
                if let description { body["description"] = description }
                if let location { body["location"] = location }
                let g = try await client.patch(calendarId: currentCalId, eventId: event.id, body: body)
                removeLocal(updated)
                if let real = g.toCalEvent(calendarId: currentCalId, accountId: event.accountId) {
                    upsertLocal(real)
                }
            } catch {
                removeLocal(updated)
                upsertLocal(original)
                showBanner("Google rechazó el cambio en \"\(title)\": \(error)")
            }
        }
    }

    func deleteEvent(_ event: CalEvent) {
        guard !event.pending, let client = clients[event.accountId] else { return }
        let original = event
        removeLocal(event)
        Task {
            do {
                try await client.delete(calendarId: event.calendarId, eventId: event.id)
                showBanner("\"\(event.summary)\" eliminado")
            } catch {
                upsertLocal(original)
                showBanner("Google rechazó eliminar \"\(event.summary)\": \(error)")
            }
        }
    }

    // MARK: - Modo headless (CLI)

    func syncOnceHeadless() async -> (calendars: Int, events: Int, errors: [String]) {
        await refreshCalendars()
        await syncAll()
        await syncTodoist()
        let total = eventsByCalendar.values.reduce(0) { $0 + $1.count }
        var errs: [String] = []
        if case .error(let m) = health { errs.append(m) }
        return (calendars.count, total, errs)
    }
}
