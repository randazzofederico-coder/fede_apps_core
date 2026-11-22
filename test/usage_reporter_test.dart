import 'dart:async';

import 'package:fede_apps_core/fede_apps_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;
  late InMemoryUsageStore store;
  late List<Uri> gcHits;
  late ValueNotifier<FedeUser?> userNotifier;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UsageTracker.instance.debugReset();
    UsageReporter.instance.debugReset();
    now = DateTime(2026, 11, 22, 10, 0);
    UsageTracker.instance.clock = () => now;
    store = InMemoryUsageStore();
    gcHits = [];
    userNotifier = ValueNotifier<FedeUser?>(null);
  });

  tearDown(() {
    UsageReporter.instance.debugReset();
    UsageTracker.instance.debugReset();
    userNotifier.dispose();
  });

  const userA = FedeUser(
    uid: 'uid-alice',
    displayName: 'Alice',
    email: 'alice@example.com',
  );
  const userB = FedeUser(
    uid: 'uid-bob',
    displayName: 'Bob',
    email: 'bob@example.com',
  );

  void configureReporter({
    FedeApp app = FedeApp.afinador,
    String platform = 'android',
    bool sendGoatCounterInDebug = true,
    SharedPreferences? prefsOverride,
  }) {
    UsageReporter.instance.configure(
      app: app,
      appVersion: '1.2.3+4',
      sendGoatCounterInDebug: sendGoatCounterInDebug,
      store: store,
      goatCounterSender: (uri) async => gcHits.add(uri),
      userListenable: userNotifier,
      clock: () => now,
      prefsOverride: prefsOverride,
      platformOverride: platform,
    );
  }

  Future<void> pump() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  group('helpers puros', () {
    test('buildGoatCounterUri arma pageviews y eventos correctamente', () {
      final page = buildGoatCounterUri(
        endpoint: kDefaultAppStatsEndpoint,
        path: '/afinador',
        title: 'Afinador',
        referrer: 'android',
        cacheBuster: 'abc',
      );
      expect(page.scheme, 'https');
      expect(page.host, 'appstats.federicorandazzo.com.ar');
      expect(page.path, '/count');
      expect(page.queryParameters['p'], '/afinador');
      expect(page.queryParameters['t'], 'Afinador');
      expect(page.queryParameters['r'], 'android');
      expect(page.queryParameters['rnd'], 'abc');
      expect(page.queryParameters.containsKey('e'), isFalse);

      final ev = buildGoatCounterUri(
        endpoint: kDefaultAppStatsEndpoint,
        path: 'elmuvi/pdf-download/mercadopago',
        title: 'web',
        referrer: 'web',
        event: true,
        cacheBuster: 'xyz',
      );
      expect(ev.queryParameters['p'], 'elmuvi/pdf-download/mercadopago');
      expect(ev.queryParameters['t'], 'web');
      expect(ev.queryParameters['r'], 'web');
      expect(ev.queryParameters['e'], 'true');
      expect(ev.queryParameters['rnd'], 'xyz');
    });

    test('practiceDurationBucket agrupa en los 5 rangos esperados', () {
      expect(practiceDurationBucket(0), isNull);
      expect(practiceDurationBucket(14), isNull);
      expect(practiceDurationBucket(15), '15s-1m');
      expect(practiceDurationBucket(59), '15s-1m');
      expect(practiceDurationBucket(60), '1-5m');
      expect(practiceDurationBucket(299), '1-5m');
      expect(practiceDurationBucket(300), '5-15m');
      expect(practiceDurationBucket(899), '5-15m');
      expect(practiceDurationBucket(900), '15-30m');
      expect(practiceDurationBucket(1799), '15-30m');
      expect(practiceDurationBucket(1800), '30m+');
      expect(practiceDurationBucket(7200), '30m+');
    });

    test('staleRecentDayKeys detecta claves con ≥ 30 días e ignora inválidas', () {
      final ref = DateTime(2026, 11, 30);
      final stale = staleRecentDayKeys(
        const [
          '2026-11-30',
          '2026-11-01', // 29 días: se mantiene
          '2026-10-31', // 30 días: caduca
          '2026-10-01',
          'invalid',
          '2026-02-31', // fecha inexistente
        ],
        ref,
      );
      expect(stale, ['2026-10-01', '2026-10-31']);
    });
  });

  group('GoatCounter', () {
    test('sendGoatCounterInDebug: false suprime envíos en modo debug/test', () async {
      configureReporter(sendGoatCounterInDebug: false);
      await UsageTracker.instance.init(listenLifecycle: false);
      UsageTracker.instance.startActivity();
      now = now.add(const Duration(seconds: 30));
      await UsageTracker.instance.stopActivity();
      await UsageReporter.instance.trackEvent('test-event');
      await pump();

      expect(gcHits, isEmpty);
    });

    test('envía pageview y eventos incluso sin sesión, con umbral de 15 s, sin tocar Firestore',
        () async {
      configureReporter(app: FedeApp.elongacionMusical, platform: 'web');
      await UsageTracker.instance.init(listenLifecycle: false);
      await pump();

      expect(gcHits.length, 1);
      expect(gcHits[0].queryParameters['p'], '/elmuvi');
      expect(gcHits[0].queryParameters['t'], 'Elongación Musical');
      expect(gcHits[0].queryParameters['r'], 'web');
      expect(gcHits[0].queryParameters.containsKey('e'), isFalse);

      // Actividad < 15 s: NO envía evento a GoatCounter.
      UsageTracker.instance.startActivity();
      now = now.add(const Duration(seconds: 10));
      await UsageTracker.instance.stopActivity();
      await pump();
      expect(gcHits.length, 1);

      // Actividad >= 15 s: envía evento de bucket.
      UsageTracker.instance.startActivity();
      now = now.add(const Duration(seconds: 40));
      await UsageTracker.instance.stopActivity();
      await pump();
      expect(gcHits.length, 2);
      expect(gcHits[1].queryParameters['p'], 'elmuvi/practice/15s-1m');
      expect(gcHits[1].queryParameters['e'], 'true');
      expect(gcHits[1].queryParameters['t'], 'web');

      // Evento explícito trackEvent.
      await UsageReporter.instance.trackEvent('pdf-download/mercadopago');
      expect(gcHits.length, 3);
      expect(gcHits[2].queryParameters['p'], 'elmuvi/pdf-download/mercadopago');
      expect(gcHits[2].queryParameters['e'], 'true');

      // Sin sesión nunca se escribe a Firestore.
      expect(store.writeCount, 0);
      expect(store.docs, isEmpty);
    });
  });

  group('Firestore deltas & multi-dispositivo', () {
    test('configurar antes vs después de UsageTracker.init() captura la apertura sin duplicar',
        () async {
      // Variante A: configure antes de init()
      userNotifier.value = userA;
      configureReporter(app: FedeApp.afinador);
      await UsageTracker.instance.init(listenLifecycle: false);
      await UsageReporter.instance.debugFlush();

      var doc = store.docFor(userA.uid, 'afinador')!;
      expect((doc['totals'] as Map)['opens'], 1);
      expect(gcHits.length, 1);

      // Variante B: init() antes de configure() + segunda llamada idempotente
      UsageReporter.instance.debugReset();
      UsageTracker.instance.debugReset();
      SharedPreferences.setMockInitialValues({});
      store = InMemoryUsageStore();
      gcHits.clear();
      UsageTracker.instance.clock = () => now;

      await UsageTracker.instance.init(listenLifecycle: false);
      configureReporter(app: FedeApp.afinador);
      // Reconfigurar en la misma sesión NO duplica el open ni el pageview.
      configureReporter(app: FedeApp.afinador);
      await UsageReporter.instance.debugFlush();

      doc = store.docFor(userA.uid, 'afinador')!;
      expect((doc['totals'] as Map)['opens'], 1);
      expect(gcHits.length, 1);
    });

    test('acumula entre dos dispositivos el mismo día sin duplicar activeDayKeys', () async {
      // Dispositivo 1: Android
      userNotifier.value = userA;
      configureReporter(app: FedeApp.metronomo, platform: 'android');
      await UsageTracker.instance.init(listenLifecycle: false);
      UsageTracker.instance.startActivity();
      now = now.add(const Duration(seconds: 75));
      await UsageTracker.instance.stopActivity();
      await pump();

      // Dispositivo 2: Web el mismo día (SharedPreferences limpias, mismo store remoto)
      UsageReporter.instance.debugReset();
      UsageTracker.instance.debugReset();
      SharedPreferences.setMockInitialValues({});
      now = DateTime(2026, 11, 22, 18, 0);
      UsageTracker.instance.clock = () => now;

      configureReporter(app: FedeApp.metronomo, platform: 'web');
      await UsageTracker.instance.init(listenLifecycle: false);
      UsageTracker.instance.startActivity();
      now = now.add(const Duration(seconds: 120));
      await UsageTracker.instance.stopActivity();
      await pump();

      final doc = store.docFor(userA.uid, 'metronomo')!;
      final totals = doc['totals'] as Map<String, int>;
      expect(totals['opens'], 2);
      expect(totals['activitySec'], 195);

      final recent = (doc['recentDays'] as Map)['2026-11-22'] as Map<String, int>;
      expect(recent['opens'], 2);
      expect(recent['activitySec'], 195);

      final month = (doc['monthly'] as Map)['2026-11'] as Map<String, dynamic>;
      expect(month['opens'], 2);
      expect(month['activitySec'], 195);
      expect(month['activeDayKeys'], ['22']);

      expect(doc['platforms'], ['android', 'web']);
      expect(doc['lastPlatform'], 'web');
    });

    test('reintento offline persiste en SharedPreferences y se envía al recuperar conexión',
        () async {
      userNotifier.value = userA;
      store.failWrites = true;
      final prefs = await SharedPreferences.getInstance();
      configureReporter(app: FedeApp.toneGenerator, prefsOverride: prefs);
      await UsageTracker.instance.init(prefs: prefs, listenLifecycle: false);

      UsageTracker.instance.startActivity();
      now = now.add(const Duration(seconds: 70));
      await UsageTracker.instance.stopActivity();
      now = now.add(const Duration(seconds: 20));
      await UsageTracker.instance.debugBackground();
      await pump();

      // Falló el envío: nada en Firestore, pero la cola local conserva todo.
      expect(store.writeCount, 0);
      expect(prefs.getString('fac_usage_pending_${userA.uid}_tonegenerator'), isNotNull);

      // Simular reinicio de app con las mismas SharedPreferences y conexión restablecida.
      UsageReporter.instance.debugReset();
      UsageTracker.instance.debugReset();
      store.failWrites = false;
      UsageTracker.instance.clock = () => now;

      configureReporter(app: FedeApp.toneGenerator, prefsOverride: prefs);
      await pump();

      final doc = store.docFor(userA.uid, 'tonegenerator')!;
      expect((doc['totals'] as Map)['opens'], 1);
      expect((doc['totals'] as Map)['activitySec'], 70);
      expect((doc['totals'] as Map)['foregroundSec'], 90);
      expect(prefs.getString('fac_usage_pending_${userA.uid}_tonegenerator'), isNull);
    });

    test('concurrencia en vuelo: un delta generado durante el flush no se pierde', () async {
      userNotifier.value = userA;
      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      store.onBeforeWrite = (_) async {
        if (!writeStarted.isCompleted) {
          writeStarted.complete();
          await releaseWrite.future;
        }
      };

      configureReporter(app: FedeApp.afinador);
      await UsageTracker.instance.init(listenLifecycle: false);

      UsageTracker.instance.startActivity();
      now = now.add(const Duration(seconds: 70));
      await UsageTracker.instance.stopActivity();
      await writeStarted.future;

      // Mientras la escritura #1 está en vuelo, ocurre otro tramo de 25 s.
      UsageTracker.instance.startActivity();
      now = now.add(const Duration(seconds: 25));
      await UsageTracker.instance.stopActivity();

      // Se completa la escritura #1.
      releaseWrite.complete();
      await pump();

      var doc = store.docFor(userA.uid, 'afinador')!;
      expect(store.writeCount, 1);
      expect((doc['totals'] as Map)['activitySec'], 70);

      // El delta de 25 s sobrevivió intacto y sube en el siguiente flush.
      await UsageReporter.instance.debugFlush();
      doc = store.docFor(userA.uid, 'afinador')!;
      expect(store.writeCount, 2);
      expect((doc['totals'] as Map)['activitySec'], 95);
    });

    test('throttle de 30 min vs flush inmediato al detener ≥ 60 s acumulados', () async {
      userNotifier.value = userA;
      configureReporter(app: FedeApp.afinador);
      await UsageTracker.instance.init(listenLifecycle: false);

      // Solo apertura: queda en cola, aún 0 escrituras.
      expect(store.writeCount, 0);

      // Primera parada (último flush == null): envía open + 20 s en 1 escritura.
      UsageTracker.instance.startActivity();
      now = now.add(const Duration(seconds: 20));
      await UsageTracker.instance.stopActivity();
      await pump();
      expect(store.writeCount, 1);

      // 5 min después (< 30 min) y solo 25 s (< 60 s): queda throttled.
      now = now.add(const Duration(minutes: 5));
      UsageTracker.instance.startActivity();
      now = now.add(const Duration(seconds: 25));
      await UsageTracker.instance.stopActivity();
      await pump();
      expect(store.writeCount, 1);

      // Ir a segundo plano < 30 min después del último flush: también queda throttled.
      now = now.add(const Duration(minutes: 5));
      await UsageTracker.instance.debugBackground();
      await pump();
      expect(store.writeCount, 1);

      // Volver antes de 30 min y acumular otros 40 s (25 + 40 = 65 >= 60 s): flush inmediato.
      await UsageTracker.instance.debugForeground();
      UsageTracker.instance.startActivity();
      now = now.add(const Duration(seconds: 40));
      await UsageTracker.instance.stopActivity();
      await pump();
      expect(store.writeCount, 2);

      // Ahora simular paso de ≥ 30 min y background con delta nuevo: debe enviar.
      now = now.add(const Duration(minutes: 31));
      await UsageTracker.instance.debugBackground();
      await pump();
      expect(store.writeCount, 3);
    });

    test('poda automática de recentDays > 30 días conservando totales y monthly', () async {
      userNotifier.value = userA;
      now = DateTime(2026, 10, 1, 10, 0);
      UsageTracker.instance.clock = () => now;
      configureReporter(app: FedeApp.atril);
      await UsageTracker.instance.init(listenLifecycle: false);

      UsageTracker.instance.startActivity();
      now = now.add(const Duration(seconds: 70));
      await UsageTracker.instance.stopActivity();
      await pump();

      var doc = store.docFor(userA.uid, 'atril')!;
      expect((doc['recentDays'] as Map).containsKey('2026-10-01'), isTrue);

      // Avanzar 35 días: una nueva escritura activa dispara la poda de 2026-10-01.
      now = DateTime(2026, 11, 5, 11, 0);
      await UsageTracker.instance.debugBackground();
      now = now.add(const Duration(minutes: 35));
      await UsageTracker.instance.debugForeground();
      UsageTracker.instance.startActivity();
      now = now.add(const Duration(seconds: 80));
      await UsageTracker.instance.stopActivity();
      await pump();

      doc = store.docFor(userA.uid, 'atril')!;
      final recent = doc['recentDays'] as Map<String, dynamic>;
      expect(recent.containsKey('2026-10-01'), isFalse);
      expect(recent.containsKey('2026-11-05'), isTrue);
      expect((doc['monthly'] as Map).containsKey('2026-10'), isTrue);
      expect((doc['monthly'] as Map).containsKey('2026-11'), isTrue);
      expect((doc['totals'] as Map)['activitySec'], 150);
    });

    test('aislamiento entre cuentas: userA -> signOut -> userB no mezcla pendientes', () async {
      userNotifier.value = userA;
      store.failWrites = true;
      configureReporter(app: FedeApp.afinador);
      await UsageTracker.instance.init(listenLifecycle: false);

      UsageTracker.instance.startActivity();
      now = now.add(const Duration(seconds: 70));
      await UsageTracker.instance.stopActivity();
      await pump();
      expect(store.writeCount, 0);

      // userA cierra sesión sin conexión y userB inicia sesión ya online.
      userNotifier.value = null;
      await pump();
      store.failWrites = false;
      userNotifier.value = userB;
      await pump();

      // Los pendientes de userA NO se escriben en userB.
      expect(store.docFor(userB.uid, 'afinador'), isNull);

      // userB usa la app y solo se registra lo suyo.
      UsageTracker.instance.startActivity();
      now = now.add(const Duration(seconds: 80));
      await UsageTracker.instance.stopActivity();
      await pump();
      expect((store.docFor(userB.uid, 'afinador')!['totals'] as Map)['activitySec'], 80);
      expect(store.docFor(userA.uid, 'afinador'), isNull);

      // Cuando userA vuelve a iniciar sesión, se envían sus pendientes intactos.
      userNotifier.value = userA;
      await pump();
      final docA = store.docFor(userA.uid, 'afinador')!;
      expect((docA['totals'] as Map)['opens'], 1);
      expect((docA['totals'] as Map)['activitySec'], 70);
    });

    test('restauración asíncrona de sesión en Web captura apertura sin quemar escritura inmediata',
        () async {
      // Arranca sin sesión (típico Web antes de restaurar Firebase Auth).
      await UsageTracker.instance.init(listenLifecycle: false);
      configureReporter(app: FedeApp.elongacionMusical, platform: 'web');
      await pump();
      expect(store.writeCount, 0);

      // Firebase restaura la sesión asincrónicamente después de configure():
      // no quema una escritura en el arranque (0 escrituras todavía), pero ya guarda el open.
      userNotifier.value = userA;
      await pump();
      expect(store.writeCount, 0);

      // Al pasar a segundo plano más tarde, envía el open + foregroundSec en 1 sola escritura.
      now = now.add(const Duration(seconds: 30));
      await UsageTracker.instance.debugBackground();
      await pump();

      final doc = store.docFor(userA.uid, 'elmuvi')!;
      expect(store.writeCount, 1);
      expect((doc['totals'] as Map)['opens'], 1);
      expect((doc['totals'] as Map)['foregroundSec'], 30);
    });
  });
}
