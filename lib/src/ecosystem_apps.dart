import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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
}
