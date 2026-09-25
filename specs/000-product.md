# Headroom — Especificación v0.2

> *Cuánto margen te queda antes de topar.*

App nativa de barra de menú para macOS que muestra, en un popover con efecto **Liquid Glass**, cuánto te queda de los límites de uso de tus suscripciones de IA (Claude, Codex/ChatGPT, etc.): ventana corta (sesión/"diaria") y ventana semanal.

---

## 1. Objetivos

| # | Objetivo | Métrica de éxito |
|---|----------|------------------|
| G1 | Ver el estado de todos mis límites con **un click** | Popover abre en < 150 ms con datos cacheados |
| G2 | Conectar varias suscripciones sin copiar tokens a mano | Detección automática de Claude Code y Codex CLI ya logueados |
| G3 | Saber **cuándo** se resetea cada límite | Cuenta regresiva por ventana |
| G4 | No ser intrusiva | < 30 MB RAM, sin Dock icon, refresco en background barato |
| G5 | Segura | Tokens solo en Keychain, sin servidores propios, sin telemetría |

### No-objetivos (v1)
- No calcula costos en USD de API por token (eso es otra app).
- No sincroniza entre Macs.
- No soporta iOS / Windows.

---

## 2. Conceptos clave (importante)

Los proveedores **no usan exactamente "diario"**. El modelo real es:

| Proveedor | Ventana corta | Ventana larga | Extra |
|-----------|---------------|---------------|-------|
| Claude (Pro/Max) | **5 horas** (sesión rodante) | **7 días** (todos los modelos) | 7 días específico de Opus/Sonnet según plan |
| Codex (ChatGPT Plus/Pro) | **5 horas** ("primary window") | **semanal** ("secondary window") | Créditos extra si aplica |
| Gemini CLI / Cursor / Copilot | Varía (requests/día, requests/mes) | — | Fase 3 |

Por eso el modelo de datos es genérico: **un proveedor expone N "ventanas" de límite**, cada una con `% usado` + `fecha de reset`. En la UI se etiquetan como "Sesión (5h)" y "Semanal", y "Diario" cuando el proveedor realmente sea diario.

---

## 3. Fuentes de datos por proveedor

> ⚠️ Estos endpoints son **internos / no documentados** (los usan las propias apps oficiales y herramientas de la comunidad como CodexBar). Pueden cambiar sin aviso → cada provider debe fallar de forma elegante y la **Fase 0** los valida en tu máquina antes de escribir UI.

### 3.1 Claude (Claude Code / claude.ai Pro/Max)
- **Credencial (auto-detectada):** Keychain, servicio `Claude Code-credentials` → JSON con `claudeAiOauth.accessToken`, `refreshToken`, `expiresAt`, `subscriptionType`. ✅ Detectado en tu Mac.
- **Endpoint:** `GET https://api.anthropic.com/api/oauth/usage`
  - Headers: `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`
  - Respuesta esperada: `five_hour`, `seven_day`, `seven_day_opus` / `seven_day_sonnet` → `{ utilization: 0–100, resets_at: ISO8601 }`
- **Refresh:** si `expiresAt` venció, no refrescamos nosotros (evita invalidar la sesión de Claude Code); mostramos "Abre Claude Code para renovar sesión". *(Revisar en Fase 0 si es seguro refrescar.)*
- **Fallback:** cookie `sessionKey` de claude.ai pegada manualmente → `GET https://claude.ai/api/organizations/{orgId}/usage`.

### 3.2 Codex (OpenAI Codex CLI / ChatGPT Plus/Pro)
- **Credencial (auto-detectada):** `~/.codex/auth.json` → `tokens.access_token`, `tokens.account_id`. ✅ Detectado en tu Mac.
- **Endpoint primario:** `GET https://chatgpt.com/backend-api/wham/usage`
  - Headers: `Authorization: Bearer <access_token>`, `ChatGPT-Account-Id: <account_id>`
  - Respuesta esperada: `rate_limit.primary_window` / `secondary_window` → `used_percent`, `reset_after_seconds` / `reset_at`, más `plan_type`.
- **Fallback offline (sin red):** último evento `token_count` con `rate_limits` en `~/.codex/sessions/**/*.jsonl` (el propio CLI lo escribe tras cada turno).

### 3.3 Proveedores futuros (Fase 3)
| Proveedor | Fuente probable |
|-----------|-----------------|
| Gemini CLI | `~/.gemini/oauth_creds.json` + quota API de Google |
| Cursor | Cookie de sesión → `cursor.com/api/usage` |
| GitHub Copilot | `gh auth token` → `api.github.com/copilot_internal/user` |
| OpenRouter / API keys | API key → endpoint oficial de créditos |

---

## 4. Experiencia de usuario

### 4.1 Ícono en la barra
- SF Symbol (`gauge.with.dots.needle.67percent`) o mini-barras dibujadas.
- **Solo ícono** (decisión). El ícono se llena según el % más crítico; el texto `72%` queda como opción en Ajustes (apagada por defecto).
- Color del ícono: normal / amarillo ≥ 75 % / rojo ≥ 90 % (configurable).

### 4.2 Popover (click) — Liquid Glass
```
╭──────────────────────────────────────────╮
│  Headroom                     ⟳  ⚙︎       │
│                                          │
│  ┌ Claude · Max 5x ───────────────────┐  │
│  │ Sesión (5h)  ███████░░░  68%  2h 14m│  │
│  │ Semanal      ███░░░░░░░  31%  4d 3h │  │
│  │ Opus semanal █░░░░░░░░░  12%  4d 3h │  │
│  └─────────────────────────────────────┘  │
│  ┌ Codex · Plus ──────────────────────┐  │
│  │ Sesión (5h)  ██████████  96%  38m   │  │
│  │ Semanal      █████░░░░░  52%  2d 9h │  │
│  └─────────────────────────────────────┘  │
│                                          │
│  Actualizado hace 1 min                  │
╰──────────────────────────────────────────╯
```
- Contenedor: `GlassEffectContainer` + tarjetas con `.glassEffect(.regular, in: .rect(cornerRadius: 16))`.
- Barras con tinte por proveedor (Claude naranja, Codex verde/negro) y cambio a amarillo/rojo por umbral.
- Hover sobre una barra → hora exacta de reset ("se reinicia hoy 18:40").
- Click en tarjeta → expande detalle (plan, última actualización, error si hay).
- Estados: *cargando* (skeleton glass), *error* (mensaje + botón "Reconectar"), *sin configurar* (CTA "Conectar").

### 4.3 Ajustes (ventana aparte, estilo System Settings)
- **Cuentas:** lista de proveedores, estado (✅ detectado / ⚠️ expirado / ➕ conectar), activar/desactivar, reordenar.
- **General:** abrir al iniciar sesión, intervalo de refresco (1 / 2 / 5 / 15 min), mostrar % en barra.
- **Notificaciones:** avisar al cruzar 75 % / 90 %, avisar cuando se resetea una ventana que estaba > 90 %.

---

## 5. Arquitectura técnica

### 5.1 Stack
| Decisión | Elección | Motivo |
|----------|----------|--------|
| Lenguaje / UI | Swift 6 + SwiftUI | Nativo, Liquid Glass de primera clase |
| Target | **macOS 26+** | `glassEffect` solo existe en 26 (fallback a `.ultraThinMaterial` si luego bajamos a 15) |
| Barra de menú | `MenuBarExtra` con `.menuBarExtraStyle(.window)` | Popover de SwiftUI puro |
| App sin Dock | `LSUIElement = YES` | Solo vive en la barra |
| Red | `URLSession` async/await | Sin dependencias |
| Secretos | Keychain (Security.framework) | Tokens manuales cifrados |
| Persistencia | `UserDefaults` (ajustes) + JSON en Application Support (caché de último snapshot) | Simple |
| Login item | `SMAppService.mainApp` | API moderna |
| Notificaciones | `UserNotifications` | — |
| Proyecto | Xcode project generado con **XcodeGen** (`project.yml`) | Diff-friendly, reproducible |
| Dependencias | **Cero** en v1 | — |

### 5.2 Capas
```
┌───────────────────────── UI (SwiftUI) ──────────────────────────┐
│ MenuBarLabel · PopoverView · ProviderCard · LimitBar · Settings │
└───────────────────────────────┬─────────────────────────────────┘
                                │ @Observable
┌───────────────────────── UsageStore ────────────────────────────┐
│ snapshots por proveedor · scheduler de refresco · umbrales/notif│
└───────────────────────────────┬─────────────────────────────────┘
                                │ protocol UsageProvider
┌──────────────┬────────────────┴────┬────────────────────────────┐
│ ClaudeProvider│ CodexProvider      │ (Gemini, Cursor, …)        │
└──────┬───────┴─────────┬──────────┴────────────────────────────┘
       │ CredentialSource (Keychain ajeno, archivo, token manual)
       │ HTTPClient (URLSession, timeouts, backoff)
```

### 5.3 Modelo de datos
```swift
enum ProviderID: String, Codable { case claude, codex /* , gemini, cursor, copilot */ }

enum WindowKind: String, Codable { case session5h, daily, weekly, weeklyModel, monthly }

struct LimitWindow: Codable, Identifiable {
    let id: String            // "five_hour", "seven_day_opus"
    let kind: WindowKind
    let label: String         // "Sesión (5h)", "Opus semanal"
    let usedPercent: Double   // 0...100
    let resetsAt: Date?
}

struct UsageSnapshot: Codable {
    let provider: ProviderID
    let planName: String?     // "Max 5x", "Plus"
    let windows: [LimitWindow]
    let fetchedAt: Date
}

enum ProviderState {
    case notConfigured
    case loading(previous: UsageSnapshot?)
    case loaded(UsageSnapshot)
    case failed(ProviderError, lastGood: UsageSnapshot?)
}

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    func detectCredentials() async -> CredentialStatus
    func fetchUsage() async throws -> UsageSnapshot
}
```

### 5.4 Refresco
- Timer cada N min (default 2) + refresco inmediato al abrir el popover si el dato tiene > 60 s.
- Proveedores en paralelo (`TaskGroup`), timeout 10 s c/u.
- Backoff exponencial en 429/5xx (máx 15 min). Pausa al dormir la Mac (`NSWorkspace` sleep/wake).
- Siempre se muestra el último snapshot bueno + badge "desactualizado" si falla.

### 5.5 Seguridad y privacidad
- Solo **lectura** de credenciales de otras apps; nunca se escriben ni se modifican.
- Acceso al ítem Keychain de Claude Code dispara el diálogo de macOS "Permitir siempre" la primera vez (esperado).
- Tokens manuales → Keychain propio (`com.alfredo.headroom`).
- Sin analytics, sin servidores intermedios; red solo hacia los dominios del proveedor.
- App **no sandboxed** en v1 (necesita leer `~/.codex` y Keychain ajeno). Distribución directa, firmada con Developer ID + notarizada (no App Store).

---

## 6. Organización del proyecto

```
ailimits/  (app: Headroom)
├── SPEC.md
├── README.md
├── project.yml                     # XcodeGen
├── Headroom/
│   ├── App/
│   │   ├── HeadroomApp.swift       # @main, MenuBarExtra + Settings scene
│   │   └── Info.plist              # LSUIElement
│   ├── Core/
│   │   ├── Models/                 # LimitWindow, UsageSnapshot, ProviderState
│   │   ├── Store/UsageStore.swift  # @Observable, scheduler
│   │   ├── Networking/HTTPClient.swift
│   │   ├── Credentials/            # KeychainReader, FileCredentialSource
│   │   └── Notifications/ThresholdNotifier.swift
│   ├── Providers/
│   │   ├── UsageProvider.swift     # protocolo + registry
│   │   ├── Claude/ClaudeProvider.swift + ClaudeDTOs.swift
│   │   └── Codex/CodexProvider.swift + CodexDTOs.swift + CodexSessionLogReader.swift
│   ├── UI/
│   │   ├── MenuBar/MenuBarLabel.swift
│   │   ├── Popover/PopoverView.swift, ProviderCard.swift, LimitBar.swift
│   │   ├── Settings/SettingsView.swift, AccountsTab.swift, GeneralTab.swift
│   │   └── Theme/ProviderTheme.swift
│   └── Resources/Assets.xcassets    # íconos de proveedores
├── HeadroomTests/
│   ├── Fixtures/                   # JSON reales anonimizados de cada endpoint
│   └── ProviderParsingTests.swift
└── Scripts/
    ├── probe_claude.sh             # Fase 0
    └── probe_codex.sh
```

---

## 6.5 Hallazgos Fase 0 (2026-09-25)

| Proveedor | Resultado | Implicación |
|-----------|-----------|-------------|
| Claude | Los 4 ítems `Claude Code-credentials*` del Keychain tienen `accessToken` **vacío** (sesión de Claude Code vive en la app de escritorio, cifrada en "Claude Safe Storage"). Endpoint respondió 429 sin auth. | No podemos depender solo del Keychain. Flujo de conexión: (1) Keychain si hay token, (2) **login OAuth propio** de Headroom, (3) cookie `sessionKey` de claude.ai. |
| Claude (tras `claude auth login`) | ✅ HTTP 200. La respuesta trae un arreglo normalizado `limits[]` (`kind`: session / weekly_all / …, `percent`, `severity`, `resets_at`, `is_active`) además de `five_hour` / `seven_day`. También `extra_usage` / `spend` (créditos extra en USD) y `seven_day_breakdown` (Claude Code vs Chats vs Cowork). El token del Keychain dura **~1 h**. | Parsear `limits[]` primero (sirve también para ventanas nuevas) y usar `five_hour`/`seven_day` como respaldo. Mostrar créditos extra y el desglose semanal en el detalle. Headroom necesita refrescar el token por su cuenta si Claude Code no está abierto. |
| Codex (live) | `wham/usage` → 401 "Could not parse your authentication token": `access_token` de `~/.codex/auth.json` es del 20-jun, expirado. CLI `codex` no está en PATH. | Headroom debe **refrescar el token** con `refresh_token` (guardando la copia en su propio Keychain, sin tocar `auth.json`) o pedir login. |
| Codex (tras `codex login`) | ✅ HTTP 200. Plan `free`: una sola ventana `primary_window` con `limit_window_seconds: 2592000` (**30 días**) y `secondary_window: null`. También trae `credits`, `code_review_rate_limit`, `additional_rate_limits`. | La duración de cada ventana **depende del plan**: la etiqueta se calcula con `limit_window_seconds` (5h → "Sesión", 7d → "Semanal", 30d → "Mensual"), no se asume. Las ventanas `null` se ocultan. |
| Codex (logs) | ✅ Funciona. `rate_limits.primary` (300 min) y `secondary` (10080 min) con `used_percent`, `resets_at` (epoch s), `plan_type: plus`. | Confirma el modelo de datos. Útil como fallback, pero solo está fresco si usas Codex. |

## 7. Roadmap

| Fase | Entregable | Criterio de "hecho" |
|------|-----------|---------------------|
| **0 · Validación** | Scripts `probe_*.sh` que llaman a cada endpoint con tus credenciales locales y guardan el JSON (anonimizado) como fixture | Vemos respuestas reales de Claude y Codex |
| **1 · MVP** | App en barra + popover glass + Claude y Codex auto-detectados + refresco | Abro la app y veo mis 2 proveedores con barras y resets correctos |
| **2 · Pulido** | Ajustes, % en barra, colores por umbral, notificaciones, login item, estados de error | Uso diario sin tocar código |
| **3 · Más proveedores** | Gemini → Cursor → Copilot | Los 3 funcionando |
| **4 · Distribución** | Firma + notarización, DMG, auto-update (Sparkle). *Sin Apple Developer aún → firma ad-hoc local mientras tanto* | Instalable en otra Mac |

---

## 8. Riesgos

| Riesgo | Impacto | Mitigación |
|--------|---------|------------|
| Endpoints internos cambian | Proveedor deja de funcionar | Parsing tolerante, fixtures en tests, fallback (logs de Codex / cookie de Claude), error claro en UI |
| Token de Claude expira y no se refresca | Datos viejos | Mostrar aviso; evaluar refresh seguro en Fase 0 |
| Términos de servicio | Uso de API no pública | Solo lectura de *tus* datos, frecuencia baja (≥ 1 min), sin scraping masivo |
| Liquid Glass solo en macOS 26 | Menos usuarios | Aceptado para v1; fallback a Material si se requiere |

---

## 9. Decisiones
| Tema | Decisión |
|------|----------|
| Barra | Solo ícono |
| Proveedores extra | Gemini, Cursor, Copilot |
| Nombre | **Headroom** — `com.alfredo.headroom` |
| Firma | Ad-hoc local hasta tener Apple Developer |
