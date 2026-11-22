# Changelog

Todas las versiones de `fede_apps_core`. Cada una tiene su tag `vX.Y.Z` en el repo.

## v0.7.0 — 2026-11-22

- **feat:** `UsageTracker` ahora expone `UsageDelta`, `dayKeyOf`, `addDeltaListener` / `removeDeltaListener` manteniendo sus totales locales `fac_usage_*` intactos.
- **feat:** nuevo `UsageReporter` + transporte multiplataforma GoatCounter (`goatcounter_stub/io/web.dart`):
  - Capa global/anónima: envía pageviews (`/<appId>`) y eventos de práctica (`<appId>/practice/<bucket>` para tramos ≥ 15 s) + `trackEvent(name)` opcional a `https://appstats.federicorandazzo.com.ar/count`.
  - Capa por usuario logueado: cola persistente de deltas por `uid` en `SharedPreferences`, envíos throttled con `FieldValue.increment` + `arrayUnion` hacia `users/{uid}/appUsage/{sourceId}`, reintento offline y poda automática de `recentDays` (> 30 días).
- **docs/copy:** actualización de `FacStrings.whatWeSaveBullets` (es/en) para informar que también se guardan estadísticas básicas de uso asociadas a la cuenta.

## v0.6.0 — 2026-11-21

- **feat:** alta de `FedeApp.elongacionMusical` (con ícono `assets/icons/elmuvi.png`) y `playStoreId` opcional en `FedeApp`.

## v0.5.1 — 2026-11-06

- **fix:** `FedeAccount.isReady` (y `ready`) inicializan la cuenta. Sin esto, si nadie había llamado a
  `init()`, `LibrarySync.canPurgeLocally` devolvía siempre `false` y no se purgaban lápidas sin sesión.

## v0.5.0 — 2026-11-06

- **feat:** `PortraitOnly`: en la web de teléfonos la app queda siempre en vertical (intenta
  `screen.orientation.lock`; en apaisado muestra "Girá el teléfono" sin reacomodar la UI).

## v0.4.1 — 2026-11-02

- **feat:** `FedeAccount.ready` / `isReady`: espera a que Firebase restaure la sesión (máx. 3 s).
- Purga conservadora: `LibrarySync.canPurgeLocally` devuelve `false` hasta que la sesión se restauró.

## v0.4.0 — 2026-11-02

Cuenta y sincronización de bibliotecas.

- **feat:** algoritmo de merge por ítem (`mergeCollection`) con tests de convergencia.
- **feat:** `FedeAccount` (login con Google vinculando la sesión anónima, perfil `users/{uid}`).
- **feat:** `LibrarySync` + `SyncAdapter` + `RemoteStore` (`FirestoreRemoteStore` / `InMemoryRemoteStore`):
  1 transacción por sync.
- **feat:** `AccountSection` y sugerencia de login (`EcosystemPrompts.maybeShowLoginPrompt`).
- **docs:** cuenta y sincronización en el README.

## v0.3.0 — 2026-11-02

- **feat:** contrato de ítems sincronizables (`SyncFields`) y `DeviceIdentity`.

## v0.2.0 — 2026-11-02

- **feat:** Atril en `FedeApp`, íconos reales de las apps, etiqueta "Beta" y links según estado
  (apps beta → su ficha en /apps).

## v0.1.0 — 2026-11-02

- **feat:** paquete compartido con `UsageTracker`, `PromptGate` y sugerencias del ecosistema
  (`EcosystemPrompts`, `EcosystemSection`, `FedeApp`).
- **feat:** actividad que sigue en segundo plano (`startActivity(continuesInBackground: true)`) y
  estilo configurable en `EcosystemSection`.
