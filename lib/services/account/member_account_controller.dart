import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../core/app_distribution.dart';
import '../reading/reading_account_scope.dart';
import 'account_auth_callback_bridge.dart';
import 'account_api_client.dart';
import 'account_avatar_cache.dart';
import 'account_models.dart';
import 'account_summary_cache.dart';
import 'account_token_store.dart';
import 'apple_purchase_service.dart';
import 'avatar_image_processor.dart';
import 'membership_cache.dart';

class MemberAccountController extends ChangeNotifier {
  MemberAccountController({
    MemberAccountApiClient? api,
    AccountAvatarCache? avatarCache,
    MemberAccountSummaryCache? summaryCache,
    MemberMembershipCache? membershipCache,
    PendingDeviceAuthorizationStore? pendingAuthorizationStore,
    AccountAuthCallbackBridge? authCallbackBridge,
    ApplePurchaseStore? appleStore,
    ReadingAccountScope? readingScope,
    this.membershipRetryDelay = const Duration(seconds: 30),
  }) : _api = api ?? MemberAccountApiClient(),
       _readingScope = readingScope ?? ReadingAccountScope.instance,
       _avatarCache = avatarCache ?? AccountAvatarCache.instance,
       _summaryCache = summaryCache ?? const MemberAccountSummaryCache(),
       _membershipCache = membershipCache ?? const MemberMembershipCache(),
       _pendingAuthorizationStore =
           pendingAuthorizationStore ?? SecurePendingDeviceAuthorizationStore(),
       _authCallbackBridge = authCallbackBridge ?? AccountAuthCallbackBridge() {
    _applePurchase = ApplePremiumPurchaseService(
      productId: appleProductId,
      store: appleStore,
      accountIdProvider: () => _user?.id,
      verify: (purchase) async {
        final accountId = _user?.id;
        if (accountId == null) {
          throw const MemberAccountException('请先登录账号');
        }
        final membership = await _api.submitApplePurchase(
          productId: purchase.productID,
          verificationData: purchase.verificationData.serverVerificationData,
        );
        if (_user?.id != accountId) {
          throw const MemberAccountException('账号已切换，请重新验证购买');
        }
        _checkMembershipOwner(membership, accountId);
        _resetMembershipSync();
        _membership = membership;
        await _persistMembership();
        _updateSummaryFromAccount();
        unawaited(_persistSummary());
        notifyListeners();
        return membership;
      },
    );
  }

  static const appleProductId = 'com.niki.xxread.premium.lifetime';

  final MemberAccountApiClient _api;
  final ReadingAccountScope _readingScope;
  MemberAccountApiClient get readingApi => _api;
  final AccountAvatarCache _avatarCache;
  final MemberAccountSummaryCache _summaryCache;
  final MemberMembershipCache _membershipCache;
  final PendingDeviceAuthorizationStore _pendingAuthorizationStore;
  final AccountAuthCallbackBridge _authCallbackBridge;
  late final ApplePremiumPurchaseService _applePurchase;

  final Duration membershipRetryDelay;
  Timer? _membershipRetry;
  bool _membershipSyncFailed = false;
  int _membershipRequest = 0;
  bool _disposed = false;
  Future<void>? _synchronizing;
  bool get membershipSyncFailed => _membershipSyncFailed;

  bool _isRetryableMembershipError(Object error) =>
      error is MemberAccountException &&
      (error.isTransientNetworkFailure ||
          error.statusCode == 429 ||
          (error.statusCode != null && error.statusCode! >= 500));

  void _resetMembershipSync() {
    _membershipRequest++;
    _membershipRetry?.cancel();
    _membershipSyncFailed = false;
  }

  void _scheduleMembershipRetry(String? accountId) {
    _membershipRetry?.cancel();
    _membershipRetry = Timer(membershipRetryDelay, () async {
      if (_disposed || _user?.id != accountId) return;
      if (_loading) {
        _scheduleMembershipRetry(accountId);
        return;
      }
      try {
        await synchronize();
      } catch (_) {
        // The refresh records failure and schedules another transient retry.
      }
    });
  }

  /// Reconcile the account without opening StoreKit or requiring a page visit.
  /// Callers may share this operation; temporary failures schedule recovery.
  Future<void> synchronize() {
    final active = _synchronizing;
    if (active != null) return active;
    if (_disposed) return Future<void>.value();
    if (_loading || _applePurchase.busy) {
      _scheduleMembershipRetry(_user?.id);
      return Future<void>.value();
    }
    late final Future<void> operation;
    operation =
        (() async {
          try {
            if (_user == null) {
              await initialize(force: true);
            } else {
              await loadMembership();
            }
          } catch (_) {
            // Public explicit actions still throw; background lifecycle sync reports
            // state through this controller and must not become an unhandled error.
          }
        })().whenComplete(() {
          if (identical(_synchronizing, operation)) _synchronizing = null;
        });
    _synchronizing = operation;
    return operation;
  }

  void _checkMembershipOwner(MemberMembership membership, String accountId) {
    if (membership.userId != null && membership.userId != accountId) {
      throw const MemberAccountException('会员权益账号不匹配，请重新登录');
    }
  }

  bool _initialized = false;
  bool _loading = false;
  MemberUser? _user;
  MemberSession? _pendingSession;
  MemberAuthConfig? _authConfig;
  MemberMembershipConfig? _membershipConfig;
  MemberMembership? _membershipValue;
  CachedMemberMembership? _cachedMembership;
  bool _membershipCacheLoaded = false;
  Timer? _membershipExpiryTimer;
  MemberMembership? get _membership => _membershipValue;
  set _membership(MemberMembership? value) {
    _membershipExpiryTimer?.cancel();
    _membershipValue = value;
    final expiresAt = value?.premiumExpiresAt;
    if (expiresAt != null && expiresAt.isAfter(DateTime.now())) {
      _membershipExpiryTimer = Timer(expiresAt.difference(DateTime.now()), () {
        if (!_disposed) notifyListeners();
      });
    }
  }

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

  /// Premium access is valid only for the currently authenticated account.
  /// A previously server-verified, account-bound snapshot may be used while a
  /// fresh server reconciliation is in flight; the summary cache alone never
  /// grants access.
  bool get hasPremiumAccess =>
      _user != null && _membership?.hasActivePremium == true;
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

  Future<void> initialize({bool force = false}) async {
    if (_loading) return;
    if (_initialized && !force) return;
    try {
      await _run(() async {
        await _restorePendingDeviceAuthorization();
        unawaited(_initializeAuthCallbackBridge());
        final cachedValues = await Future.wait<Object?>([
          _summaryCache.load(),
          _membershipCache.load(),
        ]);
        _summary = cachedValues[0] as MemberAccountSummary?;
        _cachedMembership = cachedValues[1] as CachedMemberMembership?;
        _membershipCacheLoaded = true;
        if (_summary != null) notifyListeners();
        MemberAccountException? deferred;
        try {
          final configs = await Future.wait<Object?>([
            _api.authConfig(),
            _api.membershipConfig(),
          ]);
          _authConfig = configs[0] as MemberAuthConfig;
          _membershipConfig = configs[1] as MemberMembershipConfig;
        } on MemberAccountException catch (error) {
          if (!_isRetryableMembershipError(error)) rethrow;
          deferred = error;
        }
        try {
          final session = await _api.restoreSession();
          _acceptSession(session);
          if (session.mfaRequired) {
            await _clearSummary();
            await _clearMembershipCache();
          } else {
            await _loadAccountValues();
            await _persistSummary();
          }
        } on MemberAccountException catch (error) {
          if (error.statusCode == 401) {
            _user = null;
            _pendingSession = null;
            _resetMembershipSync();
            _membership = null;
            _mfaStatus = null;
            await _clearSummary();
            await _clearMembershipCache();
          } else if (_isRetryableMembershipError(error)) {
            deferred ??= error;
          } else {
            rethrow;
          }
        }
        if (deferred != null) throw deferred;
      });
    } catch (error) {
      if (_isRetryableMembershipError(error)) {
        _membershipSyncFailed = true;
        _scheduleMembershipRetry(_user?.id);
      }
      if (error is! MemberAccountException ||
          !_isRetryableMembershipError(error)) {
        _user = null;
        _pendingSession = null;
        _resetMembershipSync();
        _membership = null;
        _mfaStatus = null;
      }
      rethrow;
    } finally {
      // The account center must remain usable after a network failure. A
      // spinner-only page with no retry is how users get stuck unable to
      // sign in with or without a proxy.
      _initialized = true;
      notifyListeners();
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
    final authorizationCode = credential.authorizationCode;
    if (authorizationCode.isEmpty) {
      throw const MemberAccountException('Apple 未返回授权码，请重新使用 Apple 登录');
    }
    final fullName = [credential.givenName, credential.familyName]
        .whereType<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .join(' ');
    return _api.loginApple(
      identityToken: identityToken,
      authorizationCode: authorizationCode,
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
    if ((isAuthenticated || mfaRequired) &&
        _pendingDeviceAuthorization == null) {
      return true;
    }

    final poll = _pollDeviceAuthorizationRecovering(authorization);
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

  Future<bool> _pollDeviceAuthorizationRecovering(
    DeviceAuthorization authorization,
  ) async {
    try {
      return await _pollDeviceAuthorization(authorization);
    } on MemberAccountException catch (error) {
      if (error.code != 'network_timeout' &&
          error.code != 'network_unavailable') {
        rethrow;
      }
      clearError();
      return false;
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
        await _clearMembershipCache();
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
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      _pendingDeviceAuthorization = DeviceAuthorization.fromJson(
        MemberExternalAuthMethod.values.byName(decoded['method'] as String),
        decoded,
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

  Future<void> purchaseApplePremium() async {
    if (_user == null) throw const MemberAccountException('请先登录账号');
    // Check authoritative access immediately before opening the payment sheet.
    final accountId = _user!.id;
    await loadMembership();
    if (_user?.id != accountId || _membership == null) {
      throw const MemberAccountException('账号已切换，请重新验证会员权益');
    }
    if ((hasPremiumAccess && _membership!.premiumExpiresAt == null) ||
        _membership!.purchaseAllowed == false) {
      return;
    }
    await _applePurchase.purchase();
  }

  Future<void> restoreApplePremium() => _applePurchase.restore();

  Future<void> loadReferral() => _run(_loadReferralValue);

  Future<void> redeemMembership(String code) => _run(() async {
    final accountId = _user?.id;
    final membership = await _api.redeemMembership(code);
    if (accountId == null || _user?.id != accountId) {
      throw const MemberAccountException('账号已切换，请重新验证会员权益');
    }
    _checkMembershipOwner(membership, accountId);
    _resetMembershipSync();
    _membership = membership;
    await _persistMembership();
    _updateSummaryFromAccount();
    await _persistSummary();
    await _loadReferralValue();
  });

  Future<void> bindReferral(String code) => _run(() async {
    _referral = await _api.bindReferral(code);
  });

  Future<MemberAccountDeletionPreview> accountDeletionPreview() =>
      _runValue(_api.accountDeletionPreview);

  Future<MemberEmailChallenge> requestAccountDeletionCode() =>
      _runValue(_api.requestAccountDeletionCode);

  /// 注销成功后本地状态必须和退出登录一样彻底清空，否则界面仍会显示已删除的账号。
  Future<bool> deleteAccount({
    required String challengeId,
    required String code,
    required String confirmation,
    String? mfaCode,
  }) => _runValue(() async {
    final appleManualRevocationRequired = await _api.deleteAccount(
      challengeId: challengeId,
      code: code,
      confirmation: confirmation,
      mfaCode: mfaCode,
    );
    await _readingScope.setOwner(null);
    _resetMembershipSync();
    _user = null;
    _pendingSession = null;
    _membership = null;
    _referral = null;
    _mfaStatus = null;
    notifyListeners();
    await _clearSummary();
    await _clearMembershipCache();
    try {
      await _api.clearLocalSession();
    } catch (_) {
      _error = '账号已注销，但本地登录信息清理失败，请重新打开应用后重试';
    }
    return appleManualRevocationRequired;
  });

  Future<void> logout() => _run(() async {
    await _readingScope.setOwner(null);
    try {
      await _api.logout();
    } finally {
      _user = null;
      _pendingSession = null;
      _resetMembershipSync();
      _membership = null;
      _referral = null;
      _mfaStatus = null;
      notifyListeners();
      await _clearSummary();
      await _clearMembershipCache();
    }
  });

  @override
  void dispose() {
    _membershipExpiryTimer?.cancel();
    _disposed = true;
    _resetMembershipSync();
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
          await _clearMembershipCache();
        }
      });

  void _acceptSession(MemberSession session) {
    if (session.mfaRequired) {
      _pendingSession = session;
      _user = null;
      _resetMembershipSync();
      _membership = null;
      _summary = null;
      _referral = null;
      _mfaStatus = null;
      notifyListeners();
      return;
    }
    _acceptAuthenticatedSession(session);
  }

  void _acceptAuthenticatedSession(MemberSession session) {
    unawaited(_readingScope.setOwner(session.user.id));
    final accountChanged = _user?.id != session.user.id;
    if (accountChanged) {
      _resetMembershipSync();
      _membership = null;
      _summary = null;
    }
    _pendingSession = null;
    _user = session.user;
    _restoreCachedMembership(session.user.id);
    _updateSummaryFromAccount();
    if (accountChanged) notifyListeners();
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

  void _restoreCachedMembership(String accountId) {
    final cached = _cachedMembership;
    if (_membership != null || cached?.userId != accountId) return;
    final owner = cached!.membership.userId;
    if (owner != null && owner != accountId) return;
    _membership = cached.membership;
  }

  Future<void> _ensureMembershipCacheLoaded() async {
    if (_membershipCacheLoaded) return;
    _cachedMembership = await _membershipCache.load();
    _membershipCacheLoaded = true;
    final accountId = _user?.id;
    if (accountId != null) {
      _restoreCachedMembership(accountId);
      _updateSummaryFromAccount();
      notifyListeners();
    }
  }

  Future<void> _persistMembership() async {
    final accountId = _user?.id;
    final membership = _membership;
    if (accountId == null || membership == null) return;
    _cachedMembership = CachedMemberMembership(
      userId: accountId,
      membership: membership,
    );
    _membershipCacheLoaded = true;
    try {
      await _membershipCache.save(accountId, membership);
    } catch (_) {
      // A verified in-memory membership remains usable if persistence fails.
    }
  }

  Future<void> _clearMembershipCache() async {
    _cachedMembership = null;
    _membershipCacheLoaded = true;
    try {
      await _membershipCache.clear();
    } catch (_) {
      // Cleared authentication state cannot be authorized by a stale cache.
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
    final accountId = _user?.id;
    if (accountId == null) return;
    final request = ++_membershipRequest;
    _membershipRetry?.cancel();
    try {
      final membership = await _api.membership();
      if (_disposed ||
          _user?.id != accountId ||
          request != _membershipRequest) {
        return;
      }
      _checkMembershipOwner(membership, accountId);
      _membership = membership;
      _membershipSyncFailed = false;
      await _persistMembership();
    } catch (error) {
      if (_disposed ||
          _user?.id != accountId ||
          request != _membershipRequest) {
        rethrow;
      }
      _membershipSyncFailed = true;
      if (_isRetryableMembershipError(error)) {
        // Keep only this session's server-verified grant; never trust UI cache.
        _scheduleMembershipRetry(accountId);
      } else {
        _membership = null;
        await _clearMembershipCache();
      }
      _updateSummaryFromAccount();
      notifyListeners();
      rethrow;
    }
    _updateSummaryFromAccount();
    notifyListeners();
  }

  Future<void> _loadReferralValue() async {
    _referral = await _api.referral();
  }

  Future<void> _loadAccountValues() async {
    await _ensureMembershipCacheLoaded();
    try {
      await _loadMembershipValue();
    } on MemberAccountException {
      // The session and user returned by authentication are authoritative.
      // Membership is supplementary and can recover on a later account load.
    }
    if (AppDistribution.usesAppleBilling) {
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
      if (!_disposed) notifyListeners();
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
