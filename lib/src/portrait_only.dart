import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'ecosystem_apps.dart';
import 'orientation_stub.dart'
    if (dart.library.js_interop) 'orientation_web.dart';

/// Mantiene la app en vertical en la **web** de los teléfonos.
///
/// En Android/iOS nativo se usa `SystemChrome.setPreferredOrientations`, pero
/// en la web un navegador no deja bloquear la rotación (salvo PWA instalada).
/// Este widget, puesto en el `builder` del `MaterialApp`:
/// * intenta el bloqueo real (`screen.orientation.lock`, cuando se puede);
/// * si el teléfono queda apaisado, tapa la app con un aviso "Girá el teléfono"
///   y **sigue dibujándola con el último tamaño vertical**, así la interfaz
///   nunca se reacomoda en apaisado y al volver queda exactamente igual.
///
/// No afecta tablets ni computadoras (lado corto ≥ [phoneMaxShortestSide]),
/// ni las apps nativas.
class PortraitOnly extends StatefulWidget {
  const PortraitOnly({
    super.key,
    required this.child,
    this.enabled = kIsWeb,
    this.backgroundColor,
    this.foregroundColor,
  });

  final Widget child;

  /// Por defecto solo en la web.
  final bool enabled;
  final Color? backgroundColor;
  final Color? foregroundColor;

  /// Un viewport con el lado corto menor a esto se considera teléfono.
  static const double phoneMaxShortestSide = 600;

  /// Para tests: fuerza la orientación del dispositivo.
  @visibleForTesting
  static bool? Function() debugDeviceIsLandscape = deviceIsLandscape;

  @override
  State<PortraitOnly> createState() => _PortraitOnlyState();
}

class _PortraitOnlyState extends State<PortraitOnly> {
  MediaQueryData? _lastPortrait;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) tryLockPortrait();
  }

  bool _isPhoneLandscape(MediaQueryData mq) {
    final size = mq.size;
    if (size.shortestSide >= PortraitOnly.phoneMaxShortestSide) return false;
    final device = PortraitOnly.debugDeviceIsLandscape();
    // Si el navegador informa la orientación, manda esa (el teclado en
    // vertical puede dejar la ventana más ancha que alta). Si no, el tamaño.
    return device ?? (size.width > size.height);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final mq = MediaQuery.of(context);
    if (!_isPhoneLandscape(mq)) {
      // Solo se recuerda un vertical "limpio" (sin teclado), para volver a él.
      if (mq.viewInsets.bottom == 0 && mq.size.height > mq.size.width) {
        _lastPortrait = mq;
      }
      return widget.child;
    }

    final portrait = _lastPortrait ??
        mq.copyWith(size: Size(mq.size.height, mq.size.width));
    final theme = Theme.of(context);
    final bg = widget.backgroundColor ?? theme.scaffoldBackgroundColor;
    final fg = widget.foregroundColor ?? theme.colorScheme.onSurface;
    final s = FacStrings.of(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        // La app sigue montada y con su tamaño vertical (no se reacomoda).
        ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minWidth: portrait.size.width,
            maxWidth: portrait.size.width,
            minHeight: portrait.size.height,
            maxHeight: portrait.size.height,
            child: MediaQuery(data: portrait, child: widget.child),
          ),
        ),
        // Aviso encima (absorbe toques).
        Positioned.fill(
          child: AbsorbPointer(
            child: ColoredBox(
              color: bg,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.screen_rotation, size: 48, color: fg),
                      const SizedBox(height: 16),
                      Text(
                        s.rotateTitle,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(color: fg),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        s.rotateBody,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: fg.withValues(alpha: 0.7)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
