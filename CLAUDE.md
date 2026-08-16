# sfcal — instrucciones para agentes

App macOS **nativa** (Swift 6/SwiftUI sobre shell AppKit, SPM puro, cero Electron).
Cliente de Google Calendar multi-cuenta con integración Todoist.

## Comandos

- **Validación:** `swift build && swift test`
- **Instalar:** `./scripts/package.sh` (build release → bundle → firma ad-hoc →
  `~/Applications/sfcal.app` + login item). Dock: `python3 scripts/dock_position1.py`.
- Debug: `swift run SFCal --sync-once` (sync headless, imprime conteos).
- Render sin pantalla: `swift run SFCal --snapshot week /tmp/week.png [--light]`.

## Setup de credenciales (lo que un agente instala para su humano)

1. OAuth Google: client "Desktop app" con Calendar API habilitada →
   `python3 scripts/setup_oauth.py <id> <secret> <etiqueta>` → `~/.sfcal/token-<etiqueta>.json`.
   Cada token = una cuenta; "personal" se lista primero.
2. Todoist (opcional): token en `~/.sfcal/todoist.token`.

## Invariantes (NO romper)

1. **Google Calendar es el hub.** Se lee/escribe la API v3 directo. El cache de
   `~/.sfcal/cache/` es espejo, jamás fuente de verdad. Jamás EventKit.
2. **Todoist es la fuente única de tareas.** sfcal espeja y COMPLETA; la proyección
   a Google ("Tareas · Todoist") es de UNA VÍA con huella `todoistId` — nunca leer
   de vuelta, nunca sync bidireccional.
3. **Tokens fuera de git** (viven en `~/.sfcal/`, chmod 600).
4. Escritura optimista SIEMPRE con rollback visible (banner) si la API rechaza.
5. Firmar el bundle (ad-hoc mínimo): sin firma, Gatekeeper re-escanea cada launch.
6. Atajos: `1-6` vistas · `Y` panel de tareas · `K` kanban · `E` evento · `R` tarea ·
   `T` tema · `H` hoy · misma tecla = vista anterior · `⇧⌘B` sidebar (bare keys via
   NSEvent monitor con guardia de first-responder; no robar teclas al escribir).
7. **El Kanban no inventa estado**: las columnas son SECCIONES de Todoist agregadas por
   nombre entre proyectos (`TodoSection.canon`); "Hecho hoy" = completadas del día.
   Drag & drop llama move/close/reopen reales. Cero estado local del tablero.

## Gotchas

- All-day de Google trae `date` (flotante) → se interpreta en tz local.
- `syncToken` + 410 GONE → limpiar token y re-fetch de ventana (el store lo hace solo).
- Instancias recurrentes: id `master_YYYYMMDD...`; PATCH edita SOLO esa instancia.
- ImageRenderer no materializa ScrollView/LazyVStack → los snapshots usan stacks planos.
- `.offset` no mueve layout: los anchors de scroll son views con posición real.
- `.dropDestination`/`.draggable` NO se montan en modo snapshot: ImageRenderer pinta el
  contenedor de drop con un fill amarillo + 🚫 gigante.
- Un `TapGesture(count: 2)` en un CONTENEDOR retrasa el click sencillo de los botones hijos
  (timeout de disambiguación ~0.5s). Los dobles clicks van en un background HERMANO.
- Los popovers son ventanas aparte que NO heredan el colorScheme: `NSApp.appearance` se
  sincroniza al tema in-app (sin eso, DatePickers/checkboxes salen del tema del sistema).
- El monitor global de scroll solo panea en vistas de tiempo; en `K`/`Y` el gesto pasa
  intacto (una vista nueva con scroll propio debe agregarse a esa lista).
- Los semáforos de la ventana se re-centran por código (`centerTrafficLights`) porque AppKit
  los resetea en resize/fullscreen.
