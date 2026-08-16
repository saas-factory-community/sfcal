import AppKit
import Combine
import ServiceManagement
import SwiftUI

enum LaunchMode {
    case gui
    case syncOnce
    case snapshot(view: String, path: String, light: Bool)
    case roundtrip(calendarId: String)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var launchMode: LaunchMode = .gui
    var window: NSWindow?
    let store = EventStore()
    let appState = AppState()
    let theme = ThemeManager()
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var hScrollAccum: CGFloat = 0
    private var hScrollConsumed = false
    private var lastScrollAt: TimeInterval = 0
    private var lastDayStepAt: TimeInterval = 0
    private var themeCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch launchMode {
        case .gui:
            startGUI()
        case .syncOnce:
            runSyncOnce()
        case .snapshot(let view, let path, let light):
            runSnapshot(view: view, path: path, light: light)
        case .roundtrip(let calendarId):
            runRoundtrip(calendarId: calendarId, title: "sfcal round-trip ✓")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // residente: cerrar la ventana no mata la app
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    // MARK: - GUI

    private func startGUI() {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        let root = RootView()
            .environmentObject(store)
            .environmentObject(appState)
            .environmentObject(theme)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 1040, height: 640)
        w.title = "sfcal"
        w.contentView = NSHostingView(rootView: root)
        w.setFrameAutosaveName("sfcal.main")
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        // Semáforos CENTRADOS con el TopBar (simetría 16 ago): AppKit los pinta
        // arriba; los bajamos al eje del renglón y re-aplicamos en cada evento
        // que los resetea (resize, fullscreen, tema).
        centerTrafficLights()
        for name in [NSWindow.didResizeNotification,
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.didEndLiveResizeNotification,
                     NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: w, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.centerTrafficLights() }
            }
        }
        store.start()
        installKeyMonitor()
        installScrollMonitor()
        registerLoginItemIfBundled()
        // La APARIENCIA de NSApp sigue al tema: los popovers son ventanas nuevas
        // que NO heredan el colorScheme de la vista — sin esto, en tema claro los
        // controles del sistema (DatePicker, checkbox, placeholders) renderizaban
        // OSCUROS sobre la card blanca (bug 16 ago).
        applyAppearance(theme.isDark)
        themeCancellable = theme.$isDark.sink { [weak self] dark in
            self?.applyAppearance(dark)
        }
    }

    private func applyAppearance(_ dark: Bool) {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    // MARK: - Scroll horizontal = navegar el periodo (mouse tilt / trackpad)

    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScroll(event) ? nil : event
        }
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard NSApp.keyWindow === window, !appState.isEditingSomething else { return false }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        let now = ProcessInfo.processInfo.systemUptime

        // Gesto nuevo: fase began (trackpad) o silencio >0.35s (mouse sin fases)
        let isNewGesture = event.phase == .began ||
            (event.phase == [] && event.momentumPhase == [] && now - lastScrollAt > 0.35)
        if isNewGesture {
            hScrollAccum = 0
            hScrollConsumed = false
        }
        lastScrollAt = now

        // Solo gestos con dominancia horizontal clara; lo vertical pasa intacto al grid
        guard abs(dx) > abs(dy) * 1.4, abs(dx) > 0.4 else { return false }

        // Tablero K / panel Y: SIN paneo de días — el gesto pasa intacto a la
        // vista (el K tiene su propio ScrollView horizontal; tragarlo aquí dejaba la
        // última columna inalcanzable, bug 16 ago)
        if [.kanban, .tasks].contains(appState.mode) { return false }
        hScrollAccum += dx

        // Vistas de tiempo: paneo GRADUAL por días con CONTROL (calibrado 15 ago pm:
        // "ruedo poquito y me manda un chingo de días"). Tres frenos profesionales:
        // umbral alto + UN día por tick + rate-limit 90ms entre días (girar rápido
        // avanza ESTABLE ~10 días/s máx, jamás en ráfaga).
        if [.day, .fourDay, .week].contains(appState.mode) {
            // Calibración "lento y de a poquito" (afinada en uso real):
            // varios ticks de rueda por día + máx ~5 días/seg sostenido
            let perDay: CGFloat = event.hasPreciseScrollingDeltas ? 140 : 180
            if abs(hScrollAccum) >= perDay, now - lastDayStepAt > 0.18 {
                let dir = hScrollAccum < 0 ? 1 : -1
                appState.scrollDays(dir)
                lastDayStepAt = now
                hScrollAccum += CGFloat(dir) * perDay
                // El sobrante nunca guarda más de ~un día: cero ráfagas de arrastre
                hScrollAccum = max(min(hScrollAccum, perDay * 0.9), -perDay * 0.9)
            }
            return true
        }

        // Resto de vistas (mes/año/agenda): un gesto = un periodo, como antes
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 55 : 8
        if !hScrollConsumed && abs(hScrollAccum) > threshold {
            hScrollConsumed = true
            appState.step(hScrollAccum < 0 ? 1 : -1)
        }
        return true
    }

    // MARK: - Teclado (bare keys estilo Notion Calendar)

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        // Jamás robar teclas mientras se escribe en un campo
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSText { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if mods == [.command, .shift] && chars == "t" { theme.toggle(); return true }
        if mods == [.command, .shift] && chars == "b" {   // ⇧⌘B = sidebar (16 ago;
            // B como en VS Code)
            withAnimation(.easeOut(duration: 0.15)) { appState.sidebarVisible.toggle() }
            return true
        }
        if mods == .command && chars == "n" { newEventNow(); return true }
        if mods == .command {
            switch chars {
            case "+", "=": appState.zoomIn(); return true
            case "-": appState.zoomOut(); return true
            case "0": appState.zoomReset(); return true
            default: break
            }
        }
        // Flechas traen .numericPad/.function; limpiarlos para tratar todo como bare key.
        // OJO: no se bloquea por "estar editando" — si un campo tiene el foco, el
        // check de first-responder de arriba ya nos sacó. Un guard extra de estado
        // dejó las teclas muertas cuando un draft quedaba huérfano (bug 15 ago).
        guard mods.subtracting([.numericPad, .function]).isEmpty else { return false }

        switch event.keyCode {
        case 123: appState.step(-1); return true   // ←
        case 124: appState.step(1); return true    // →
        case 51:                                    // delete
            if let id = appState.selectedEventId, let ev = store.event(byId: id) {
                store.deleteEvent(ev)
                appState.selectedEventId = nil
                return true
            }
            return false
        case 53:                                    // esc: cierra detalle/drafts, luego selección
            if appState.detailTaskId != nil {
                appState.detailTaskId = nil
                return true
            }
            if appState.isEditingSomething {
                appState.draft = nil
                appState.taskDraft = nil
                appState.editingEventId = nil
                return true
            }
            appState.selectedEventId = nil
            return false
        default: break
        }

        // Esquema keyboard-first: 1-6 vistas · E evento · R tarea · T tema · H hoy
        switch chars {
        case "1": appState.setMode(.year); return true
        case "2": appState.setMode(.month); return true
        case "3": appState.setMode(.week); return true
        case "4": appState.setMode(.fourDay); return true
        case "5": appState.setMode(.day); return true
        case "6": appState.setMode(.agenda); return true
        case "e": newEventNow(); return true
        case "r": newTaskDraft(); return true
        case "t": theme.toggle(); return true
        case "h": appState.goToday(); return true
        case "y": appState.setMode(.tasks); return true      // Y = panel de tareas (16 ago)
        case "k": appState.setMode(.kanban); return true     // K = Kanban de flujo (16 ago)
        // Aliases legacy (memoria muscular de Google Calendar)
        case "d": appState.setMode(.day); return true
        case "w": appState.setMode(.week); return true
        default: return false
        }
    }

    /// Baja los 3 botones estándar de la ventana para que su centro caiga en el
    /// eje Y del TopBar (altura 46 → centro 23pt desde arriba). AppKit los
    /// regresa a su lugar en varios eventos; los observers re-llaman esto.
    private func centerTrafficLights() {
        guard let w = window else { return }
        let desiredCenterFromTop: CGFloat = 23
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let btn = w.standardWindowButton(type), let sv = btn.superview else { continue }
            let inWindow = sv.convert(btn.frame, to: nil)
            let currentCenterFromTop = w.frame.height - inWindow.midY
            let delta = desiredCenterFromTop - currentCenterFromTop
            guard abs(delta) > 0.5 else { continue }
            var f = btn.frame
            f.origin.y += sv.isFlipped ? delta : -delta
            btn.frame = f
        }
    }

    private func newTaskDraft() {
        guard store.todoistAvailable else {
            store.showBanner("Todoist no está configurado (~/.sfcal/todoist.token)")
            return
        }
        appState.taskDraft = TaskDraft(day: appState.focusDate)
    }

    @objc private func menuNewEvent() { newEventNow() }
    @objc private func menuNewTask() { newTaskDraft() }
    @objc private func menuYear() { appState.setMode(.year) }
    @objc private func menuDay() { appState.setMode(.day) }
    @objc private func menuFourDay() { appState.setMode(.fourDay) }
    @objc private func menuWeek() { appState.setMode(.week) }
    @objc private func menuMonth() { appState.setMode(.month) }
    @objc private func menuAgenda() { appState.setMode(.agenda) }
    @objc private func menuTasks() { appState.setMode(.tasks) }
    @objc private func menuKanban() { appState.setMode(.kanban) }
    @objc private func menuToggleSidebar() {
        withAnimation(.easeOut(duration: 0.15)) { appState.sidebarVisible.toggle() }
    }
    @objc private func menuToday() { appState.goToday() }
    @objc private func menuTheme() { theme.toggle() }
    @objc private func menuZoomIn() { appState.zoomIn() }
    @objc private func menuZoomOut() { appState.zoomOut() }
    @objc private func menuZoomReset() { appState.zoomReset() }

    private func newEventNow() {
        guard let cal = store.defaultWritableCalendar else { return }
        let now = Date()
        let minute = DateKit.cal.component(.minute, from: now)
        let rounded = DateKit.cal.date(byAdding: .minute, value: (15 - minute % 15) % 15, to: now) ?? now
        appState.draft = DraftEvent(
            start: rounded,
            end: rounded.addingTimeInterval(3600),
            calendarId: cal.id)
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Acerca de sfcal",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ocultar sfcal", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Salir de sfcal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let evItem = NSMenuItem()
        main.addItem(evItem)
        let evMenu = NSMenu(title: "Crear")
        let nuevo = NSMenuItem(title: "Nuevo evento  (E)", action: #selector(menuNewEvent), keyEquivalent: "n")
        nuevo.target = self
        evMenu.addItem(nuevo)
        let tarea = NSMenuItem(title: "Nueva tarea Todoist  (R)", action: #selector(menuNewTask), keyEquivalent: "")
        tarea.target = self
        evMenu.addItem(tarea)
        evItem.submenu = evMenu

        let verItem = NSMenuItem()
        main.addItem(verItem)
        let verMenu = NSMenu(title: "Ver")
        for (title, sel) in [("Año  (1)", #selector(menuYear)),
                             ("Mes  (2)", #selector(menuMonth)),
                             ("Semana  (3)", #selector(menuWeek)),
                             ("4 días  (4)", #selector(menuFourDay)),
                             ("Día  (5)", #selector(menuDay)),
                             ("Agenda  (6)", #selector(menuAgenda)),
                             ("Tareas  (Y)", #selector(menuTasks)),
                             ("Flujo  (K)", #selector(menuKanban)),
                             ("Hoy  (H)", #selector(menuToday))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            verMenu.addItem(item)
        }
        verMenu.addItem(.separator())
        for (title, sel, key) in [("Acercar", #selector(menuZoomIn), "+"),
                                  ("Alejar", #selector(menuZoomOut), "-"),
                                  ("Tamaño real", #selector(menuZoomReset), "0")] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.target = self
            verMenu.addItem(item)
        }
        verMenu.addItem(.separator())
        let sidebar = NSMenuItem(title: "Mostrar/ocultar calendarios",
                                 action: #selector(menuToggleSidebar), keyEquivalent: "b")
        sidebar.keyEquivalentModifierMask = [.command, .shift]
        sidebar.target = self
        verMenu.addItem(sidebar)
        let tema = NSMenuItem(title: "Alternar tema  (T)", action: #selector(menuTheme), keyEquivalent: "t")
        tema.keyEquivalentModifierMask = [.command, .shift]
        tema.target = self
        verMenu.addItem(tema)
        verItem.submenu = verMenu

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "Ventana")
        winMenu.addItem(withTitle: "Minimizar", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        winItem.submenu = winMenu

        NSApp.mainMenu = main
    }

    private func registerLoginItemIfBundled() {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }

    // MARK: - Modos CLI

    private func runSyncOnce() {
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let r = await store.syncOnceHeadless()
            print("calendars=\(r.calendars) events=\(r.events)")
            for c in store.calendars {
                print("  \(c.summary) [\(c.accountId)] → \(store.eventsByCalendar[c.id]?.count ?? 0) eventos")
            }
            if !r.errors.isEmpty {
                print("errors: \(r.errors.joined(separator: " | "))")
                exit(1)
            }
            exit(0)
        }
    }

    /// Evidencia round-trip: ejercita el MISMO pipeline optimista del store que
    /// disparan los gestos de la UI (crear → mover → borrar), imprimiendo el id real.
    func runRoundtrip(calendarId: String, title: String) {
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            _ = await store.syncOnceHeadless()
            guard store.calendar(calendarId) != nil else {
                print("RT_FAIL calendario \(calendarId) no existe")
                exit(1)
            }
            let start = DateKit.cal.date(byAdding: .hour, value: 3, to: Date())!
            let end = start.addingTimeInterval(3600)

            store.createEvent(calendarId: calendarId, title: title, start: start, end: end, isAllDay: false)
            try? await Task.sleep(for: .seconds(4))
            guard let created = (store.eventsByCalendar[calendarId] ?? [])
                .first(where: { $0.summary == title && !$0.pending && !$0.id.hasPrefix("tmp-") }) else {
                print("RT_FAIL el evento no confirmó contra Google")
                exit(1)
            }
            print("RT_CREATED id=\(created.id) start=\(GDate.format(created.start))")

            store.moveEvent(created, newStart: created.start.addingTimeInterval(5400),
                            newEnd: created.end.addingTimeInterval(5400))
            try? await Task.sleep(for: .seconds(4))
            guard let moved = (store.eventsByCalendar[calendarId] ?? [])
                .first(where: { $0.id == created.id && !$0.pending }) else {
                print("RT_FAIL el move no confirmó")
                exit(1)
            }
            print("RT_MOVED id=\(moved.id) start=\(GDate.format(moved.start)) (+90 min)")
            print("RT_OK")
            exit(0)
        }
    }

    private func runSnapshot(view: String, path: String, light: Bool) {
        NSApp.setActivationPolicy(.prohibited)
        theme.isDark = !light
        appState.hourHeight = 60   // el canvas del snapshot asume el zoom default
        Task { @MainActor in
            _ = await store.syncOnceHeadless()
            switch view {
            case "day": appState.mode = .day
            case "month": appState.mode = .month
            case "year": appState.mode = .year
            case "4day": appState.mode = .fourDay
            case "agenda": appState.mode = .agenda
            case "tasks": appState.mode = .tasks
            case "kanban": appState.mode = .kanban
            case "flujo": appState.mode = .kanban
            case "rtask":
                appState.mode = .week
                appState.taskDraft = TaskDraft(day: Date())
            default: appState.mode = .week
            }
            appState.focusDate = Date()
            let content = RootView()
                .environment(\.sfcalSnapshotHours, 5.0...21.0)
                .environmentObject(store)
                .environmentObject(appState)
                .environmentObject(theme)
                .frame(width: 1600, height: appState.mode == .month ? 1000 : 1120)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            if let img = renderer.nsImage,
               let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("SNAPSHOT_OK \(path)")
                exit(0)
            }
            print("SNAPSHOT_FAIL")
            exit(1)
        }
    }
}

extension EventStore {
    func event(byId id: String) -> CalEvent? {
        for list in eventsByCalendar.values {
            if let e = list.first(where: { $0.id == id }) { return e }
        }
        return nil
    }
}
