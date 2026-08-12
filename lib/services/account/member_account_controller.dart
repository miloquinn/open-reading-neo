import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'account_auth_callback_bridge.dart';
import 'account_api_client.dart';
import 'account_avatar_cache.dart';
import 'account_models.dart';
import 'account_summary_cache.dart';
import 'account_token_store.dart';
import 'apple_purchase_service.dart';
import 'avatar_image_processor.dart';

class MemberAccountController extends ChangeNotifier {
  MemberAccountController({
    MemberAccountApiClient? api,
    AccountAvatarCache? avatarCache,
    MemberAccountSummaryCache? summaryCache,
    PendingDeviceAuthorizationStore? pendingAuthorizationStore,
    AccountAuthCallbackBridge? authCallbackBridge,
  }) : _api = api ?? MemberAccountApiClient(),
       _avatarCache = avatarCache ?? AccountAvatarCache.instance,
       _summaryCache = summaryCache ?? const MemberAccountSummaryCache(),
       _pendingAuthorizationStore =
           pendingAuthorizationStore ?? SecurePendingDeviceAuthorizationStore(),
       _authCallbackBridge = authCallbackBridge ?? AccountAuthCallbackBridge() {
    _applePurchase = ApplePremiumPurchaseService(
      productId: appleProductId,
      verify: (purchase) => _api.submitApplePurchase(
        productId: purchase.productID,
        verificationData: purchase.verificationData.serverVerificationData,
      ),
      onMembership: (membership) {
        _membership = membership;
        _updateSummaryFromAccount();
        unawaited(_persistSummary());
        notifyListeners();
      },
    );
  }

  static const appleProductId = 'com.niki.xxread.premium.lifetime';

  final MemberAccountApiClient _api;
  final AccountAvatarCache _avatarCache;
  final MemberAccountSummaryCache _summaryCache;
  final PendingDeviceAuthorizationStore _pendingAuthorizationStore;
  final AccountAuthCallbackBridge _authCallbackBridge;
  late final ApplePremiumPurchaseService _applePurchase;

  bool _initialized = false;
  bool _loading = false;
  MemberUser? _user;
  MemberSession? _pendingSession;
  MemberAuthConfig? _authConfig;
  MemberMembershipConfig? _membershipConfig;
  MemberMembership? _membership;
  MemberAccountSummary? _summary;
  MemberReferral? _referral;
  MemberMfaStatus? _mfaStatus;
  String? _error;
  DeviceAuthorization? _pendingDeviceAuthorization;
  StreamSubscription<Uri>? _authCallbackSubscription;
  Completer<void>? _authCallbackSignal;
  Future<void>? _callbackCompletion;
  Future<bool>? _deviceAuthorizationPoll;
  String? _deviceAuthorizationPollCode;

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
  MemberAccountSummary? get summary => _summary;
  MemberReferral? get referral => _referral;
  MemberMfaStatus? get mfaStatus => _mfaStatus;
  String? get error => _error;
  ApplePremiumPurchaseService get applePurchase => _applePurchase;

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  Future<void> initialize() async {
    if (_initialized || _loading) return;
    try {
      await _run(() async {
        await _restorePendingDeviceAuthorization();
        unawaited(_initializeAuthCallbackBridge());
        _summary = await _summaryCache.load();
        if (_summary != null) notifyListeners();
        final configs = await Future.wait<Object?>([
          _api.authConfig(),
          _api.membershipConfig(),
        ]);
        _authConfig = configs[0] as MemberAuthConfig;
        _membershipConfig = configs[1] as MemberMembershipConfig;
        try {
          final session = await _api.restoreSession();
          _acceptSession(session);
          if (session.mfaRequired) {
            await _clearSummary();
          } else {
            await _loadAccountValues();
            await _persistSummary();
          }
        } on MemberAccountException catch (error) {
          if (error.statusCode != 401) rethrow;
          _user = null;
          _pendingSession = null;
          _membership = null;
          _mfaStatus = null;
          await _clearSummary();
        }
      });
      _initialized = true;
    } catch (_) {
      _user = null;
      _pendingSession = null;
      _membership = null;
      _mfaStatus = null;
      await _clearSummary();
      rethrow;
    }
  }

  Future<void> loginPassword(String email, String password) =>
      _authenticate(() => _api.loginPassword(email, password));

  Future<void> loginPasskey() => _run(() async {
    final begin = await _api.beginPasskeyLogin();
    final options = AuthenticateRequestType.fromJson(
      Map<String, dynamic>.from(begin['public_key'] as Map),
      preferImmediatelyAvailableCredentials: false,
    );
    final credential = await PasskeyAuthenticator().authenticate(options);
    final session = await _api.finishPasskeyLogin(
      challengeId: begin['challenge_id'] as String,
      credential: credential.toJson(),
    );
    _acceptAuthenticatedSession(session);
    await _loadAccountValues();
    await _persistSummary();
  });

  Future<void> loginWithApple() => _authenticate(() async {
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );
    final identityToken = credential.identityToken;
    if (identityToken == null || identityToken.isEmpty) {
      throw const MemberAccountException('Apple 未返回身份令牌');
    }
    final fullName = [credential.givenName, credential.familyName]
        .whereType<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .join(' ');
    return _api.loginApple(
      identityToken: identityToken,
      fullName: fullName.isEmpty ? null : fullName,
    );
  });

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
    await _persistSummary();
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
    await _persistSummary();
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
    await _loadAccountValues();
    await _persistSummary();
  });

  Future<DeviceAuthorization> beginExternalLogin(
    MemberExternalAuthMethod method,
  ) => _runValue(() async {
    await _initializeAuthCallbackBridge();
    final authorization = await _api.beginExternalLogin(method);
    _pendingDeviceAuthorization = authorization;
    _authCallbackSignal = Completer<void>();
    await _pendingAuthorizationStore.save(
      jsonEncode(_deviceAuthorizationJson(authorization)),
    );
    return authorization;
  });

  Future<void> _initializeAuthCallbackBridge() async {
    if (_authCallbackSubscription != null) return;
    try {
      _authCallbackSubscription = _authCallbackBridge.callbacks.listen(
        _handleAuthCallback,
      );
      await _authCallbackBridge.initialize();
    } catch (_) {
      await _authCallbackSubscription?.cancel();
      _authCallbackSubscription = null;
      // Polling remains the compatibility fallback on unsupported hosts.
    }
  }

  DeviceAuthorization? get pendingDeviceAuthorization =>
      _pendingDeviceAuthorization;

  Future<void> waitForAuthCallback(Duration timeout) async {
    final signal = _authCallbackSignal ??= Completer<void>();
    try {
      await signal.future.timeout(timeout);
    } on TimeoutException {
      // Normal polling remains the fallback when the browser cannot deep-link.
    }
  }

  Future<bool> pollDeviceAuthorization(
    DeviceAuthorization authorization,
  ) async {
    final activePoll = _deviceAuthorizationPoll;
    if (activePoll != null) {
      if (_deviceAuthorizationPollCode == authorization.deviceCode) {
        return activePoll;
      }
      return _pollDeviceAuthorization(authorization);
    }

    final poll = _pollDeviceAuthorization(authorization);
    _deviceAuthorizationPoll = poll;
    _deviceAuthorizationPollCode = authorization.deviceCode;
    try {
      return await poll;
    } finally {
      if (identical(_deviceAuthorizationPoll, poll)) {
        _deviceAuthorizationPoll = null;
        _deviceAuthorizationPollCode = null;
      }
    }
  }

  Future<bool> _pollDeviceAuthorization(
    DeviceAuthorization authorization,
  ) async {
    var completed = false;
    await _run(() async {
      final session = await _api.pollDeviceAuthorization(authorization);
      if (session == null) return;
      _acceptSession(session);
      if (session.mfaRequired) {
        await _clearSummary();
      } else {
        await _loadAccountValues();
        await _persistSummary();
      }
      completed = true;
      _pendingDeviceAuthorization = null;
      _authCallbackSignal = null;
      await _pendingAuthorizationStore.clear();
    });
    return completed;
  }

  void _handleAuthCallback(Uri uri) {
    if (uri.path != '/device' || uri.queryParameters['status'] != 'success') {
      return;
    }
    final code = uri.queryParameters['device_code']?.toUpperCase();
    final pending = _pendingDeviceAuthorization;
    if (pending == null || (code != null && code != pending.userCode)) return;
    final signal = _authCallbackSignal ??= Completer<void>();
    if (!signal.isCompleted) signal.complete();
    _callbackCompletion ??= _completePendingAuthorizationFromCallback();
  }

  Future<void> _completePendingAuthorizationFromCallback() async {
    try {
      while (_loading) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final authorization = _pendingDeviceAuthorization;
      if (authorization == null || isAuthenticated || mfaRequired) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await pollDeviceAuthorization(authorization);
    } catch (_) {
      // The account page polling loop remains the final fallback.
    } finally {
      _callbackCompletion = null;
    }
  }

  Future<void> _restorePendingDeviceAuthorization() async {
    final payload = await _pendingAuthorizationStore.read();
    if (payload == null || payload.isEmpty) return;
    try {
      _pendingDeviceAuthorization = DeviceAuthorization.fromJson(
        MemberExternalAuthMethod.values.byName(
          (jsonDecode(payload) as Map<String, dynamic>)['method'] as String,
        ),
        jsonDecode(payload) as Map<String, dynamic>,
        baseUri: _api.baseUri,
      );
      _authCallbackSignal = Completer<void>();
    } catch (_) {
      await _pendingAuthorizationStore.clear();
    }
  }

  Map<String, Object?> _deviceAuthorizationJson(DeviceAuthorization value) => {
    'method': value.method.name,
    'device_code': value.deviceCode,
    'user_code': value.userCode,
    'verification_uri': value.verificationUri.toString(),
    'verification_uri_complete': value.verificationUriComplete?.toString(),
    'expires_in': value.expiresIn,
    'interval': value.interval,
  };

  Future<void> updateProfile({required String username, String? displayName}) =>
      _run(() async {
        _user = await _api.updateProfile(
          username: username,
          displayName: displayName,
        );
        _updateSummaryFromAccount();
        await _persistSummary();
      });

  Future<void> uploadAvatar(AvatarUploadData upload) => _run(() async {
    final previousUrl = _avatarUri(_user?.avatarUrl);
    final updated = await _api.uploadAvatar(upload);
    final updatedUrl = _avatarUri(updated.avatarUrl);
    await _evictAvatar(previousUrl);
    if (updatedUrl != previousUrl) await _evictAvatar(updatedUrl);
    _user = updated;
    _updateSummaryFromAccount();
    await _persistSummary();
  });

  Future<void> deleteAvatar() => _run(() async {
    final previousUrl = _avatarUri(_user?.avatarUrl);
    await _api.deleteAvatar();
    final updated = await _api.currentUser();
    await _evictAvatar(previousUrl);
    final updatedUrl = _avatarUri(updated.avatarUrl);
    if (updatedUrl != previousUrl) await _evictAvatar(updatedUrl);
    _user = updated;
    _updateSummaryFromAccount();
    await _persistSummary();
  });

  Future<void> loadMembership() => _run(() async {
    await _loadMembershipValue();
    await _persistSummary();
  });

  Future<void> purchaseApplePremium() => _applePurchase.purchase();

  Future<void> restoreApplePremium() => _applePurchase.restore();

  Future<void> loadReferral() => _run(_loadReferralValue);

  Future<void> redeemMembership(String code) => _run(() async {
    _membership = await _api.redeemMembership(code);
    _updateSummaryFromAccount();
    await _persistSummary();
    await _loadReferralValue();
  });

  Future<void> bindReferral(String code) => _run(() async {
    _referral = await _api.bindReferral(code);
  });

  Future<void> logout() => _run(() async {
    try {
      await _api.logout();
    } finally {
      _user = null;
      _pendingSession = null;
      _membership = null;
      _referral = null;
      _mfaStatus = null;
      await _clearSummary();
    }
  });

  @override
  void dispose() {
    _applePurchase.dispose();
    super.dispose();
  }

  Future<void> _authenticate(Future<MemberSession> Function() action) =>
      _run(() async {
        final session = await action();
        _acceptSession(session);
        if (!session.mfaRequired) {
          await _loadAccountValues();
          await _persistSummary();
        } else {
          await _clearSummary();
        }
      });

  void _acceptSession(MemberSession session) {
    if (session.mfaRequired) {
      _pendingSession = session;
      _user = null;
      _membership = null;
      _summary = null;
      _referral = null;
      _mfaStatus = null;
      return;
    }
    _acceptAuthenticatedSession(session);
  }

  void _acceptAuthenticatedSession(MemberSession session) {
    _pendingSession = null;
    _user = session.user;
    _updateSummaryFromAccount();
  }

  void _updateSummaryFromAccount() {
    final user = _user;
    if (user == null) return;
    final cachedPremium = _summary?.userId == user.id
        ? _summary!.premium
        : false;
    _summary = MemberAccountSummary.fromAccount(
      user,
      premium: _membership?.premium ?? cachedPremium,
    );
  }

  Future<void> _persistSummary() async {
    _updateSummaryFromAccount();
    final summary = _summary;
    if (summary == null) return;
    try {
      await _summaryCache.save(summary);
    } catch (_) {
      // The account remains usable if a best-effort UI cache cannot be saved.
    }
  }

  Future<void> _clearSummary() async {
    _summary = null;
    try {
      await _summaryCache.clear();
    } catch (_) {
      // Authentication state is authoritative even if cache cleanup fails.
    }
  }

  Uri? _avatarUri(String? value) {
    if (value == null || value.isEmpty) return null;
    return Uri.tryParse(value);
  }

  Future<void> _evictAvatar(Uri? uri) async {
    if (uri == null) return;
    try {
      await _avatarCache.evict(uri);
    } catch (_) {
      // Cache invalidation must not turn a completed account update into an
      // error. A changed URL still causes the avatar widget to reload.
    }
  }

  Future<void> _loadMembershipValue() async {
    _membership = await _api.membership();
    _updateSummaryFromAccount();
  }

  Future<void> _loadReferralValue() async {
    _referral = await _api.referral();
  }

  Future<void> _loadAccountValues() async {
    await _loadMembershipValue();
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      try {
        await _applePurchase.initialize();
      } catch (_) {
        // StoreKit availability is independent from account authentication;
        // the account page can still offer a retry or restore action.
      }
    }
    try {
      await _loadReferralValue();
    } on MemberAccountException {
      // Referral is additive. Older servers or a temporary referral endpoint
      // failure must not prevent an otherwise valid account session.
      _referral = null;
    }
  }

  Future<void> _run(Future<void> Function() action) async {
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
