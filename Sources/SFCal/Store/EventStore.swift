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
    @Published var todoistError = false
    @Published var todoistVisible: Bool {
        didSet { UserDefaults.standard.set(todoistVisible, forKey: "sfcal.todoist.visible") }
    }

    let accounts: [CalAccount]
    let todoistAvailable: Bool
    private let todoist: TodoistClient?
    private var taskMirror: TaskMirror?
    private var todoistTick = 0
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
        do {
            let all = try await todoist.activeTasks()
            let from = windowFrom
            let to = windowTo
            let pendingIds = Set(tasks.filter(\.pendingDone).map(\.id))
            tasks = all
                .filter { t in
                    guard let d = t.due else { return false }
                    return d >= from && d <= to && !pendingIds.contains(t.id)
                }
                .sorted { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
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

    /// Captura rápida (tecla R): crea en Todoist (LA pluma de tareas). Optimista.
    /// El espejo a Google la proyecta en el siguiente reconcile (~30s).
    func createTask(content: String, due: Date?, hasTime: Bool) {
        guard let todoist else { return }
        let clean = content.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        var temp = TodoTask(id: "tmp-\(UUID().uuidString)", content: clean,
                            due: due, hasTime: hasTime, priority: 3)
        temp.pendingDone = false
        tasks.append(temp)
        tasks.sort { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
        Task {
            do {
                let real = try await todoist.create(content: clean, due: due, hasTime: hasTime)
                tasks.removeAll { $0.id == temp.id }
                if let d = real.due, d >= windowFrom, d <= windowTo {
                    tasks.append(real)
                    tasks.sort { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
                }
                showBanner("✓ \"\(clean)\" creada en Todoist")
                await taskMirror?.reconcile(tasks: tasks, from: windowFrom, to: windowTo)
            } catch {
                tasks.removeAll { $0.id == temp.id }
                showBanner("Todoist rechazó crear \"\(clean)\": \(error)")
            }
        }
    }

    func completeTask(_ task: TodoTask) {
        guard let todoist, !task.pendingDone else { return }
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx].pendingDone = true
        Task {
            do {
                try await todoist.close(taskId: task.id)
                tasks.removeAll { $0.id == task.id }
                showBanner("✓ \"\(task.content)\" completada en Todoist")
            } catch {
                if let i = tasks.firstIndex(where: { $0.id == task.id }) {
                    tasks[i].pendingDone = false
                }
                showBanner("Todoist rechazó completar \"\(task.content)\": \(error)")
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

    func createEvent(calendarId: String, title: String, start: Date, end: Date, isAllDay: Bool) {
        guard let cal = calendar(calendarId), let client = clients[cal.accountId] else { return }
        let tempId = "tmp-\(UUID().uuidString)"
        var draft = CalEvent(
            id: tempId, calendarId: calendarId, accountId: cal.accountId,
            summary: title.isEmpty ? "(sin título)" : title,
            start: start, end: end, isAllDay: isAllDay, status: "confirmed")
        draft.pending = true
        upsertLocal(draft)
        UserDefaults.standard.set(calendarId, forKey: "sfcal.defaultCalendar")
        Task {
            var body = timeBody(start: start, end: end, isAllDay: isAllDay)
            body["summary"] = draft.summary
            do {
                let g = try await client.insert(calendarId: calendarId, body: body)
                removeLocal(draft)
                if let real = g.toCalEvent(calendarId: calendarId, accountId: cal.accountId) {
                    upsertLocal(real)
                }
            } catch {
                removeLocal(draft)
                showBanner("No se pudo crear \"\(draft.summary)\": \(error)")
            }
        }
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

    func updateEvent(_ event: CalEvent, title: String, start: Date, end: Date, calendarId: String) {
        guard !event.pending, let client = clients[event.accountId] else { return }
        let original = event
        let targetCalendarChanged = calendarId != event.calendarId

        var updated = event
        updated.summary = title
        updated.start = start
        updated.end = end
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
