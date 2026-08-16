import Foundation

/// Todoist es LA pluma de tareas (fuente única, la opera tu agente/el iPhone).
/// sfcal la ESPEJA: lee, muestra y puede COMPLETAR. Jamás duplica tareas
/// hacia Google ni crea una tercera fuente de verdad.
struct TodoTask: Codable, Identifiable, Hashable {
    let id: String
    var content: String
    var description: String = ""
    var labels: [String] = []
    var projectId: String?
    var sectionId: String?     // columna del Kanban (sección de Todoist)
    var due: Date?
    var hasTime: Bool
    var priority: Int          // API: 4 = p1 urgente … 1 = p4
    var durationMin: Int?
    var pendingDone: Bool = false
}

struct TodoProject: Codable, Identifiable, Hashable {
    let id: String
    let name: String
}

/// Sección de Todoist = COLUMNA del Kanban (tecla K). El estado del tablero
/// vive en Todoist, jamás local: secciones del mismo nombre en proyectos
/// distintos se AGREGAN en una sola columna global.
struct TodoSection: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let projectId: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case projectId = "project_id"
    }

    /// Nombre canónico para AGRUPAR secciones entre proyectos ("💡 Ideas" y
    /// "ideas" son la misma columna): minúsculas, sin emoji/símbolos/acentos.
    static func canon(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: .init(identifier: "es"))
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Parámetros completos de creación (lo que la API v1 permite y usamos).
struct TodoNewTask {
    var content: String
    var description: String = ""
    var projectId: String?          // nil = Inbox
    var priority: Int = 1           // API: 1=p4 … 4=p1
    var labels: [String] = []
    var due: Date?
    var hasTime: Bool = false
    var durationMin: Int?           // solo aplica con hora
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

    /// Crea una tarea con el set completo que la API v1 permite (tecla R).
    func create(_ nt: TodoNewTask) async throws -> TodoTask {
        var body: [String: Any] = ["content": nt.content, "priority": nt.priority]
        if !nt.description.isEmpty { body["description"] = nt.description }
        if let p = nt.projectId { body["project_id"] = p }
        if !nt.labels.isEmpty { body["labels"] = nt.labels }
        if let due = nt.due {
            if nt.hasTime {
                body["due_datetime"] = Self.naiveLocal.string(from: due)
                if let dur = nt.durationMin, dur > 0 {
                    body["duration"] = dur
                    body["duration_unit"] = "minute"
                }
            } else {
                body["due_date"] = GDate.formatDay(due)
            }
        }
        let data = try await request("tasks", method: "POST", json: body)
        return Self.toTask(try JSONDecoder().decode(RawTask.self, from: data))
    }

    private struct RawDue: Codable { let date: String? }
    private struct RawDuration: Codable { let amount: Int?; let unit: String? }
    private struct RawTask: Codable {
        let id: String
        let content: String
        let description: String?
        let labels: [String]?
        let project_id: String?
        let section_id: String?
        let due: RawDue?
        let priority: Int?
        let duration: RawDuration?
    }

    private static func toTask(_ r: RawTask) -> TodoTask {
        var due: Date?
        var hasTime = false
        if let raw = r.due?.date, let (d, t) = TodoistDue.parse(raw) {
            due = d
            hasTime = t
        }
        var durMin: Int?
        if let d = r.duration, let amount = d.amount {
            durMin = (d.unit == "day") ? amount * 24 * 60 : amount
        }
        return TodoTask(id: r.id, content: r.content,
                        description: r.description ?? "", labels: r.labels ?? [],
                        projectId: r.project_id, sectionId: r.section_id,
                        due: due, hasTime: hasTime,
                        priority: r.priority ?? 1, durationMin: durMin)
    }

    func activeTasks() async throws -> [TodoTask] {
        struct Page: Codable { let results: [RawTask]?; let next_cursor: String? }
        var out: [TodoTask] = []
        var cursor: String?
        for _ in 0..<10 {
            var path = "tasks?limit=200"
            if let cursor,
               let enc = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                path += "&cursor=\(enc)"
            }
            let page = try JSONDecoder().decode(Page.self, from: try await request(path))
            out += (page.results ?? []).map(Self.toTask)
            cursor = page.next_cursor
            if cursor == nil { break }
        }
        return out
    }

    func projects() async throws -> [TodoProject] {
        struct Page: Codable { let results: [TodoProject]? }
        let data = try await request("projects?limit=100")
        return (try JSONDecoder().decode(Page.self, from: data)).results ?? []
    }

    func labelNames() async throws -> [String] {
        struct L: Codable { let name: String }
        struct Page: Codable { let results: [L]? }
        let data = try await request("labels?limit=100")
        return (try JSONDecoder().decode(Page.self, from: data)).results?.map(\.name) ?? []
    }

    func close(taskId: String) async throws {
        _ = try await request("tasks/\(taskId)/close", method: "POST")
    }

    /// Reabre una completada (sacarla de "Hecho hoy" en el Kanban).
    func reopen(taskId: String) async throws {
        _ = try await request("tasks/\(taskId)/reopen", method: "POST")
    }

    func sections() async throws -> [TodoSection] {
        struct Page: Codable { let results: [TodoSection]?; let next_cursor: String? }
        var out: [TodoSection] = []
        var cursor: String?
        for _ in 0..<5 {
            var path = "sections?limit=200"
            if let cursor,
               let enc = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                path += "&cursor=\(enc)"
            }
            let page = try JSONDecoder().decode(Page.self, from: try await request(path))
            out += page.results ?? []
            cursor = page.next_cursor
            if cursor == nil { break }
        }
        return out
    }

    func createSection(name: String, projectId: String) async throws -> TodoSection {
        let data = try await request("sections", method: "POST",
                                     json: ["name": name, "project_id": projectId])
        return try JSONDecoder().decode(TodoSection.self, from: data)
    }

    /// Mueve una tarea a una sección (columna) o al root de su proyecto
    /// (Backlog). Endpoint oficial /move, verificado 16 ago (HTTP 200 ida y
    /// vuelta); acepta EXACTAMENTE uno de section_id/project_id.
    func move(taskId: String, toSection sectionId: String) async throws {
        _ = try await request("tasks/\(taskId)/move", method: "POST",
                              json: ["section_id": sectionId])
    }

    func move(taskId: String, toProjectRoot projectId: String) async throws {
        _ = try await request("tasks/\(taskId)/move", method: "POST",
                              json: ["project_id": projectId])
    }

    /// Completadas de HOY (columna "Hecho" del Kanban: marcador del día, no
    /// archivo). Shape verificado 16 ago: {items:[<task con completed_at>]}.
    func completedToday() async throws -> [TodoTask] {
        struct Page: Codable { let items: [RawTask]? }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: Date())
        let path = "tasks/completed/by_completion_date?since=\(day)T00:00:00&until=\(day)T23:59:59"
        let page = try JSONDecoder().decode(Page.self, from: try await request(path))
        return (page.items ?? []).map(Self.toTask)
    }

    /// Edita una tarea existente (título, prioridad, fecha/hora). El proyecto no
    /// se mueve por aquí (la API pide su endpoint de move; V2).
    func update(taskId: String, content: String, priority: Int,
                due: Date?, hasTime: Bool,
                description: String? = nil, labels: [String]? = nil) async throws -> TodoTask {
        var body: [String: Any] = ["content": content, "priority": priority]
        if let description { body["description"] = description }
        if let labels { body["labels"] = labels }
        if let due {
            if hasTime { body["due_datetime"] = Self.naiveLocal.string(from: due) }
            else { body["due_date"] = GDate.formatDay(due) }
        }
        let data = try await request("tasks/\(taskId)", method: "POST", json: body)
        return Self.toTask(try JSONDecoder().decode(RawTask.self, from: data))
    }

    /// El borrado NO vive en REST (DELETE /tasks → 405, verificado 15 ago): va por
    /// el endpoint de sync con el comando item_delete.
    func delete(taskId: String) async throws {
        let body: [String: Any] = ["commands": [[
            "type": "item_delete",
            "uuid": UUID().uuidString,
            "args": ["id": taskId],
        ]]]
        _ = try await request("sync", method: "POST", json: body)
    }
}
