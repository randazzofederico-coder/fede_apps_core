import 'package:fede_apps_core/fede_apps_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;
  final tracker = UsageTracker.instance;
  final gate = PromptGate.instance;

  Future<void> boot() async {
    tracker.debugReset();
    gate.debugReset();
    tracker.clock = () => now;
    await tracker.init(listenLifecycle: false);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 11, 2, 10);
    await boot();
  });

  group('UsageTracker', () {
    test('primera apertura', () {
      expect(tracker.openCount, 1);
      expect(tracker.activeDays, 1);
      expect(tracker.firstOpenAt, now);
    });

    test('volver rápido no es apertura nueva; tras 30 min sí', () async {
      await tracker.debugBackground();
      now = now.add(const Duration(minutes: 5));
      await tracker.debugForeground();
      expect(tracker.openCount, 1);

      await tracker.debugBackground();
      now = now.add(const Duration(minutes: 31));
      await tracker.debugForeground();
      expect(tracker.openCount, 2);
      expect(tracker.activeDays, 1);
    });

    test('días distintos', () async {
      for (var i = 1; i <= 4; i++) {
        now = now.add(const Duration(days: 1));
        await boot(); // arranque en frío
      }
      expect(tracker.activeDays, 5);
      expect(tracker.openCount, 5);
    });

    test('actividad: suma, no cuenta segundo plano, tope por tramo', () async {
      tracker.startActivity();
      now = now.add(const Duration(minutes: 10));
      expect(tracker.activitySeconds, 600);
      await tracker.debugBackground();
      now = now.add(const Duration(hours: 1));
      expect(tracker.activitySeconds, 600);
      await tracker.debugForeground();
      now = now.add(const Duration(minutes: 5));
      await tracker.stopActivity();
      expect(tracker.activitySeconds, 900);
      expect(tracker.isActivityRunning, isFalse);

      tracker.startActivity();
      now = now.add(const Duration(hours: 10));
      await tracker.stopActivity();
      expect(tracker.activitySeconds, 900 + 4 * 3600);
    });

    test('actividad que sigue en segundo plano (audio)', () async {
      tracker.startActivity(continuesInBackground: true);
      now = now.add(const Duration(minutes: 10));
      await tracker.debugBackground();
      now = now.add(const Duration(minutes: 20));
      expect(tracker.activitySeconds, 1800);
      await tracker.debugForeground();
      await tracker.stopActivity();
      expect(tracker.activitySeconds, 1800);
    });

    test('foreground minutes', () async {
      now = now.add(const Duration(minutes: 7));
      expect(tracker.foregroundMinutes, 7);
      await tracker.debugBackground();
      now = now.add(const Duration(minutes: 20));
      expect(tracker.foregroundMinutes, 7);
    });
  });

  group('PromptGate', () {
    test('una por sesión y por día, cooldown, máximo', () async {
      expect(gate.canShow('x'), isTrue);
      await gate.markShown('x');
      expect(gate.canShow('x'), isFalse); // misma sesión
      expect(gate.canShow('y'), isFalse); // otra sugerencia, mismo día

      now = now.add(const Duration(days: 1));
      await boot();
      expect(gate.canShow('y'), isTrue);
      expect(gate.canShow('x'), isFalse); // cooldown 14 días

      for (var i = 0; i < 2; i++) {
        now = now.add(const Duration(days: 15));
        await boot();
        expect(gate.canShow('x'), isTrue);
        await gate.markShown('x');
        await gate.markResult('x', PromptResult.dismissed);
      }
      now = now.add(const Duration(days: 15));
      await boot();
      expect(gate.shows('x'), 3);
      expect(gate.canShow('x'), isFalse); // maxShows
    });

    test('aceptada o "no volver a mostrar" cierra', () async {
      await gate.markShown('x');
      await gate.markResult('x', PromptResult.accepted);
      await gate.markShown('y');
      await gate.markResult('y', PromptResult.never);
      now = now.add(const Duration(days: 60));
      await boot();
      expect(gate.canShow('x'), isFalse);
      expect(gate.canShow('y'), isFalse);
    });
  });

  group('FedeApp links', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('Android: pública → Play Store; beta → ficha en /apps', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(FedeApp.afinador.uri().toString(),
          'https://play.google.com/store/apps/details?id=com.saroo.afinador');
      expect(FedeApp.metronomo.uri().toString(),
          'https://federicorandazzo.com.ar/apps/#metronomo');
      expect(FedeApp.toneGenerator.uri(es: false).toString(),
          'https://federicorandazzo.com.ar/en/apps/#tonegenerator');
    });

    test('otras plataformas: versión web o ficha en /apps', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(FedeApp.metronomo.uri().toString(),
          'https://federicorandazzo.com.ar/metronomo/');
      expect(FedeApp.atril.uri().toString(),
          'https://federicorandazzo.com.ar/apps/#atril');
    });
  });

  group('EcosystemPrompts', () {
    test('elegibilidad', () async {
      expect(EcosystemPrompts.isEligible(), isFalse);
      tracker.startActivity();
      now = now.add(const Duration(minutes: 31));
      expect(EcosystemPrompts.isEligible(), isFalse); // nunca durante la actividad
      await tracker.stopActivity();
      expect(EcosystemPrompts.isEligible(), isTrue);
    });

    testWidgets('muestra la hoja con las otras apps', (tester) async {
      tracker.startActivity();
      now = now.add(const Duration(minutes: 31));
      await tracker.stopActivity();

      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const Scaffold();
        }),
      ));

      final shown = EcosystemPrompts.maybeShowAppsPrompt(ctx,
          currentApp: FedeApp.afinador);
      await tester.pumpAndSettle();
      expect(find.text('Enjoying the Tuner?'), findsOneWidget);
      expect(find.text('Metronome'), findsOneWidget);
      expect(find.text('Tone Generator'), findsOneWidget);
      expect(find.text('Atril'), findsOneWidget);
      expect(find.text('Beta'), findsNWidgets(3));
      expect(find.text('Tuner'), findsNothing);
      expect(find.text("Don't show again"), findsNothing);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(await shown, isTrue);
      expect(gate.shows(EcosystemPrompts.appsPromptId), 1);
      expect(gate.isClosed(EcosystemPrompts.appsPromptId), isFalse);
    });
  });
}
