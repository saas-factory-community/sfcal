import SwiftUI

enum CalViewMode: String, CaseIterable, Identifiable {
    case year, month, week, fourDay, day, agenda, tasks, kanban
    var id: String { rawValue }

    var label: String {
        switch self {
        case .year: return "Año"
        case .month: return "Mes"
        case .week: return "Semana"
        case .fourDay: return "4 días"
        case .day: return "Día"
        case .agenda: return "Agenda"
        case .tasks: return "Tareas"
        case .kanban: return "Flujo"
        }
    }

    /// Atajos keyboard-first: 1 Año · 2 Mes · 3 Semana · 4 Cuatro días ·
    /// 5 Día · 6 Agenda · Y Tareas · K Flujo.
    var key: String {
        switch self {
        case .year: return "1"
        case .month: return "2"
        case .week: return "3"
        case .fourDay: return "4"
        case .day: return "5"
        case .agenda: return "6"
        case .tasks: return "Y"
        case .kanban: return "K"
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
    /// Tarea abierta en el panel de detalle (overlay global, reutiliza
    /// TaskDetailPane del panel Y). Esc lo cierra.
    @Published var detailTaskId: String?
    /// Sidebar de calendarios visible (⇧⌘V / botón junto a las flechas).
    @Published var sidebarVisible: Bool {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "sfcal.sidebarVisible") }
    }
    /// Zoom de las vistas de tiempo (⌘+/⌘-/⌘0): altura de la hora en px, persistida.
    @Published var hourHeight: CGFloat {
        didSet { UserDefaults.standard.set(Double(hourHeight), forKey: "sfcal.hourHeight") }
    }

    init() {
        let saved = UserDefaults.standard.double(forKey: "sfcal.hourHeight")
        hourHeight = saved == 0 ? 60 : CGFloat(min(max(saved, 36), 140))
        sidebarVisible = UserDefaults.standard.object(forKey: "sfcal.sidebarVisible") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "sfcal.sidebarVisible")
    }

    func zoomIn() { withAnimation(.easeOut(duration: 0.12)) { hourHeight = min(140, (hourHeight * 1.15).rounded()) } }
    func zoomOut() { withAnimation(.easeOut(duration: 0.12)) { hourHeight = max(36, (hourHeight / 1.15).rounded()) } }
    func zoomReset() { withAnimation(.easeOut(duration: 0.12)) { hourHeight = 60 } }

    /// Escala TIPOGRÁFICA del contenido del grid, amarrada al mismo zoom (⌘+/⌘-).
    /// Piso 0.9× y techo 1.35×: la letra crece con el zoom sin romper bloques cortos.
    /// El CHROME (sidebar, header, popovers) NO escala a propósito — marcos fijos.
    var fontScale: CGFloat { min(1.35, max(0.9, hourHeight / 60)) }

    var isEditingSomething: Bool { editingEventId != nil || draft != nil || taskDraft != nil }

    func goToday() {
        withAnimation(.easeOut(duration: 0.15)) {
            // En semana, "hoy" re-alinea a lunes (con hoy adentro); el scroll la desliza
            focusDate = mode == .week ? DateKit.startOfWeek(Date()) : Date()
        }
    }

    /// Paneo GRADUAL por días (scroll horizontal, 15 ago pm): la ventana visible se
    /// desliza de a UN día — en semana la vuelve rodante hasta que re-alinees con
    /// flechas (±7) o con H.
    func scrollDays(_ direction: Int) {
        focusDate = DateKit.addDays(focusDate, direction)
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
            case .tasks: break      // el panel no navega periodos
            case .kanban: break     // el flujo tampoco
            }
        }
    }

    private var previousMode: CalViewMode = .week

    func setMode(_ m: CalViewMode) {
        withAnimation(.easeOut(duration: 0.15)) {
            // Toggle-back (15 ago pm): la MISMA tecla otra vez regresa a la vista
            // anterior (K → Flujo, K → de vuelta a donde estabas). Aplica a todas.
            let target: CalViewMode
            if m == mode {
                target = previousMode
            } else {
                target = m
            }
            guard target != mode else { return }
            previousMode = mode
            if target == .week { focusDate = DateKit.startOfWeek(focusDate) }  // entrada alineada
            mode = target
        }
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
        case .tasks:
            return "Tareas"
        case .kanban:
            return "Flujo"
        }
    }
}
