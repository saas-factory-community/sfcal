import Foundation

/// ESPEJO DE UNA VÍA Todoist → Google Calendar (principio de Daniel, 15 ago:
/// "todo sincronizado" — la tarea debe verse en Google y por herencia en Apple).
///
/// Reglas que evitan el monstruo del sync bidireccional (incidente Todoist↔Board):
/// 1. UNA VÍA ESTRICTA: aquí solo se ESCRIBE la proyección; jamás se lee de vuelta
///    como fuente. Todoist sigue siendo la única pluma de tareas.
/// 2. Calendario DEDICADO ("Tareas · Todoist") en la cuenta personal: no ensucia
///    ningún calendario real y Apple/iPhone lo heredan solos vía Google.
/// 3. Idempotencia por huella: cada evento-espejo lleva
///    extendedProperties.private.todoistId. Eventos sin huella NO se tocan.
/// 4. sfcal OCULTA este calendario de su propia UI (las tareas ya se pintan
///    nativas); existe para Google/Apple, no para sfcal.
/// 5. Tarea completada/borrada → su espejo se borra en el siguiente reconcile.
final class TaskMirror {
    static let marker = "Tareas · Todoist"
    private let client: GCalClient
    private(set) var calendarId: String?

    init(client: GCalClient) {
        self.client = client
        calendarId = UserDefaults.standard.string(forKey: "sfcal.mirror.calendar")
    }

    private func ensure() async throws -> String {
        if let calendarId { return calendarId }
        let list = try await client.calendarList()
        if let found = list.first(where: { ($0.summary ?? "") == Self.marker }) {
            calendarId = found.id
        } else {
            let id = try await client.createCalendar(summary: Self.marker)
            await client.setCalendarColorBestEffort(calendarId: id, colorId: "3")
            calendarId = id
        }
        UserDefaults.standard.set(calendarId, forKey: "sfcal.mirror.calendar")
        return calendarId!
    }

    private func desiredBody(_ t: TodoTask, due: Date) -> [String: Any] {
        var body: [String: Any] = [
            "summary": "○ \(t.content)",
            "description": "Espejo de Todoist — la tarea vive en Todoist (sfcal la proyecta; completa allá y este evento se borra solo).",
            "extendedProperties": ["private": ["todoistId": t.id]],
        ]
        if t.hasTime {
            let tz = TimeZone.current.identifier
            body["start"] = ["dateTime": GDate.format(due), "timeZone": tz]
            body["end"] = ["dateTime": GDate.format(due.addingTimeInterval(1800)), "timeZone": tz]
        } else {
            body["start"] = ["date": GDate.formatDay(due)]
            body["end"] = ["date": GDate.formatDay(DateKit.addDays(due, 1))]
        }
        return body
    }

    /// Reconcilia la proyección con el estado actual de tareas. Best effort:
    /// si falla, el siguiente ciclo (~30s) reintenta. Devuelve el calendarId.
    @discardableResult
    func reconcile(tasks: [TodoTask], from: Date, to: Date) async -> String? {
        do {
            let calId = try await ensure()
            let (gevents, _) = try await client.windowEvents(calendarId: calId, from: from, to: to)
            var mirrorByTask: [String: GEvent] = [:]
            for g in gevents {
                if let tid = g.extendedProperties?.privateProps?["todoistId"] {
                    mirrorByTask[tid] = g
                }
            }
            var keep = Set<String>()
            for t in tasks where !t.pendingDone {
                guard let due = t.due, due >= from, due <= to else { continue }
                keep.insert(t.id)
                let body = desiredBody(t, due: due)
                if let existing = mirrorByTask[t.id] {
                    let existingStart = (existing.start?.dateTime ?? existing.start?.date)
                        .flatMap(GDate.parse)
                    let existingHasTime = existing.start?.dateTime != nil
                    let drift = existingStart.map { abs($0.timeIntervalSince(due)) > 60 } ?? true
                    if existing.summary != "○ \(t.content)" || drift || existingHasTime != t.hasTime {
                        _ = try? await client.patch(calendarId: calId, eventId: existing.id, body: body)
                    }
                } else {
                    _ = try? await client.insert(calendarId: calId, body: body)
                }
            }
            for (tid, g) in mirrorByTask where !keep.contains(tid) {
                try? await client.delete(calendarId: calId, eventId: g.id)
            }
            return calId
        } catch {
            return nil
        }
    }
}
