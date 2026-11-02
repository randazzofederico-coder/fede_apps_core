import 'package:flutter/material.dart';

import 'ecosystem_apps.dart';
import 'ecosystem_section.dart';
import 'prompt_gate.dart';
import 'usage_tracker.dart';

/// Sugerencias del ecosistema ("conocé las otras apps / la web").
///
/// Cada app llama a [maybeShowAppsPrompt] en sus "momentos tranquilos"
/// (entrar a Ajustes, pausar el micrófono, detener la reproducción...).
/// La función decide sola si corresponde mostrar algo; casi siempre no hace nada.
class EcosystemPrompts {
  EcosystemPrompts._();

  static const appsPromptId = 'apps';

  /// Umbrales por defecto: uso "bueno" = 5 días distintos o 30 min de actividad principal.
  static const defaultMinActiveDays = 5;
  static const defaultMinActivity = Duration(minutes: 30);

  static bool isEligible({
    int minActiveDays = defaultMinActiveDays,
    Duration minActivity = defaultMinActivity,
  }) {
    final t = UsageTracker.instance;
    if (!t.isReady) return false;
    if (t.isActivityRunning) return false; // nunca mientras se usa (mic, audio)
    return t.activeDays >= minActiveDays ||
        t.activitySeconds >= minActivity.inSeconds;
  }

  /// Muestra (si corresponde) la hoja "¿Te está sirviendo...? También hice estas apps".
  /// Devuelve `true` si se mostró.
  static Future<bool> maybeShowAppsPrompt(
    BuildContext context, {
    required FedeApp currentApp,
    int minActiveDays = defaultMinActiveDays,
    Duration minActivity = defaultMinActivity,
  }) async {
    final gate = PromptGate.instance;
    if (!isEligible(minActiveDays: minActiveDays, minActivity: minActivity)) {
      return false;
    }
    if (!gate.canShow(appsPromptId)) return false;
    if (!context.mounted) return false;

    await gate.markShown(appsPromptId);
    if (!context.mounted) return false;
    final result = await showAppsSheet(
      context,
      currentApp: currentApp,
      offerNever: gate.shows(appsPromptId) >= 2,
    );
    await gate.markResult(appsPromptId, result ?? PromptResult.dismissed);
    return true;
  }

  /// La hoja en sí (también se puede abrir a mano, sin límites de frecuencia).
  static Future<PromptResult?> showAppsSheet(
    BuildContext context, {
    required FedeApp currentApp,
    bool offerNever = false,
  }) {
    return showModalBottomSheet<PromptResult>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) =>
          _AppsSheet(currentApp: currentApp, offerNever: offerNever),
    );
  }
}

class _AppsSheet extends StatelessWidget {
  const _AppsSheet({required this.currentApp, required this.offerNever});

  final FedeApp currentApp;
  final bool offerNever;

  @override
  Widget build(BuildContext context) {
    final s = FacStrings.of(context);
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                s.appsPromptTitle(currentApp),
                style: theme.textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(s.appsPromptBody, style: theme.textTheme.bodyMedium),
            ),
            for (final app in currentApp.others)
              EcosystemAppTile(
                app: app,
                onTap: () {
                  openExternal(app.uri(es: s.es));
                  Navigator.of(context).pop(PromptResult.accepted);
                },
              ),
            ListTile(
              leading: const SizedBox(width: 40, child: Icon(Icons.apps)),
              title: Text(s.allApps),
              subtitle: Text(s.allAppsSub),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () {
                openExternal(appsPageUri(es: s.es));
                Navigator.of(context).pop(PromptResult.accepted);
              },
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (offerNever)
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).pop(PromptResult.never),
                    child: Text(s.dontShowAgain),
                  ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop(PromptResult.dismissed),
                  child: Text(s.notNow),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
