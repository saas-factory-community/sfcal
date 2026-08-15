import SwiftUI

/// Vista ANUAL: 12 mini-meses (4×3). Un punto marca los días con eventos.
/// Click en un día → vista Día; click en el nombre del mes → vista Mes.
struct YearView: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        let p = theme.palette
        let year = DateKit.cal.component(.year, from: appState.focusDate)
        let busyDays = busySet()
        GeometryReader { geo in
            let cols = 4
            let rows = 3
            let w = geo.size.width / CGFloat(cols)
            let h = geo.size.height / CGFloat(rows)
            ZStack(alignment: .topLeading) {
                ForEach(0..<12, id: \.self) { m in
                    let anchor = DateKit.cal.date(from: DateComponents(year: year, month: m + 1, day: 1))!
                    miniMonth(anchor, busyDays: busyDays, palette: p)
                        .frame(width: w - 18, height: h - 14)
                        .offset(x: CGFloat(m % cols) * w + 12, y: CGFloat(m / cols) * h + 8)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private func busySet() -> Set<Date> {
        var out = Set<Date>()
        for cal in store.visibleCalendars where !cal.isObjetivo {
            for e in store.eventsByCalendar[cal.id] ?? [] {
                out.insert(DateKit.startOfDay(e.start))
            }
        }
        for t in store.tasks {
            if let d = t.due { out.insert(DateKit.startOfDay(d)) }
        }
        return out
    }

    private func miniMonth(_ anchor: Date, busyDays: Set<Date>, palette p: Palette) -> some View {
        let month = DateKit.cal.component(.month, from: anchor)
        let days = DateKit.monthGrid(anchor)
        // Solo las filas de semana que tocan el mes: sin renglones muertos abajo
        let weekRows: [[Date]] = (0..<6)
            .map { Array(days[($0 * 7)..<($0 * 7 + 7)]) }
            .filter { row in row.contains { DateKit.cal.component(.month, from: $0) == month } }
        return VStack(alignment: .leading, spacing: 5) {
            Button(action: {
                appState.focusDate = anchor
                appState.setMode(.month)
            }) {
                Text(DateKit.cap(DateKit.monthName.string(from: anchor)))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DateKit.cal.isDate(anchor, equalTo: Date(), toGranularity: .month) ? p.gold : p.textPrimary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 0) {
                ForEach(["L", "M", "X", "J", "V", "S", "D"], id: \.self) { d in
                    Text(d)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(p.textMuted.opacity(0.8))
                        .frame(maxWidth: .infinity)
                }
            }
            // Filas FLEXIBLES: el grid llena TODA la altura del card
            VStack(spacing: 0) {
                ForEach(Array(weekRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(row, id: \.self) { day in
                            Group {
                                if DateKit.cal.component(.month, from: day) == month {
                                    yearDay(day, busy: busyDays.contains(DateKit.startOfDay(day)), palette: p)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(p.surface.opacity(p.isDark ? 0.55 : 0.7)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border, lineWidth: 1))
    }

    private func yearDay(_ day: Date, busy: Bool, palette p: Palette) -> some View {
        let today = DateKit.isToday(day)
        return Button(action: {
            appState.focusDate = day
            appState.setMode(.day)
        }) {
            VStack(spacing: 2.5) {
                Text(DateKit.dayNum.string(from: day))
                    .font(.system(size: 11.5, weight: today ? .heavy : .medium))
                    .foregroundStyle(today ? Color(hex: "#09090b") : p.textSecondary)
                    .frame(width: 23, height: 23)
                    .background(Circle().fill(today ? p.gold : .clear))
                Circle()
                    .fill(busy ? p.accent.opacity(0.85) : .clear)
                    .frame(width: 3.5, height: 3.5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
