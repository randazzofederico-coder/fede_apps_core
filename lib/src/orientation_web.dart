import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Orientación real del dispositivo según `screen.orientation.type`.
/// A diferencia del tamaño de la ventana, no cambia cuando aparece el teclado
/// (que en vertical puede dejar la ventana más ancha que alta).
/// `null` si el navegador no lo soporta (Safari viejo).
bool? deviceIsLandscape() {
  try {
    final type = web.window.screen.orientation.type;
    if (type.isEmpty) return null;
    return type.startsWith('landscape');
  } catch (_) {
    return null;
  }
}

/// Intenta bloquear la orientación en vertical. Solo funciona en algunos
/// contextos (PWA instalada en Android, pantalla completa); en el resto el
/// navegador lo rechaza y no pasa nada.
void tryLockPortrait() {
  try {
    web.window.screen.orientation
        .lock('portrait')
        .toDart
        .then((_) {}, onError: (Object _) {});
  } catch (_) {}
}
