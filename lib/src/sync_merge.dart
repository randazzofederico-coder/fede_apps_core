import 'dart:convert';

import 'sync_fields.dart';

/// Arma la "copia por conflicto" de un ítem (la implementa cada app a través de
/// `SyncAdapter.conflictCopy`): id nuevo y nombre "… (otro dispositivo)".
typedef ConflictCopyFn = Map<String, dynamic> Function(Map<String, dynamic> item);

/// Formato de cada ítem dentro de `collections.<colección>` en Firestore:
///
/// ```text
/// { rev: 3, deleted: false, deletedAt: null, updatedAt: "...", dev: "...",
///   payload: "<JSON completo del ítem>" }
/// ```
abstract final class RemoteEntry {
  static const payload = 'payload';

  static Map<String, dynamic> fromItem(Map<String, dynamic> item) {
    final deletedAt = item[SyncFields.deletedAt];
    final updatedAt = item[SyncFields.updatedAt];
    final deleted = SyncFields.readDeleted(item);
    return {
      SyncFields.rev: SyncFields.readRev(item),
      SyncFields.deleted: deleted,
      SyncFields.deletedAt: deleted && deletedAt is String ? deletedAt : null,
      SyncFields.updatedAt: updatedAt is String ? updatedAt : null,
      SyncFields.device: SyncFields.readDevice(item),
      payload: jsonEncode(item),
    };
  }

  /// El ítem completo guardado en la entrada (o null si está dañada).
  static Map<String, dynamic>? decode(Map<String, dynamic> entry, String id) {
    final p = entry[payload];
    if (p is! String) return null;
    try {
      final v = jsonDecode(p);
      if (v is! Map) return null;
      final m = Map<String, dynamic>.from(v);
      m[SyncFields.id] = id;
      return m;
    } catch (_) {
      return null;
    }
  }
}

/// Resultado de [mergeCollection].
class MergeResult {
  const MergeResult({
    required this.upserts,
    required this.localRemovals,
    required this.remote,
    required this.changedRemote,
    required this.base,
  });

  /// Ítems a escribir en local tal cual (sin subir `rev`).
  final List<Map<String, dynamic>> upserts;

  /// Ids a eliminar físicamente en local (lápidas purgadas).
  final List<String> localRemovals;

  /// La colección remota nueva (id → entrada).
  final Map<String, Map<String, dynamic>> remote;

  /// ¿Hay que escribir la nube?
  final bool changedRemote;

  /// `base` nuevo: id → `rev` final de cada ítem.
  final Map<String, int> base;
}

/// Merge por ítem de una colección (función pura; ver el diseño en el README).
///
/// * [local]: todos los ítems locales, con lápidas.
/// * [remote]: `collections.<colección>` tal como está en la nube (id → entrada).
/// * [base]: id → `rev` de la última sincronización exitosa de este dispositivo.
///
/// Hay cambios locales si `L.rev != base`, y en la nube si `R.rev != base`
/// (sin `base`, se considera que cambiaron los dos lados).
MergeResult mergeCollection({
  required List<Map<String, dynamic>> local,
  required Map<String, dynamic> remote,
  required Map<String, int> base,
  required DateTime now,
  required ConflictCopyFn conflictCopy,
  required String deviceId,
}) {
  final localById = <String, Map<String, dynamic>>{};
  for (final item in local) {
    final id = item[SyncFields.id];
    if (id is String && id.isNotEmpty) localById[id] = item;
  }

  // La salida arranca igual a la nube (también las entradas dañadas, que se
  // conservan salvo que se sobrescriban).
  final out = <String, Map<String, dynamic>>{};
  final remoteEntries = <String, Map<String, dynamic>>{};
  final remoteItems = <String, Map<String, dynamic>>{};
  remote.forEach((id, e) {
    if (e is! Map) return;
    final entry = Map<String, dynamic>.from(e);
    out[id] = entry;
    final item = RemoteEntry.decode(entry, id);
    if (item != null) {
      remoteEntries[id] = entry;
      remoteItems[id] = item;
    }
  });

  var changed = false;
  final upserts = <Map<String, dynamic>>[];
  final removals = <String>[];
  final newBase = <String, int>{};

  void upload(Map<String, dynamic> item) {
    out[item[SyncFields.id] as String] = RemoteEntry.fromItem(item);
    changed = true;
  }

  bool oldTombstone(bool deleted, DateTime? deletedAt) =>
      deleted &&
      SyncFields.shouldPurge(deleted: true, deletedAt: deletedAt, now: now);

  final ids = {...localById.keys, ...remoteItems.keys}.toList()..sort();
  for (final id in ids) {
    final l = localById[id];
    final r = remoteItems[id];
    final b = base[id];

    // ── Solo en local ───────────────────────────────────────────────────────
    if (r == null) {
      final lRev = SyncFields.readRev(l!);
      final lDel = SyncFields.readDeleted(l);
      if ((b == null || b == lRev) &&
          oldTombstone(lDel, SyncFields.readDeletedAt(l))) {
        // Lápida vieja ya sincronizada (la nube la purgó) o que nunca llegó a
        // subirse: nadie más la necesita.
        removals.add(id);
        continue;
      }
      upload(l);
      newBase[id] = lRev;
      continue;
    }

    final rEntry = remoteEntries[id]!;
    final rRev = SyncFields.readRev(rEntry);
    final rDel = SyncFields.readDeleted(rEntry);
    final rPurge = oldTombstone(rDel, SyncFields.readDeletedAt(rEntry));

    // ── Solo en la nube ─────────────────────────────────────────────────────
    if (l == null) {
      if (rDel) {
        // Lápida: no se descarga; se purga si es vieja.
        if (rPurge) {
          out.remove(id);
          changed = true;
        }
        continue;
      }
      upserts.add(r);
      newBase[id] = rRev;
      continue;
    }

    // ── En los dos lados ────────────────────────────────────────────────────
    final lRev = SyncFields.readRev(l);
    final lDel = SyncFields.readDeleted(l);

    // Queda la versión de la nube. [exact]: bajarla también si solo difieren
    // los metadatos (para que todos los dispositivos queden idénticos).
    void takeRemote({bool exact = false}) {
      if (rPurge) {
        out.remove(id);
        changed = true;
        removals.add(id);
      } else {
        // Con la misma rev ya es la misma versión: no se reescribe.
        if (rRev != lRev || lDel != rDel || (exact && !_jsonEquals(l, r))) {
          upserts.add(r);
        }
        newBase[id] = rRev;
      }
    }

    final localChanged = b == null || lRev != b;
    final remoteChanged = b == null || rRev != b;

    if (!localChanged) {
      // Sin cambios locales: queda (o se baja) lo de la nube.
      takeRemote();
    } else if (!remoteChanged) {
      upload(l);
      newBase[id] = lRev;
    } else if (sameContent(l, r)) {
      // Cambiaron los dos con el mismo contenido: queda la rev más alta
      // (con la misma rev, la de la nube).
      if (lRev > rRev) {
        upload(l);
        newBase[id] = lRev;
      } else {
        takeRemote(exact: true);
      }
    } else if (lDel != rDel) {
      // Borrado vs. edición: gana la edición, con rev = máx + 1.
      final revived = Map<String, dynamic>.from(lDel ? r : l)
        ..remove(SyncFields.deleted)
        ..remove(SyncFields.deletedAt);
      final newRev = (lRev > rRev ? lRev : rRev) + 1;
      revived[SyncFields.rev] = newRev;
      upload(revived);
      upserts.add(revived);
      newBase[id] = newRev;
    } else {
      // Ediciones distintas: gana la rev más alta; la otra queda como copia.
      final localWins = _compareVersions(l, lRev, r, rRev) > 0;
      if (localWins) {
        var winner = l;
        if (lRev <= rRev) {
          // Empate de rev: se sube una rev para que el otro lado vea el cambio.
          winner = Map<String, dynamic>.from(l)..[SyncFields.rev] = rRev + 1;
          upserts.add(winner);
        }
        upload(winner);
        newBase[id] = SyncFields.readRev(winner);
      } else {
        upserts.add(r);
        newBase[id] = rRev;
      }

      final loser = localWins ? r : l;
      final copy = Map<String, dynamic>.from(
          conflictCopy(Map<String, dynamic>.from(loser)));
      final proposed = copy[SyncFields.id];
      final copyId = (proposed is! String ||
              proposed.isEmpty ||
              proposed == id ||
              localById.containsKey(proposed) ||
              out.containsKey(proposed))
          ? '$id-c${now.microsecondsSinceEpoch}'
          : proposed;
      copy
        ..[SyncFields.id] = copyId
        ..remove(SyncFields.deleted)
        ..remove(SyncFields.deletedAt)
        ..[SyncFields.rev] = 1
        ..[SyncFields.updatedAt] = now.toIso8601String()
        ..[SyncFields.device] = deviceId;
      upload(copy);
      upserts.add(copy);
      newBase[copyId] = 1;
    }
  }

  return MergeResult(
    upserts: upserts,
    localRemovals: removals,
    remote: out,
    changedRemote: changed,
    base: newBase,
  );
}

/// ¿Mismo contenido? (Ignora los campos de sincronización; dos lápidas son iguales.)
bool sameContent(Map<String, dynamic> a, Map<String, dynamic> b) {
  final aDel = SyncFields.readDeleted(a);
  final bDel = SyncFields.readDeleted(b);
  if (aDel || bDel) return aDel == bDel;
  return _jsonEquals(_strip(a), _strip(b));
}

Map<String, dynamic> _strip(Map<String, dynamic> m) =>
    {for (final e in m.entries) if (!SyncFields.all.contains(e.key)) e.key: e.value};

bool _jsonEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_jsonEquals(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// > 0 si gana [a]. Rev más alta → `updatedAt` más reciente → `dev` mayor →
/// JSON mayor (para que todos los dispositivos decidan lo mismo).
int _compareVersions(
    Map<String, dynamic> a, int aRev, Map<String, dynamic> b, int bRev) {
  if (aRev != bRev) return aRev.compareTo(bRev);
  final aAt = _date(a[SyncFields.updatedAt]);
  final bAt = _date(b[SyncFields.updatedAt]);
  if (aAt != null || bAt != null) {
    if (aAt == null) return -1;
    if (bAt == null) return 1;
    final c = aAt.compareTo(bAt);
    if (c != 0) return c;
  }
  final c = (SyncFields.readDevice(a) ?? '').compareTo(SyncFields.readDevice(b) ?? '');
  if (c != 0) return c;
  return jsonEncode(a).compareTo(jsonEncode(b));
}

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
