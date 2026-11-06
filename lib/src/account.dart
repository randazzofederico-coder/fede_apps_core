import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Usuario con sesión iniciada (con Google; nunca anónimo).
@immutable
class FedeUser {
  const FedeUser({
    required this.uid,
    this.email,
    this.displayName,
    this.photoUrl,
  });

  final String uid;
  final String? email;
  final String? displayName;
  final String? photoUrl;

  /// Nombre para mostrar: el de la cuenta o, si no hay, el email.
  String get label => (displayName?.trim().isNotEmpty ?? false)
      ? displayName!.trim()
      : (email ?? '');

  @override
  bool operator ==(Object other) =>
      other is FedeUser &&
      other.uid == uid &&
      other.email == email &&
      other.displayName == displayName &&
      other.photoUrl == photoUrl;

  @override
  int get hashCode => Object.hash(uid, email, displayName, photoUrl);

  @override
  String toString() => 'FedeUser($uid, $email)';
}

/// Motivo de un error de login (para elegir el mensaje).
enum FedeAuthError {
  /// Sin conexión.
  network,

  /// La cuenta está deshabilitada.
  userDisabled,

  /// Falta configuración (SHA-1 en Firebase, cliente OAuth, dominio autorizado...).
  configuration,

  /// El navegador bloqueó la ventana de Google.
  popupBlocked,

  /// Cualquier otro.
  unknown,
}

/// Error de [FedeAccount.signInWithGoogle]. Cancelar **no** es un error
/// (devuelve `null`).
class FedeAuthException implements Exception {
  const FedeAuthException(this.code, [this.detail]);

  final FedeAuthError code;

  /// Detalle técnico (para logs).
  final String? detail;

  @override
  String toString() => 'FedeAuthException($code${detail == null ? '' : ': $detail'})';
}

/// Lo que [FedeAccount] necesita de la autenticación. La implementación real es
/// [FirebaseAccountBackend]; los tests usan una falsa.
abstract class AccountBackend {
  FedeUser? get currentUser;

  /// Emite cada vez que cambia el usuario (null = sin sesión o anónimo).
  Stream<FedeUser?> userChanges();

  /// `null` si el usuario cancela. Lanza [FedeAuthException].
  Future<FedeUser?> signInWithGoogle();

  Future<void> signOut();
}

/// Cuenta del ecosistema (la misma en todas las apps y en la web).
///
/// Las apps siguen funcionando igual sin cuenta. La sesión anónima que usan
/// los links compartidos se trata como "sin sesión".
class FedeAccount {
  FedeAccount._();
  static final FedeAccount instance = FedeAccount._();

  final ValueNotifier<FedeUser?> _user = ValueNotifier(null);
  AccountBackend? _backend;
  StreamSubscription<FedeUser?>? _sub;
  Completer<void> _ready = Completer<void>();

  /// Se completa cuando Firebase ya restauró (o no) la sesión guardada: primer
  /// evento de sesión, o a los [readyTimeout] como máximo. En web la sesión se
  /// restaura de forma asíncrona, así que antes de esto [currentUser] puede ser
  /// null aunque haya sesión.
  Future<void> get ready {
    init();
    return _ready.future;
  }

  bool get isReady {
    init();
    return _ready.isCompleted;
  }

  static const readyTimeout = Duration(seconds: 3);

  void _markReady() {
    _readyTimer?.cancel();
    _readyTimer = null;
    if (!_ready.isCompleted) _ready.complete();
  }

  Timer? _readyTimer;

  /// Usuario con sesión iniciada (null = sin sesión o sesión anónima).
  ValueListenable<FedeUser?> get user {
    init();
    return _user;
  }

  FedeUser? get currentUser => user.value;
  bool get isSignedIn => user.value != null;

  /// Empieza a escuchar la sesión. Idempotente; se llama solo al usar la cuenta.
  /// Requiere `Firebase.initializeApp` antes.
  void init() {
    if (_sub != null) return;
    try {
      final b = _backend ??= FirebaseAccountBackend();
      _user.value = b.currentUser;
      _sub = b.userChanges().listen((u) {
        _user.value = u;
        _markReady();
      });
      if (!_ready.isCompleted) _readyTimer ??= Timer(readyTimeout, _markReady);
    } catch (e) {
      debugPrint('FedeAccount: sin Firebase ($e)');
      _markReady();
    }
  }

  /// Login con Google. `null` si el usuario cancela. Lanza [FedeAuthException].
  Future<FedeUser?> signInWithGoogle() async {
    init();
    final b = _backend;
    if (b == null) throw const FedeAuthException(FedeAuthError.configuration);
    final u = await b.signInWithGoogle();
    if (u != null) _user.value = u;
    return u;
  }

  /// Cierra la sesión (Firebase y Google). No borra nada local.
  Future<void> signOut() async {
    init();
    await _backend?.signOut();
    _user.value = null;
  }

  /// Para tests: usa otro backend.
  @visibleForTesting
  void debugSetBackend(AccountBackend? backend) {
    _sub?.cancel();
    _sub = null;
    _backend = backend;
    _user.value = null;
    _ready = Completer<void>();
    _readyTimer?.cancel();
    _readyTimer = null;
    if (backend != null) {
      // En tests el backend ya está listo: sin espera.
      _markReady();
      init();
    }
  }
}

/// Nombre para el perfil `users/{uid}`: el de Google o, si no hay, la parte
/// local del email; recortado a 2..60 caracteres (lo exigen las reglas).
String profileDisplayName(String? displayName, String email) {
  var name = (displayName ?? '').trim();
  if (name.length < 2) name = email.split('@').first.trim();
  if (name.length < 2) name = name.padRight(2, '_');
  if (name.length > 60) name = name.substring(0, 60);
  return name;
}

/// Implementación real: Firebase Auth + Google Sign-In (Android) / popup (web).
class FirebaseAccountBackend implements AccountBackend {
  FirebaseAccountBackend({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    GoogleSignIn? googleSignIn,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestoreOverride = firestore,
        _googleOverride = googleSignIn;

  final FirebaseAuth _auth;
  final FirebaseFirestore? _firestoreOverride;
  final GoogleSignIn? _googleOverride;
  GoogleSignIn? _google;

  FirebaseFirestore get _firestore =>
      _firestoreOverride ?? FirebaseFirestore.instance;
  GoogleSignIn get _googleSignIn =>
      _google ??= _googleOverride ?? GoogleSignIn(scopes: const ['email']);

  final _controller = StreamController<FedeUser?>.broadcast();
  StreamSubscription<User?>? _authSub;
  bool _signingIn = false;

  static FedeUser? _map(User? u) {
    if (u == null || u.isAnonymous) return null;
    String? fromProvider(String? Function(UserInfo) f) {
      for (final p in u.providerData) {
        final v = f(p);
        if (v != null && v.isNotEmpty) return v;
      }
      return null;
    }

    return FedeUser(
      uid: u.uid,
      email: u.email ?? fromProvider((p) => p.email),
      displayName: (u.displayName?.isNotEmpty ?? false)
          ? u.displayName
          : fromProvider((p) => p.displayName),
      photoUrl: u.photoURL ?? fromProvider((p) => p.photoURL),
    );
  }

  @override
  FedeUser? get currentUser => _map(_auth.currentUser);

  @override
  Stream<FedeUser?> userChanges() {
    // userChanges (no solo authStateChanges): también avisa cuando la sesión
    // anónima se vincula con Google (mismo uid).
    _authSub ??= _auth.userChanges().listen((u) {
      if (!_signingIn) _controller.add(_map(u));
    });
    return _controller.stream;
  }

  @override
  Future<FedeUser?> signInWithGoogle() async {
    _signingIn = true;
    try {
      final ok = kIsWeb ? await _signInWeb() : await _signInNative();
      if (!ok) return null;
      final user = _auth.currentUser;
      if (user == null) return null;
      try {
        // Token nuevo con email y email_verified (lo exigen las reglas).
        await user.getIdToken(true);
      } catch (_) {}
      unawaited(_ensureProfile(user));
      return _map(_auth.currentUser);
    } on FirebaseAuthException catch (e) {
      if (const {'popup-closed-by-user', 'cancelled-popup-request', 'web-context-cancelled'}
          .contains(e.code)) {
        return null;
      }
      throw FedeAuthException(_mapAuthCode(e.code), '${e.code}: ${e.message}');
    } on PlatformException catch (e) {
      final msg = '${e.code} ${e.message}';
      if (e.code == GoogleSignIn.kSignInCanceledError || msg.contains('12501')) {
        return null;
      }
      if (e.code == GoogleSignIn.kNetworkError || msg.contains('ApiException: 7')) {
        throw FedeAuthException(FedeAuthError.network, msg);
      }
      if (msg.contains('ApiException: 10') || msg.contains('ApiException: 12500')) {
        throw FedeAuthException(FedeAuthError.configuration, msg);
      }
      throw FedeAuthException(FedeAuthError.unknown, msg);
    } on FedeAuthException {
      rethrow;
    } catch (e) {
      final s = e.toString().toLowerCase();
      if (s.contains('network') || s.contains('socket') || s.contains('host lookup')) {
        throw FedeAuthException(FedeAuthError.network, '$e');
      }
      throw FedeAuthException(FedeAuthError.unknown, '$e');
    } finally {
      _signingIn = false;
      _controller.add(_map(_auth.currentUser));
    }
  }

  Future<bool> _signInWeb() async {
    final provider = GoogleAuthProvider()..addScope('email');
    final current = _auth.currentUser;
    if (current != null && current.isAnonymous) {
      try {
        await current.linkWithPopup(provider);
      } on FirebaseAuthException catch (e) {
        if (!_alreadyInUse(e.code)) rethrow;
        final cred = e.credential;
        if (cred != null) {
          await _auth.signInWithCredential(cred);
        } else {
          await _auth.signInWithPopup(provider);
        }
      }
    } else {
      await _auth.signInWithPopup(provider);
    }
    return true;
  }

  Future<bool> _signInNative() async {
    final account = await _googleSignIn.signIn();
    if (account == null) return false; // canceló
    final tokens = await account.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: tokens.accessToken,
      idToken: tokens.idToken,
    );
    final current = _auth.currentUser;
    if (current != null && current.isAnonymous) {
      try {
        await current.linkWithCredential(credential);
      } on FirebaseAuthException catch (e) {
        if (!_alreadyInUse(e.code)) rethrow;
        // La cuenta de Google ya existe: se entra a esa (la sesión anónima se descarta).
        await _auth.signInWithCredential(e.credential ?? credential);
      }
    } else {
      await _auth.signInWithCredential(credential);
    }
    return true;
  }

  static bool _alreadyInUse(String code) =>
      code == 'credential-already-in-use' || code == 'email-already-in-use';

  static FedeAuthError _mapAuthCode(String code) => switch (code) {
        'network-request-failed' => FedeAuthError.network,
        'user-disabled' => FedeAuthError.userDisabled,
        'popup-blocked' => FedeAuthError.popupBlocked,
        'operation-not-allowed' ||
        'unauthorized-domain' ||
        'invalid-api-key' ||
        'app-not-authorized' =>
          FedeAuthError.configuration,
        _ => FedeAuthError.unknown,
      };

  /// Crea `users/{uid}` con el mismo formato que el sitio, si falta.
  /// Nunca lanza: un error acá no impide el login.
  Future<void> _ensureProfile(User user) async {
    try {
      final mapped = _map(user);
      final email = mapped?.email;
      if (mapped == null || email == null) return;
      final ref = _firestore.collection('users').doc(user.uid);
      final snap = await ref.get();
      if (snap.exists) return;
      await ref.set({
        'displayName': profileDisplayName(mapped.displayName, email),
        'email': email,
        'role': 'user',
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('FedeAccount: no se pudo crear el perfil ($e)');
    }
  }

  @override
  Future<void> signOut() async {
    await _auth.signOut();
    if (!kIsWeb) {
      try {
        await _googleSignIn.signOut();
      } catch (_) {}
    }
  }
}
