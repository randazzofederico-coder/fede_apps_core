import 'dart:convert';
import 'dart:math';

import 'package:fede_apps_core/fede_apps_core.dart';
import 'package:flutter_test/flutter_test.dart';

final t0 = DateTime(2026, 11, 2, 10);

Map<String, dynamic> item(
  String id, {
  int rev = 1,
  String name = 'x',
  bool deleted = false,
  DateTime? deletedAt,
  DateTime? updatedAt,
  String dev = 'A',
}) {
  final m = <String, dynamic>{
    'id': id,
    'name': name,
    'updatedAt': (updatedAt ?? t0).toIso8601String(),
  };
  SyncFields.write(m,
      rev: rev,
      deleted: deleted,
      deletedAt: deleted ? (deletedAt ?? t0) : null,
      device: dev);
  return m;
}

Map<String, dynamic> entry(Map<String, dynamic> i) => RemoteEntry.fromItem(i);

Map<String, dynamic> copyOf(Map<String, dynamic> i) =>
    {...i, 'id': '${i['id']}-copy', 'name': '${i['name']} (otro dispositivo)'};

MergeResult merge({
  List<Map<String, dynamic>> local = const [],
  Map<String, dynamic> remote = const {},
  Map<String, int> base = const {},
  DateTime? now,
  String dev = 'A',
}) =>
    mergeCollection(
      local: local,
      remote: remote,
      base: base,
      now: now ?? t0,
      conflictCopy: copyOf,
      deviceId: dev,
    );

Map<String, dynamic> payloadOf(MergeResult r, String id) =>
    jsonDecode(r.remote[id]!['payload'] as String) as Map<String, dynamic>;

void main() {
  group('RemoteEntry', () {
    test('formato y roundtrip', () {
      final i = item('a', rev: 3, deleted: true, dev: 'D');
      final e = entry(i);
      expect(e['rev'], 3);
      expect(e['deleted'], true);
      expect(e['deletedAt'], t0.toIso8601String());
      expect(e['updatedAt'], t0.toIso8601String());
      expect(e['dev'], 'D');
      expect(RemoteEntry.decode(e, 'a'), i);
      expect(RemoteEntry.decode({'payload': 'nope{'}, 'a'), isNull);
    });
  });

  group('mergeCollection: un solo lado', () {
    test('solo en local → se sube', () {
      final r = merge(local: [item('a')]);
      expect(r.changedRemote, isTrue);
      expect(r.remote['a']!['rev'], 1);
      expect(payloadOf(r, 'a'), item('a'));
      expect(r.upserts, isEmpty);
      expect(r.base, {'a': 1});
    });

    test('solo en local, lápida reciente → se sube', () {
      final r = merge(local: [item('a', rev: 2, deleted: true)]);
      expect(r.remote['a']!['deleted'], true);
      expect(r.base, {'a': 2});
    });

    test('solo en local, lápida vieja sincronizada (la nube la purgó) → se purga', () {
      final r = merge(
        local: [item('a', rev: 2, deleted: true, deletedAt: t0)],
        base: {'a': 2},
        now: t0.add(const Duration(days: 31)),
      );
      expect(r.localRemovals, ['a']);
      expect(r.changedRemote, isFalse);
      expect(r.base, isEmpty);
    });

    test('solo en local, lápida vieja nunca subida → se purga sin subir', () {
      final r = merge(
        local: [item('a', rev: 2, deleted: true, deletedAt: t0)],
        now: t0.add(const Duration(days: 31)),
      );
      expect(r.localRemovals, ['a']);
      expect(r.remote, isEmpty);
    });

    test('solo en local, lápida vieja con cambios sin subir → se sube', () {
      final r = merge(
        local: [item('a', rev: 3, deleted: true, deletedAt: t0)],
        base: {'a': 2},
        now: t0.add(const Duration(days: 31)),
      );
      expect(r.localRemovals, isEmpty);
      expect(r.remote['a']!['rev'], 3);
    });

    test('solo en local, viva y sincronizada (la nube la perdió) → se vuelve a subir', () {
      final r = merge(local: [item('a', rev: 2)], base: {'a': 2});
      expect(r.remote['a']!['rev'], 2);
      expect(r.changedRemote, isTrue);
    });

    test('solo en la nube y viva → se baja', () {
      final r = merge(remote: {'a': entry(item('a', rev: 4, dev: 'B'))});
      expect(r.upserts, [item('a', rev: 4, dev: 'B')]);
      expect(r.changedRemote, isFalse);
      expect(r.base, {'a': 4});
    });

    test('solo en la nube como lápida → se ignora', () {
      final r = merge(remote: {'a': entry(item('a', rev: 2, deleted: true))});
      expect(r.upserts, isEmpty);
      expect(r.changedRemote, isFalse);
      expect(r.remote.keys, ['a']);
      expect(r.base, isEmpty);
    });

    test('solo en la nube como lápida vieja → se purga de la nube', () {
      final r = merge(
        remote: {'a': entry(item('a', rev: 2, deleted: true, deletedAt: t0))},
        now: t0.add(const Duration(days: 30)),
      );
      expect(r.remote, isEmpty);
      expect(r.changedRemote, isTrue);
    });

    test('entrada remota dañada: se conserva, salvo que local la reemplace', () {
      final r1 = merge(remote: {'a': {'rev': 1, 'payload': 'xx'}});
      expect(r1.remote['a'], {'rev': 1, 'payload': 'xx'});
      expect(r1.changedRemote, isFalse);
      final r2 = merge(local: [item('a')], remote: {'a': {'rev': 1, 'payload': 'xx'}});
      expect(payloadOf(r2, 'a'), item('a'));
    });
  });

  group('mergeCollection: en los dos lados', () {
    test('sin cambios → nada', () {
      final r = merge(
        local: [item('a', rev: 2)],
        remote: {'a': entry(item('a', rev: 2))},
        base: {'a': 2},
      );
      expect(r.changedRemote, isFalse);
      expect(r.upserts, isEmpty);
      expect(r.base, {'a': 2});
    });

    test('sin cambios locales, la nube cambió → se baja', () {
      final remote = item('a', rev: 3, name: 'nuevo', dev: 'B');
      final r = merge(
        local: [item('a', rev: 2)],
        remote: {'a': entry(remote)},
        base: {'a': 2},
      );
      expect(r.upserts, [remote]);
      expect(r.changedRemote, isFalse);
      expect(r.base, {'a': 3});
    });

    test('sin cambios locales, la nube la borró → se baja la lápida', () {
      final remote = item('a', rev: 3, deleted: true, dev: 'B');
      final r = merge(
        local: [item('a', rev: 2)],
        remote: {'a': entry(remote)},
        base: {'a': 2},
      );
      expect(r.upserts, [remote]);
      expect(r.base, {'a': 3});
    });

    test('sin cambios locales, lápida vieja en la nube → se purga en los dos lados', () {
      final r = merge(
        local: [item('a', rev: 2)],
        remote: {'a': entry(item('a', rev: 3, deleted: true, deletedAt: t0))},
        base: {'a': 2},
        now: t0.add(const Duration(days: 40)),
      );
      expect(r.localRemovals, ['a']);
      expect(r.upserts, isEmpty);
      expect(r.remote, isEmpty);
      expect(r.changedRemote, isTrue);
      expect(r.base, isEmpty);
    });

    test('lápida sincronizada en los dos lados y vieja → se purga en los dos', () {
      final tomb = item('a', rev: 3, deleted: true, deletedAt: t0);
      final r = merge(
        local: [tomb],
        remote: {'a': entry(tomb)},
        base: {'a': 3},
        now: t0.add(const Duration(days: 30)),
      );
      expect(r.localRemovals, ['a']);
      expect(r.remote, isEmpty);
      expect(r.base, isEmpty);
    });

    test('lápida sincronizada reciente → se conserva', () {
      final tomb = item('a', rev: 3, deleted: true, deletedAt: t0);
      final r = merge(
        local: [tomb],
        remote: {'a': entry(tomb)},
        base: {'a': 3},
        now: t0.add(const Duration(days: 29)),
      );
      expect(r.localRemovals, isEmpty);
      expect(r.changedRemote, isFalse);
      expect(r.base, {'a': 3});
    });

    test('cambio local, la nube sin cambios → se sube', () {
      final local = item('a', rev: 3, name: 'nuevo');
      final r = merge(
        local: [local],
        remote: {'a': entry(item('a', rev: 2))},
        base: {'a': 2},
      );
      expect(payloadOf(r, 'a'), local);
      expect(r.upserts, isEmpty);
      expect(r.base, {'a': 3});
    });

    test('borrado local, la nube sin cambios → se sube la lápida', () {
      final r = merge(
        local: [item('a', rev: 3, deleted: true)],
        remote: {'a': entry(item('a', rev: 2))},
        base: {'a': 2},
      );
      expect(r.remote['a']!['deleted'], true);
      expect(r.base, {'a': 3});
    });

    test('edición local revive una lápida vieja de la nube sin cambios', () {
      final r = merge(
        local: [item('a', rev: 3, name: 'editado')],
        remote: {'a': entry(item('a', rev: 2, deleted: true, deletedAt: t0))},
        base: {'a': 2},
        now: t0.add(const Duration(days: 40)),
      );
      expect(r.remote['a']!['deleted'], false);
      expect(r.remote['a']!['rev'], 3);
      expect(r.localRemovals, isEmpty);
    });

    test('cambiaron los dos con el mismo contenido → queda la rev más alta', () {
      // Local más alta: se sube.
      var r = merge(
        local: [item('a', rev: 4, name: 'igual', dev: 'A')],
        remote: {'a': entry(item('a', rev: 3, name: 'igual', dev: 'B'))},
        base: {'a': 2},
      );
      expect(r.remote['a']!['rev'], 4);
      expect(r.upserts, isEmpty);
      expect(r.base, {'a': 4});
      // Nube más alta: se baja.
      r = merge(
        local: [item('a', rev: 3, name: 'igual')],
        remote: {'a': entry(item('a', rev: 5, name: 'igual', dev: 'B'))},
        base: {'a': 2},
      );
      expect(r.changedRemote, isFalse);
      expect(SyncFields.readRev(r.upserts.single), 5);
      expect(r.base, {'a': 5});
      // Misma rev: queda la de la nube (solo cambian metadatos, sin escribir la nube).
      r = merge(
        local: [item('a', rev: 3, name: 'igual', updatedAt: t0)],
        remote: {
          'a': entry(item('a',
              rev: 3, name: 'igual', dev: 'B', updatedAt: t0.add(const Duration(hours: 1))))
        },
        base: {'a': 2},
      );
      expect(r.changedRemote, isFalse);
      expect(r.upserts.single['dev'], 'B');
      expect(r.base, {'a': 3});
    });

    test('borrados en los dos lados → se iguala (rev más alta)', () {
      final r = merge(
        local: [item('a', rev: 3, deleted: true, name: 'v1')],
        remote: {'a': entry(item('a', rev: 4, deleted: true, name: 'v2', dev: 'B'))},
        base: {'a': 2},
      );
      expect(r.changedRemote, isFalse);
      expect(SyncFields.readRev(r.upserts.single), 4);
      expect(r.base, {'a': 4});
    });

    test('borrado local vs. edición en la nube → gana la edición, rev = máx + 1', () {
      final r = merge(
        local: [item('a', rev: 5, deleted: true)],
        remote: {'a': entry(item('a', rev: 3, name: 'editado', dev: 'B'))},
        base: {'a': 2},
      );
      final revived = r.upserts.single;
      expect(revived['name'], 'editado');
      expect(SyncFields.readRev(revived), 6);
      expect(SyncFields.readDeleted(revived), isFalse);
      expect(revived.containsKey('deletedAt'), isFalse);
      expect(payloadOf(r, 'a'), revived);
      expect(r.remote['a']!['deleted'], false);
      expect(r.base, {'a': 6});
    });

    test('edición local vs. borrado en la nube → gana la edición, rev = máx + 1', () {
      final r = merge(
        local: [item('a', rev: 3, name: 'editado')],
        remote: {'a': entry(item('a', rev: 4, deleted: true, dev: 'B'))},
        base: {'a': 2},
      );
      expect(r.upserts.single['name'], 'editado');
      expect(SyncFields.readRev(r.upserts.single), 5);
      expect(r.remote['a']!['rev'], 5);
      expect(r.base, {'a': 5});
    });

    test('ediciones distintas: gana la nube (rev más alta), copia de la local', () {
      final remote = item('a', rev: 4, name: 'nube', dev: 'B');
      final r = merge(
        local: [item('a', rev: 3, name: 'local')],
        remote: {'a': entry(remote)},
        base: {'a': 2},
        dev: 'A',
      );
      expect(r.upserts.length, 2);
      expect(r.upserts.first, remote);
      final copy = r.upserts[1];
      expect(copy['id'], 'a-copy');
      expect(copy['name'], 'local (otro dispositivo)');
      expect(SyncFields.readRev(copy), 1);
      expect(copy['dev'], 'A');
      expect(copy['updatedAt'], t0.toIso8601String());
      expect(payloadOf(r, 'a-copy'), copy);
      expect(r.remote['a']!['rev'], 4);
      expect(r.base, {'a': 4, 'a-copy': 1});
    });

    test('ediciones distintas: gana la local (rev más alta), copia de la nube', () {
      final local = item('a', rev: 5, name: 'local');
      final r = merge(
        local: [local],
        remote: {'a': entry(item('a', rev: 4, name: 'nube', dev: 'B'))},
        base: {'a': 2},
      );
      expect(payloadOf(r, 'a'), local);
      expect(r.upserts.single['name'], 'nube (otro dispositivo)');
      expect(r.base, {'a': 5, 'a-copy': 1});
    });

    test('empate de rev: gana updatedAt más reciente; si gana local, sube una rev', () {
      final local = item('a', rev: 3, name: 'local', updatedAt: t0.add(const Duration(minutes: 5)));
      final r = merge(
        local: [local],
        remote: {'a': entry(item('a', rev: 3, name: 'nube', dev: 'B', updatedAt: t0))},
        base: {'a': 2},
      );
      expect(r.remote['a']!['rev'], 4);
      expect(payloadOf(r, 'a')['name'], 'local');
      expect(r.upserts.map((e) => e['name']), ['local', 'nube (otro dispositivo)']);
      expect(SyncFields.readRev(r.upserts.first), 4);
      expect(r.base, {'a': 4, 'a-copy': 1});
    });

    test('empate de rev y de updatedAt: decide dev (determinista)', () {
      final a = item('a', rev: 3, name: 'deA', dev: 'A');
      final b = item('a', rev: 3, name: 'deB', dev: 'B');
      // Visto desde A (local = a): gana B.
      final ra = merge(local: [a], remote: {'a': entry(b)}, base: {'a': 2}, dev: 'A');
      expect(ra.upserts.first['name'], 'deB');
      expect(ra.upserts[1]['name'], 'deA (otro dispositivo)');
      // Visto desde B (local = b): también gana B.
      final rb = merge(local: [b], remote: {'a': entry(a)}, base: {'a': 2}, dev: 'B');
      expect(payloadOf(rb, 'a')['name'], 'deB');
      expect(rb.upserts.last['name'], 'deA (otro dispositivo)');
    });

    test('sin base (primer sync tras el login): iguales → se iguala; distintos → conflicto', () {
      var r = merge(
        local: [item('a', rev: 1, name: 'igual')],
        remote: {'a': entry(item('a', rev: 2, name: 'igual', dev: 'B'))},
      );
      expect(r.upserts.length, 1);
      expect(r.base, {'a': 2});
      r = merge(
        local: [item('a', rev: 1, name: 'mío')],
        remote: {'a': entry(item('a', rev: 2, name: 'otro', dev: 'B'))},
      );
      expect(r.upserts.map((e) => e['name']), ['otro', 'mío (otro dispositivo)']);
    });

    test('la copia por conflicto con id repetido recibe un id nuevo', () {
      final r = mergeCollection(
        local: [item('a', rev: 3, name: 'local')],
        remote: {'a': entry(item('a', rev: 4, name: 'nube', dev: 'B'))},
        base: {'a': 2},
        now: t0,
        conflictCopy: (i) => {...i},
        deviceId: 'A',
      );
      final copy = r.upserts[1];
      expect(copy['id'], isNot('a'));
      expect(r.remote.containsKey(copy['id']), isTrue);
    });

    test('comparar contenido ignora campos de sync y 1 == 1.0', () {
      final a = {...item('a', rev: 1), 'list': [1, 2, {'x': 1}]};
      final b = {...item('a', rev: 9, dev: 'Z', updatedAt: t0.add(const Duration(days: 1))), 'list': [1.0, 2, {'x': 1}]};
      expect(sameContent(a, b), isTrue);
      expect(sameContent(a, {...b, 'list': [1, 2]}), isFalse);
    });
  });

  group('convergencia', () {
    test('dos dispositivos que sincronizan alternados convergen', () {
      for (var seed = 0; seed < 300; seed++) {
        _simulate(seed);
      }
    });

    test('tres dispositivos también convergen', () {
      for (var seed = 0; seed < 300; seed++) {
        _simulate(seed, devices: 3);
      }
    });
  });
}

/// Simulación: dos dispositivos con operaciones aleatorias y syncs alternados.
void _simulate(int seed, {int devices = 2}) {
  final rnd = Random(seed);
  var now = t0;
  final devs = [for (var i = 0; i < devices; i++) _Dev(String.fromCharCode(65 + i))];
  var remote = <String, dynamic>{};
  var nextId = 0;

  void sync(_Dev d) {
    final r = mergeCollection(
      local: d.items.values.toList(),
      remote: remote,
      base: d.base,
      now: now,
      conflictCopy: (i) => {...i, 'id': 'c${nextId++}', 'name': '${i['name']}*'},
      deviceId: d.name,
    );
    if (r.changedRemote) remote = jsonDecode(jsonEncode(r.remote)) as Map<String, dynamic>;
    for (final u in r.upserts) {
      d.items[u['id'] as String] = jsonDecode(jsonEncode(u)) as Map<String, dynamic>;
    }
    for (final id in r.localRemovals) {
      d.items.remove(id);
    }
    d.base = r.base;
  }

  for (var step = 0; step < 60; step++) {
    now = now.add(Duration(hours: rnd.nextInt(30)));
    final d = devs[rnd.nextInt(devs.length)];
    final live = d.items.values.where((i) => !SyncFields.readDeleted(i)).toList();
    switch (rnd.nextInt(5)) {
      case 0:
        final id = 'i${nextId++}';
        d.items[id] = item(id, name: 'n${rnd.nextInt(3)}', updatedAt: now, dev: d.name);
      case 1 when live.isNotEmpty:
        final i = live[rnd.nextInt(live.length)];
        d.items[i['id'] as String] = {
          ...i,
          'name': 'n${rnd.nextInt(3)}',
          'rev': SyncFields.readRev(i) + 1,
          'updatedAt': now.toIso8601String(),
          'dev': d.name,
        };
      case 2 when live.isNotEmpty:
        final i = live[rnd.nextInt(live.length)];
        d.items[i['id'] as String] = {
          ...i,
          'rev': SyncFields.readRev(i) + 1,
          'deleted': true,
          'deletedAt': now.toIso8601String(),
          'updatedAt': now.toIso8601String(),
          'dev': d.name,
        };
      default:
        sync(d);
    }
  }
  // Dos rondas tranquilas: todos quedan iguales entre sí y con la nube.
  for (var i = 0; i < 2; i++) {
    devs.forEach(sync);
  }
  Map<String, Map<String, dynamic>> liveOf(_Dev d) => {
        for (final e in d.items.entries)
          if (!SyncFields.readDeleted(e.value)) e.key: e.value,
      };
  final a = liveOf(devs[0]);
  for (final d in devs.skip(1)) {
    expect(jsonEncode(_sorted(liveOf(d))), jsonEncode(_sorted(a)), reason: 'seed $seed');
  }
  final remoteLive = {
    for (final e in remote.entries)
      if ((e.value as Map)['deleted'] != true)
        e.key: jsonDecode((e.value as Map)['payload'] as String),
  };
  expect(jsonEncode(_sorted(remoteLive)), jsonEncode(_sorted(a)), reason: 'seed $seed');
  // Una ronda más no escribe nada.
  for (final d in devs) {
    final r = mergeCollection(
      local: d.items.values.toList(),
      remote: remote,
      base: d.base,
      now: now,
      conflictCopy: (i) => i,
      deviceId: d.name,
    );
    expect(r.changedRemote, isFalse, reason: 'seed $seed');
    expect(r.upserts, isEmpty, reason: 'seed $seed');
  }
}

Object? _sorted(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _sorted(v[k])};
  }
  if (v is List) return v.map(_sorted).toList();
  return v;
}

class _Dev {
  _Dev(this.name);
  final String name;
  final Map<String, Map<String, dynamic>> items = {};
  Map<String, int> base = {};
}
