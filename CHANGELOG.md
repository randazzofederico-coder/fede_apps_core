# Changelog

Todas las versiones de `fede_apps_core`. Cada una tiene su tag `vX.Y.Z` en el repo.

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
