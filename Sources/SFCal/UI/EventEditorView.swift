import SwiftUI

/// Popover de creación (draft) y edición de eventos.
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
            TextField("Título", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(p.textPrimary)
                .onSubmit { save() }

            VStack(alignment: .leading, spacing: 8) {
                if editedEvent?.isAllDay == true {
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
                labeled("Calendario") { calendarPicker }
            }

            if let e = editedEvent, let loc = e.location, !loc.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "mappin.and.ellipse").font(.system(size: 10))
                    Text(loc).lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(p.textMuted)
            }

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
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "#09090b"))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(p.gold))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(p.card)
        .onAppear { loadOnce() }
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
                calendarId = d.calendarId
            }
        case .edit(let e):
            title = e.summary
            start = e.start
            end = e.end
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
                end: max(end, start.addingTimeInterval(15 * 60)),
                isAllDay: false)
        case .edit(let e):
            store.updateEvent(
                e,
                title: finalTitle.isEmpty ? e.summary : finalTitle,
                start: start,
                end: e.isAllDay ? end : max(end, start.addingTimeInterval(15 * 60)),
                calendarId: calendarId)
        }
        close()
    }

    private func close() {
        appState.draft = nil
        appState.editingEventId = nil
    }
}
