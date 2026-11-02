import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Lo que devuelve la función de [RemoteStore.update]: qué escribir (o null
/// para no escribir nada) y el resultado para quien llamó.
typedef RemoteUpdate<T> = ({Map<String, dynamic>? write, T result});

/// Sin conexión (o la nube no responde): se reintenta en el próximo disparador.
class RemoteUnavailableException implements Exception {
  const RemoteUnavailableException([this.detail]);
  final String? detail;
  @override
  String toString() => 'RemoteUnavailableException($detail)';
}

/// Almacenamiento remoto de las bibliotecas: un documento por usuario y app
/// (`users/{uid}/appData/{appId}`) con el mapa `collections`.
abstract class RemoteStore {
  /// Lee `collections` (null si el documento no existe), llama a [transform] y,
  /// si devuelve `write`, reemplaza `collections` — todo en una transacción.
  /// [transform] puede ejecutarse más de una vez (reintentos): tiene que ser pura.
  ///
  /// Lanza [RemoteUnavailableException] sin conexión.
  Future<T> update<T>({
    required String uid,
    required String appId,
    required RemoteUpdate<T> Function(Map<String, dynamic>? collections) transform,
  });
}

/// Implementación con Cloud Firestore: 1 lectura + como máximo 1 escritura.
class FirestoreRemoteStore implements RemoteStore {
  FirestoreRemoteStore({FirebaseFirestore? firestore, this.timeout = const Duration(seconds: 30)})
      : _override = firestore;

  final FirebaseFirestore? _override;
  final Duration timeout;

  FirebaseFirestore get _db => _override ?? FirebaseFirestore.instance;

  static const schemaVersion = 1;

  static const _offlineCodes = {'unavailable', 'deadline-exceeded', 'network-request-failed'};

  @override
  Future<T> update<T>({
    required String uid,
    required String appId,
    required RemoteUpdate<T> Function(Map<String, dynamic>? collections) transform,
  }) async {
    final ref = _db.collection('users').doc(uid).collection('appData').doc(appId);
    try {
      return await _db.runTransaction<T>((tx) async {
        final snap = await tx.get(ref);
        final data = snap.data();
        final cols = data?['collections'];
        final r = transform(cols is Map ? _deepCast(cols) : null);
        final w = r.write;
        if (w != null) {
          tx.set(ref, {
            'schemaVersion': schemaVersion,
            'updatedAt': FieldValue.serverTimestamp(),
            'collections': w,
          });
        }
        return r.result;
      }, maxAttempts: 3).timeout(timeout);
    } on TimeoutException catch (e) {
      throw RemoteUnavailableException('timeout: $e');
    } on FirebaseException catch (e) {
      if (_offlineCodes.contains(e.code)) {
        throw RemoteUnavailableException('${e.code}: ${e.message}');
      }
      rethrow;
    }
  }

  static Map<String, dynamic> _deepCast(Map m) => {
        for (final e in m.entries)
          e.key.toString(): e.value is Map ? _deepCast(e.value as Map) : e.value,
      };
}

/// Implementación en memoria (tests de las apps y del paquete).
/// Guarda los datos como JSON, igual que viajan a la nube.
class InMemoryRemoteStore implements RemoteStore {
  final Map<String, String> _docs = {};

  /// `false` simula estar sin conexión.
  bool online = true;

  /// Cuántas lecturas / escrituras hubo (para comprobar costos).
  int reads = 0;
  int writes = 0;

  /// Se llama dentro de la "transacción", después de leer (para simular carreras).
  @visibleForTesting
  Future<void> Function()? onRead;

  String _key(String uid, String appId) => '$uid/$appId';

  Map<String, dynamic>? collections(String uid, String appId) {
    final s = _docs[_key(uid, appId)];
    return s == null ? null : (jsonDecode(s) as Map).cast<String, dynamic>();
  }

  void clear() => _docs.clear();

  @override
  Future<T> update<T>({
    required String uid,
    required String appId,
    required RemoteUpdate<T> Function(Map<String, dynamic>? collections) transform,
  }) async {
    await Future<void>.delayed(Duration.zero);
    if (!online) throw const RemoteUnavailableException('offline');
    reads++;
    final key = _key(uid, appId);
    final before = _docs[key];
    await onRead?.call();
    if (_docs[key] != before) {
      // Otro escribió en el medio: se reintenta (como Firestore).
      return update(uid: uid, appId: appId, transform: transform);
    }
    final r = transform(before == null ? null : (jsonDecode(before) as Map).cast<String, dynamic>());
    final w = r.write;
    if (w != null) {
      writes++;
      _docs[key] = jsonEncode(w);
    }
    return r.result;
  }
}
