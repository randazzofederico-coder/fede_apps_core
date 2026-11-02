import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Medición de uso 100% local (shared_preferences). No manda nada a ningún servidor.
///
/// Mide:
/// * [openCount]: aperturas (arranques en frío + vueltas tras ≥30 min en segundo plano).
/// * [activeDays]: días calendario distintos en los que se usó la app.
/// * [foregroundMinutes]: minutos con la app en primer plano.
/// * [activitySeconds]: segundos de la "actividad principal" de cada app
///   (afinar, reproducir...), marcada con [startActivity] / [stopActivity].
///
/// Uso: `await UsageTracker.instance.init();` en `main()`, antes de `runApp`.
class UsageTracker {
  UsageTracker._();
  static final UsageTracker instance = UsageTracker._();

  /// Reloj inyectable (para tests).
  DateTime Function() clock = DateTime.now;

  static const _kFirstOpen = 'fac_usage_first_open';
  static const _kOpenCount = 'fac_usage_open_count';
  static const _kActiveDays = 'fac_usage_active_days';
  static const _kLastDay = 'fac_usage_last_day';
  static const _kForegroundSec = 'fac_usage_foreground_sec';
  static const _kActivitySec = 'fac_usage_activity_sec';

  /// Tras este tiempo en segundo plano, volver cuenta como una apertura (y sesión) nueva.
  static const newSessionAfter = Duration(minutes: 30);

  /// Tope por tramo, para que un reloj raro o una app olvidada abierta no infle los números.
  static const _maxChunk = Duration(hours: 4);

  SharedPreferences? _prefs;
  AppLifecycleListener? _lifecycle;
  DateTime? _foregroundSince;
  DateTime? _activitySince;
  DateTime? _backgroundSince;
  int _sessionId = 0;

  bool get isReady => _prefs != null;

  /// Preferencias ya cargadas (uso interno del paquete, p. ej. [PromptGate]).
  SharedPreferences? get prefs => _prefs;

  /// Identificador de la sesión actual (cambia en cada apertura). Lo usa [PromptGate]
  /// para no mostrar más de una sugerencia por sesión.
  int get sessionId => _sessionId;

  Future<void> init({SharedPreferences? prefs, bool listenLifecycle = true}) async {
    if (_prefs != null) return;
    _prefs = prefs ?? await SharedPreferences.getInstance();
    final p = _prefs!;
    if (!p.containsKey(_kFirstOpen)) {
      await p.setString(_kFirstOpen, clock().toIso8601String());
    }
    await _registerOpen();
    _foregroundSince = clock();
    if (listenLifecycle) {
      _lifecycle = AppLifecycleListener(
        onHide: _onBackground,
        onShow: _onForeground,
      );
    }
  }

  // ── Lecturas ──────────────────────────────────────────────────────────────
  DateTime? get firstOpenAt {
    final s = _prefs?.getString(_kFirstOpen);
    return s == null ? null : DateTime.tryParse(s);
  }

  int get openCount => _prefs?.getInt(_kOpenCount) ?? 0;
  int get activeDays => _prefs?.getInt(_kActiveDays) ?? 0;

  /// Incluye el tramo en curso.
  int get foregroundMinutes {
    var sec = _prefs?.getInt(_kForegroundSec) ?? 0;
    if (_foregroundSince != null) sec += _elapsedSec(_foregroundSince!);
    return sec ~/ 60;
  }

  /// Incluye el tramo en curso.
  int get activitySeconds {
    var sec = _prefs?.getInt(_kActivitySec) ?? 0;
    if (_activitySince != null) sec += _elapsedSec(_activitySince!);
    return sec;
  }

  bool get isActivityRunning => _activitySince != null || _pausedActivity;

  // ── Actividad principal ───────────────────────────────────────────────────
  /// Llamar cuando empieza la actividad principal (p. ej. el micrófono del afinador).
  /// Llamarlo dos veces seguidas no duplica nada.
  ///
  /// [continuesInBackground]: `true` si la actividad sigue con la app en segundo plano
  /// (audio que sigue sonando: metrónomo, tone generator). Si es `false` (afinador),
  /// el tiempo en segundo plano no se cuenta.
  void startActivity({bool continuesInBackground = false}) {
    _pausedActivity = false;
    _activityInBackground = continuesInBackground;
    _activitySince ??= clock();
  }

  /// Llamar cuando termina la actividad principal.
  Future<void> stopActivity() async {
    _pausedActivity = false;
    final since = _activitySince;
    if (since == null) return;
    _activitySince = null;
    await _add(_kActivitySec, _elapsedSec(since));
  }

  // ── Ciclo de vida ─────────────────────────────────────────────────────────
  Future<void> _onBackground() async {
    _backgroundSince = clock();
    final fg = _foregroundSince;
    _foregroundSince = null;
    if (fg != null) await _add(_kForegroundSec, _elapsedSec(fg));
    final act = _activitySince;
    if (act == null) return;
    if (_activityInBackground) {
      // Sigue sonando: se guarda lo acumulado (por si el sistema mata la app) y sigue contando.
      _activitySince = clock();
      await _add(_kActivitySec, _elapsedSec(act));
    } else {
      // Se corta al ir a segundo plano; si sigue activa, se retoma al volver.
      _activitySince = null;
      _pausedActivity = true;
      await _add(_kActivitySec, _elapsedSec(act));
    }
  }

  bool _pausedActivity = false;
  bool _activityInBackground = false;

  Future<void> _onForeground() async {
    final now = clock();
    _foregroundSince = now;
    if (_pausedActivity) {
      // No se cuenta el tiempo en segundo plano como actividad.
      _activitySince = now;
      _pausedActivity = false;
    }
    final bg = _backgroundSince;
    _backgroundSince = null;
    if (bg == null || now.difference(bg) >= newSessionAfter) {
      await _registerOpen();
    } else {
      await _registerDay();
    }
  }

  /// Para tests: simula ir a segundo plano y volver.
  @visibleForTesting
  Future<void> debugBackground() => _onBackground();
  @visibleForTesting
  Future<void> debugForeground() => _onForeground();

  /// Para tests: olvida el estado en memoria.
  @visibleForTesting
  void debugReset() {
    _lifecycle?.dispose();
    _lifecycle = null;
    _prefs = null;
    _foregroundSince = null;
    _activitySince = null;
    _backgroundSince = null;
    _pausedActivity = false;
    _activityInBackground = false;
    _sessionId = 0;
    clock = DateTime.now;
  }

  // ── Internos ──────────────────────────────────────────────────────────────
  Future<void> _registerOpen() async {
    _sessionId++;
    await _add(_kOpenCount, 1);
    await _registerDay();
  }

  Future<void> _registerDay() async {
    final p = _prefs;
    if (p == null) return;
    final now = clock();
    final today =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    if (p.getString(_kLastDay) != today) {
      await p.setString(_kLastDay, today);
      await _add(_kActiveDays, 1);
    }
  }

  int _elapsedSec(DateTime since) {
    final d = clock().difference(since);
    if (d.isNegative) return 0;
    return (d > _maxChunk ? _maxChunk : d).inSeconds;
  }

  Future<void> _add(String key, int delta) async {
    final p = _prefs;
    if (p == null || delta <= 0) return;
    await p.setInt(key, (p.getInt(key) ?? 0) + delta);
  }
}
