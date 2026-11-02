import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

const String kSiteUrl = 'https://federicorandazzo.com.ar';

/// Las apps del ecosistema.
enum FedeApp {
  afinador(
    nameEs: 'Afinador',
    nameEn: 'Tuner',
    taglineEs: 'Afinador cromático preciso',
    taglineEn: 'Accurate chromatic tuner',
    playStoreId: 'com.saroo.afinador',
    webPath: '/afinador/',
    icon: Icons.graphic_eq,
  ),
  metronomo(
    nameEs: 'Metrónomo',
    nameEn: 'Metronome',
    taglineEs: 'Subdivisiones, polirritmia y playlists',
    taglineEn: 'Subdivisions, polyrhythms and playlists',
    playStoreId: 'com.Saroo.Metronomo',
    webPath: '/metronomo/',
    icon: Icons.av_timer,
  ),
  toneGenerator(
    nameEs: 'Tone Generator',
    nameEn: 'Tone Generator',
    taglineEs: 'Generador de tonos multicanal',
    taglineEn: 'Multichannel tone generator',
    playStoreId: 'com.saroo.tone_generator',
    webPath: '/tone-generator/',
    icon: Icons.waves,
  );

  const FedeApp({
    required this.nameEs,
    required this.nameEn,
    required this.taglineEs,
    required this.taglineEn,
    required this.playStoreId,
    required this.webPath,
    required this.icon,
  });

  final String nameEs;
  final String nameEn;
  final String taglineEs;
  final String taglineEn;
  final String playStoreId;
  final String webPath;
  final IconData icon;

  String name(bool es) => es ? nameEs : nameEn;
  String tagline(bool es) => es ? taglineEs : taglineEn;

  /// En Android: ficha de Play Store. En el resto (web, desktop): la versión web.
  Uri get uri {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return Uri.parse('https://play.google.com/store/apps/details?id=$playStoreId');
    }
    return Uri.parse('$kSiteUrl$webPath');
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
          FedeApp.toneGenerator => '¿Te está sirviendo el Tone Generator?',
        }
      : 'Enjoying the ${app.nameEn}?';
  String get appsPromptBody => es
      ? 'También hice estas apps, gratis:'
      : 'I also made these apps, for free:';
  String get visitSite => es ? 'Conocé la web' : 'Visit the website';
  String get visitSiteSub => es
      ? 'Foro, docencia, música y más'
      : 'Forum, lessons, music and more';
  String get notNow => es ? 'Ahora no' : 'Not now';
  String get dontShowAgain => es ? 'No volver a mostrar' : "Don't show again";
  String get moreApps => es ? 'Más apps' : 'More apps';
}
