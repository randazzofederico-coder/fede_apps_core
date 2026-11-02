import 'dart:async';

import 'package:flutter/material.dart';

import 'account.dart';
import 'ecosystem_apps.dart';
import 'library_sync.dart';

/// Login con Google mostrando un SnackBar si falla. `null` si canceló o falló.
Future<FedeUser?> signInWithGoogleOrSnack(BuildContext context) async {
  final s = FacStrings.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    return await FedeAccount.instance.signInWithGoogle();
  } on FedeAuthException catch (e) {
    debugPrint('FedeAccount: $e');
    messenger?.showSnackBar(SnackBar(content: Text(s.authError(e.code))));
    return null;
  }
}

/// Sección "Cuenta" para la pantalla de Ajustes.
///
/// * Sin sesión: "Guardá tu biblioteca" + "Continuar con Google"
///   (con [hasLibrary] `false`: "Tu cuenta del ecosistema").
/// * Con sesión: nombre/email, estado de la sincronización, "Sincronizar ahora"
///   (solo con biblioteca) y "Cerrar sesión" (con confirmación).
///
/// Estilo: igual que [EcosystemSection] ([showHeader], [iconColor], [contentPadding]); el botón usa [buttonColor] o el tema.
class AccountSection extends StatefulWidget {
  const AccountSection({
    super.key,
    this.hasLibrary = true,
    this.showHeader = true,
    this.iconColor,
    this.buttonColor,
    this.contentPadding,
    this.sync,
  });

  /// `false` en apps sin biblioteca (Afinador): solo identidad del ecosistema.
  final bool hasLibrary;
  final bool showHeader;
  final Color? iconColor;
  final Color? buttonColor;
  final EdgeInsetsGeometry? contentPadding;

  /// Por defecto [LibrarySync.instance].
  final LibrarySync? sync;

  @override
  State<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<AccountSection> {
  bool _busy = false;
  Timer? _tick;

  LibrarySync get _sync => widget.sync ?? LibrarySync.instance;

  @override
  void initState() {
    super.initState();
    // Refresca "Sincronizado hace X".
    if (widget.hasLibrary) {
      _tick = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() => _busy = true);
    await signInWithGoogleOrSnack(context);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _signOut() async {
    final s = FacStrings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.signOutConfirmTitle),
        content: Text(s.signOutConfirmBody(hasLibrary: widget.hasLibrary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.signOut),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await FedeAccount.instance.signOut();
    } catch (e) {
      debugPrint('FedeAccount: $e');
    }
  }

  String _statusLine(FacStrings s, SyncStatus st) => switch (st.state) {
        SyncState.syncing => s.syncing,
        SyncState.offline => s.syncOffline,
        SyncState.error => s.syncError,
        SyncState.idle || SyncState.disabled => st.lastSyncedAt == null
            ? s.syncPending
            : s.syncedAgo(st.lastSyncedAt!, _sync.clock()),
      };

  @override
  Widget build(BuildContext context) {
    final s = FacStrings.of(context);
    final theme = Theme.of(context);
    return ValueListenableBuilder<FedeUser?>(
      valueListenable: FedeAccount.instance.user,
      builder: (context, user, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showHeader)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                s.account,
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: theme.colorScheme.primary),
              ),
            ),
          if (user == null) ..._signedOut(s) else ..._signedIn(s, user),
        ],
      ),
    );
  }

  List<Widget> _signedOut(FacStrings s) => [
        ListTile(
          contentPadding: widget.contentPadding,
          leading: SizedBox(
            width: 40,
            child: Icon(
              widget.hasLibrary ? Icons.cloud_upload_outlined : Icons.account_circle_outlined,
              color: widget.iconColor,
            ),
          ),
          title: Text(widget.hasLibrary ? s.saveLibraryTitle : s.ecosystemAccountTitle),
          subtitle: Text(widget.hasLibrary ? s.saveLibrarySub : s.ecosystemAccountSub),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.icon(
              style: widget.buttonColor == null
                  ? null
                  : FilledButton.styleFrom(backgroundColor: widget.buttonColor),
              onPressed: _busy ? null : _signIn,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login),
              label: Text(s.continueWithGoogle),
            ),
          ),
        ),
      ];

  List<Widget> _signedIn(FacStrings s, FedeUser user) {
    final photo = user.photoUrl;
    final initial = user.label.isEmpty ? '?' : user.label.characters.first.toUpperCase();
    final avatar = CircleAvatar(
      radius: 20,
      foregroundImage: photo == null ? null : NetworkImage(photo),
      onForegroundImageError: photo == null ? null : (_, _) {},
      child: Text(initial),
    );
    final hasEmailLine = user.email != null && user.email != user.label;

    return [
      if (widget.hasLibrary)
        ValueListenableBuilder<SyncStatus>(
          valueListenable: _sync.status,
          builder: (context, st, _) => ListTile(
            contentPadding: widget.contentPadding,
            leading: avatar,
            title: Text(user.label, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [if (hasEmailLine) user.email!, _statusLine(s, st)].join('\n'),
            ),
            isThreeLine: hasEmailLine,
          ),
        )
      else
        ListTile(
          contentPadding: widget.contentPadding,
          leading: avatar,
          title: Text(user.label, overflow: TextOverflow.ellipsis),
          subtitle: hasEmailLine ? Text(user.email!) : null,
        ),
      if (widget.hasLibrary)
        ValueListenableBuilder<SyncStatus>(
          valueListenable: _sync.status,
          builder: (context, st, _) => ListTile(
            contentPadding: widget.contentPadding,
            leading: SizedBox(
              width: 40,
              child: Icon(Icons.sync, color: widget.iconColor),
            ),
            title: Text(s.syncNow),
            enabled: st.state != SyncState.syncing,
            onTap: () => _sync.syncNow(force: true),
          ),
        ),
      ListTile(
        contentPadding: widget.contentPadding,
        leading: SizedBox(
          width: 40,
          child: Icon(Icons.logout, color: widget.iconColor),
        ),
        title: Text(s.signOut),
        onTap: _signOut,
      ),
    ];
  }
}
