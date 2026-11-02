import 'dart:async';

import 'package:fede_apps_core/fede_apps_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const userA = FedeUser(uid: 'u1', email: 'fede@example.com', displayName: 'Fede');

class FakeBackend implements AccountBackend {
  final _c = StreamController<FedeUser?>.broadcast();
  FedeUser? current;
  FedeUser? next = userA;
  FedeAuthException? error;
  int signIns = 0;
  int signOuts = 0;

  @override
  FedeUser? get currentUser => current;

  @override
  Stream<FedeUser?> userChanges() => _c.stream;

  @override
  Future<FedeUser?> signInWithGoogle() async {
    signIns++;
    if (error != null) throw error!;
    current = next;
    _c.add(current);
    return current;
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    current = null;
    _c.add(null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeBackend backend;
  late LibrarySync sync;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    UsageTracker.instance.debugReset();
    PromptGate.instance.debugReset();
    DeviceIdentity.debugReset();
    await UsageTracker.instance.init(listenLifecycle: false);
    backend = FakeBackend();
    FedeAccount.instance.debugSetBackend(backend);
    sync = LibrarySync(
      store: InMemoryRemoteStore(),
      user: FedeAccount.instance.user,
      listenLifecycle: false,
    );
  });

  tearDown(() {
    sync.dispose();
    FedeAccount.instance.debugSetBackend(null);
  });

  Widget app(Widget child) => MaterialApp(home: Scaffold(body: ListView(children: [child])));

  group('profileDisplayName', () {
    test('usa el nombre; si no, la parte local del email; recorta a 2..60', () {
      expect(profileDisplayName('Fede R', 'x@y.com'), 'Fede R');
      expect(profileDisplayName(null, 'fede.r@y.com'), 'fede.r');
      expect(profileDisplayName(' ', 'ab@y.com'), 'ab');
      expect(profileDisplayName('', 'a@y.com'), 'a_');
      expect(profileDisplayName('x' * 80, 'a@y.com').length, 60);
    });
  });

  group('FedeAccount', () {
    test('sigue al backend', () async {
      expect(FedeAccount.instance.user.value, isNull);
      final u = await FedeAccount.instance.signInWithGoogle();
      expect(u, userA);
      expect(FedeAccount.instance.isSignedIn, isTrue);
      await FedeAccount.instance.signOut();
      expect(FedeAccount.instance.user.value, isNull);
      expect(backend.signOuts, 1);
    });

    test('cancelar devuelve null', () async {
      backend.next = null;
      expect(await FedeAccount.instance.signInWithGoogle(), isNull);
      expect(FedeAccount.instance.user.value, isNull);
    });
  });

  group('AccountSection', () {
    testWidgets('sin sesión → login → con sesión → cerrar sesión', (tester) async {
      await tester.pumpWidget(app(AccountSection(sync: sync)));
      expect(find.text('Account'), findsOneWidget);
      expect(find.text('Save your library'), findsOneWidget);
      expect(find.text('Sign in with Google to have it on all your devices'), findsOneWidget);

      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      expect(backend.signIns, 1);
      expect(find.text('Fede'), findsOneWidget);
      expect(find.textContaining('fede@example.com'), findsOneWidget);
      expect(find.text('Sync now'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Sign out?'), findsOneWidget);
      expect(find.text('Your library stays on this device, but stops syncing.'),
          findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(backend.signOuts, 0);

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
      await tester.pumpAndSettle();
      expect(backend.signOuts, 1);
      expect(find.text('Save your library'), findsOneWidget);
    });

    testWidgets('estado de la sincronización', (tester) async {
      backend.current = userA;
      FedeAccount.instance.debugSetBackend(backend);
      final adapter = _EmptyAdapter();
      await tester.runAsync(() => sync.configure(adapter));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpWidget(app(AccountSection(sync: sync)));
      expect(find.textContaining('Synced just now'), findsOneWidget);
    });

    testWidgets('sin biblioteca: identidad del ecosistema, sin "Sync now"', (tester) async {
      await tester.pumpWidget(app(AccountSection(hasLibrary: false, sync: sync)));
      expect(find.text('Your ecosystem account'), findsOneWidget);
      expect(find.text('The same account across all apps and the website'), findsOneWidget);
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      expect(find.text('Sync now'), findsNothing);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('error de login → SnackBar', (tester) async {
      backend.error = const FedeAuthException(FedeAuthError.network);
      await tester.pumpWidget(app(AccountSection(sync: sync)));
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      expect(find.text("No connection. Try again when you're online."), findsOneWidget);
      expect(find.text('Save your library'), findsOneWidget);
    });
  });

  group('maybeShowLoginPrompt', () {
    Future<BuildContext> host(WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const Scaffold();
        }),
      ));
      return ctx;
    }

    testWidgets('pocos ítems o con sesión → no se muestra', (tester) async {
      final ctx = await host(tester);
      expect(
          await EcosystemPrompts.maybeShowLoginPrompt(ctx,
              currentApp: FedeApp.metronomo, libraryCount: 2),
          isFalse);
      await FedeAccount.instance.signInWithGoogle();
      expect(
          await EcosystemPrompts.maybeShowLoginPrompt(ctx,
              currentApp: FedeApp.metronomo, libraryCount: 10),
          isFalse);
    });

    testWidgets('se muestra; "Continuar con Google" la acepta si el login sale bien',
        (tester) async {
      final ctx = await host(tester);
      final shown = EcosystemPrompts.maybeShowLoginPrompt(ctx,
          currentApp: FedeApp.metronomo, libraryCount: 3);
      await tester.pumpAndSettle();
      expect(find.text('☁️ Your library lives only on this device'), findsOneWidget);
      expect(find.text("Don't show again"), findsNothing);
      expect(find.text('Only your library and your settings.'), findsNothing);
      await tester.tap(find.text('What do we save?'));
      await tester.pumpAndSettle();
      expect(find.text('Only your library and your settings.'), findsOneWidget);

      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      expect(await shown, isTrue);
      expect(FedeAccount.instance.isSignedIn, isTrue);
      expect(PromptGate.instance.isClosed(EcosystemPrompts.loginPromptId), isTrue);
    });

    testWidgets('si el login falla, la hoja queda abierta con el error', (tester) async {
      backend.error = const FedeAuthException(FedeAuthError.unknown);
      final ctx = await host(tester);
      final shown = EcosystemPrompts.maybeShowLoginPrompt(ctx,
          currentApp: FedeApp.metronomo, libraryCount: 5);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue with Google'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't sign in. Please try again."), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(await shown, isTrue);
      expect(PromptGate.instance.isClosed(EcosystemPrompts.loginPromptId), isFalse);
      expect(PromptGate.instance.shows(EcosystemPrompts.loginPromptId), 1);
    });
  });
}

class _EmptyAdapter implements SyncAdapter {
  @override
  String get appId => 'tonegenerator';
  @override
  List<String> get collections => const ['presets'];
  @override
  Future<List<Map<String, dynamic>>> readAll(String collection) async => [];
  @override
  Future<void> applyRemote(String collection,
      {required List<Map<String, dynamic>> upserts, required List<String> removals}) async {}
  @override
  Map<String, dynamic> conflictCopy(String collection, Map<String, dynamic> item) => item;
}
