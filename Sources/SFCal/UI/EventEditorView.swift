import SwiftUI

enum Recurrencia: String, CaseIterable, Identifiable {
    case nunca, diario, semanal, lunAVie, mensual
    var id: String { rawValue }

    var label: String {
        switch self {
        case .nunca: return "No se repite"
        case .diario: return "Todos los días"
        case .semanal: return "Semanal (este día)"
        case .lunAVie: return "Lun a vie"
        case .mensual: return "Mensual (mismo día)"
        }
    }

    var rule: String? {
        switch self {
        case .nunca: return nil
        case .diario: return "RRULE:FREQ=DAILY"
        case .semanal: return "RRULE:FREQ=WEEKLY"
        case .lunAVie: return "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        case .mensual: return "RRULE:FREQ=MONTHLY"
        }
    }
}

/// Editor de eventos al nivel del composer de Google Calendar: título, descripción,
/// lugar, todo-el-día, calendario, recurrencia e invitados (crear). En edición:
/// título, descripción, lugar, fechas y calendario. Meet/visibilidad = V2.
struct EventEditorView: View {
    enum Mode {
        case draft
        case edit(CalEvent)
    }

    let mode: Mode

    @EnvironmentObject var store: EventStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    @State private var title = ""
    @State private var descripcion = ""
    @State private var lugar = ""
    @State private var invitados = ""
    @State private var recurrencia: Recurrencia = .nunca
    @State private var allDay = false
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var calendarId = ""
    @State private var loaded = false

    private var isDraft: Bool {
        if case .draft = mode { return true }
        return false
    }

    private var editedEvent: CalEvent? {
        if case .edit(let e) = mode { return e }
        return nil
    }

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 12) {
            // Título + descripción
            VStack(alignment: .leading, spacing: 5) {
                TextField("Agregar título", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(p.textPrimary)
                    .onSubmit { save() }
                TextField("Descripción (opcional)", text: $descripcion, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.textSecondary)
            }

            // Lugar
            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 10))
                    .foregroundStyle(p.textMuted)
                TextField("Agregar lugar", text: $lugar)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.textSecondary)
            }

            Rectangle().fill(p.border).frame(height: 1)

            // Fechas
            VStack(alignment: .leading, spacing: 8) {
                if allDay {
                    labeled("Día") {
                        DatePicker("", selection: $start, displayedComponents: [.date])
                            .labelsHidden()
                    }
                } else {
                    labeled("Empieza") {
                        DatePicker("", selection: $start, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }
                    labeled("Termina") {
                        DatePicker("", selection: $end,
                                   in: start.addingTimeInterval(5 * 60)...,
                                   displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }
                }
                if isDraft {
                    Toggle(isOn: $allDay) {
                        Text("todo el día")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(p.textSecondary)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            // Calendario + recurrencia
            HStack(spacing: 8) {
                labeled("Calendario") { calendarPicker }
                if isDraft {
                    shell(palette: p) {
                        Menu {
                            ForEach(Recurrencia.allCases) { r in
                                Button(r.label) { recurrencia = r }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "repeat")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(recurrencia == .nunca ? p.textMuted : p.accent)
                                Text(recurrencia.label)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(p.textPrimary)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }

            // Invitados (solo crear)
            if isDraft {
                HStack(spacing: 6) {
                    Image(systemName: "person.2")
                        .font(.system(size: 10))
                        .foregroundStyle(p.textMuted)
                    TextField("Invitados: correos separados por coma", text: $invitados)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(p.textSecondary)
                }
            }

            Rectangle().fill(p.border).frame(height: 1)

            // Acciones
            HStack {
                if let e = editedEvent {
                    Button(role: .destructive, action: {
                        store.deleteEvent(e)
                        close()
                    }) {
                        Text("Eliminar")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(p.bad)
                    }
                    .buttonStyle(.plain)
                    if e.recurringEventId != nil {
                        Text("· solo esta instancia")
                            .font(.system(size: 10))
                            .foregroundStyle(p.textMuted)
                    }
                } else {
                    Text(resumen)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(p.textMuted)
                        .lineLimit(2)
                }
                Spacer()
                Button(action: close) {
                    Text("Cancelar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.textSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button(action: save) {
                    Text(isDraft ? "Crear" : "Guardar")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Color(hex: "#09090b"))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6.5)
                        .background(Capsule().fill(p.gold))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(p.card)
        .onAppear { loadOnce() }
    }

    private var resumen: String {
        var parts: [String] = []
        parts.append(store.calendar(calendarId)?.summary ?? "…")
        if recurrencia != .nunca { parts.append(recurrencia.label.lowercased()) }
        let emails = invitadosList
        if !emails.isEmpty { parts.append("\(emails.count) invitado\(emails.count == 1 ? "" : "s")") }
        parts.append("→ Google/Apple")
        return parts.joined(separator: " · ")
    }

    private var invitadosList: [String] {
        invitados.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.palette.textMuted)
                .frame(width: 68, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func shell<Content: View>(palette p: Palette, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(p.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.border, lineWidth: 1))
    }

    private var calendarPicker: some View {
        let options = store.calendars.filter { cal in
            guard cal.canWrite && !cal.isObjetivo else { return false }
            if let e = editedEvent { return cal.accountId == e.accountId }
            return true
        }
        return Menu {
            ForEach(options) { cal in
                Button(action: { calendarId = cal.id }) {
                    HStack {
                        Image(systemName: "circle.fill")
                        Text(cal.summary)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.fromCalendarHex(store.calendar(calendarId)?.bgColorHex ?? "#8C27F1"))
                    .frame(width: 8, height: 8)
                Text(store.calendar(calendarId)?.summary ?? "…")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.palette.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        switch mode {
        case .draft:
            if let d = appState.draft {
                title = d.title
                start = d.start
                end = d.end
                allDay = d.isAllDay
                calendarId = d.calendarId
            }
        case .edit(let e):
            title = e.summary
            descripcion = e.notes ?? ""
            lugar = e.location ?? ""
            start = e.start
            end = e.end
            allDay = e.isAllDay
            calendarId = e.calendarId
        }
    }

    private func save() {
        let finalTitle = title.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .draft:
            store.createEvent(
                calendarId: calendarId,
                title: finalTitle.isEmpty ? "Nuevo evento" : finalTitle,
                start: start,
                end: allDay ? start : max(end, start.addingTimeInterval(15 * 60)),
                isAllDay: allDay,
                description: descripcion,
                location: lugar,
                recurrence: recurrencia.rule.map { [$0] } ?? [],
                attendees: invitadosList)
        case .edit(let e):
            store.updateEvent(
                e,
                title: finalTitle.isEmpty ? e.summary : finalTitle,
                start: start,
                end: e.isAllDay ? end : max(end, start.addingTimeInterval(15 * 60)),
                calendarId: calendarId,
                description: descripcion,
                location: lugar)
        }
        close()
    }

    private func close() {
        appState.draft = nil
        appState.editingEventId = nil
    }
}
