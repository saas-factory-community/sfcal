# sfcal

**El calendario nativo de macOS que se construyó en vivo, y ahora es tuyo.**

App de calendario para Mac construida 100% con agentes de IA en un día, en directo para la
comunidad de [SaaS Factory](https://www.saasfactory.so). Swift nativo, cero Electron, cero
lag: cliente directo de Google Calendar con integración de Todoist.

> Regalo para la comunidad de YouTube → [saasfactory.so/free](https://www.saasfactory.so/free)

## Qué hace

- **Cliente nativo de Google Calendar** (N cuentas, todos tus calendarios con sus colores).
  Google sigue siendo tu hub: lo que hagas aquí se sincroniza a tu iPhone/Apple Calendar solo.
- **6 vistas**: Año · Mes · Semana · 4 días · Día · Agenda.
- **Keyboard-first**: `1-6` cambian de vista · `E` nuevo evento · `R` nueva tarea · `T` tema
  oscuro/claro · `H` hoy · flechas o **scroll horizontal** navegan · drag para mover/estirar
  eventos (snap de 15 min) · doble click en el grid crea.
- **Todoist integrado**: tus tareas aparecen en el calendario (bloques punteados), las completas
  desde ahí, capturas nuevas con `R`, y un **espejo de una vía** las proyecta a un calendario
  "Tareas · Todoist" en Google para que también vivan en tu iPhone.
- **Sync incremental** cada 10s con syncToken (cambios de otros lados aparecen solos) +
  escritura optimista con rollback visible si Google rechaza.
- **Banda de HITOS**: los eventos all-day de calendarios cuyo nombre empiece con "Objetivo"
  se muestran como banda prominente (tu norte del día/semana/mes, siempre a la vista).
- **Residente**: arranca al login, vive en el Dock, abre al instante desde caché local.
- Dark/light con la paleta de la casa. Línea de AHORA. Sin Electron, sin web views.

## Instalación AI-first (recomendada)

Copia este prompt y pégaselo a tu agente de IA (Claude Code, Cursor, etc.) en una terminal:

```
Instala sfcal (calendario nativo de macOS, open source) en mi Mac. Repo:
https://github.com/saas-factory-community/sfcal

1. Clónalo a ~/Developer/sfcal, lee README.md y CLAUDE.md completos.
2. Verifica requisitos: macOS 15+, Swift/Xcode Command Line Tools
   (si falta: xcode-select --install), python3 con pip.
3. Guíame para crear mi OAuth Client de Google (yo clickeo, tú me dices dónde):
   console.cloud.google.com → proyecto nuevo → habilitar "Google Calendar API"
   → pantalla de consentimiento OAuth (External, modo Testing, agrégame como
   test user) → credencial tipo "Desktop app" → me quedo con client_id y
   client_secret.
4. Corre: pip3 install google-auth-oauthlib && python3 scripts/setup_oauth.py
   <client_id> <client_secret> personal — se abre mi navegador, autorizo, y el
   token queda en ~/.sfcal/. Si tengo más cuentas Google, repite con otra
   etiqueta (ej. "trabajo").
5. (Opcional, si uso Todoist) Pídeme mi API token (Todoist → Ajustes →
   Integraciones → Developer) y guárdalo en ~/.sfcal/todoist.token (chmod 600).
6. Compila e instala: ./scripts/package.sh — queda en ~/Applications/sfcal.app,
   firmada y con arranque al login. Ponla en el Dock: python3 scripts/dock_position1.py
7. Ábrela, verifica que se ven mis calendarios, y termina enseñándome los
   atajos: 1-6 vistas, E evento, R tarea, T tema, H hoy, scroll horizontal.
```

## Instalación manual

```bash
git clone https://github.com/saas-factory-community/sfcal.git && cd sfcal
pip3 install google-auth-oauthlib
python3 scripts/setup_oauth.py <CLIENT_ID> <CLIENT_SECRET> personal   # navegador → autorizar
./scripts/package.sh                                                  # build + instala + login item
python3 scripts/dock_position1.py                                     # al Dock (opcional)
```

Necesitas un OAuth Client de Google tipo **Desktop app** con la **Calendar API habilitada**
(gratis, ~3 min en [console.cloud.google.com](https://console.cloud.google.com)). Para Todoist:
tu API token en `~/.sfcal/todoist.token`.

## Convenciones

| Cosa | Convención |
|---|---|
| Cuentas | Un archivo `~/.sfcal/token-<etiqueta>.json` por cuenta ("personal" se lista primero) |
| Hitos | Calendarios cuyo nombre empieza con `Objetivo` alimentan la banda superior |
| Tareas | Todoist es la fuente de verdad; sfcal las espeja y proyecta a Google (una vía) |
| Cache | `~/.sfcal/cache/` (espejo para pintar rápido; bórralo sin miedo) |

## Validación

```bash
swift build && swift test
```

## Stack

Swift 6 + SwiftUI sobre shell AppKit · SPM puro (sin .xcodeproj) · Google Calendar API v3
directo con URLSession (cero SDKs) · Todoist API v1 · Cero dependencias de terceros.

## Licencia

MIT. Construida por [Daniel Carreón](https://www.youtube.com/@DanielCarreonAI) con agentes
de IA, en vivo. Úsala, fórkéala, hazla tuya.
