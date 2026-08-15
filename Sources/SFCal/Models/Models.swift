import Foundation

struct CalAccount: Codable, Identifiable, Hashable {
    let id: String        // "personal" | "empresa"
    let email: String
}

struct CalendarInfo: Codable, Identifiable, Hashable {
    let id: String        // google calendar id
    let accountId: String
    var summary: String
    var bgColorHex: String
    var fgColorHex: String
    var accessRole: String
    var isPrimary: Bool

    /// Los calendarios "Objetivo del dia/semana/mes" alimentan la banda de hitos,
    /// no la fila de all-day.
    var isObjetivo: Bool { summary.lowercased().hasPrefix("objetivo") }
    var canWrite: Bool { accessRole == "owner" || accessRole == "writer" }
}

struct CalEvent: Codable, Identifiable, Hashable {
    var id: String
    var calendarId: String
    var accountId: String
    var summary: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var status: String
    var recurringEventId: String?
    var etag: String?
    var notes: String?
    var location: String?
    var updated: Date?
    var pending: Bool = false     // op optimista en vuelo

    var duration: TimeInterval { end.timeIntervalSince(start) }
}
