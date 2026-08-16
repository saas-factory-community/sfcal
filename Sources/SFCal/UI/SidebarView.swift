import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            // El lockup vive ahora en el TopBar (una sola línea con los semáforos,
            // simetría 16 ago); el sidebar arranca directo con el mini-mes
            MiniMonthView()
                .padding(.horizontal, 12)
                .padding(.top, 12)

            // VStack plano (no ScrollView): ImageRenderer no pinta contenido de ScrollView
            // y la lista es corta. Si algún día hay 30 calendarios, se revisa.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.accounts) { account in
                    accountSection(account, palette: p)
                }
                if store.accounts.isEmpty {
                    Text("Sin cuentas.\nFalta ~/.sfcal/token-*.json")
                        .font(.system(size: 11))
                        .foregroundStyle(p.textMuted)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
                todoistSection(palette: p)
            }
            .padding(.top, 16)

            Spacer(minLength: 0)
            SyncBadgeView()
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.palette.surface)
    }

    @ViewBuilder
    private func accountSection(_ account: CalAccount, palette p: Palette) -> some View {
        let cals = store.calendars.filter { $0.accountId == account.id }
        if !cals.isEmpty {
            Text(account.email)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(p.textMuted)
                .tracking(0.4)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(cals) { cal in
                calendarRow(cal, palette: p)
            }
        }
    }

    @ViewBuilder
    private func todoistSection(palette p: Palette) -> some View {
        if store.todoistAvailable {
            HStack(spacing: 5) {
                Text("todoist")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(p.textMuted)
                    .tracking(0.4)
                if store.todoistError {
                    Circle().fill(p.bad).frame(width: 5, height: 5)
                        .help("Todoist no respondió; mostrando lo último leído")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            Button(action: { store.todoistVisible.toggle() }) {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(store.todoistVisible ? p.accent : p.textMuted)
                    Text("Tareas")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(store.todoistVisible ? p.textPrimary : p.textMuted)
                    Spacer(minLength: 0)
                    if store.todoistVisible && store.tasksDueToday > 0 {
                        Text("\(store.tasksDueToday) hoy")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(p.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(p.accent.opacity(0.16)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(store.todoistVisible ? 1 : 0.75)
        }
    }

    private func calendarRow(_ cal: CalendarInfo, palette p: Palette) -> some View {
        let hidden = store.hiddenCalendarIds.contains(cal.id)
        let color = Color.fromCalendarHex(cal.bgColorHex)
        return Button(action: { store.toggleCalendar(cal.id) }) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(hidden ? Color.clear : color)
                    .overlay(RoundedRectangle(cornerRadius: 3.5).stroke(color, lineWidth: 1.5))
                    .frame(width: 12, height: 12)
                Text(cal.summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hidden ? p.textMuted : p.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if cal.isObjetivo {
                    Image(systemName: "scope")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(p.gold.opacity(hidden ? 0.35 : 0.8))
                        .help("Alimenta la banda de hitos")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hidden ? 0.75 : 1)
    }
}

/// Marca de la app dibujada en vector (espejo del logo SVG de assets/).
struct LogoMark: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color(hex: "#141418"))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.22)
                        .stroke(Color(hex: "#8C27F1"), lineWidth: max(1.2, size * 0.06)))
            VStack(spacing: size * 0.10) {
                Capsule()
                    .fill(Color(hex: "#8C27F1"))
                    .frame(width: size * 0.56, height: size * 0.10)
                HStack(spacing: size * 0.10) {
                    Circle().fill(Color(hex: "#a1a1aa").opacity(0.9))
                    Circle().fill(Color(hex: "#a1a1aa").opacity(0.9))
                    Circle().fill(Color(hex: "#ff9101"))
                }
                .frame(height: size * 0.14)
            }
            .frame(width: size * 0.6)
        }
        .frame(width: size, height: size)
    }
}

struct MiniMonthView: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        let p = theme.palette
        let days = DateKit.monthGrid(appState.focusDate)
        let month = DateKit.cal.component(.month, from: appState.focusDate)
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                Text(DateKit.cap(DateKit.monthYear.string(from: appState.focusDate)))
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(p.textSecondary)
                Spacer()
                miniNav("chevron.left", palette: p) {
                    withAnimation(.easeOut(duration: 0.12)) {
                        appState.focusDate = DateKit.addMonths(appState.focusDate, -1)
                    }
                }
                miniNav("chevron.right", palette: p) {
                    withAnimation(.easeOut(duration: 0.12)) {
                        appState.focusDate = DateKit.addMonths(appState.focusDate, 1)
                    }
                }
            }
            .padding(.horizontal, 4)
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(["L", "M", "X", "J", "V", "S", "D"], id: \.self) { d in
                    Text(d)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(p.textMuted)
                }
                ForEach(days, id: \.self) { day in
                    miniDay(day, inMonth: DateKit.cal.component(.month, from: day) == month, palette: p)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(p.bg.opacity(p.isDark ? 0.55 : 0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border, lineWidth: 1))
    }

    private func miniNav(_ symbol: String, palette p: Palette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(p.textMuted)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func miniDay(_ day: Date, inMonth: Bool, palette p: Palette) -> some View {
        let isToday = DateKit.isToday(day)
        let isFocus = DateKit.isSameDay(day, appState.focusDate)
        return Button(action: {
            withAnimation(.easeOut(duration: 0.12)) { appState.focusDate = day }
        }) {
            Text(DateKit.dayNum.string(from: day))
                .font(.system(size: 9.5, weight: isToday ? .heavy : .medium))
                .foregroundStyle(isToday ? Color(hex: "#f7f8f8") : (inMonth ? p.textSecondary : p.textMuted.opacity(0.45)))
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(isToday ? p.accent : .clear)
                        .overlay(Circle().stroke(isFocus && !isToday ? p.accent.opacity(0.8) : .clear, lineWidth: 1.2))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SyncBadgeView: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        let p = theme.palette
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(store.health.isError ? p.bad : p.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(p.bg.opacity(p.isDark ? 0.6 : 0.5)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                store.health.isError ? p.bad.opacity(0.5) : p.border, lineWidth: 1))
            .help(helpText)
        }
    }

    private var dotColor: Color {
        let p = theme.palette
        switch store.health {
        case .ok: return p.ok
        case .syncing: return p.accent
        case .error: return p.bad
        }
    }

    private var label: String {
        switch store.health {
        case .syncing: return "sincronizando…"
        case .error: return "sync con error"
        case .ok:
            guard let t = store.lastSyncAt else { return "—" }
            let s = Int(Date().timeIntervalSince(t))
            if s < 3 { return "sync ahora" }
            if s < 60 { return "sync hace \(s)s" }
            return "sync hace \(s / 60)m"
        }
    }

    private var helpText: String {
        if case .error(let m) = store.health { return m }
        return "Sync incremental con Google cada 10s"
    }
}
