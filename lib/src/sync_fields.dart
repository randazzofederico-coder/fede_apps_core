import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Contrato de los ítems sincronizables (bibliotecas de las apps).
///
/// Cada ítem guardado en JSON lleva, además de sus datos:
///
/// | clave       | tipo            | significado                                              |
/// | :---------- | :-------------- | :------------------------------------------------------- |
/// | `id`        | String (UUID)   | generado en el dispositivo                               |
/// | `rev`       | int ≥ 1         | sube en **cada** cambio (editar, renombrar, borrar...)   |
/// | `updatedAt` | ISO 8601        | última modificación                                      |
/// | `deleted`   | bool            | lápida: el ítem se borró (no se elimina físicamente aún) |
/// | `deletedAt` | ISO 8601 / null | cuándo se borró                                          |
/// | `dev`       | String          | [DeviceIdentity.id] del dispositivo que hizo el cambio   |
///
/// JSON viejo sin estas claves se lee como `rev: 1, deleted: false`.
/// Las lápidas se purgan después de [tombstoneRetention] (ver [shouldPurge]).
abstract final class SyncFields {
  static const rev = 'rev';
  static const deleted = 'deleted';
  static const deletedAt = 'deletedAt';
  static const device = 'dev';

  /// Cuánto se conserva una lápida (papelera) antes de purgarla.
  static const tombstoneRetention = Duration(days: 30);

  /// Lee `rev` de un JSON (por defecto 1).
  static int readRev(Map<String, dynamic> json) {
    final v = json[rev];
    return v is int && v >= 1 ? v : (v is num && v >= 1 ? v.toInt() : 1);
  }

  static bool readDeleted(Map<String, dynamic> json) => json[deleted] == true;

  static DateTime? readDeletedAt(Map<String, dynamic> json) {
    final v = json[deletedAt];
    return v is String ? DateTime.tryParse(v) : null;
  }

  static String? readDevice(Map<String, dynamic> json) {
    final v = json[device];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// Escribe los campos de sincronización en [json] (no toca `id` ni `updatedAt`).
  static void write(
    Map<String, dynamic> json, {
    required int rev,
    required bool deleted,
    DateTime? deletedAt,
    String? device,
  }) {
    json[SyncFields.rev] = rev;
    if (deleted) {
      json[SyncFields.deleted] = true;
      if (deletedAt != null) {
        json[SyncFields.deletedAt] = deletedAt.toIso8601String();
      }
    }
    if (device != null) json[SyncFields.device] = device;
  }

  /// ¿Corresponde purgar esta lápida? (Más adelante, con sync, además habrá
  /// que esperar a que la lápida se haya subido.)
  static bool shouldPurge({
    required bool deleted,
    DateTime? deletedAt,
    DateTime? now,
  }) {
    if (!deleted) return false;
    if (deletedAt == null) return true;
    return (now ?? DateTime.now()).difference(deletedAt) >= tombstoneRetention;
  }
}

/// Identificador estable de esta instalación (no identifica a la persona).
/// Se usa en el campo `dev` de los ítems para saber qué dispositivo hizo cada cambio.
class DeviceIdentity {
  DeviceIdentity._();

  static const _key = 'fac_device_id';
  static String? _id;

  /// Disponible después de [ensure] (lo llama `UsageTracker.init`).
  static String? get id => _id;

  static Future<String> ensure([SharedPreferences? prefs]) async {
    if (_id != null) return _id!;
    final p = prefs ?? await SharedPreferences.getInstance();
    var v = p.getString(_key);
    if (v == null || v.isEmpty) {
      final r = Random.secure();
      v = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join();
      await p.setString(_key, v);
    }
    return _id = v;
  }

  /// Para tests.
  static void debugReset() => _id = null;
}
