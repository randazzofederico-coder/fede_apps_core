import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account.dart';

const String kSiteUrl = 'https://federicorandazzo.com.ar';

/// Página de apps del sitio (con versión en inglés en /en/apps/).
Uri appsPageUri({bool es = true, String? anchor}) => Uri.parse(
    '$kSiteUrl${es ? '' : '/en'}/apps/${anchor == null ? '' : '#$anchor'}');

/// Las apps del ecosistema (mismo orden que la página /apps del sitio).
///
/// [beta] = Android en prueba cerrada (hay que ser tester). Para esas apps
/// el link no va directo a la Play Store (a quien no es tester le daría
/// "no encontrada"), sino a su ficha en /apps, donde se pide acceso y,
/// si ya es tester, aparece el botón a Google Play.
enum FedeApp {
  afinador(
    siteId: 'afinador',
    nameEs: 'Afinador',
    nameEn: 'Tuner',
    taglineEs: 'Afinador cromático de alta precisión',
    taglineEn: 'High-precision chromatic tuner',
    playStoreId: 'com.saroo.afinador',
    webPath: '/afinador/',
    beta: false,
  ),
  metronomo(
    siteId: 'metronomo',
    nameEs: 'Metrónomo',
    nameEn: 'Metronome',
    taglineEs: 'Polirritmias, tuplets y subdivisiones',
    taglineEn: 'Polyrhythms, tuplets and subdivisions',
    playStoreId: 'com.Saroo.Metronomo',
    webPath: '/metronomo/',
    beta: true,
  ),
  atril(
    siteId: 'atril',
    nameEs: 'Atril',
    nameEn: 'Atril',
    taglineEs: 'Tus partituras, listas para el escenario',
    taglineEn: 'Your sheet music, ready for the stage',
    playStoreId: 'com.saroo.atril',
    webPath: null, // solo Android
    beta: true,
  ),
  toneGenerator(
    siteId: 'tonegenerator',
    nameEs: 'Generador de Tonos',
    nameEn: 'Tone Generator',
    taglineEs: 'Frecuencias multi-canal en tiempo real',
    taglineEn: 'Real-time multichannel frequencies',
    playStoreId: 'com.saroo.tone_generator',
    webPath: '/tone-generator/',
    beta: true,
  );

  const FedeApp({
    required this.siteId,
    required this.nameEs,
    required this.nameEn,
    required this.taglineEs,
    required this.taglineEn,
    required this.playStoreId,
    required this.webPath,
    required this.beta,
  });

  /// Id canónico del sitio (src/data/apps.ts, anclas de /apps, Firestore).
  final String siteId;
  final String nameEs;
  final String nameEn;
  final String taglineEs;
  final String taglineEn;
  final String playStoreId;
  final String? webPath;
  final bool beta;

  String name(bool es) => es ? nameEs : nameEn;
  String tagline(bool es) => es ? taglineEs : taglineEn;

  /// Ícono real de la app (incluido en el paquete).
  ImageProvider get iconImage =>
      AssetImage('assets/icons/$siteId.png', package: 'fede_apps_core');

  Uri get playStoreUri =>
      Uri.parse('https://play.google.com/store/apps/details?id=$playStoreId');

  /// A dónde lleva tocar la app:
  /// * Android: Play Store si es pública; su ficha en /apps si es beta.
  /// * Web / otros: la versión web si existe; si no, su ficha en /apps.
  Uri uri({bool es = true}) {
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    if (android) {
      return beta ? appsPageUri(es: es, anchor: siteId) : playStoreUri;
    }
    final path = webPath;
    if (path != null) return Uri.parse('$kSiteUrl$path');
    return appsPageUri(es: es, anchor: siteId);
  }

  /// Las otras apps (todas menos esta).
  List<FedeApp> get others => FedeApp.values.where((a) => a != this).toList();
}

/// Abre una URL fuera de la app (Play Store, navegador). Nunca lanza.
Future<bool> openExternal(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Textos del paquete (es / en). Cualquier idioma que no sea español usa inglés.
class FacStrings {
  const FacStrings._(this.es);
  final bool es;

  static FacStrings of(BuildContext context) =>
      FacStrings._(Localizations.maybeLocaleOf(context)?.languageCode == 'es');

  String appsPromptTitle(FedeApp app) => es
      ? switch (app) {
          FedeApp.afinador => '¿Te está sirviendo el afinador?',
          FedeApp.metronomo => '¿Te está sirviendo el metrónomo?',
          FedeApp.atril => '¿Te está sirviendo el Atril?',
          FedeApp.toneGenerator => '¿Te está sirviendo el generador de tonos?',
        }
      : 'Enjoying the ${app.nameEn}?';
  String get appsPromptBody => es
      ? 'También hice estas apps, gratis:'
      : 'I also made these apps, for free:';
  String get allApps => es ? 'Ver todas en la web' : 'See all on the website';
  String get allAppsSub => es
      ? 'Apps, foro, docencia y más'
      : 'Apps, forum, lessons and more';
  String get beta => 'Beta';
  String get notNow => es ? 'Ahora no' : 'Not now';
  String get dontShowAgain => es ? 'No volver a mostrar' : "Don't show again";
  String get moreApps => es ? 'Más apps' : 'More apps';
  String get rotateTitle => es ? 'Girá el teléfono' : 'Rotate your phone';
  String get rotateBody => es
      ? 'Por ahora la app funciona en vertical.'
      : 'For now the app works in portrait.';

  // ── Cuenta y sincronización ───────────────────────────────────────────────
  String get account => es ? 'Cuenta' : 'Account';
  String get saveLibraryTitle => es ? 'Guardá tu biblioteca' : 'Save your library';
  String get saveLibrarySub => es
      ? 'Iniciá sesión con Google para tenerla en todos tus dispositivos'
      : 'Sign in with Google to have it on all your devices';
  String get ecosystemAccountTitle =>
      es ? 'Tu cuenta del ecosistema' : 'Your ecosystem account';
  String get ecosystemAccountSub => es
      ? 'La misma cuenta en todas las apps y en la web'
      : 'The same account across all apps and the website';
  String get continueWithGoogle =>
      es ? 'Continuar con Google' : 'Continue with Google';
  String get syncNow => es ? 'Sincronizar ahora' : 'Sync now';
  String get signOut => es ? 'Cerrar sesión' : 'Sign out';
  String get signOutConfirmTitle => es ? '¿Cerrar sesión?' : 'Sign out?';
  String signOutConfirmBody({required bool hasLibrary}) => hasLibrary
      ? (es
          ? 'Tu biblioteca queda en este dispositivo, pero deja de sincronizarse.'
          : 'Your library stays on this device, but stops syncing.')
      : (es
          ? 'Podés volver a iniciar sesión cuando quieras.'
          : 'You can sign in again anytime.');
  String get cancel => es ? 'Cancelar' : 'Cancel';
  String get syncing => es ? 'Sincronizando…' : 'Syncing…';
  String get syncOffline => es
      ? 'Sin conexión, se sincroniza cuando vuelva'
      : "Offline, it'll sync when you're back online";
  String get syncError => es ? 'No se pudo sincronizar' : "Couldn't sync";
  String get syncPending => es ? 'Todavía no se sincronizó' : 'Not synced yet';

  /// "Sincronizado hace 2 min".
  String syncedAgo(DateTime at, DateTime now) {
    final d = now.difference(at);
    if (d.inMinutes < 1) return es ? 'Sincronizado recién' : 'Synced just now';
    if (d.inMinutes < 60) {
      return es
          ? 'Sincronizado hace ${d.inMinutes} min'
          : 'Synced ${d.inMinutes} min ago';
    }
    if (d.inHours < 24) {
      return es ? 'Sincronizado hace ${d.inHours} h' : 'Synced ${d.inHours} h ago';
    }
    final days = d.inDays;
    return es
        ? 'Sincronizado hace $days ${days == 1 ? 'día' : 'días'}'
        : 'Synced $days ${days == 1 ? 'day' : 'days'} ago';
  }

  String authError(FedeAuthError code) => switch (code) {
        FedeAuthError.network => es
            ? 'Sin conexión. Probá de nuevo cuando tengas internet.'
            : "No connection. Try again when you're online.",
        FedeAuthError.userDisabled =>
          es ? 'Esta cuenta está deshabilitada.' : 'This account is disabled.',
        FedeAuthError.configuration => es
            ? 'No se pudo iniciar sesión con Google en este dispositivo.'
            : "Couldn't sign in with Google on this device.",
        FedeAuthError.popupBlocked => es
            ? 'El navegador bloqueó la ventana de Google. Permitila y probá de nuevo.'
            : 'The browser blocked the Google window. Allow pop-ups and try again.',
        FedeAuthError.unknown => es
            ? 'No se pudo iniciar sesión. Probá de nuevo.'
            : "Couldn't sign in. Please try again.",
      };

  String get loginPromptTitle => es
      ? '☁️ Tu biblioteca vive solo en este dispositivo'
      : '☁️ Your library lives only on this device';
  String get loginPromptBody => es
      ? 'Guardala gratis para no perderla y tenerla en el celu y en la compu.'
      : "Save it for free so you don't lose it, and have it on your phone and computer.";
  String get whatWeSave => es ? '¿Qué guardamos?' : 'What do we save?';
  List<String> get whatWeSaveBullets => es
      ? const [
          'Solo tu biblioteca y tu configuración.',
          'Las apps siguen funcionando igual, también sin internet.',
          'Lo que ya tenés se suma a tu cuenta: no se borra nada.',
          'Podés borrar tu cuenta y tus datos desde Mi cuenta en la web.',
        ]
      : const [
          'Only your library and your settings.',
          'The apps keep working the same, also offline.',
          'What you already have is added to your account: nothing gets deleted.',
          'You can delete your account and your data from My account on the website.',
        ];
}
