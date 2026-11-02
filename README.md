# fede_apps_core

Código compartido de las apps Flutter de federicorandazzo.com.ar (Afinador, Metrónomo, Tone Generator).

## Cómo se usa

En el `pubspec.yaml` de cada app (las carpetas tienen que estar una al lado de la otra en `C:\dev`):

```yaml
dependencies:
  fede_apps_core:
    path: ../fede_apps_core
```

> El código **no se copia** a los repos de las apps: cada una solo guarda esa línea.
> Si algún día se compila en otra máquina o en CI, se cambia por
> `git: { url: https://github.com/randazzofederico-coder/fede_apps_core.git, ref: v0.1.0 }`.

```dart
// main.dart, antes de runApp:
await UsageTracker.instance.init();

// Actividad principal (afinar, reproducir):
UsageTracker.instance.startActivity();                             // afinador (mic)
UsageTracker.instance.startActivity(continuesInBackground: true);  // audio que sigue sonando
await UsageTracker.instance.stopActivity();

// En un "momento tranquilo" (entrar a Ajustes, pausar el mic, detener):
EcosystemPrompts.maybeShowAppsPrompt(context, currentApp: FedeApp.afinador);

// Sección fija en Ajustes (con encabezado propio de la app):
EcosystemSection(
  currentApp: FedeApp.afinador,
  showHeader: false,               // usar FacStrings.of(context).moreApps en el header propio
  showSite: false,                 // si Ajustes ya tiene links a la web
  iconColor: Colors.blueAccent,    // igualar el estilo de los ListTile de la app
);
```

## Qué hay

| Pieza | Qué hace |
| :-- | :-- |
| `UsageTracker` | Mide uso **solo en el dispositivo** (shared_preferences, claves `fac_usage_*`): aperturas, días activos, minutos en primer plano y segundos de actividad principal. |
| `PromptGate` | Límites de frecuencia para cualquier sugerencia (claves `fac_prompt_*`): una por sesión y por día, cooldown de 14 días, máximo 3 veces; aceptada o "no volver a mostrar" la cierra. |
| `EcosystemPrompts` | La hoja "¿Te está sirviendo…? También hice estas apps". Se muestra solo con buen uso (≥ 5 días distintos o ≥ 30 min de actividad) y nunca durante la actividad. |
| `EcosystemSection` | Sección "Más apps" para Ajustes: las otras apps con su ícono real, nombre, etiqueta "Beta" y tagline (como la lista de /apps del sitio), y una fila "Ver todas en la web" que lleva a /apps. |
| `FedeApp` | Registro de las apps (Afinador, Metrónomo, Atril, Generador de Tonos), con su ícono y los links a Play Store y a la web. **Links:** en Android, las apps públicas abren la Play Store y las beta abren su ficha en `federicorandazzo.com.ar/apps/#<id>`, donde se pide acceso como tester o, si ya lo es, aparece el botón a Google Play. En otras plataformas abren la versión web, o la ficha en /apps si no hay versión web. |

> Cuando una app beta pase a producción, cambiar `beta: false` en `FedeApp`.

Textos en español e inglés (cualquier otro idioma usa inglés).

## Cuenta y sincronización (v0.4.0)

Las apps funcionan **siempre** sin cuenta y sin internet. Con sesión iniciada (solo Google),
la biblioteca de cada app se sincroniza con `users/{uid}/appData/{appId}` en Firestore
(proyecto `federicorandazzo-a5c9b`).

| Pieza | Qué hace |
| :-- | :-- |
| `SyncFields` / `DeviceIdentity` | Contrato de los ítems sincronizables (`id`, `rev`, `updatedAt`, `deleted`, `deletedAt`, `dev`) e id estable de la instalación. |
| `FedeAccount` | Login con Google y cierre de sesión. **Web:** popup (`linkWithPopup` / `signInWithPopup`). **Android:** `google_sign_in` → `linkWithCredential` sobre la sesión anónima; si la cuenta ya existe (`credential-already-in-use`), `signInWithCredential`. Si falta, crea el perfil `users/{uid}` con el mismo formato que el sitio (nunca bloquea el login). |
| `LibrarySync` | Motor de sincronización: 1 documento por app, merge por ítem en una transacción. |
| `SyncAdapter` | Lo implementa cada app (colecciones, leer, aplicar, copia por conflicto). |
| `mergeCollection()` | Función pura con todo el algoritmo de merge. |
| `RemoteStore` | Acceso a la nube: `FirestoreRemoteStore` (real) e `InMemoryRemoteStore` (tests). |
| `AccountSection` | Sección "Cuenta" para Ajustes. |
| `EcosystemPrompts.maybeShowLoginPrompt` | Sugerencia de login en capas (`PromptGate`, id `login`). |

### API

```dart
// Cuenta
FedeAccount.instance.user;                     // ValueListenable<FedeUser?> (null = sin sesión o anónimo)
FedeAccount.instance.currentUser;              // FedeUser? {uid, email, displayName, photoUrl}
await FedeAccount.instance.signInWithGoogle(); // FedeUser? (null = canceló); lanza FedeAuthException(code)
await FedeAccount.instance.signOut();          // Firebase + Google; no borra nada local

// Sincronización
await LibrarySync.instance.configure(MiAdapter()); // una vez, después de Firebase.initializeApp
LibrarySync.instance.status;                   // ValueListenable<SyncStatus> {state, lastSyncedAt, lastError}
LibrarySync.instance.notifyLocalChange();      // después de cada cambio local
await LibrarySync.instance.syncNow(force: true);
LibrarySync.instance.canPurgeLocally(collection, id, rev); // para la purga propia de lápidas

// UI
AccountSection(hasLibrary: true, showHeader: false, iconColor: ..., buttonColor: ..., contentPadding: ...);
EcosystemPrompts.maybeShowLoginPrompt(context, currentApp: FedeApp.metronomo, libraryCount: n);
```

`SyncState`: `disabled` (sin sesión) · `idle` · `syncing` · `offline` (se reintenta en el próximo
disparador) · `error`. `FedeAuthError`: `network`, `userDisabled`, `configuration`, `popupBlocked`,
`unknown` (mensajes en `FacStrings.authError`).

### Contrato del adapter

```dart
class MiAdapter implements SyncAdapter {
  @override String get appId => 'metronomo';            // tiene que estar permitido en las reglas
  @override List<String> get collections => ['sessions', 'playlists', 'presets'];

  /// Todos los ítems (JSON completo) **con lápidas**.
  @override Future<List<Map<String, dynamic>>> readAll(String collection) async => ...;

  /// Escribir `upserts` **tal cual** (sin subir rev ni tocar updatedAt/dev; pueden ser lápidas)
  /// y eliminar físicamente `removals` (lápidas purgadas). Notificar a la UI.
  @override Future<void> applyRemote(String collection,
      {required List<Map<String, dynamic>> upserts, required List<String> removals}) async => ...;

  /// Copia por conflicto: id nuevo (UUID) y nombre "… (otro dispositivo)".
  /// El paquete pone rev 1, updatedAt, dev y quita la lápida.
  @override Map<String, dynamic> conflictCopy(String collection, Map<String, dynamic> item) =>
      {...item, 'id': uuid(), 'name': '${item['name']} (otro dispositivo)'};
}
```

Reglas para la app: cada cambio local sube `rev` (también borrar, que deja lápida); `applyRemote`
no debe llamar a `notifyLocalChange` (no es un cambio local).

### Formato en Firestore

```text
users/{uid}/appData/{appId} = {
  schemaVersion: 1, updatedAt: serverTimestamp,
  collections: { <colección>: { <id>: { rev, deleted, deletedAt, updatedAt, dev, payload: "<JSON del ítem>" } } }
}
```

`payload` va como texto JSON (Firestore no admite listas dentro de listas y mezcla int/double).
Límite: 1 MB por documento. Las colecciones que la app no conoce se conservan.

### Merge (por ítem)

Cada dispositivo guarda `base[id]` = `rev` en la última sync exitosa (SharedPreferences,
`fac_sync_base_<uid>_<appId>`). Cambio local si `L.rev != base`; en la nube si `R.rev != base`;
sin `base` (primer sync tras el login) se consideran cambiados los dos.

| Caso | Resultado |
| :-- | :-- |
| Solo en local | Se sube. |
| Solo en la nube y viva | Se baja. |
| Solo en la nube como lápida | Se ignora. |
| Sin cambios locales, la nube cambió | Se baja (también lápidas). |
| Cambio local, la nube sin cambios | Se sube. |
| Cambiaron los dos, mismo contenido (ignorando campos de sync) | Queda la `rev` más alta; con la misma `rev`, la versión de la nube. |
| Cambiaron los dos y uno es un borrado | Gana la edición, con `rev` = máx + 1. |
| Cambiaron los dos, ediciones distintas | Gana la `rev` más alta (empate: `updatedAt` más reciente → `dev` mayor). Si gana la local con la misma `rev`, se le suma 1. La otra versión se guarda como copia por conflicto (`rev` 1) en los dos lados. |

**Lápidas:** en la nube se purgan (en la misma transacción) cuando superan 30 días; en local, cuando
ya están sincronizadas y superan 30 días (o si nunca se subieron y la nube no las tiene). Caso límite
aceptado: un dispositivo que pase más de 30 días sin sincronizar puede revivir un ítem borrado en otro.

**Cambios durante la sync:** si el usuario modifica un ítem mientras corre la transacción, no se pisa;
queda para la próxima sync.

### Cuándo se sincroniza

Siempre con sesión iniciada y sin bloquear la UI: al iniciar sesión; al llamar a `configure`
(abrir la app); al volver a la app si pasaron más de 2 min; 10 s después del último
`notifyLocalChange()`; con "Sincronizar ahora". Entre una sync y otra pasan al menos 20 s
(salvo `force`); una sola a la vez (los pedidos se encolan).

**Costo:** 1 lectura + como máximo 1 escritura por sync (sin listeners). Entra de sobra en el plan
gratuito. Cerrar sesión deja la biblioteca en el dispositivo y borra el `base` de ese `uid`.

### Integración en una app, paso a paso

1. `pubspec.yaml`: ya trae `firebase_core`, `firebase_auth`, `cloud_firestore` y `google_sign_in`
   (^6.2.2) como dependencias del paquete; la app sigue declarando las suyas con las mismas restricciones.
2. **Android:** el SHA-1 / SHA-256 de la firma (debug, upload y la de Play App Signing) tiene que estar
   cargado en la app Android del proyecto Firebase, y el `google-services.json` actualizado
   (con el cliente OAuth web, tipo 3). Sin eso, Google Sign-In falla con `ApiException: 10`
   (`FedeAuthError.configuration`). Proveedor Google habilitado en Firebase Auth.
3. **Web:** el dominio tiene que estar en *Authorized domains* de Firebase Auth. La sesión se comparte
   con el sitio (mismo origen).
4. `main.dart`, después de `Firebase.initializeApp(...)` y de `UsageTracker.instance.init()`:
   `await LibrarySync.instance.configure(MiAdapter());` (sin biblioteca no hace falta).
5. Después de cada cambio local: `LibrarySync.instance.notifyLocalChange();`.
6. En `applyRemote`, refrescar la UI y ejecutar los mismos hooks que un borrado local cuando llega
   una lápida (p. ej. sacar la sesión de las playlists).
7. Si la app purga lápidas por su cuenta, hacerlo solo si `LibrarySync.instance.canPurgeLocally(...)`.
8. Ajustes: `AccountSection(...)` (Afinador: `hasLibrary: false`).
9. Al guardar un ítem: `EcosystemPrompts.maybeShowLoginPrompt(context, currentApp: ..., libraryCount: n)`.

## Tests

```powershell
flutter test
```

Incluyen todas las filas de la tabla de merge, purga, conflictos, convergencia (2 y 3 dispositivos
con operaciones aleatorias) y `LibrarySync` con `InMemoryRemoteStore` (dos dispositivos, sin conexión,
debounce, intervalo mínimo, cierre de sesión).
