import SwiftUI

/// La banda de HITOS: objetivos de mes/semana/día (calendarios "Objetivo ..."),
/// planificación por niveles (Objetivo del día/semana/mes). Prominente, no enterrada.
struct HitosBand: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var theme: ThemeManager

    private var referenceDay: Date {
        appState.mode == .day ? appState.focusDate : Date()
    }

    var body: some View {
        let p = theme.palette
        let items = store.objetivos(covering: referenceDay)
        if !items.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    chip(nivel: item.nivel, text: item.evento.summary, palette: p)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(height: 38)   // cinturón: la banda JAMÁS crece verticalmente
            .background(p.surface.opacity(p.isDark ? 0.6 : 0.5))
            .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
        }
    }

    /// Mismo lenguaje visual que un bloque de evento (fill tintado + barra de color,
    /// sin outline) — crítico round 2 — pero la banda mantiene su posición prominente:
    /// el spec la exige elevada (la planificación por niveles).
    private func chip(nivel: String, text: String, palette p: Palette) -> some View {
        let tint = nivel == "DÍA" ? p.gold : p.accent
        return HStack(spacing: 0) {
            // Altura FIJA: un Shape sin height es greedy y en vista Mes el VStack
            // le repartía media pantalla al chip (bug 15 ago)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 3, height: 15)
            HStack(spacing: 7) {
                Text(nivel)
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(tint)
                    .tracking(0.5)
                Text(text)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(p.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 4.5)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(p.isDark ? 0.10 : 0.08)))
    }
}
