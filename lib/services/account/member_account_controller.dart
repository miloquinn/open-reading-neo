import 'package:flutter/foundation.dart';

import 'account_api_client.dart';
import 'account_models.dart';

class MemberAccountController extends ChangeNotifier {
  MemberAccountController({MemberAccountApiClient? api})
    : _api = api ?? MemberAccountApiClient();

  final MemberAccountApiClient _api;

  bool _initialized = false;
  bool _loading = false;
  MemberUser? _user;
  MemberSession? _pendingSession;
  MemberAuthConfig? _authConfig;
  MemberMembershipConfig? _membershipConfig;
  MemberMembership? _membership;
  MemberMfaStatus? _mfaStatus;
  String? _error;

  bool get initialized => _initialized;
  bool get loading => _loading;
  bool get isAuthenticated => _user != null;
  bool get mfaRequired => _pendingSession?.mfaRequired == true;
  MemberUser? get user => _user;
  MemberUser? get pendingUser => _pendingSession?.user;
  MemberAuthConfig? get authConfig => _authConfig;
  MemberAuthProviders get providers =>
      _authConfig?.providers ?? const MemberAuthProviders();
  MemberMembershipConfig? get membershipConfig => _membershipConfig;
  MemberMembership? get membership => _membership;
  MemberMfaStatus? get mfaStatus => _mfaStatus;
  String? get error => _error;

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  Future<void> initialize() async {
    if (_initialized || _loading) return;
    await _run(() async {
      final configs = await Future.wait<Object?>([
        _api.authConfig(),
        _api.membershipConfig(),
      ]);
      _authConfig = configs[0] as MemberAuthConfig;
      _membershipConfig = configs[1] as MemberMembershipConfig;
      try {
        final session = await _api.restoreSession();
        _acceptSession(session);
        if (!session.mfaRequired) await _loadMembershipValue();
      } on MemberAccountException catch (error) {
        if (error.statusCode != 401) rethrow;
        _user = null;
        _pendingSession = null;
        _membership = null;
        _mfaStatus = null;
      }
    }, markInitialized: true);
  }

  Future<void> loginPassword(String email, String password) =>
      _authenticate(() => _api.loginPassword(email, password));

  Future<MemberEmailChallenge> requestCode(
    String email,
    MemberEmailCodePurpose purpose,
  ) => _runValue(() => _api.requestCode(email, purpose));

  Future<void> verifyEmailCode({
    required String email,
    required String challengeId,
    required String code,
  }) => _authenticate(
    () => _api.verifyEmailCode(
      email: email,
      challengeId: challengeId,
      code: code,
    ),
  );

  Future<void> registerPassword({
    required String email,
    required String challengeId,
    required String code,
    required String username,
    required String password,
    String? displayName,
  }) => _authenticate(
    () => _api.registerPassword(
      email: email,
      challengeId: challengeId,
      code: code,
      username: username,
      displayName: displayName,
      password: password,
    ),
  );

  Future<void> resetPassword({
    required String email,
    required String challengeId,
    required String code,
    required String password,
  }) => _authenticate(
    () => _api.resetPassword(
      email: email,
      challengeId: challengeId,
      code: code,
      password: password,
    ),
  );

  Future<MemberEmailChangeChallenge> requestEmailChangeCode(String newEmail) =>
      _runValue(() => _api.requestEmailChangeCode(newEmail));

  Future<void> changeEmail({
    required String newEmail,
    required String currentChallengeId,
    required String currentCode,
    required String newChallengeId,
    required String newCode,
  }) => _run(() async {
    final session = await _api.changeEmail(
      newEmail: newEmail,
      currentChallengeId: currentChallengeId,
      currentCode: currentCode,
      newChallengeId: newChallengeId,
      newCode: newCode,
    );
    _acceptAuthenticatedSession(session);
  });

  Future<MemberEmailChallenge> requestPasswordChangeCode() =>
      _runValue(_api.requestPasswordChangeCode);

  Future<void> changePassword({
    required String challengeId,
    required String code,
    required String password,
  }) => _run(() async {
    final session = await _api.changePassword(
      challengeId: challengeId,
      code: code,
      password: password,
    );
    _acceptAuthenticatedSession(session);
  });

  Future<void> loadMfaStatus() => _run(() async {
    _mfaStatus = await _api.mfaStatus();
  });

  Future<MemberEmailChallenge> requestMfaSetupCode() =>
      _runValue(_api.requestMfaSetupCode);

  Future<MemberMfaSetup> setupMfa({
    required String challengeId,
    required String code,
  }) => _runValue(() => _api.setupMfa(challengeId: challengeId, code: code));

  Future<MemberMfaConfirmation> confirmMfa(String code) async {
    final confirmation = await _runValue(() => _api.confirmMfa(code));
    _mfaStatus = MemberMfaStatus(
      enabled: confirmation.enabled,
      recoveryCodesRemaining: confirmation.recoveryCodes.length,
    );
    notifyListeners();
    return confirmation;
  }

  Future<void> disableMfa(String code) => _run(() async {
    await _api.disableMfa(code);
    _mfaStatus = const MemberMfaStatus(enabled: false);
  });

  Future<void> verifyMfa(String code) => _run(() async {
    final pending = _pendingSession;
    if (pending == null || !pending.mfaRequired) {
      throw const MemberAccountException('没有待验证的双重验证登录');
    }
    final session = await _api.verifyMfa(
      code: code,
      pendingAccessToken: pending.accessToken,
    );
    _acceptAuthenticatedSession(session);
    await _loadMembershipValue();
  });

  Future<DeviceAuthorization> beginExternalLogin(
    MemberExternalAuthMethod method,
  ) => _runValue(() => _api.beginExternalLogin(method));

  Future<bool> pollDeviceAuthorization(
    DeviceAuthorization authorization,
  ) async {
    var completed = false;
    await _run(() async {
      final session = await _api.pollDeviceAuthorization(authorization);
      if (session == null) return;
      _acceptSession(session);
      if (!session.mfaRequired) await _loadMembershipValue();
      completed = true;
    });
    return completed;
  }

  Future<void> updateProfile({required String username, String? displayName}) =>
      _run(() async {
        _user = await _api.updateProfile(
          username: username,
          displayName: displayName,
        );
      });

  Future<void> uploadAvatar(String path) => _run(() async {
    _user = await _api.uploadAvatar(path);
  });

  Future<void> deleteAvatar() => _run(() async {
    await _api.deleteAvatar();
    _user = await _api.currentUser();
  });

  Future<void> loadMembership() => _run(_loadMembershipValue);

  Future<void> redeemMembership(String code) => _run(() async {
    _membership = await _api.redeemMembership(code);
  });

  Future<void> logout() => _run(() async {
    try {
      await _api.logout();
    } finally {
      _user = null;
      _pendingSession = null;
      _membership = null;
      _mfaStatus = null;
    }
  });

  Future<void> _authenticate(Future<MemberSession> Function() action) =>
      _run(() async {
        final session = await action();
        _acceptSession(session);
        if (!session.mfaRequired) await _loadMembershipValue();
      });

  void _acceptSession(MemberSession session) {
    if (session.mfaRequired) {
      _pendingSession = session;
      _user = null;
      _membership = null;
      _mfaStatus = null;
      return;
    }
    _acceptAuthenticatedSession(session);
  }

  void _acceptAuthenticatedSession(MemberSession session) {
    _pendingSession = null;
    _user = session.user;
  }

  Future<void> _loadMembershipValue() async {
    _membership = await _api.membership();
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool markInitialized = false,
  }) async {
    if (_loading) {
      throw const MemberAccountException('账号操作正在进行，请稍候');
    }
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await action();
    } on MemberAccountException catch (error) {
      _error = error.message;
      rethrow;
    } catch (_) {
      const error = MemberAccountException('账号操作失败，请稍后再试');
      _error = error.message;
      throw error;
    } finally {
      if (markInitialized) _initialized = true;
      _loading = false;
      notifyListeners();
    }
  }

  Future<T> _runValue<T>(Future<T> Function() action) async {
    T? value;
    await _run(() async {
      value = await action();
    });
    return value as T;
  }
}
