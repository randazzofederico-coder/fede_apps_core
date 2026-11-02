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

## Próximo

Cuenta (login con Google vinculando la sesión anónima) y sincronización de bibliotecas local-first.

## Tests

```powershell
flutter test
```
