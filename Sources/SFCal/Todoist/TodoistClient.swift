import Foundation

/// Todoist es LA pluma de tareas (fuente única, la opera Levy/el iPhone).
/// sfcal la ESPEJA: lee, muestra y puede COMPLETAR. Jamás duplica tareas
/// hacia Google ni crea una tercera fuente de verdad.
struct TodoTask: Codable, Identifiable, Hashable {
    let id: String
    var content: String
    var due: Date?
    var hasTime: Bool
    var priority: Int          // API: 4 = p1 urgente … 1 = p4
    var pendingDone: Bool = false
}

enum TodoistDue {
    /// v1: `due.date` puede venir "2026-08-15", "2026-08-15T14:00:00" (naive local)
    /// o RFC3339 con offset. Devuelve (fecha, tieneHora).
    static func parse(_ raw: String) -> (Date, Bool)? {
        if raw.contains("T") {
            if let d = GDate.parse(raw) { return (d, true) }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            if let d = f.date(from: raw) { return (d, true) }
            return nil
        }
        if let d = GDate.dayOnly.date(from: raw) { return (d, false) }
        return nil
    }
}

final class TodoistClient {
    private let token: String

    init?() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sfcal/todoist.token")
        guard let t = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        token = t
    }

    private func request(_ path: String, method: String = "GET",
                         json: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.todoist.com/api/v1/\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw SFError.http(code, String(String(data: data, encoding: .utf8)?.prefix(200) ?? ""))
        }
        return data
    }

    private static let naiveLocal: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// Crea una tarea (captura rápida desde sfcal, tecla R). Va al Inbox:
    /// el triage a proyectos es de la revisión del domingo / de Levy.
    func create(content: String, due: Date?, hasTime: Bool) async throws -> TodoTask {
        var body: [String: Any] = ["content": content, "priority": 3]   // p2 en la UI
        if let due {
            if hasTime { body["due_datetime"] = Self.naiveLocal.string(from: due) }
            else { body["due_date"] = GDate.formatDay(due) }
        }
        struct RawDue: Codable { let date: String? }
        struct Raw: Codable { let id: String; let content: String; let due: RawDue?; let priority: Int? }
        let data = try await request("tasks", method: "POST", json: body)
        let r = try JSONDecoder().decode(Raw.self, from: data)
        var d: Date?
        var t = false
        if let raw = r.due?.date, let (pd, pt) = TodoistDue.parse(raw) { d = pd; t = pt }
        return TodoTask(id: r.id, content: r.content, due: d, hasTime: t, priority: r.priority ?? 3)
    }

    func activeTasks() async throws -> [TodoTask] {
        struct RawDue: Codable { let date: String? }
        struct Raw: Codable { let id: String; let content: String; let due: RawDue?; let priority: Int? }
        struct Page: Codable { let results: [Raw]?; let next_cursor: String? }
        var out: [TodoTask] = []
        var cursor: String?
        for _ in 0..<10 {
            var path = "tasks?limit=200"
            if let cursor,
               let enc = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                path += "&cursor=\(enc)"
            }
            let page = try JSONDecoder().decode(Page.self, from: try await request(path))
            for r in page.results ?? [] {
                var due: Date?
                var hasTime = false
                if let raw = r.due?.date, let (d, t) = TodoistDue.parse(raw) {
                    due = d
                    hasTime = t
                }
                out.append(TodoTask(id: r.id, content: r.content, due: due,
                                    hasTime: hasTime, priority: r.priority ?? 1))
            }
            cursor = page.next_cursor
            if cursor == nil { break }
        }
        return out
    }

    func close(taskId: String) async throws {
        _ = try await request("tasks/\(taskId)/close", method: "POST")
    }
}
