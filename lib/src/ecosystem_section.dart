import 'package:flutter/material.dart';

import 'ecosystem_apps.dart';

/// Fila de una app, con el mismo espíritu que la lista de /apps del sitio:
/// ícono real + nombre (+ "Beta") + tagline.
class EcosystemAppTile extends StatelessWidget {
  const EcosystemAppTile({
    super.key,
    required this.app,
    this.onTap,
    this.trailingColor,
    this.trailingSize = 18,
    this.contentPadding,
  });

  final FedeApp app;

  /// Si es null, abre [FedeApp.uri].
  final VoidCallback? onTap;
  final Color? trailingColor;
  final double trailingSize;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final s = FacStrings.of(context);
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: contentPadding,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image(image: app.iconImage, width: 40, height: 40),
      ),
      title: Row(
        children: [
          Flexible(child: Text(app.name(s.es), overflow: TextOverflow.ellipsis)),
          if (app.beta) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                s.beta,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(app.tagline(s.es)),
      trailing:
          Icon(Icons.open_in_new, size: trailingSize, color: trailingColor),
      onTap: onTap ?? () => openExternal(app.uri(es: s.es)),
    );
  }
}

/// Sección fija para la pantalla de Ajustes: las otras apps + "Ver todas en la web".
/// Siempre visible, sin límites: es el lugar donde el usuario curioso lo encuentra solo.
///
/// Para encajar en el estilo de cada app: [showHeader] `false` + el encabezado propio
/// (con `FacStrings.of(context).moreApps`), y [iconColor], [trailingColor],
/// [contentPadding] para igualar los ListTile existentes.
class EcosystemSection extends StatelessWidget {
  const EcosystemSection({
    super.key,
    required this.currentApp,
    this.showHeader = true,
    this.showSite = true,
    this.iconColor,
    this.trailingColor,
    this.trailingSize = 18,
    this.contentPadding,
  });

  final FedeApp currentApp;
  final bool showHeader;

  /// Fila final "Ver todas en la web" (→ /apps).
  final bool showSite;

  /// Color del ícono de la fila "Ver todas en la web" (las apps usan su ícono real).
  final Color? iconColor;
  final Color? trailingColor;
  final double trailingSize;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final s = FacStrings.of(context);
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              s.moreApps,
              style: theme.textTheme.titleSmall
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
          ),
        for (final app in currentApp.others)
          EcosystemAppTile(
            app: app,
            trailingColor: trailingColor,
            trailingSize: trailingSize,
            contentPadding: contentPadding,
          ),
        if (showSite)
          ListTile(
            contentPadding: contentPadding,
            leading: SizedBox(
              width: 40,
              child: Icon(Icons.apps, color: iconColor),
            ),
            title: Text(s.allApps),
            subtitle: Text(s.allAppsSub),
            trailing: Icon(Icons.open_in_new,
                size: trailingSize, color: trailingColor),
            onTap: () => openExternal(appsPageUri(es: s.es)),
          ),
      ],
    );
  }
}
