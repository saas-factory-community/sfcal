import Foundation

/// Espejo en disco para pintar al instante en frio. NUNCA es fuente de verdad:
/// Google manda; esto solo evita el spinner.
struct CacheState: Codable {
    var calendars: [CalendarInfo] = []
    var events: [String: [CalEvent]] = [:]
    var syncTokens: [String: String] = [:]
    var hiddenCalendarIds: Set<String> = []
    var savedAt: Date = .distantPast
}

enum DiskCache {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".sfcal/cache/state.json")
    }

    static func load() -> CacheState? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheState.self, from: d)
    }

    static func save(_ s: CacheState) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(s) else { return }
        let tmp = dir.appendingPathComponent("state.tmp.\(UUID().uuidString.prefix(6))")
        do {
            try d.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
