import Foundation

struct GCalendarListItem: Codable {
    let id: String
    let summary: String?
    let summaryOverride: String?
    let backgroundColor: String?
    let foregroundColor: String?
    let accessRole: String?
    let primary: Bool?
    let hidden: Bool?
}

struct GEventTime: Codable {
    var date: String?
    var dateTime: String?
    var timeZone: String?
}

struct GExtendedProps: Codable {
    let privateProps: [String: String]?
    enum CodingKeys: String, CodingKey { case privateProps = "private" }
}

struct GEvent: Codable {
    let id: String
    let etag: String?
    let status: String?
    let summary: String?
    let description: String?
    let location: String?
    let start: GEventTime?
    let end: GEventTime?
    let recurringEventId: String?
    let updated: String?
    let extendedProperties: GExtendedProps?
}

struct GEventsPage: Codable {
    let items: [GEvent]?
    let nextPageToken: String?
    let nextSyncToken: String?
}

extension GEvent {
    func toCalEvent(calendarId: String, accountId: String) -> CalEvent? {
        guard status != "cancelled" else { return nil }
        let allDay = start?.date != nil
        guard let s = (start?.dateTime ?? start?.date).flatMap(GDate.parse) else { return nil }
        let e = (end?.dateTime ?? end?.date).flatMap(GDate.parse) ?? s.addingTimeInterval(3600)
        return CalEvent(
            id: id, calendarId: calendarId, accountId: accountId,
            summary: summary ?? "(sin título)", start: s, end: max(e, s),
            isAllDay: allDay, status: status ?? "confirmed",
            recurringEventId: recurringEventId, etag: etag,
            notes: description, location: location,
            updated: updated.flatMap(GDate.parse)
        )
    }
}

/// Merge puro de un delta incremental sobre el estado actual (testeable).
enum SyncMerge {
    static func apply(current: [CalEvent], delta: [GEvent], calendarId: String, accountId: String) -> [CalEvent] {
        var byId = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for g in delta {
            if g.status == "cancelled" {
                byId.removeValue(forKey: g.id)
            } else if let e = g.toCalEvent(calendarId: calendarId, accountId: accountId) {
                byId[e.id] = e
            }
        }
        return byId.values.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
    }
}

final class GCalClient {
    let auth: OAuthSession
    let accountId: String

    init(auth: OAuthSession, accountId: String) {
        self.auth = auth
        self.accountId = accountId
    }

    private static let idAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: Self.idAllowed) ?? s
    }

    private func request(_ path: String, query: [String: String] = [:],
                         method: String = "GET", json: [String: Any]? = nil) async throws -> Data {
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/\(path)")!
        if !query.isEmpty {
            comps.percentEncodedQueryItems = query.map {
                URLQueryItem(name: $0.key,
                             value: $0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
            }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        let bearer = try await auth.token()
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 410 { throw SFError.gone }
        guard (200..<300).contains(code) else {
            throw SFError.http(code, String(String(data: data, encoding: .utf8)?.prefix(300) ?? ""))
        }
        return data
    }

    func calendarList() async throws -> [GCalendarListItem] {
        struct Page: Codable { let items: [GCalendarListItem]? }
        let data = try await request("users/me/calendarList",
                                     query: ["maxResults": "100", "showHidden": "false"])
        return (try JSONDecoder().decode(Page.self, from: data)).items ?? []
    }

    func windowEvents(calendarId: String, from: Date, to: Date) async throws -> (events: [GEvent], syncToken: String?) {
        var all: [GEvent] = []
        var pageToken: String?
        var syncToken: String?
        repeat {
            var q = [
                "singleEvents": "true",
                "showDeleted": "true",   // debe COINCIDIR con el delta para que el syncToken valga
                "timeMin": GDate.format(from),
                "timeMax": GDate.format(to),
                "maxResults": "2500",
            ]
            if let pageToken { q["pageToken"] = pageToken }
            let data = try await request("calendars/\(enc(calendarId))/events", query: q)
            let page = try JSONDecoder().decode(GEventsPage.self, from: data)
            all += page.items ?? []
            pageToken = page.nextPageToken
            if let t = page.nextSyncToken { syncToken = t }
        } while pageToken != nil
        return (all, syncToken)
    }

    func delta(calendarId: String, syncToken: String) async throws -> (events: [GEvent], syncToken: String?) {
        var all: [GEvent] = []
        var pageToken: String?
        var newToken: String?
        repeat {
            // showDeleted: las cancelaciones DEBEN llegar en el delta o los borrados
            // hechos fuera de sfcal se quedarían pintados para siempre
            var q = ["singleEvents": "true", "showDeleted": "true",
                     "syncToken": syncToken, "maxResults": "2500"]
            if let pageToken { q["pageToken"] = pageToken }
            let data = try await request("calendars/\(enc(calendarId))/events", query: q)
            let page = try JSONDecoder().decode(GEventsPage.self, from: data)
            all += page.items ?? []
            pageToken = page.nextPageToken
            if let t = page.nextSyncToken { newToken = t }
        } while pageToken != nil
        return (all, newToken)
    }

    func insert(calendarId: String, body: [String: Any]) async throws -> GEvent {
        let data = try await request("calendars/\(enc(calendarId))/events", method: "POST", json: body)
        return try JSONDecoder().decode(GEvent.self, from: data)
    }

    func patch(calendarId: String, eventId: String, body: [String: Any]) async throws -> GEvent {
        let data = try await request("calendars/\(enc(calendarId))/events/\(enc(eventId))",
                                     method: "PATCH", json: body)
        return try JSONDecoder().decode(GEvent.self, from: data)
    }

    func move(calendarId: String, eventId: String, destination: String) async throws -> GEvent {
        let data = try await request(
            "calendars/\(enc(calendarId))/events/\(enc(eventId))/move",
            query: ["destination": destination], method: "POST")
        return try JSONDecoder().decode(GEvent.self, from: data)
    }

    func delete(calendarId: String, eventId: String) async throws {
        _ = try await request("calendars/\(enc(calendarId))/events/\(enc(eventId))", method: "DELETE")
    }

    func createCalendar(summary: String) async throws -> String {
        struct C: Codable { let id: String }
        let data = try await request("calendars", method: "POST", json: ["summary": summary])
        return try JSONDecoder().decode(C.self, from: data).id
    }

    /// Best effort: color del calendario en la lista del usuario (grape ≈ morado).
    func setCalendarColorBestEffort(calendarId: String, colorId: String) async {
        _ = try? await request("users/me/calendarList/\(enc(calendarId))",
                               method: "PATCH", json: ["colorId": colorId])
    }
}
