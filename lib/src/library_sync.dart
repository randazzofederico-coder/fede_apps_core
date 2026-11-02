import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account.dart';
import 'remote_store.dart';
import 'sync_fields.dart';
import 'sync_merge.dart';

/// Lo implementa cada app para que [LibrarySync] pueda leer y escribir su biblioteca.
///
/// Los ítems son el JSON completo, con los campos de [SyncFields]
/// (`id`, `rev`, `updatedAt`, `deleted`, `deletedAt`, `dev`).
abstract class SyncAdapter {
  /// Id de la app en Firestore (`users/{uid}/appData/{appId}`), p. ej. `metronomo`.
  String get appId;

  /// Nombres de las colecciones (p. ej. `['sessions', 'playlists']`).
  List<String> get collections;

  /// Todos los ítems de la colección, **con lápidas**.
  Future<List<Map<String, dynamic>>> readAll(String collection);

  /// Aplica lo que llegó de la nube: escribe [upserts] **tal cual** (sin subir
  /// `rev` ni tocar `updatedAt`/`dev`; pueden ser lápidas) y elimina
  /// físicamente los ids de [removals] (lápidas purgadas).
  Future<void> applyRemote(
    String collection, {
    required List<Map<String, dynamic>> upserts,
    required List<String> removals,
  });

  /// Copia por conflicto de [item]: id nuevo y nombre "… (otro dispositivo)".
  /// El paquete se encarga de `rev`, `updatedAt`, `dev` y de quitar la lápida.
  Map<String, dynamic> conflictCopy(String collection, Map<String, dynamic> item);
}

enum SyncState {
  /// Sin sesión o sin adapter: no se sincroniza.
  disabled,
  idle,
  syncing,

  /// Sin conexión: se reintenta en el próximo disparador.
  offline,
  error,
}

@immutable
class SyncStatus {
  const SyncStatus(this.state, {this.lastSyncedAt, this.lastError});

  final SyncState state;

  /// Última sincronización exitosa (con esta cuenta, en este dispositivo).
  final DateTime? lastSyncedAt;

  /// Detalle técnico del último error.
  final String? lastError;

  SyncStatus copyWith({SyncState? state, DateTime? lastSyncedAt, String? lastError}) =>
      SyncStatus(state ?? this.state,
          lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt, lastError: lastError);

  @override
  bool operator ==(Object other) =>
      other is SyncStatus &&
      other.state == state &&
      other.lastSyncedAt == lastSyncedAt &&
      other.lastError == lastError;

  @override
  int get hashCode => Object.hash(state, lastSyncedAt, lastError);

  @override
  String toString() => 'SyncStatus($state, $lastSyncedAt, $lastError)';
}

/// Motor de sincronización de la biblioteca: 1 documento por app, merge por ítem
/// dentro de una transacción (1 lectura + como máximo 1 escritura por sync).
///
/// Disparadores (siempre con sesión iniciada): al iniciar sesión, al configurar
/// (abrir la app), al volver a la app tras [resumeAfter], [debounce] después de
/// [notifyLocalChange] y con [syncNow]. Entre una sync y otra pasan al menos
/// [minInterval] (salvo `force`).
class LibrarySync {
  LibrarySync({
    RemoteStore? store,
    ValueListenable<FedeUser?>? user,
    DateTime Function()? clock,
    String? deviceId,
    this.listenLifecycle = true,
    @visibleForTesting this.prefsPrefix = 'fac_sync_',
  })  : _storeOverride = store,
        _userOverride = user,
        clock = clock ?? DateTime.now,
        _deviceIdOverride = deviceId;

  static LibrarySync? _instance;
  static LibrarySync get instance => _instance ??= LibrarySync();

  /// Para tests: reemplaza la instancia global.
  @visibleForTesting
  static set debugInstance(LibrarySync? value) => _instance = value;

  static const debounce = Duration(seconds: 10);
  static const minInterval = Duration(seconds: 20);
  static const resumeAfter = Duration(minutes: 2);

  final RemoteStore? _storeOverride;
  final ValueListenable<FedeUser?>? _userOverride;
  final String? _deviceIdOverride;
  final bool listenLifecycle;
  final DateTime Function() clock;

  RemoteStore? _store;
  RemoteStore get _remote => _store ??= _storeOverride ?? FirestoreRemoteStore();
  ValueListenable<FedeUser?> get _user => _userOverride ?? FedeAccount.instance.user;

  final ValueNotifier<SyncStatus> _status =
      ValueNotifier(const SyncStatus(SyncState.disabled));
  ValueListenable<SyncStatus> get status => _status;

  SyncAdapter? _adapter;
  SyncAdapter? get adapter => _adapter;

  bool _listening = false;
  AppLifecycleListener? _lifecycle;
  String? _uid;
  Map<String, Map<String, int>> _base = {};
  Future<void>? _baseLoad;
  bool _baseLoaded = false;

  Future<void>? _running;
  bool _again = false;
  bool _againForce = false;
  Completer<void>? _againDone;
  DateTime? _lastAttempt;
  Timer? _debounceTimer;
  Timer? _deferredTimer;

  /// Prefijo de las claves en SharedPreferences (ac_sync_).
  final String prefsPrefix;
  String baseKey(String uid, String appId) => '${prefsPrefix}base_${uid}_$appId';
  String lastKey(String uid, String appId) => '${prefsPrefix}last_${uid}_$appId';

  /// Registra la biblioteca de la app y arranca (si hay sesión, sincroniza).
  /// Llamar una vez, después de `Firebase.initializeApp`.
  Future<void> configure(SyncAdapter adapter) async {
    _adapter = adapter;
    if (!_listening) {
      _listening = true;
      _user.addListener(_onUser);
    }
    if (listenLifecycle) _lifecycle ??= AppLifecycleListener(onResume: _onResume);
    _uid = null;
    await _onUser();
  }

  /// Sincroniza ahora (respeta [minInterval] salvo [force]). Si ya hay una en
  /// curso, se encola una más y el Future termina con esa.
  Future<void> syncNow({bool force = false}) => _request(force: force);

  /// La app lo llama después de cada cambio local (guardar, renombrar, borrar).
  void notifyLocalChange() {
    if (_uid == null || _adapter == null) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      _debounceTimer = null;
      _request(force: false);
    });
  }

  /// ¿Se puede purgar localmente esta lápida? Sí sin sesión; con sesión, solo
  /// si ya está sincronizada (`base[id] == rev`).
  bool canPurgeLocally(String collection, String id, int rev) {
    if (_user.value == null) return true;
    if (!_baseLoaded || _uid != _user.value?.uid) return false;
    return _base[collection]?[id] == rev;
  }

  // ── Sesión ────────────────────────────────────────────────────────────────
  Future<void> _onUser() async {
    final newUid = _user.value?.uid;
    if (newUid == _uid && (_uid != null || _status.value.state == SyncState.disabled)) {
      return;
    }
    final old = _uid;
    _uid = newUid;
    _base = {};
    _baseLoaded = false;
    _baseLoad = null;
    _lastAttempt = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _deferredTimer?.cancel();
    _deferredTimer = null;
    final adapter = _adapter;
    if (old != null && adapter != null) {
      // Cerró sesión (o cambió de cuenta): la biblioteca queda; se olvida el base.
      final p = await SharedPreferences.getInstance();
      await p.remove(baseKey(old, adapter.appId));
      await p.remove(lastKey(old, adapter.appId));
    }
    if (newUid == null || adapter == null) {
      _status.value = const SyncStatus(SyncState.disabled);
      return;
    }
    final p = await SharedPreferences.getInstance();
    if (_uid != newUid) return;
    final last = DateTime.tryParse(p.getString(lastKey(newUid, adapter.appId)) ?? '');
    _status.value = SyncStatus(SyncState.idle, lastSyncedAt: last);
    await _ensureBase(newUid);
    unawaited(_request(force: true));
  }

  Future<void> _ensureBase(String uid) {
    return _baseLoad ??= () async {
      final adapter = _adapter;
      if (adapter == null) return;
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(baseKey(uid, adapter.appId));
      final base = <String, Map<String, int>>{};
      if (raw != null) {
        try {
          final m = jsonDecode(raw) as Map;
          m.forEach((c, v) {
            if (v is Map) {
              base[c as String] = {
                for (final e in v.entries)
                  if (e.value is num) e.key as String: (e.value as num).toInt(),
              };
            }
          });
        } catch (_) {}
      }
      if (_uid == uid) {
        _base = base;
        _baseLoaded = true;
      }
    }();
  }

  void _onResume() {
    if (_uid == null) return;
    final last = _lastAttempt;
    if (last == null || clock().difference(last) >= resumeAfter) {
      _request(force: false);
    }
  }

  // ── Cola ──────────────────────────────────────────────────────────────────
  Future<void> _request({required bool force}) {
    if (_adapter == null || _uid == null) return Future.value();
    if (_running != null) {
      _again = true;
      _againForce |= force;
      return (_againDone ??= Completer<void>()).future;
    }
    final last = _lastAttempt;
    if (!force && last != null) {
      final wait = minInterval - clock().difference(last);
      if (wait > Duration.zero) {
        _deferredTimer ??= Timer(wait, () {
          _deferredTimer = null;
          _request(force: false);
        });
        return Future.value();
      }
    }
    _deferredTimer?.cancel();
    _deferredTimer = null;
    final run = _run();
    _running = run;
    return run.whenComplete(() {
      _running = null;
      if (_again) {
        final f = _againForce;
        final done = _againDone;
        _again = false;
        _againForce = false;
        _againDone = null;
        _request(force: f).whenComplete(() => done?.complete());
      }
    });
  }

  // ── Sync ──────────────────────────────────────────────────────────────────
  Future<void> _run() async {
    final adapter = _adapter!;
    final uid = _uid!;
    _lastAttempt = clock();
    _status.value = _status.value.copyWith(state: SyncState.syncing);
    try {
      await _ensureBase(uid);
      final prefs = await SharedPreferences.getInstance();
      final dev = _deviceIdOverride ?? await DeviceIdentity.ensure(prefs);
      final now = clock();
      final cols = adapter.collections;

      final snapshot = <String, List<Map<String, dynamic>>>{};
      for (final c in cols) {
        snapshot[c] = await adapter.readAll(c);
      }
      final baseSnap = {
        for (final c in cols) c: Map<String, int>.from(_base[c] ?? const {}),
      };

      final results = await _remote.update<Map<String, MergeResult>>(
        uid: uid,
        appId: adapter.appId,
        transform: (remote) {
          final out = <String, dynamic>{...?remote}; // conserva colecciones desconocidas
          final results = <String, MergeResult>{};
          var changed = false;
          for (final c in cols) {
            final rc = remote?[c];
            final r = mergeCollection(
              local: snapshot[c]!,
              remote: rc is Map ? Map<String, dynamic>.from(rc) : const {},
              base: baseSnap[c]!,
              now: now,
              conflictCopy: (item) => adapter.conflictCopy(c, item),
              deviceId: dev,
            );
            results[c] = r;
            out[c] = r.remote;
            changed |= r.changedRemote;
          }
          return (write: changed ? out : null, result: results);
        },
      );

      // Ya confirmado en la nube: se aplica en local. Lo que el usuario cambió
      // mientras tanto no se pisa (queda para la próxima).
      final newBase = <String, Map<String, int>>{};
      for (final c in cols) {
        final r = results[c]!;
        final base = Map<String, int>.from(r.base);
        if (r.upserts.isNotEmpty || r.localRemovals.isNotEmpty) {
          final before = _revs(snapshot[c]!);
          final current = _revs(await adapter.readAll(c));
          bool touched(String id) =>
              current[id] != before[id] ||
              current.containsKey(id) != before.containsKey(id);
          void restore(String id) {
            final old = baseSnap[c]![id];
            if (old == null) {
              base.remove(id);
            } else {
              base[id] = old;
            }
          }

          final upserts = <Map<String, dynamic>>[];
          for (final item in r.upserts) {
            final id = item[SyncFields.id] as String;
            if (touched(id)) {
              restore(id);
            } else {
              upserts.add(item);
            }
          }
          final removals = <String>[];
          for (final id in r.localRemovals) {
            if (touched(id)) {
              restore(id);
            } else {
              removals.add(id);
            }
          }
          if (upserts.isNotEmpty || removals.isNotEmpty) {
            await adapter.applyRemote(c, upserts: upserts, removals: removals);
          }
        }
        newBase[c] = base;
      }

      if (_uid != uid) return; // cerró sesión en el medio
      _base = newBase;
      _baseLoaded = true;
      final at = clock();
      await prefs.setString(baseKey(uid, adapter.appId), jsonEncode(newBase));
      await prefs.setString(lastKey(uid, adapter.appId), at.toIso8601String());
      if (_uid != uid) return;
      _status.value = SyncStatus(SyncState.idle, lastSyncedAt: at);
    } on RemoteUnavailableException catch (e) {
      if (_uid != uid) return;
      _status.value = _status.value.copyWith(state: SyncState.offline, lastError: '$e');
    } catch (e, st) {
      debugPrint('LibrarySync: $e\n$st');
      if (_uid != uid) return;
      _status.value = _status.value.copyWith(state: SyncState.error, lastError: '$e');
    }
  }

  static Map<String, int> _revs(List<Map<String, dynamic>> items) => {
        for (final i in items)
          if (i[SyncFields.id] is String) i[SyncFields.id] as String: SyncFields.readRev(i),
      };

  /// Para tests: deja de escuchar y cancela timers.
  @visibleForTesting
  void dispose() {
    if (_listening) _user.removeListener(_onUser);
    _listening = false;
    _lifecycle?.dispose();
    _lifecycle = null;
    _debounceTimer?.cancel();
    _deferredTimer?.cancel();
  }

  /// Para tests: simula volver a la app.
  @visibleForTesting
  void debugResume() => _onResume();
}
