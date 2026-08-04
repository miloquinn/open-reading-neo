enum MemberEmailCodePurpose { login, registration, passwordReset }

extension MemberEmailCodePurposeValue on MemberEmailCodePurpose {
  String get apiValue => switch (this) {
    MemberEmailCodePurpose.login => 'login',
    MemberEmailCodePurpose.registration => 'registration',
    MemberEmailCodePurpose.passwordReset => 'password_reset',
  };
}

enum MemberExternalAuthMethod { google, github, apple, passkey }

extension MemberExternalAuthMethodValue on MemberExternalAuthMethod {
  String get apiValue => name;
}

class MemberUser {
  const MemberUser({
    required this.id,
    required this.email,
    required this.emailVerified,
    required this.username,
    required this.effectiveName,
    required this.authMethods,
    required this.createdAt,
    this.displayName,
    this.avatarUrl,
  });

  factory MemberUser.fromJson(Map<String, dynamic> json, {Uri? baseUri}) {
    final rawAvatar = json['avatar_url'] as String?;
    return MemberUser(
      id: json['id'] as String,
      email: json['email'] as String,
      emailVerified: json['email_verified'] as bool? ?? true,
      username: json['username'] as String,
      displayName: json['display_name'] as String?,
      effectiveName:
          json['effective_name'] as String? ??
          json['display_name'] as String? ??
          json['username'] as String,
      avatarUrl: _absoluteUrl(rawAvatar, baseUri),
      authMethods: List<String>.unmodifiable(
        (json['auth_methods'] as List? ?? const []).whereType<String>(),
      ),
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  final String id;
  final String email;
  final bool emailVerified;
  final String username;
  final String? displayName;
  final String effectiveName;
  final String? avatarUrl;
  final List<String> authMethods;
  final DateTime createdAt;
}

class MemberAuthProviders {
  const MemberAuthProviders({
    this.google = false,
    this.github = false,
    this.apple = false,
    this.passkey = false,
  });

  factory MemberAuthProviders.fromJson(Map<String, dynamic> json) =>
      MemberAuthProviders(
        google: json['google'] as bool? ?? false,
        github: json['github'] as bool? ?? false,
        apple: json['apple'] as bool? ?? false,
        passkey: json['passkey'] as bool? ?? false,
      );

  final bool google;
  final bool github;
  final bool apple;
  final bool passkey;

  bool supports(MemberExternalAuthMethod method) => switch (method) {
    MemberExternalAuthMethod.google => google,
    MemberExternalAuthMethod.github => github,
    MemberExternalAuthMethod.apple => apple,
    MemberExternalAuthMethod.passkey => passkey,
  };
}

class MemberAuthConfig {
  const MemberAuthConfig({
    required this.providers,
    required this.usernameMinLength,
    required this.usernameMaxLength,
    required this.passwordMinLength,
    required this.passwordMaxLength,
    this.usernamePattern,
  });

  factory MemberAuthConfig.fromJson(Map<String, dynamic> json) {
    final username = _map(json['username']);
    final password = _map(json['password']);
    return MemberAuthConfig(
      providers: MemberAuthProviders.fromJson(_map(json['providers'])),
      usernamePattern: username['pattern'] as String?,
      usernameMinLength: username['min_length'] as int? ?? 3,
      usernameMaxLength: username['max_length'] as int? ?? 30,
      passwordMinLength: password['min_length'] as int? ?? 12,
      passwordMaxLength: password['max_length'] as int? ?? 128,
    );
  }

  final MemberAuthProviders providers;
  final String? usernamePattern;
  final int usernameMinLength;
  final int usernameMaxLength;
  final int passwordMinLength;
  final int passwordMaxLength;
}

class MemberSession {
  const MemberSession({
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresIn,
    required this.refreshExpiresIn,
    required this.user,
    this.mfaRequired = false,
  });

  factory MemberSession.fromJson(Map<String, dynamic> json, {Uri? baseUri}) =>
      MemberSession(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
        accessExpiresIn: json['access_expires_in'] as int,
        refreshExpiresIn: json['refresh_expires_in'] as int,
        user: MemberUser.fromJson(_map(json['user']), baseUri: baseUri),
        mfaRequired: json['mfa_required'] as bool? ?? false,
      );

  final String accessToken;
  final String refreshToken;
  final int accessExpiresIn;
  final int refreshExpiresIn;
  final MemberUser user;
  final bool mfaRequired;
}

class MemberEmailChallenge {
  const MemberEmailChallenge({
    required this.id,
    required this.expiresIn,
    required this.message,
  });

  factory MemberEmailChallenge.fromJson(Map<String, dynamic> json) =>
      MemberEmailChallenge(
        id: json['challenge_id'] as String,
        expiresIn: json['expires_in'] as int,
        message: json['message'] as String? ?? '验证码已发送',
      );

  final String id;
  final int expiresIn;
  final String message;
}

class MemberEmailChangeChallenge {
  const MemberEmailChangeChallenge({
    required this.currentChallengeId,
    required this.newChallengeId,
    required this.expiresIn,
  });

  factory MemberEmailChangeChallenge.fromJson(Map<String, dynamic> json) =>
      MemberEmailChangeChallenge.fromChallenges(
        current: _map(json['current']),
        next: _map(json['new']),
      );

  factory MemberEmailChangeChallenge.fromChallenges({
    required Map<String, dynamic> current,
    required Map<String, dynamic> next,
  }) => MemberEmailChangeChallenge(
    currentChallengeId: current['challenge_id'] as String,
    newChallengeId: next['challenge_id'] as String,
    expiresIn: _shorterExpiry(
      current['expires_in'] as int,
      next['expires_in'] as int,
    ),
  );

  final String currentChallengeId;
  final String newChallengeId;
  final int expiresIn;
}

class MemberMfaStatus {
  const MemberMfaStatus({
    required this.enabled,
    this.recoveryCodesRemaining = 0,
  });

  factory MemberMfaStatus.fromJson(Map<String, dynamic> json) =>
      MemberMfaStatus(
        enabled: json['enabled'] as bool? ?? false,
        recoveryCodesRemaining: json['recovery_codes_remaining'] as int? ?? 0,
      );

  final bool enabled;
  final int recoveryCodesRemaining;
}

class MemberMfaSetup {
  const MemberMfaSetup({required this.secret, required this.otpauthUri});

  factory MemberMfaSetup.fromJson(Map<String, dynamic> json) => MemberMfaSetup(
    secret: json['secret'] as String,
    otpauthUri: Uri.parse(json['otpauth_uri'] as String),
  );

  final String secret;
  final Uri otpauthUri;
}

class MemberMfaConfirmation {
  const MemberMfaConfirmation({
    required this.enabled,
    required this.recoveryCodes,
  });

  factory MemberMfaConfirmation.fromJson(Map<String, dynamic> json) =>
      MemberMfaConfirmation(
        enabled: json['enabled'] as bool? ?? true,
        recoveryCodes: List<String>.unmodifiable(
          (json['recovery_codes'] as List? ?? const []).whereType<String>(),
        ),
      );

  final bool enabled;
  final List<String> recoveryCodes;
}

class DeviceAuthorization {
  const DeviceAuthorization({
    required this.method,
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
    this.verificationUriComplete,
  });

  factory DeviceAuthorization.fromJson(
    MemberExternalAuthMethod method,
    Map<String, dynamic> json, {
    Uri? baseUri,
  }) {
    final verification =
        json['verification_uri'] as String? ??
        json['verification_url'] as String? ??
        json['authorization_url'] as String?;
    if (verification == null) {
      throw const FormatException('Missing device verification URL');
    }
    return DeviceAuthorization(
      method: method,
      deviceCode: json['device_code'] as String,
      userCode: json['user_code'] as String? ?? '',
      verificationUri: Uri.parse(_absoluteUrl(verification, baseUri)!),
      verificationUriComplete: switch (json['verification_uri_complete']
          as String?) {
        final value? => Uri.parse(_absoluteUrl(value, baseUri)!),
        null => null,
      },
      expiresIn: json['expires_in'] as int? ?? 600,
      interval: json['interval'] as int? ?? 5,
    );
  }

  final MemberExternalAuthMethod method;
  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final Uri? verificationUriComplete;
  final int expiresIn;
  final int interval;
}

class MemberMembershipConfig {
  const MemberMembershipConfig({
    required this.product,
    required this.features,
    this.purchaseUrl,
    this.appleProductId,
  });

  factory MemberMembershipConfig.fromJson(
    Map<String, dynamic> json, {
    Uri? baseUri,
  }) => MemberMembershipConfig(
    product: json['product'] as String,
    purchaseUrl: _absoluteUrl(json['purchase_url'] as String?, baseUri),
    appleProductId: json['apple_product_id'] as String?,
    features: List<String>.unmodifiable(
      (json['features'] as List? ?? const []).whereType<String>(),
    ),
  );

  final String product;
  final String? purchaseUrl;
  final String? appleProductId;
  final List<String> features;
}

class MemberEntitlement {
  const MemberEntitlement({
    required this.featureKey,
    required this.source,
    required this.status,
    required this.grantedAt,
    this.expiresAt,
  });

  factory MemberEntitlement.fromJson(Map<String, dynamic> json) =>
      MemberEntitlement(
        featureKey: json['feature_key'] as String,
        source: json['source'] as String,
        status: json['status'] as String,
        grantedAt: DateTime.parse(json['granted_at'] as String),
        expiresAt: switch (json['expires_at'] as String?) {
          final value? => DateTime.parse(value),
          null => null,
        },
      );

  final String featureKey;
  final String source;
  final String status;
  final DateTime grantedAt;
  final DateTime? expiresAt;
}

class MemberMembership {
  const MemberMembership({
    required this.premium,
    required this.features,
    required this.entitlements,
    this.redeemed,
  });

  factory MemberMembership.fromJson(Map<String, dynamic> json) =>
      MemberMembership(
        premium: json['premium'] as bool? ?? false,
        features: Map<String, bool>.unmodifiable(
          _map(
            json['features'],
          ).map((key, value) => MapEntry(key, value as bool? ?? false)),
        ),
        entitlements: List<MemberEntitlement>.unmodifiable(
          (json['entitlements'] as List? ?? const []).whereType<Map>().map(
            (item) => MemberEntitlement.fromJson(item.cast<String, dynamic>()),
          ),
        ),
        redeemed: json['redeemed'] as bool?,
      );

  final bool premium;
  final Map<String, bool> features;
  final List<MemberEntitlement> entitlements;
  final bool? redeemed;
}

class MemberReferralInviter {
  const MemberReferralInviter({
    required this.code,
    required this.name,
    required this.status,
  });

  factory MemberReferralInviter.fromJson(Map<String, dynamic> json) =>
      MemberReferralInviter(
        code: json['code'] as String,
        name: json['name'] as String,
        status: json['status'] as String,
      );

  final String code;
  final String name;
  final String status;
}

class MemberReferral {
  const MemberReferral({
    required this.inviteCode,
    required this.inviteUrl,
    required this.invitedCount,
    required this.rewardedCount,
    required this.recentInvites,
    this.inviter,
  });

  factory MemberReferral.fromJson(Map<String, dynamic> json) {
    final inviter = _map(json['inviter']);
    final stats = _map(json['stats']);
    return MemberReferral(
      inviteCode: json['invite_code'] as String,
      inviteUrl: Uri.parse(json['invite_url'] as String),
      inviter: inviter.isEmpty ? null : MemberReferralInviter.fromJson(inviter),
      invitedCount: stats['invited'] as int? ?? 0,
      rewardedCount: stats['rewarded'] as int? ?? 0,
      recentInvites: List<MemberReferralInvite>.unmodifiable(
        (json['recent_invites'] as List? ?? const []).whereType<Map>().map(
          (item) => MemberReferralInvite.fromJson(item.cast<String, dynamic>()),
        ),
      ),
    );
  }

  final String inviteCode;
  final Uri inviteUrl;
  final MemberReferralInviter? inviter;
  final int invitedCount;
  final int rewardedCount;
  final List<MemberReferralInvite> recentInvites;
}

class MemberReferralInvite {
  const MemberReferralInvite({
    required this.name,
    required this.status,
    required this.boundAt,
    this.rewardedAt,
  });

  factory MemberReferralInvite.fromJson(Map<String, dynamic> json) =>
      MemberReferralInvite(
        name: json['name'] as String,
        status: json['status'] as String,
        boundAt: DateTime.parse(json['bound_at'] as String),
        rewardedAt: json['rewarded_at'] == null
            ? null
            : DateTime.parse(json['rewarded_at'] as String),
      );

  final String name;
  final String status;
  final DateTime boundAt;
  final DateTime? rewardedAt;
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : const {};

String? _absoluteUrl(String? value, Uri? baseUri) {
  if (value == null || value.isEmpty) return null;
  final uri = Uri.parse(value);
  return (uri.isAbsolute || baseUri == null ? uri : baseUri.resolveUri(uri))
      .toString();
}

int _shorterExpiry(int first, int second) => first < second ? first : second;
