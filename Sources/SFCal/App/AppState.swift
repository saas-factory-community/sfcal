import SwiftUI

enum CalViewMode: String, CaseIterable, Identifiable {
    case year, month, week, fourDay, day, agenda
    var id: String { rawValue }

    var label: String {
        switch self {
        case .year: return "Año"
        case .month: return "Mes"
        case .week: return "Semana"
        case .fourDay: return "4 días"
        case .day: return "Día"
        case .agenda: return "Agenda"
        }
    }

    /// Atajo numérico (esquema de Daniel, 15 ago): 1 Año · 2 Mes · 3 Semana ·
    /// 4 Cuatro días · 5 Día · 6 Agenda.
    var key: String {
        switch self {
        case .year: return "1"
        case .month: return "2"
        case .week: return "3"
        case .fourDay: return "4"
        case .day: return "5"
        case .agenda: return "6"
        }
    }
}

struct DraftEvent: Identifiable, Equatable {
    let id = UUID()
    var title: String = ""
    var start: Date
    var end: Date
    var isAllDay: Bool = false
    var calendarId: String
}

/// Borrador de TAREA (captura rápida a Todoist, tecla R). Default sin hora:
/// captura GTD sin fricción; la hora es opt-in.
struct TaskDraft: Identifiable, Equatable {
    let id = UUID()
    var content: String = ""
    var day: Date = Date()
    var withTime: Bool = false
    var time: Date = Date()
}

@MainActor
final class AppState: ObservableObject {
    @Published var mode: CalViewMode = .week
    @Published var focusDate: Date = Date()
    @Published var selectedEventId: String?
    @Published var editingEventId: String?
    @Published var draft: DraftEvent?
    @Published var taskDraft: TaskDraft?

    var isEditingSomething: Bool { editingEventId != nil || draft != nil || taskDraft != nil }

    func goToday() {
        withAnimation(.easeOut(duration: 0.15)) { focusDate = Date() }
    }

    func step(_ direction: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            switch mode {
            case .year: focusDate = DateKit.cal.date(byAdding: .year, value: direction, to: focusDate) ?? focusDate
            case .month: focusDate = DateKit.addMonths(focusDate, direction)
            case .week: focusDate = DateKit.addWeeks(focusDate, direction)
            case .fourDay: focusDate = DateKit.addDays(focusDate, direction * 4)
            case .day: focusDate = DateKit.addDays(focusDate, direction)
            case .agenda: focusDate = DateKit.addDays(focusDate, direction * 7)
            }
        }
    }

    func setMode(_ m: CalViewMode) {
        withAnimation(.easeOut(duration: 0.15)) { mode = m }
    }

    var title: String {
        switch mode {
        case .year:
            return String(DateKit.cal.component(.year, from: focusDate))
        case .month, .week, .agenda:
            let anchor = mode == .week ? DateKit.weekDays(focusDate)[3] : focusDate
            return DateKit.cap(DateKit.monthYear.string(from: anchor))
        case .fourDay:
            return DateKit.cap(DateKit.monthYear.string(from: focusDate))
        case .day:
            return DateKit.cap(DateKit.fullDay.string(from: focusDate))
        }
    }
}
