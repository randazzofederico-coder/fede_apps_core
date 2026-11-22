import 'package:web/web.dart' as web;

/// Envía un hit anónimo a GoatCounter en Flutter Web usando `sendBeacon` o `Image`
/// sin bloquear ni propagar errores.
Future<void> sendGoatCounterHit(Uri uri) async {
  try {
    final url = uri.toString();
    final sent = web.window.navigator.sendBeacon(url);
    if (!sent) {
      web.HTMLImageElement().src = url;
    }
  } catch (_) {
    // No afectar la experiencia de la app por telemetría.
  }
}
