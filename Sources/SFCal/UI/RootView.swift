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
        HStack(alignment: .top, spacing: 0) {
            SidebarView()
                .frame(width: 236)
            Rectangle()
                .fill(p.border)
                .frame(width: 1)
            VStack(spacing: 0) {
                HeaderBar()
                HitosBand()
                mainContent
            }
        }
        .background(p.bg)
        .environment(\.colorScheme, p.isDark ? .dark : .light)
        .overlay(alignment: .bottom) { bannerView }
        .overlay { draftOverlay }
        .ignoresSafeArea()
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
        switch appState.mode {
        case .day:
            TimelineGridView(days: [DateKit.startOfDay(appState.focusDate)])
                .id("day-\(DateKit.startOfDay(appState.focusDate).timeIntervalSince1970)")
        case .fourDay:
            TimelineGridView(days: (0..<4).map { DateKit.addDays(DateKit.startOfDay(appState.focusDate), $0) })
                .id("4day-\(DateKit.startOfDay(appState.focusDate).timeIntervalSince1970)")
        case .week:
            TimelineGridView(days: DateKit.weekDays(appState.focusDate))
                .id("week-\(DateKit.startOfWeek(appState.focusDate).timeIntervalSince1970)")
        case .month:
            MonthView()
        case .year:
            YearView()
        case .agenda:
            AgendaView()
                .id("agenda-\(DateKit.startOfDay(appState.focusDate).timeIntervalSince1970)")
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

struct HeaderBar: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        let p = theme.palette
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                navButton("chevron.left") { appState.step(-1) }
                navButton("chevron.right") { appState.step(1) }
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
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: 52)
        .padding(.top, 8)   // aire para la barra de tráfico (fullSizeContentView)
        .contentShape(Rectangle())
        // Doble click en el header = zoom (estándar macOS; el titlebar transparente
        // dejaba el gesto enterrado bajo el contenido). Los botones siguen ganando.
        .gesture(TapGesture(count: 2).onEnded {
            NSApp.keyWindow?.zoom(nil)
        })
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

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(p.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
