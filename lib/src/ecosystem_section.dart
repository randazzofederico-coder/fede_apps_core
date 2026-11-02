import 'package:flutter/material.dart';

import 'ecosystem_apps.dart';

/// Sección fija para la pantalla de Ajustes: "Más apps" + la web.
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
  final bool showSite;
  final Color? iconColor;
  final Color? trailingColor;
  final double trailingSize;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final s = FacStrings.of(context);
    final theme = Theme.of(context);

    Widget tile(IconData icon, String title, String subtitle, Uri uri) =>
        ListTile(
          contentPadding: contentPadding,
          leading: Icon(icon, color: iconColor),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: Icon(Icons.open_in_new,
              size: trailingSize, color: trailingColor),
          onTap: () => openExternal(uri),
        );

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
          tile(app.icon, app.name(s.es), app.tagline(s.es), app.uri),
        if (showSite)
          tile(Icons.language, s.visitSite, s.visitSiteSub,
              Uri.parse(kSiteUrl)),
      ],
    );
  }
}
