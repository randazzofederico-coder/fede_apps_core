import 'package:flutter/foundation.dart';

import 'usage_tracker.dart';

/// Resultado de una sugerencia mostrada.
enum PromptResult {
  /// Tocó la acción principal: no se vuelve a mostrar esa sugerencia.
  accepted,

  /// "Ahora no": vuelve a aparecer después del cooldown.
  dismissed,

  /// "No volver a mostrar".
  never,
}

/// Límites de frecuencia para cualquier sugerencia (apps, login...).
///
/// Reglas:
/// * Una sugerencia aceptada o marcada "no volver a mostrar" no vuelve.
/// * Como máximo [maxShows] veces, separadas al menos por [cooldown].
/// * Como máximo **una sugerencia (de cualquier tipo) por sesión y por día**.
class PromptGate {
  PromptGate._();
  static final PromptGate instance = PromptGate._();

  static const _kLastAnyDay = 'fac_prompt_last_any_day';
  String _kShows(String id) => 'fac_prompt_${id}_shows';
  String _kLast(String id) => 'fac_prompt_${id}_last';
  String _kState(String id) => 'fac_prompt_${id}_state';

  int? _lastSessionShown;

  UsageTracker get _tracker => UsageTracker.instance;

  int shows(String id) => _tracker.prefs?.getInt(_kShows(id)) ?? 0;

  bool isClosed(String id) => _tracker.prefs?.getString(_kState(id)) != null;

  bool canShow(
    String id, {
    Duration cooldown = const Duration(days: 14),
    int maxShows = 3,
  }) {
    final p = _tracker.prefs;
    if (p == null) return false;
    if (isClosed(id)) return false;
    if (shows(id) >= maxShows) return false;
    if (_lastSessionShown == _tracker.sessionId) return false;
    final now = _tracker.clock();
    if (p.getString(_kLastAnyDay) == _day(now)) return false;
    final last = DateTime.tryParse(p.getString(_kLast(id)) ?? '');
    if (last != null && now.difference(last) < cooldown) return false;
    return true;
  }

  Future<void> markShown(String id) async {
    final p = _tracker.prefs;
    if (p == null) return;
    final now = _tracker.clock();
    _lastSessionShown = _tracker.sessionId;
    await p.setInt(_kShows(id), shows(id) + 1);
    await p.setString(_kLast(id), now.toIso8601String());
    await p.setString(_kLastAnyDay, _day(now));
  }

  Future<void> markResult(String id, PromptResult result) async {
    final p = _tracker.prefs;
    if (p == null) return;
    switch (result) {
      case PromptResult.accepted:
        await p.setString(_kState(id), 'accepted');
      case PromptResult.never:
        await p.setString(_kState(id), 'never');
      case PromptResult.dismissed:
        break;
    }
  }

  @visibleForTesting
  void debugReset() => _lastSessionShown = null;

  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
