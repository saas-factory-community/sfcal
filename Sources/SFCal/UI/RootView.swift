import SwiftUI

private struct SnapshotHoursKey: EnvironmentKey {
    static let defaultValue: ClosedRange<Double>? = nil
}

extension EnvironmentValues {
    /// Al fijarse (modo --snapshot), la vista de tiempo pinta esas horas sin scroll.
    var sfcalSnapshotHours: ClosedRange<Double>? {
        get { self[SnapshotHoursKey.self] }
        set { self[SnapshotHoursKey.self] = newValue }
    }
}

struct RootView: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        let p = theme.palette
        // TopBar de ANCHO COMPLETO (simetría 16 ago): semáforos, logo y todos los
        // controles en UNA sola línea; el sidebar y el contenido viven debajo.
        VStack(spacing: 0) {
            HeaderBar()
            HStack(alignment: .top, spacing: 0) {
                if appState.sidebarVisible {
                    SidebarView()
                        .frame(width: 236)
                        .transition(.move(edge: .leading))
                    Rectangle()
                        .fill(p.border)
                        .frame(width: 1)
                }
                VStack(spacing: 0) {
                    HitosBand()
                    mainContent
                }
            }
        }
        .background(p.bg)
        .environment(\.colorScheme, p.isDark ? .dark : .light)
        .overlay(alignment: .bottom) { bannerView }
        .overlay { draftOverlay }
        .overlay { detailOverlay }
        .ignoresSafeArea()
    }

    /// Overlay GLOBAL de detalle de tarea (reutiliza TaskDetailPane del panel Y):
    /// cualquier vista lo abre con appState.detailTaskId. Esc / backdrop cierran.
    @ViewBuilder
    private var detailOverlay: some View {
        let p = theme.palette
        if let id = appState.detailTaskId {
            ZStack {
                Color.black.opacity(p.isDark ? 0.45 : 0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { appState.detailTaskId = nil }
                if let task = store.allTasks.first(where: { $0.id == id }) {
                    TaskDetailPane(task: task) { appState.detailTaskId = nil }
                        .id(task.id)
                        .frame(width: 410, height: 560)
                        .background(RoundedRectangle(cornerRadius: 13).fill(p.card))
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(p.border, lineWidth: 1))
                        .shadow(color: .black.opacity(p.isDark ? 0.55 : 0.25), radius: 30, y: 10)
                        .offset(y: -30)
                } else {
                    // La tarea se completó/eliminó con el panel abierto: cerrar solo
                    Color.clear.onAppear { appState.detailTaskId = nil }
                }
            }
            .transition(.opacity)
            .animation(.easeOut(duration: 0.12), value: appState.detailTaskId)
        }
    }

    /// Overlay central DETERMINISTA para los drafts de teclado (E evento, R tarea).
    /// Los popovers desde anclas invisibles no montaban y dejaban el estado
    /// huérfano bloqueando el teclado (bug 15 ago): backdrop + card, cero magia.
    @ViewBuilder
    private var draftOverlay: some View {
        let p = theme.palette
        if appState.draft != nil || appState.taskDraft != nil {
            ZStack {
                Color.black.opacity(p.isDark ? 0.45 : 0.25)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.draft = nil
                        appState.taskDraft = nil
                    }
                Group {
                    if let d = appState.draft {
                        EventEditorView(mode: .draft)
                            .id(d.id)
                    } else if let t = appState.taskDraft {
                        TaskCreatePopover(draft: t)
                            .id(t.id)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(p.border, lineWidth: 1))
                .shadow(color: .black.opacity(p.isDark ? 0.55 : 0.25), radius: 30, y: 10)
                .offset(y: -60)
            }
            .transition(.opacity)
            .animation(.easeOut(duration: 0.12), value: appState.draft)
            .animation(.easeOut(duration: 0.12), value: appState.taskDraft)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        // SIN .id() por fecha en las vistas de tiempo: forzar identidad nueva por día
        // destruía y recreaba el grid entero en cada paso del paneo (el "parpadeo",
        // 15 ago pm). Sin él, SwiftUI difea en su lugar: smooth, y el scroll vertical
        // se conserva al navegar (comportamiento Google).
        switch appState.mode {
        case .day:
            TimelineGridView(days: [DateKit.startOfDay(appState.focusDate)])
        case .fourDay:
            TimelineGridView(days: (0..<4).map { DateKit.addDays(DateKit.startOfDay(appState.focusDate), $0) })
        case .week:
            // Ventana RODANTE de 7 días desde focusDate: el scroll horizontal la
            // desliza día a día; flechas/H/tecla 3 la dejan alineada a lunes
            TimelineGridView(days: (0..<7).map { DateKit.addDays(DateKit.startOfDay(appState.focusDate), $0) })
        case .month:
            MonthView()
        case .year:
            YearView()
        case .agenda:
            AgendaView()
                .id("agenda-\(DateKit.startOfDay(appState.focusDate).timeIntervalSince1970)")
        case .tasks:
            TasksPanelView()
        case .kanban:
            KanbanView()
        }
    }

    @ViewBuilder
    private var bannerView: some View {
        if let text = store.banner {
            let p = theme.palette
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(p.textPrimary)
                .lineLimit(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(p.card)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(p.border, lineWidth: 1))
                        .shadow(color: .black.opacity(p.isDark ? 0.5 : 0.15), radius: 14, y: 4)
                )
                .padding(.bottom, 18)
                .frame(maxWidth: 560)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeOut(duration: 0.2), value: store.banner)
        }
    }
}

/// El lockup del TopBar usa el ICONO REAL de la app (el mismo .icns del Dock,
/// leído del bundle) para que jamás vuelvan a divergir (reporte 16 ago: el
/// dibujo custom del sidebar no coincidía con la barra de tareas). En el
/// binario suelto de `swift run` (snapshots) no hay bundle → LogoMark.
struct AppLockup: View {
    @EnvironmentObject var theme: ThemeManager
    var body: some View {
        HStack(spacing: 8) {
            if Bundle.main.bundleURL.pathExtension == "app" {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
            } else {
                LogoMark(size: 22)
            }
            Text("sfcal")
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(theme.palette.textPrimary)
                .tracking(0.2)
        }
    }
}

/// Botón de icono del header con HOVER de verdad (fondo + borde al pasar,
/// pedido 16 ago): un botón que no reacciona parece adorno.
struct HeaderIconButton: View {
    let symbol: String
    var tint: Color
    var help: String
    let action: () -> Void
    @EnvironmentObject var theme: ThemeManager
    @State private var hover = false

    var body: some View {
        let p = theme.palette
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(hover ? p.textPrimary : tint)
                .frame(width: 27, height: 27)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(hover ? p.card : .clear))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(hover ? p.border : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.1), value: hover)
    }
}

struct HeaderBar: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        let p = theme.palette
        // DOS segmentos (calibración 16 ago):
        // el tramo sobre el sidebar lleva SU MISMO surface (columna blanca
        // continua, sin hairline horizontal cruzándola) y contiene semáforos +
        // lockup; el divisor vertical sube hasta el tope; el toggle y todo lo
        // demás viven A LA DERECHA de esa línea, sobre el bg del contenido.
        HStack(alignment: .top, spacing: 0) {
            if appState.sidebarVisible {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 58, height: 1)   // zona de los semáforos
                    AppLockup()
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .frame(width: 236, height: 47)
                .background(p.surface)
                .transition(.move(edge: .leading))
                Rectangle().fill(p.border).frame(width: 1, height: 47)
            } else {
                Color.clear.frame(width: 70, height: 1)       // solo los semáforos
            }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    HeaderIconButton(symbol: "sidebar.leading",
                                     tint: appState.sidebarVisible ? p.textSecondary : p.accent,
                                     help: "Mostrar/ocultar calendarios (⇧⌘B)") {
                        withAnimation(.easeOut(duration: 0.15)) { appState.sidebarVisible.toggle() }
                    }
                    HStack(spacing: 2) {
                        HeaderIconButton(symbol: "chevron.left", tint: p.textSecondary,
                                         help: "Anterior") { appState.step(-1) }
                        HeaderIconButton(symbol: "chevron.right", tint: p.textSecondary,
                                         help: "Siguiente") { appState.step(1) }
                    }
                    Button(action: { appState.goToday() }) {
                        Text("Hoy")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(p.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).stroke(p.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    titleView(palette: p)
                        .padding(.leading, 4)

                    Spacer()

                    modeSwitcher
                    themeButton
                    avatarBadge(palette: p)
                }
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .frame(height: 46)
                Rectangle().fill(p.border).frame(height: 1)
            }
        }
        // Doble click en el VACÍO del header = zoom. Vive en un BACKGROUND
        // (hermano de los controles), jamás en el contenedor: un TapGesture(2)
        // en el ancestro obliga a esperar el timeout de doble click antes de
        // entregar el click a los botones hijos — era la latencia que se
        // sentía en el botón del sidebar y no en el atajo (cazado 16 ago).
        .background(
            Color.clear
                .contentShape(Rectangle())
                .gesture(TapGesture(count: 2).onEnded {
                    NSApp.keyWindow?.zoom(nil)
                })
        )
    }

    /// "Agosto" bold + "2026" light: el contraste tipográfico que separa un título
    /// diseñado de una etiqueta default (crítico round 2).
    @ViewBuilder
    private func titleView(palette p: Palette) -> some View {
        let full = appState.title
        let parts = full.split(separator: " ").map(String.init)
        if appState.mode != .day, parts.count >= 2, let year = parts.last, Int(year) != nil {
            HStack(spacing: 6) {
                Text(parts.dropLast().joined(separator: " "))
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(p.textPrimary)
                Text(year)
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(p.textSecondary)
            }
        } else {
            Text(full)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(p.textPrimary)
        }
    }

    private func avatarBadge(palette p: Palette) -> some View {
        let emails = store.accounts.map(\.email)
        let initial = emails.first?.first.map { String($0).uppercased() } ?? "•"
        return Text(initial)
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(p.textPrimary)
            .frame(width: 27, height: 27)
            .background(Circle().fill(p.card))
            .overlay(Circle().stroke(p.accent.opacity(0.65), lineWidth: 1.3))
            .help(emails.isEmpty ? "Sin cuentas" : emails.joined(separator: " + "))
    }

    private var modeSwitcher: some View {
        let p = theme.palette
        return HStack(spacing: 2) {
            ForEach(CalViewMode.allCases) { mode in
                Button(action: { appState.setMode(mode) }) {
                    HStack(spacing: 5) {
                        Text(mode.label)
                            .font(.system(size: 12, weight: .semibold))
                        Text(mode.key)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(appState.mode == mode ? p.gold : p.textMuted)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill((appState.mode == mode ? p.gold : p.textMuted).opacity(0.14)))
                    }
                    .foregroundStyle(appState.mode == mode ? p.textPrimary : p.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(appState.mode == mode ? p.card : .clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(appState.mode == mode ? p.accent.opacity(0.55) : .clear,
                                            lineWidth: 1))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(p.border, lineWidth: 1))
    }

    private var themeButton: some View {
        let p = theme.palette
        return Button(action: { theme.toggle() }) {
            Image(systemName: p.isDark ? "sun.max" : "moon")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(p.textSecondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).stroke(p.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Alternar tema (⌘⇧T)")
    }
}
