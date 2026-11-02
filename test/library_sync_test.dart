import 'package:fake_async/fake_async.dart';
import 'package:fede_apps_core/fede_apps_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAdapter implements SyncAdapter {
  FakeAdapter(this.dev, {this.clock});

  final String dev;
  final DateTime Function()? clock;
  final Map<String, Map<String, Map<String, dynamic>>> data = {
    'presets': {},
    'sessions': {},
  };
  int applyCalls = 0;

  DateTime get _now => (clock ?? DateTime.now)();

  @override
  String get appId => 'metronomo';

  @override
  List<String> get collections => data.keys.toList();

  @override
  Future<List<Map<String, dynamic>>> readAll(String collection) async =>
      data[collection]!.values.map((e) => Map<String, dynamic>.from(e)).toList();

  @override
  Future<void> applyRemote(String collection,
      {required List<Map<String, dynamic>> upserts,
      required List<String> removals}) async {
    applyCalls++;
    for (final u in upserts) {
      data[collection]![u['id'] as String] = Map<String, dynamic>.from(u);
    }
    for (final id in removals) {
      data[collection]!.remove(id);
    }
  }

  @override
  Map<String, dynamic> conflictCopy(String collection, Map<String, dynamic> item) =>
      {...item, 'id': '${item['id']}-$dev', 'name': '${item['name']} (otro dispositivo)'};

  // ── Operaciones locales (como haría la app) ──
  void add(String c, String id, String name) => data[c]![id] = {
        'id': id,
        'name': name,
        'rev': 1,
        'updatedAt': _now.toIso8601String(),
        'dev': dev,
      };

  void edit(String c, String id, String name) {
    final i = data[c]![id]!;
    data[c]![id] = {
      ...i,
      'name': name,
      'rev': (i['rev'] as int) + 1,
      'updatedAt': _now.toIso8601String(),
      'dev': dev,
    };
  }

  void delete(String c, String id) {
    final i = data[c]![id]!;
    data[c]![id] = {
      ...i,
      'rev': (i['rev'] as int) + 1,
      'deleted': true,
      'deletedAt': _now.toIso8601String(),
      'updatedAt': _now.toIso8601String(),
      'dev': dev,
    };
  }

  Map<String, String> live(String c) => {
        for (final e in data[c]!.entries)
          if (e.value['deleted'] != true) e.key: e.value['name'] as String,
      };
}

class ThrowingStore implements RemoteStore {
  @override
  Future<T> update<T>({
    required String uid,
    required String appId,
    required RemoteUpdate<T> Function(Map<String, dynamic>? collections) transform,
  }) async =>
      throw StateError('permission-denied');
}

const userA = FedeUser(uid: 'u1', email: 'a@b.com', displayName: 'Fede');

Future<void> settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryRemoteStore store;
  late ValueNotifier<FedeUser?> user;
  final created = <LibrarySync>[];

  LibrarySync device(String name, {RemoteStore? remote, DateTime Function()? clock}) {
    final s = LibrarySync(
      store: remote ?? store,
      user: user,
      deviceId: name,
      clock: clock,
      listenLifecycle: false,
      prefsPrefix: 'fac_sync_${name}_',
    );
    created.add(s);
    return s;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = InMemoryRemoteStore();
    user = ValueNotifier(null);
  });

  tearDown(() {
    for (final s in created) {
      s.dispose();
    }
    created.clear();
  });

  test('sin sesión: inactivo y no hace nada', () async {
    final sync = device('A');
    final a = FakeAdapter('A')..add('presets', 'p1', 'uno');
    await sync.configure(a);
    expect(sync.status.value.state, SyncState.disabled);
    await sync.syncNow(force: true);
    expect(store.reads, 0);
    expect(sync.canPurgeLocally('presets', 'p1', 1), isTrue);
  });

  test('al iniciar sesión sube lo local, guarda base y estado', () async {
    final sync = device('A');
    final a = FakeAdapter('A')
      ..add('presets', 'p1', 'uno')
      ..add('sessions', 's1', 'ses');
    await sync.configure(a);
    user.value = userA;
    await settle();
    expect(sync.status.value.state, SyncState.idle);
    expect(sync.status.value.lastSyncedAt, isNotNull);
    expect(store.reads, 1);
    expect(store.writes, 1);
    final remote = store.collections('u1', 'metronomo')!;
    expect((remote['presets'] as Map).keys, ['p1']);
    expect((remote['sessions'] as Map).keys, ['s1']);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(sync.baseKey('u1', 'metronomo')), isNotNull);
    expect(sync.canPurgeLocally('presets', 'p1', 1), isTrue);
    expect(sync.canPurgeLocally('presets', 'p1', 2), isFalse);

    // Sin cambios: 1 lectura, 0 escrituras.
    await sync.syncNow(force: true);
    expect(store.reads, 2);
    expect(store.writes, 1);
  });

  test('al configurar con sesión ya iniciada sincroniza (abrir la app)', () async {
    user.value = userA;
    final sync = device('A');
    await sync.configure(FakeAdapter('A')..add('presets', 'p1', 'uno'));
    await settle();
    expect(store.writes, 1);
    expect(sync.status.value.state, SyncState.idle);
  });

  test('dos dispositivos: alta, edición, borrado y conflicto', () async {
    user.value = userA;
    final syncA = device('A');
    final syncB = device('B');
    final a = FakeAdapter('A');
    final b = FakeAdapter('B');
    await syncA.configure(a);
    await syncB.configure(b);
    await settle();

    a.add('presets', 'p1', 'uno');
    await syncA.syncNow(force: true);
    await syncB.syncNow(force: true);
    expect(b.live('presets'), {'p1': 'uno'});

    b.edit('presets', 'p1', 'uno editado');
    await syncB.syncNow(force: true);
    await syncA.syncNow(force: true);
    expect(a.live('presets'), {'p1': 'uno editado'});

    b.delete('presets', 'p1');
    await syncB.syncNow(force: true);
    await syncA.syncNow(force: true);
    expect(a.live('presets'), isEmpty);
    expect(a.data['presets']!['p1']!['deleted'], true);

    // Conflicto: los dos editan el mismo ítem.
    a.add('sessions', 's1', 'ses');
    await syncA.syncNow(force: true);
    await syncB.syncNow(force: true);
    a.edit('sessions', 's1', 'versión A');
    b.edit('sessions', 's1', 'versión B');
    b.edit('sessions', 's1', 'versión B2'); // rev más alta → gana B
    await syncA.syncNow(force: true);
    await syncB.syncNow(force: true);
    await syncA.syncNow(force: true);
    expect(a.live('sessions'), {
      's1': 'versión B2',
      's1-B': 'versión A (otro dispositivo)',
    });
    expect(b.live('sessions'), a.live('sessions'));
    expect(a.data, b.data);
  });

  test('sin conexión → offline; al volver, sincroniza', () async {
    user.value = userA;
    store.online = false;
    final sync = device('A');
    final a = FakeAdapter('A')..add('presets', 'p1', 'uno');
    await sync.configure(a);
    await settle();
    expect(sync.status.value.state, SyncState.offline);
    expect(sync.status.value.lastSyncedAt, isNull);
    expect(sync.canPurgeLocally('presets', 'p1', 1), isFalse);

    store.online = true;
    await sync.syncNow(force: true);
    expect(sync.status.value.state, SyncState.idle);
    expect(store.writes, 1);
  });

  test('otro error → error', () async {
    user.value = userA;
    final sync = device('A', remote: ThrowingStore());
    await sync.configure(FakeAdapter('A'));
    await settle();
    expect(sync.status.value.state, SyncState.error);
    expect(sync.status.value.lastError, contains('permission-denied'));
  });

  test('cerrar sesión borra el base de ese uid y desactiva; la biblioteca queda', () async {
    user.value = userA;
    final sync = device('A');
    final a = FakeAdapter('A')..add('presets', 'p1', 'uno');
    await sync.configure(a);
    await settle();
    final prefs = await SharedPreferences.getInstance();
    final key = sync.baseKey('u1', 'metronomo');
    expect(prefs.getString(key), isNotNull);

    user.value = null;
    await settle();
    expect(prefs.getString(key), isNull);
    expect(prefs.getString(sync.lastKey('u1', 'metronomo')), isNull);
    expect(sync.status.value.state, SyncState.disabled);
    expect(a.live('presets'), {'p1': 'uno'});
    expect(sync.canPurgeLocally('presets', 'p1', 99), isTrue);

    // Volver a entrar: merge normal con base vacío, sin duplicar nada.
    user.value = userA;
    await settle();
    expect(sync.status.value.state, SyncState.idle);
    expect(a.live('presets'), {'p1': 'uno'});
  });

  test('las colecciones desconocidas de la nube se conservan', () async {
    user.value = userA;
    final sync = device('A');
    await store.update<void>(
      uid: 'u1',
      appId: 'metronomo',
      transform: (_) => (write: {'futura': {'x': {'rev': 1, 'payload': '{}'}}}, result: null),
    );
    await sync.configure(FakeAdapter('A')..add('presets', 'p1', 'uno'));
    await settle();
    final remote = store.collections('u1', 'metronomo')!;
    expect(remote.keys, containsAll(['futura', 'presets', 'sessions']));
  });

  test('un cambio local durante la sync no se pisa', () async {
    user.value = userA;
    final syncA = device('A');
    final syncB = device('B');
    final a = FakeAdapter('A');
    final b = FakeAdapter('B');
    await syncA.configure(a);
    await syncB.configure(b);
    await settle();
    a.add('presets', 'p1', 'uno');
    await syncA.syncNow(force: true);
    await syncB.syncNow(force: true);

    b.edit('presets', 'p1', 'de B');
    await syncB.syncNow(force: true);

    // A baja "de B", pero justo en el medio el usuario edita en A.
    store.onRead = () async {
      store.onRead = null;
      a.edit('presets', 'p1', 'de A en el medio');
    };
    await syncA.syncNow(force: true);
    expect(a.live('presets'), {'p1': 'de A en el medio'});
    expect(syncA.canPurgeLocally('presets', 'p1', 2), isFalse);

    // La próxima lo resuelve como conflicto, sin perder nada.
    await syncA.syncNow(force: true);
    await syncB.syncNow(force: true);
    expect(a.live('presets').values.toSet(), {'de A en el medio', 'de B (otro dispositivo)'});
    expect(b.live('presets'), a.live('presets'));
  });

  test('una sync a la vez: los pedidos se encolan', () async {
    user.value = userA;
    final sync = device('A');
    await sync.configure(FakeAdapter('A'));
    await settle();
    final before = store.reads;
    var inFlight = 0;
    var maxInFlight = 0;
    store.onRead = () async {
      inFlight++;
      maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
      await Future<void>.delayed(Duration.zero);
      inFlight--;
    };
    await Future.wait([
      sync.syncNow(force: true),
      sync.syncNow(force: true),
      sync.syncNow(force: true),
    ]);
    expect(maxInFlight, 1);
    expect(store.reads - before, 2); // la primera + una encolada
  });

  test('debounce de 10 s, intervalo mínimo de 20 s y volver a la app', () {
    fakeAsync((async) {
      final start = DateTime(2026, 11, 2, 10);
      DateTime now() => start.add(async.elapsed);
      user.value = userA;
      final sync = device('A', clock: now);
      final a = FakeAdapter('A', clock: now);
      sync.configure(a);
      async.elapse(const Duration(milliseconds: 10));
      expect(store.reads, 1); // al abrir

      // Cambios seguidos: una sola sync, 10 s después del último
      // (y al menos 20 s después de la anterior).
      async.elapse(const Duration(seconds: 15));
      a.add('presets', 'p1', 'uno');
      sync.notifyLocalChange();
      async.elapse(const Duration(seconds: 5));
      a.add('presets', 'p2', 'dos');
      sync.notifyLocalChange();
      async.elapse(const Duration(seconds: 9));
      expect(store.reads, 1);
      async.elapse(const Duration(seconds: 2));
      expect(store.reads, 2);
      expect(store.writes, 1);

      // Cambio justo después: el debounce vence a los 10 s, pero espera a los 20 s.
      a.add('presets', 'p3', 'tres');
      sync.notifyLocalChange();
      async.elapse(const Duration(seconds: 15));
      expect(store.reads, 2);
      async.elapse(const Duration(seconds: 6));
      expect(store.reads, 3);

      // Sin force, syncNow respeta el intervalo; con force, no.
      sync.syncNow();
      async.elapse(const Duration(milliseconds: 10));
      expect(store.reads, 3);
      async.elapse(const Duration(seconds: 25));
      expect(store.reads, 4); // la diferida
      sync.syncNow(force: true);
      async.elapse(const Duration(milliseconds: 10));
      expect(store.reads, 5);

      // Volver a la app: solo si pasaron más de 2 min.
      async.elapse(const Duration(minutes: 1));
      sync.debugResume();
      async.elapse(const Duration(milliseconds: 10));
      expect(store.reads, 5);
      async.elapse(const Duration(minutes: 2));
      sync.debugResume();
      async.elapse(const Duration(milliseconds: 10));
      expect(store.reads, 6);
      expect(a.live('presets').length, 3);
    });
  });

  test('notifyLocalChange sin sesión no hace nada', () {
    fakeAsync((async) {
      final sync = device('A');
      sync.configure(FakeAdapter('A'));
      async.elapse(const Duration(milliseconds: 10));
      sync.notifyLocalChange();
      async.elapse(const Duration(seconds: 30));
      expect(store.reads, 0);
    });
  });
}
