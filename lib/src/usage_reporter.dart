import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account.dart';
import 'ecosystem_apps.dart';
import 'goatcounter_stub.dart'
    if (dart.library.io) 'goatcounter_io.dart'
    if (dart.library.js_interop) 'goatcounter_web.dart' as gc_transport;
import 'usage_tracker.dart';

/// Endpoint público de GoatCounter compartido por las 5 apps del ecosistema.
const String kDefaultAppStatsEndpoint = 'https://appstats.federicorandazzo.com.ar/count';

/// Firma para enviar hits a GoatCounter (inyectable en tests).
typedef GoatCounterSender = Future<void> Function(Uri uri);

/// Etiqueta normalizada de la plataforma actual (`web`, `android`, `ios`, etc.).
String currentPlatformLabel() {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.windows => 'windows',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.linux => 'linux',
    TargetPlatform.fuchsia => 'fuchsia',
  };
}

/// Construye la URL `/count` de GoatCounter para un pageview o evento.
Uri buildGoatCounterUri({
  required String endpoint,
  required String path,
  String? title,
  String? referrer,
  bool event = false,
  String? cacheBuster,
}) {
  final base = Uri.parse(endpoint);
  final params = <String, String>{
    'p': path,
    if (title != null && title.isNotEmpty) 't': title,
    if (referrer != null && referrer.isNotEmpty) 'r': referrer,
    if (event) 'e': 'true',
    'rnd': cacheBuster ?? DateTime.now().millisecondsSinceEpoch.toRadixString(36),
  };
  return base.replace(queryParameters: params);
}

/// Agrupa un tramo de práctica en buckets legibles, o `null` si duró < 15 s.
String? practiceDurationBucket(int seconds) {
  if (seconds < 15) return null;
  if (seconds < 60) return '15s-1m';
  if (seconds < 300) return '1-5m';
  if (seconds < 900) return '5-15m';
  if (seconds < 1800) return '15-30m';
  return '30m+';
}

/// Devuelve las claves `YYYY-MM-DD` estrictamente anteriores a la ventana de [keepDays] días.
List<String> staleRecentDayKeys(
  Iterable<String> keys,
  DateTime now, {
  int keepDays = 30,
}) {
  final todayUtc = DateTime.utc(now.year, now.month, now.day);
  final stale = <String>[];
  for (final key in keys) {
    final parts = key.split('-');
    if (parts.length != 3) continue;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) continue;
    final parsed = DateTime.utc(y, m, d);
    if (parsed.year != y || parsed.month != m || parsed.day != d) continue;
    if (todayUtc.difference(parsed).inDays >= keepDays) {
      stale.add(key);
    }
  }
  stale.sort();
  return stale;
}

/// Acumulador diario de métricas pendientes o enviadas.
@immutable
class DayUsageDelta {
  const DayUsageDelta({
    this.opens = 0,
    this.foregroundSec = 0,
    this.activitySec = 0,
  });

  final int opens;
  final int foregroundSec;
  final int activitySec;

  bool get isEmpty => opens == 0 && foregroundSec == 0 && activitySec == 0;

  DayUsageDelta operator +(DayUsageDelta other) => DayUsageDelta(
        opens: opens + other.opens,
        foregroundSec: foregroundSec + other.foregroundSec,
        activitySec: activitySec + other.activitySec,
      );

  DayUsageDelta subtractClamped(DayUsageDelta sent) => DayUsageDelta(
        opens: math.max(0, opens - sent.opens),
        foregroundSec: math.max(0, foregroundSec - sent.foregroundSec),
        activitySec: math.max(0, activitySec - sent.activitySec),
      );

  Map<String, dynamic> toJson() => {
        'o': opens,
        'f': foregroundSec,
        'a': activitySec,
      };

  factory DayUsageDelta.fromJson(Map<String, dynamic> json) => DayUsageDelta(
        opens: (json['o'] as num?)?.toInt() ?? 0,
        foregroundSec: (json['f'] as num?)?.toInt() ?? 0,
        activitySec: (json['a'] as num?)?.toInt() ?? 0,
      );
}

/// Carga útil de una escritura incremental hacia `users/{uid}/appUsage/{sourceId}`.
@immutable
class UsageFlushPayload {
  const UsageFlushPayload({
    required this.uid,
    required this.sourceId,
    required this.days,
    required this.activeAt,
    required this.platform,
    this.appVersion,
    this.includeFirstActiveAt = false,
    this.pruneRecentDays = const [],
  });

  final String uid;
  final String sourceId;
  final Map<String, DayUsageDelta> days;
  final DateTime activeAt;
  final String platform;
  final String? appVersion;
  final bool includeFirstActiveAt;
  final List<String> pruneRecentDays;
}

/// Backend de almacenamiento para métricas individuales (Firestore en prod, memoria en tests).
abstract class UsageStore {
  Future<void> applyDelta(UsageFlushPayload payload);
}

/// Implementación oficial sobre Cloud Firestore (`users/{uid}/appUsage/{sourceId}`).
class FirestoreUsageStore implements UsageStore {
  FirestoreUsageStore([FirebaseFirestore? db]) : _db = db;

  final FirebaseFirestore? _db;

  FirebaseFirestore? _resolveDb() {
    if (_db != null) return _db;
    if (Firebase.apps.isEmpty) return null;
    return FirebaseFirestore.instance;
  }

  @override
  Future<void> applyDelta(UsageFlushPayload payload) async {
    final db = _resolveDb();
    if (db == null) throw StateError('Firebase no inicializado');
    if (payload.days.isEmpty && payload.pruneRecentDays.isEmpty) return;

    var totalOpens = 0;
    var totalFg = 0;
    var totalAct = 0;

    final recentDaysPatch = <String, dynamic>{};
    final monthlyBuckets = <String, _MonthlyAccumulator>{};

    for (final entry in payload.days.entries) {
      final dayKey = entry.key;
      final d = entry.value;
      if (d.isEmpty) continue;

      totalOpens += d.opens;
      totalFg += d.foregroundSec;
      totalAct += d.activitySec;

      recentDaysPatch[dayKey] = <String, dynamic>{
        if (d.opens > 0) 'opens': FieldValue.increment(d.opens),
        if (d.foregroundSec > 0) 'foregroundSec': FieldValue.increment(d.foregroundSec),
        if (d.activitySec > 0) 'activitySec': FieldValue.increment(d.activitySec),
      };

      if (dayKey.length >= 10) {
        final monthKey = dayKey.substring(0, 7);
        final dayOfMonth = dayKey.substring(8, 10);
        final acc = monthlyBuckets.putIfAbsent(monthKey, _MonthlyAccumulator.new);
        acc.opens += d.opens;
        acc.foregroundSec += d.foregroundSec;
        acc.activitySec += d.activitySec;
        acc.dayKeys.add(dayOfMonth);
      }
    }

    for (final staleKey in payload.pruneRecentDays) {
      if (!payload.days.containsKey(staleKey)) {
        recentDaysPatch[staleKey] = FieldValue.delete();
      }
    }

    final monthlyPatch = <String, dynamic>{
      for (final entry in monthlyBuckets.entries)
        entry.key: <String, dynamic>{
          if (entry.value.opens > 0) 'opens': FieldValue.increment(entry.value.opens),
          if (entry.value.foregroundSec > 0)
            'foregroundSec': FieldValue.increment(entry.value.foregroundSec),
          if (entry.value.activitySec > 0)
            'activitySec': FieldValue.increment(entry.value.activitySec),
          if (entry.value.dayKeys.isNotEmpty)
            'activeDayKeys': FieldValue.arrayUnion(entry.value.dayKeys.toList()),
        },
    };

    final activeIso = payload.activeAt.toUtc().toIso8601String();
    final trimmedVersion = payload.appVersion?.trim();

    final docData = <String, dynamic>{
      'schemaVersion': 1,
      'sourceId': payload.sourceId,
      if (payload.includeFirstActiveAt) 'firstActiveAt': activeIso,
      'lastActiveAt': activeIso,
      'updatedAt': FieldValue.serverTimestamp(),
      'lastPlatform': payload.platform,
      if (trimmedVersion != null && trimmedVersion.isNotEmpty) 'lastAppVersion': trimmedVersion,
      'platforms': FieldValue.arrayUnion([payload.platform]),
      if (totalOpens > 0 || totalFg > 0 || totalAct > 0)
        'totals': <String, dynamic>{
          if (totalOpens > 0) 'opens': FieldValue.increment(totalOpens),
          if (totalFg > 0) 'foregroundSec': FieldValue.increment(totalFg),
          if (totalAct > 0) 'activitySec': FieldValue.increment(totalAct),
        },
      if (recentDaysPatch.isNotEmpty) 'recentDays': recentDaysPatch,
      if (monthlyPatch.isNotEmpty) 'monthly': monthlyPatch,
    };

    final ref = db
        .collection('users')
        .doc(payload.uid)
        .collection('appUsage')
        .doc(payload.sourceId);
    await ref.set(docData, SetOptions(merge: true)).timeout(const Duration(seconds: 6));
  }
}

class _MonthlyAccumulator {
  int opens = 0;
  int foregroundSec = 0;
  int activitySec = 0;
  final Set<String> dayKeys = {};
}

/// Implementación en memoria para tests unitarios: simula exactamente los `increment`,
/// `arrayUnion` y podas de Firestore sin tocar red.
class InMemoryUsageStore implements UsageStore {
  final Map<String, Map<String, dynamic>> docs = {};
  bool failWrites = false;
  int writeCount = 0;
  Future<void> Function(UsageFlushPayload payload)? onBeforeWrite;

  Map<String, dynamic>? docFor(String uid, String sourceId) => docs['$uid/$sourceId'];

  @override
  Future<void> applyDelta(UsageFlushPayload payload) async {
    if (onBeforeWrite != null) {
      await onBeforeWrite!(payload);
    }
    if (failWrites) {
      throw StateError('Simulated offline write failure');
    }
    writeCount++;

    final docKey = '${payload.uid}/${payload.sourceId}';
    final doc = docs.putIfAbsent(docKey, () => <String, dynamic>{});
    final activeIso = payload.activeAt.toUtc().toIso8601String();

    doc['schemaVersion'] = 1;
    doc['sourceId'] = payload.sourceId;
    if (payload.includeFirstActiveAt && !doc.containsKey('firstActiveAt')) {
      doc['firstActiveAt'] = activeIso;
    }
    doc['lastActiveAt'] = activeIso;
    doc['updatedAt'] = activeIso;
    doc['lastPlatform'] = payload.platform;
    if (payload.appVersion != null && payload.appVersion!.trim().isNotEmpty) {
      doc['lastAppVersion'] = payload.appVersion!.trim();
    }

    final platforms = List<String>.from((doc['platforms'] as List?) ?? const []);
    if (!platforms.contains(payload.platform)) platforms.add(payload.platform);
    doc['platforms'] = platforms;

    final totals = Map<String, int>.from((doc['totals'] as Map?) ?? const {});
    final recentDays = Map<String, Map<String, int>>.fromEntries(
      ((doc['recentDays'] as Map?) ?? const {}).entries.map(
            (e) => MapEntry(e.key.toString(), Map<String, int>.from(e.value as Map)),
          ),
    );
    final monthly = Map<String, Map<String, dynamic>>.fromEntries(
      ((doc['monthly'] as Map?) ?? const {}).entries.map(
            (e) => MapEntry(e.key.toString(), Map<String, dynamic>.from(e.value as Map)),
          ),
    );

    for (final entry in payload.days.entries) {
      final dayKey = entry.key;
      final d = entry.value;
      if (d.isEmpty) continue;

      totals['opens'] = (totals['opens'] ?? 0) + d.opens;
      totals['foregroundSec'] = (totals['foregroundSec'] ?? 0) + d.foregroundSec;
      totals['activitySec'] = (totals['activitySec'] ?? 0) + d.activitySec;

      final rd = recentDays.putIfAbsent(dayKey, () => <String, int>{});
      rd['opens'] = (rd['opens'] ?? 0) + d.opens;
      rd['foregroundSec'] = (rd['foregroundSec'] ?? 0) + d.foregroundSec;
      rd['activitySec'] = (rd['activitySec'] ?? 0) + d.activitySec;

      if (dayKey.length >= 10) {
        final monthKey = dayKey.substring(0, 7);
        final dayOfMonth = dayKey.substring(8, 10);
        final m = monthly.putIfAbsent(monthKey, () => <String, dynamic>{});
        m['opens'] = ((m['opens'] as int?) ?? 0) + d.opens;
        m['foregroundSec'] = ((m['foregroundSec'] as int?) ?? 0) + d.foregroundSec;
        m['activitySec'] = ((m['activitySec'] as int?) ?? 0) + d.activitySec;
        final daysSet = List<String>.from((m['activeDayKeys'] as List?) ?? const []);
        if (!daysSet.contains(dayOfMonth)) daysSet.add(dayOfMonth);
        m['activeDayKeys'] = daysSet;
      }
    }

    for (final stale in payload.pruneRecentDays) {
      recentDays.remove(stale);
    }

    doc['totals'] = totals;
    doc['recentDays'] = recentDays;
    doc['monthly'] = monthly;
  }
}

/// Coordina telemetría híbrida:
/// - **Todos los usuarios:** hits anónimos a GoatCounter (`appstats.federicorandazzo.com.ar`).
/// - **Usuarios con sesión:** deltas incrementales locales con throttle hacia Firestore
///   (`users/{uid}/appUsage/{sourceId}`).
///
/// Nunca lanza excepciones ni bloquea el hilo principal.
class UsageReporter {
  UsageReporter._();
  static final UsageReporter instance = UsageReporter._();

  static const _kPendingPrefix = 'fac_usage_pending_';
  static const _kFirstReportedPrefix = 'fac_usage_first_reported_';
  static const _kKnownDaysPrefix = 'fac_usage_known_days_';
  static const _kLastPrunePrefix = 'fac_usage_last_prune_';
  static const _kLastFlushPrefix = 'fac_usage_last_flush_';
  static const _pruneInterval = Duration(days: 7);
  static const _immediateActivityThresholdSec = 60;

  FedeApp? _app;
  String? _appVersion;
  String _goatCounterEndpoint = kDefaultAppStatsEndpoint;
  bool _sendGoatCounter = false;
  bool _enableFirestore = true;
  Duration _minFlushInterval = const Duration(minutes: 30);

  UsageStore? _store;
  GoatCounterSender? _goatCounterSender;
  UsageTracker? _tracker;
  ValueListenable<FedeUser?>? _userListenable;
  DateTime Function()? _clock;
  SharedPreferences? _prefsOverride;
  String? _platformOverride;

  String? _currentUid;
  int _lastGoatCounterSessionId = 0;
  int _lastCapturedOpenSessionId = 0;

  final Map<String, Map<String, DayUsageDelta>> _pendingByUid = {};
  bool _flushing = false;
  String? _pendingFollowUpUid;
  bool _pendingFollowUpForce = false;

  bool get isConfigured => _app != null;

  /// Configura el reporter para la app actual. Puede llamarse antes o después de
  /// `UsageTracker.instance.init()`. Es idempotente y nunca bloquea ni falla.
  void configure({
    required FedeApp app,
    String? appVersion,
    String goatCounterEndpoint = kDefaultAppStatsEndpoint,
    bool sendGoatCounterInDebug = false,
    bool enableFirestore = true,
    Duration minFlushInterval = const Duration(minutes: 30),
    @visibleForTesting UsageStore? store,
    @visibleForTesting GoatCounterSender? goatCounterSender,
    @visibleForTesting UsageTracker? tracker,
    @visibleForTesting ValueListenable<FedeUser?>? userListenable,
    @visibleForTesting DateTime Function()? clock,
    @visibleForTesting SharedPreferences? prefsOverride,
    @visibleForTesting String? platformOverride,
  }) {
    _detachListeners();

    _app = app;
    _appVersion = appVersion;
    _goatCounterEndpoint = goatCounterEndpoint;
    _sendGoatCounter = !kDebugMode || sendGoatCounterInDebug;
    _enableFirestore = enableFirestore;
    _minFlushInterval = minFlushInterval;

    _store = store ?? (enableFirestore ? FirestoreUsageStore() : null);
    _goatCounterSender = goatCounterSender;
    _tracker = tracker ?? UsageTracker.instance;
    _userListenable = userListenable ?? FedeAccount.instance.user;
    _clock = clock;
    _prefsOverride = prefsOverride;
    _platformOverride = platformOverride;

    _tracker!.addDeltaListener(_onDelta);
    _userListenable!.addListener(_onUserChanged);
    _currentUid = _userListenable!.value?.uid;

    final uid = _currentUid;
    final hadPriorPending =
        uid != null && _enableFirestore && !_isPendingMapEmpty(_loadOrHydratePending(uid));

    // Si UsageTracker.init() corrió antes de configure(), capturar la sesión actual
    // sin esperar al próximo evento.
    final activeSessionId = _tracker!.sessionId;
    if (_tracker!.isReady && activeSessionId > 0) {
      if (_lastGoatCounterSessionId != activeSessionId) {
        _lastGoatCounterSessionId = activeSessionId;
        unawaited(_sendSessionOpenHit());
      }
      if (uid != null && _enableFirestore && _lastCapturedOpenSessionId != activeSessionId) {
        _lastCapturedOpenSessionId = activeSessionId;
        _recordLocalDelta(
          uid,
          UsageDelta(dayKey: UsageTracker.dayKeyOf(_now()), opens: 1),
        );
      }
    }

    if (uid != null && hadPriorPending) {
      unawaited(_flushIfPending(uid: uid, force: true));
    }
  }

  /// Envía un evento liviano opcional a GoatCounter (`<appId>/<name>`, sin consumo en Firestore).
  Future<void> trackEvent(String name, {String? title}) async {
    try {
      final app = _app;
      if (app == null || !_sendGoatCounter) return;
      final clean = name.trim().replaceFirst(RegExp(r'^/+'), '');
      if (clean.isEmpty) return;
      final platform = _platform();
      final uri = buildGoatCounterUri(
        endpoint: _goatCounterEndpoint,
        path: '${app.siteId}/$clean',
        title: title ?? platform,
        referrer: platform,
        event: true,
      );
      await _dispatchGoatCounter(uri);
    } catch (_) {
      // Nunca propagar fallos de analítica.
    }
  }

  /// Fuerza un flush inmediato de deltas pendientes (útil para tests).
  @visibleForTesting
  Future<void> debugFlush() async {
    final uid = _currentUid;
    if (uid == null) return;
    await _flush(uid: uid, force: true);
  }

  /// Reinicia el estado interno del reporter (útil para tests).
  @visibleForTesting
  void debugReset() {
    _detachListeners();
    _app = null;
    _appVersion = null;
    _goatCounterEndpoint = kDefaultAppStatsEndpoint;
    _sendGoatCounter = false;
    _enableFirestore = true;
    _minFlushInterval = const Duration(minutes: 30);
    _store = null;
    _goatCounterSender = null;
    _tracker = null;
    _userListenable = null;
    _clock = null;
    _prefsOverride = null;
    _platformOverride = null;
    _currentUid = null;
    _lastGoatCounterSessionId = 0;
    _lastCapturedOpenSessionId = 0;
    _pendingByUid.clear();
    _flushing = false;
    _pendingFollowUpUid = null;
    _pendingFollowUpForce = false;
  }

  void _detachListeners() {
    _tracker?.removeDeltaListener(_onDelta);
    _userListenable?.removeListener(_onUserChanged);
  }

  DateTime _now() => (_clock ?? _tracker?.clock ?? DateTime.now)();

  String _platform() => _platformOverride ?? currentPlatformLabel();

  SharedPreferences? _syncPrefs() => _prefsOverride ?? _tracker?.prefs;

  Future<SharedPreferences?> _resolvePrefs() async {
    final sync = _syncPrefs();
    if (sync != null) return sync;
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  // ── Manejo de deltas de UsageTracker ───────────────────────────────────────
  void _onDelta(UsageDelta delta) {
    final app = _app;
    final tracker = _tracker;
    if (app == null || tracker == null) return;

    // 1) Capa GoatCounter (todos los usuarios).
    if (delta.opens > 0 && _lastGoatCounterSessionId != tracker.sessionId) {
      _lastGoatCounterSessionId = tracker.sessionId;
      unawaited(_sendSessionOpenHit());
    }
    if (delta.activityStopped) {
      final bucket = practiceDurationBucket(delta.activitySec);
      if (bucket != null) {
        unawaited(trackEvent('practice/$bucket'));
      }
    }

    // 2) Capa Firestore (solo usuarios con sesión).
    final uid = _currentUid;
    if (uid == null || !_enableFirestore) return;
    if (delta.opens > 0) {
      _lastCapturedOpenSessionId = tracker.sessionId;
    }

    _recordLocalDelta(uid, delta);

    final shouldFlushNow = _shouldFlushOnDelta(uid, delta);
    if (shouldFlushNow) {
      unawaited(_flush(uid: uid, force: false));
    }
  }

  void _onUserChanged() {
    final newUid = _userListenable?.value?.uid;
    final oldUid = _currentUid;
    _currentUid = newUid;
    if (newUid == null || newUid == oldUid || !_enableFirestore) return;

    final hadPriorPending = !_isPendingMapEmpty(_loadOrHydratePending(newUid));
    final tracker = _tracker;
    if (tracker != null &&
        tracker.isReady &&
        tracker.sessionId > 0 &&
        _lastCapturedOpenSessionId != tracker.sessionId) {
      _lastCapturedOpenSessionId = tracker.sessionId;
      _recordLocalDelta(
        newUid,
        UsageDelta(dayKey: UsageTracker.dayKeyOf(_now()), opens: 1),
      );
    }

    if (hadPriorPending) {
      unawaited(_flushIfPending(uid: newUid, force: true));
    }
  }

  void _recordLocalDelta(String uid, UsageDelta delta) {
    final inc = DayUsageDelta(
      opens: delta.opens,
      foregroundSec: delta.foregroundSec,
      activitySec: delta.activitySec,
    );
    if (inc.isEmpty) return;

    final map = _loadOrHydratePending(uid);
    final prev = map[delta.dayKey];
    map[delta.dayKey] = prev == null ? inc : prev + inc;
    _persistPending(uid, map);
    _recordKnownDay(uid, delta.dayKey);
  }

  bool _shouldFlushOnDelta(String uid, UsageDelta delta) {
    final map = _loadOrHydratePending(uid);
    if (_isPendingMapEmpty(map)) return false;

    if (delta.activityStopped) {
      final totalAct = map.values.fold<int>(0, (acc, d) => acc + d.activitySec);
      if (totalAct >= _immediateActivityThresholdSec) return true;
      return _hasThrottleElapsed(uid);
    }

    if (delta.wentBackground) {
      return _hasThrottleElapsed(uid);
    }

    return false;
  }

  bool _hasThrottleElapsed(String uid) {
    final prefs = _syncPrefs();
    if (prefs == null) return true;
    final lastMs = prefs.getInt(_kLastFlushKey(uid));
    if (lastMs == null) return true;
    final elapsed = _now().difference(DateTime.fromMillisecondsSinceEpoch(lastMs));
    return elapsed >= _minFlushInterval;
  }

  Future<void> _flushIfPending({required String uid, bool force = false}) async {
    final map = _loadOrHydratePending(uid);
    if (_isPendingMapEmpty(map)) return;
    final has60sActivity =
        map.values.fold<int>(0, (acc, d) => acc + d.activitySec) >= _immediateActivityThresholdSec;
    if (!force && !has60sActivity && !_hasThrottleElapsed(uid)) return;
    await _flush(uid: uid, force: force);
  }

  Future<void> _flush({required String uid, bool force = false}) async {
    final app = _app;
    final store = _store;
    if (app == null || store == null || !_enableFirestore) return;

    if (_flushing) {
      _pendingFollowUpUid = uid;
      if (force) _pendingFollowUpForce = true;
      return;
    }

    final liveMap = _loadOrHydratePending(uid);
    final snapshot = <String, DayUsageDelta>{
      for (final e in liveMap.entries)
        if (!e.value.isEmpty) e.key: e.value,
    };
    if (snapshot.isEmpty) return;

    _flushing = true;
    var triggerFollowUp = false;
    try {
      final prefs = _syncPrefs() ?? await _resolvePrefs();
      final now = _now();
      final firstReportedKey = _kFirstReportedKey(uid);
      final includeFirst = !(prefs?.getBool(firstReportedKey) ?? false);

      final lastPruneKey = _kLastPruneKey(uid);
      final lastPruneMs = prefs?.getInt(lastPruneKey);
      final pruneDue = lastPruneMs == null ||
          now.difference(DateTime.fromMillisecondsSinceEpoch(lastPruneMs)) >= _pruneInterval;

      var staleDays = const <String>[];
      if (pruneDue && prefs != null) {
        final known = prefs.getStringList(_kKnownDaysKey(uid)) ?? const <String>[];
        staleDays = staleRecentDayKeys(known, now)
            .where((d) => !snapshot.containsKey(d))
            .toList(growable: false);
      }

      final payload = UsageFlushPayload(
        uid: uid,
        sourceId: app.siteId,
        days: snapshot,
        activeAt: now,
        platform: _platform(),
        appVersion: _appVersion,
        includeFirstActiveAt: includeFirst,
        pruneRecentDays: staleDays,
      );

      await store.applyDelta(payload);

      // Solo restar exactamente lo enviado si Firestore aceptó el delta.
      final current = _loadOrHydratePending(uid);
      for (final entry in snapshot.entries) {
        final existing = current[entry.key];
        if (existing == null) continue;
        final remaining = existing.subtractClamped(entry.value);
        if (remaining.isEmpty) {
          current.remove(entry.key);
        } else {
          current[entry.key] = remaining;
        }
      }
      await _persistPending(uid, current);

      if (prefs != null) {
        await prefs.setInt(_kLastFlushKey(uid), now.millisecondsSinceEpoch);
        if (includeFirst) {
          await prefs.setBool(firstReportedKey, true);
        }
        if (pruneDue) {
          await prefs.setInt(lastPruneKey, now.millisecondsSinceEpoch);
          if (staleDays.isNotEmpty) {
            final staleSet = staleDays.toSet();
            final updatedKnown = (prefs.getStringList(_kKnownDaysKey(uid)) ?? const <String>[])
                .where((d) => !staleSet.contains(d))
                .toList();
            await prefs.setStringList(_kKnownDaysKey(uid), updatedKnown);
          }
        }
      }

      if (_pendingFollowUpUid != null) {
        triggerFollowUp = true;
      }
    } catch (_) {
      // Sin conexión o error transitorio: los deltas quedan intactos en SharedPreferences.
    } finally {
      final followUpUid = _pendingFollowUpUid;
      final followUpForce = _pendingFollowUpForce;
      _pendingFollowUpUid = null;
      _pendingFollowUpForce = false;
      _flushing = false;
      if (triggerFollowUp && followUpUid != null) {
        unawaited(_flushIfPending(uid: followUpUid, force: followUpForce));
      }
    }
  }

  // ── GoatCounter helpers ────────────────────────────────────────────────────
  Future<void> _sendSessionOpenHit() async {
    try {
      final app = _app;
      if (app == null || !_sendGoatCounter) return;
      final uri = buildGoatCounterUri(
        endpoint: _goatCounterEndpoint,
        path: '/${app.siteId}',
        title: app.nameEs,
        referrer: _platform(),
      );
      await _dispatchGoatCounter(uri);
    } catch (_) {}
  }

  Future<void> _dispatchGoatCounter(Uri uri) async {
    try {
      final sender = _goatCounterSender ?? gc_transport.sendGoatCounterHit;
      await sender(uri);
    } catch (_) {}
  }

  // ── Persistencia local por uid/app ─────────────────────────────────────────
  String _scopeSuffix(String uid) => '${uid}_${_app?.siteId ?? 'app'}';
  String _kPendingKey(String uid) => '$_kPendingPrefix${_scopeSuffix(uid)}';
  String _kFirstReportedKey(String uid) => '$_kFirstReportedPrefix${_scopeSuffix(uid)}';
  String _kKnownDaysKey(String uid) => '$_kKnownDaysPrefix${_scopeSuffix(uid)}';
  String _kLastPruneKey(String uid) => '$_kLastPrunePrefix${_scopeSuffix(uid)}';
  String _kLastFlushKey(String uid) => '$_kLastFlushPrefix${_scopeSuffix(uid)}';

  Map<String, DayUsageDelta> _loadOrHydratePending(String uid) {
    final existing = _pendingByUid[uid];
    if (existing != null) return existing;

    final loaded = <String, DayUsageDelta>{};
    final raw = _syncPrefs()?.getString(_kPendingKey(uid));
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            if (entry.value is Map) {
              final d = DayUsageDelta.fromJson(
                Map<String, dynamic>.from(entry.value as Map),
              );
              if (!d.isEmpty) loaded[entry.key] = d;
            }
          }
        }
      } catch (_) {}
    }
    _pendingByUid[uid] = loaded;
    return loaded;
  }

  Future<void> _persistPending(String uid, Map<String, DayUsageDelta> map) async {
    final prefs = _syncPrefs() ?? await _resolvePrefs();
    if (prefs == null) return;
    final nonEmpty = <String, dynamic>{
      for (final e in map.entries)
        if (!e.value.isEmpty) e.key: e.value.toJson(),
    };
    final future = nonEmpty.isEmpty
        ? prefs.remove(_kPendingKey(uid))
        : prefs.setString(_kPendingKey(uid), jsonEncode(nonEmpty));
    await future;
  }

  void _recordKnownDay(String uid, String dayKey) {
    final prefs = _syncPrefs();
    if (prefs == null) return;
    final key = _kKnownDaysKey(uid);
    final current = prefs.getStringList(key) ?? const <String>[];
    if (!current.contains(dayKey)) {
      unawaited(prefs.setStringList(key, [...current, dayKey]));
    }
  }

  static bool _isPendingMapEmpty(Map<String, DayUsageDelta> map) =>
      map.values.every((d) => d.isEmpty);
}
