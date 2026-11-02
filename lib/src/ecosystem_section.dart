import 'package:flutter/material.dart';

import 'ecosystem_apps.dart';

/// Sección fija para la pantalla de Ajustes: "Más apps" + la web.
/// Siempre visible, sin límites: es el lugar donde el usuario curioso lo encuentra solo.
class EcosystemSection extends StatelessWidget {
  const EcosystemSection({
    super.key,
    required this.currentApp,
    this.showHeader = true,
    this.showSite = true,
  });

  final FedeApp currentApp;
  final bool showHeader;
  final bool showSite;

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
          ListTile(
            leading: Icon(app.icon),
            title: Text(app.name(s.es)),
            subtitle: Text(app.tagline(s.es)),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => openExternal(app.uri),
          ),
        if (showSite)
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(s.visitSite),
            subtitle: Text(s.visitSiteSub),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => openExternal(Uri.parse(kSiteUrl)),
          ),
      ],
    );
  }
}
