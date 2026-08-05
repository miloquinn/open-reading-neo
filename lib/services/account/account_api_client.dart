import 'dart:async';

import 'package:dio/dio.dart';

import 'account_models.dart';
import 'account_token_store.dart';
import 'avatar_image_processor.dart';

class MemberAccountException implements Exception {
  const MemberAccountException(
    this.message, {
    this.statusCode,
    this.code,
    this.retryAfter,
  });

  final String message;
  final int? statusCode;
  final String? code;
  final int? retryAfter;

  @override
  String toString() => message;
}

class MemberAccountApiClient {
  MemberAccountApiClient({Dio? dio, MemberTokenStore? tokenStore, Uri? baseUri})
    : baseUri = baseUri ?? Uri.parse('https://open.xxread.top'),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 30),
            ),
          ),
      _tokenStore = tokenStore ?? SecureMemberTokenStore();

  static const authRoot = '/api/v1/auth';
  static const membershipRoot = '/api/v1/membership';

  final Dio _dio;
  final MemberTokenStore _tokenStore;
  final Uri baseUri;
  Future<MemberSession>? _refreshing;

  Future<MemberAuthConfig> authConfig() async => MemberAuthConfig.fromJson(
    await _jsonRequest('GET', '$authRoot/config', authenticated: false),
  );

  Future<MemberMembershipConfig> membershipConfig() async =>
      MemberMembershipConfig.fromJson(
        await _jsonRequest(
          'GET',
          '$membershipRoot/config',
          authenticated: false,
        ),
        baseUri: baseUri,
      );

  Future<MemberUser> currentUser() async {
    final pending = await _tokenStore.readMfaPending();
    final json = await _jsonRequest(
      'GET',
      '$authRoot/me',
      retryAuthentication: !pending,
    );
    return MemberUser.fromJson(_map(json['user']), baseUri: baseUri);
  }

  Future<MemberSession> restoreSession() async {
    final storedPending = await _tokenStore.readMfaPending();
    final json = await _jsonRequest(
      'GET',
      '$authRoot/me',
      retryAuthentication: !storedPending,
    );
    final accessToken = await _tokenStore.readAccessToken();
    final refreshToken = await _tokenStore.readRefreshToken();
    if (accessToken == null ||
        accessToken.isEmpty ||
        refreshToken == null ||
        refreshToken.isEmpty) {
      throw const MemberAccountException('请先登录', statusCode: 401);
    }
    final mfaRequired = json['mfa_required'] as bool? ?? false;
    if (mfaRequired != storedPending) {
      await _tokenStore.saveTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
        mfaPending: mfaRequired,
      );
    }
    return MemberSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      accessExpiresIn: 0,
      refreshExpiresIn: 0,
      user: MemberUser.fromJson(_map(json['user']), baseUri: baseUri),
      mfaRequired: mfaRequired,
    );
  }

  Future<MemberSession> loginPassword(String email, String password) =>
      _sessionRequest('$authRoot/password/login', {
        'email': email.trim(),
        'password': password,
      });

  Future<MemberEmailChallenge> requestCode(
    String email,
    MemberEmailCodePurpose purpose,
  ) async {
    final path = switch (purpose) {
      MemberEmailCodePurpose.login => '$authRoot/email/code',
      MemberEmailCodePurpose.registration => '$authRoot/password/register/code',
      MemberEmailCodePurpose.passwordReset => '$authRoot/password/reset/code',
    };
    return MemberEmailChallenge.fromJson(
      await _jsonRequest(
        'POST',
        path,
        data: {'email': email.trim()},
        authenticated: false,
      ),
    );
  }

  Future<MemberSession> verifyEmailCode({
    required String email,
    required String challengeId,
    required String code,
  }) => _sessionRequest('$authRoot/email/verify', {
    'email': email.trim(),
    'challenge_id': challengeId,
    'code': code.trim(),
  });

  Future<MemberSession> registerPassword({
    required String email,
    required String challengeId,
    required String code,
    required String username,
    required String password,
    String? displayName,
  }) => _sessionRequest('$authRoot/password/register', {
    'email': email.trim(),
    'challenge_id': challengeId,
    'code': code.trim(),
    'username': username.trim(),
    'display_name': _optionalText(displayName),
    'password': password,
  });

  Future<MemberSession> resetPassword({
    required String email,
    required String challengeId,
    required String code,
    required String password,
  }) => _sessionRequest('$authRoot/password/reset', {
    'email': email.trim(),
    'challenge_id': challengeId,
    'code': code.trim(),
    'password': password,
  });

  Future<MemberEmailChangeChallenge> requestEmailChangeCode(
    String newEmail,
  ) async => MemberEmailChangeChallenge.fromJson(
    await _jsonRequest(
      'POST',
      '$authRoot/security/email/code',
      data: {'new_email': newEmail.trim()},
    ),
  );

  Future<MemberSession> changeEmail({
    required String newEmail,
    required String currentChallengeId,
    required String currentCode,
    required String newChallengeId,
    required String newCode,
  }) => _sessionRequest('$authRoot/security/email/change', {
    'new_email': newEmail.trim(),
    'current_challenge_id': currentChallengeId,
    'current_code': currentCode.trim(),
    'new_challenge_id': newChallengeId,
    'new_code': newCode.trim(),
  }, authenticated: true);

  Future<MemberEmailChallenge> requestPasswordChangeCode() async =>
      MemberEmailChallenge.fromJson(
        await _jsonRequest('POST', '$authRoot/security/password/code'),
      );

  Future<MemberSession> changePassword({
    required String challengeId,
    required String code,
    required String password,
  }) => _sessionRequest('$authRoot/security/password/change', {
    'challenge_id': challengeId,
    'code': code.trim(),
    'password': password,
  }, authenticated: true);

  Future<MemberMfaStatus> mfaStatus() async => MemberMfaStatus.fromJson(
    await _jsonRequest('GET', '$authRoot/security/mfa/status'),
  );

  Future<MemberEmailChallenge> requestMfaSetupCode() async =>
      MemberEmailChallenge.fromJson(
        await _jsonRequest('POST', '$authRoot/security/mfa/setup/code'),
      );

  Future<MemberMfaSetup> setupMfa({
    required String challengeId,
    required String code,
  }) async => MemberMfaSetup.fromJson(
    await _jsonRequest(
      'POST',
      '$authRoot/security/mfa/setup',
      data: {'challenge_id': challengeId, 'code': code.trim()},
    ),
  );

  Future<MemberMfaConfirmation> confirmMfa(String code) async =>
      MemberMfaConfirmation.fromJson(
        await _jsonRequest(
          'POST',
          '$authRoot/security/mfa/confirm',
          data: {'code': code.trim()},
        ),
      );

  Future<void> disableMfa(String code) => _emptyRequest(
    'POST',
    '$authRoot/security/mfa/disable',
    data: {'code': code.trim()},
  );

  Future<MemberSession> verifyMfa({
    required String code,
    required String pendingAccessToken,
  }) => _sessionRequest(
    '$authRoot/mfa/verify',
    {'code': code.trim()},
    accessToken: pendingAccessToken,
    retryAuthentication: false,
  );

  Future<DeviceAuthorization> beginExternalLogin(
    MemberExternalAuthMethod method,
  ) async => DeviceAuthorization.fromJson(
    method,
    await _jsonRequest(
      'POST',
      '$authRoot/device/${method.apiValue}/begin',
      authenticated: false,
    ),
    baseUri: baseUri,
  );

  Future<MemberSession> loginApple({
    required String identityToken,
    String? fullName,
  }) => _sessionRequest('$authRoot/apple/login', {
    'identity_token': identityToken,
    if (fullName != null && fullName.trim().isNotEmpty)
      'full_name': fullName.trim(),
  }, authenticated: false);

  Future<Map<String, dynamic>> beginPasskeyLogin() => _jsonRequest(
    'POST',
    '$authRoot/passkeys/login/begin',
    authenticated: false,
  );

  Future<MemberSession> finishPasskeyLogin({
    required String challengeId,
    required Map<String, dynamic> credential,
  }) => _sessionRequest('$authRoot/passkeys/login/finish', {
    'challenge_id': challengeId,
    'credential': credential,
  }, authenticated: false);

  Future<MemberSession?> pollDeviceAuthorization(
    DeviceAuthorization authorization,
  ) async {
    try {
      return await _sessionRequest('$authRoot/device/token', {
        'device_code': authorization.deviceCode,
      });
    } on MemberAccountException catch (error) {
      if (error.code == 'authorization_pending' ||
          error.statusCode == 202 ||
          error.statusCode == 428) {
        return null;
      }
      rethrow;
    }
  }

  Future<MemberUser> updateProfile({
    required String username,
    String? displayName,
  }) async {
    final json = await _jsonRequest(
      'PATCH',
      '$authRoot/profile',
      data: {
        'username': username.trim(),
        'display_name': _optionalText(displayName),
      },
    );
    return MemberUser.fromJson(_map(json['user']), baseUri: baseUri);
  }

  Future<MemberUser> uploadAvatar(AvatarUploadData upload) async {
    final json = await _jsonRequest(
      'POST',
      '$authRoot/avatar',
      data: FormData.fromMap({
        'avatar': MultipartFile.fromBytes(
          upload.bytes,
          filename: upload.filename,
          contentType: DioMediaType.parse(upload.contentType),
        ),
      }),
    );
    return MemberUser.fromJson(_map(json['user']), baseUri: baseUri);
  }

  Future<void> deleteAvatar() => _emptyRequest('DELETE', '$authRoot/avatar');

  Future<MemberMembership> membership() async =>
      MemberMembership.fromJson(await _jsonRequest('GET', membershipRoot));

  Future<MemberMembership> redeemMembership(String code) async =>
      MemberMembership.fromJson(
        await _jsonRequest(
          'POST',
          '$membershipRoot/redeem',
          data: {'code': code.trim()},
        ),
      );

  Future<MemberReferral> referral() async => MemberReferral.fromJson(
    await _jsonRequest('GET', '$membershipRoot/referral'),
  );

  Future<MemberReferral> bindReferral(String code) async =>
      MemberReferral.fromJson(
        await _jsonRequest(
          'POST',
          '$membershipRoot/referral/bind',
          data: {'code': code.trim()},
        ),
      );

  Future<MemberMembership> submitApplePurchase({
    required String productId,
    required String verificationData,
    String? purchaseId,
    String? transactionDate,
  }) async => MemberMembership.fromJson(
    await _jsonRequest(
      'POST',
      '$membershipRoot/apple/purchase',
      data: {'signed_transaction_info': verificationData},
    ),
  );

  Future<void> logout() async {
    try {
      final token = await _tokenStore.readAccessToken();
      if (token != null && token.isNotEmpty) {
        await _request(
          'POST',
          '$authRoot/logout',
          accessToken: token,
          retryAuthentication: false,
        );
      }
    } finally {
      await _tokenStore.clear();
    }
  }

  Future<MemberSession> refreshSession() async {
    final active = _refreshing;
    if (active != null) return active;
    final future = _performRefresh();
    _refreshing = future;
    try {
      return await future;
    } finally {
      if (identical(_refreshing, future)) _refreshing = null;
    }
  }

  Future<MemberSession> _performRefresh() async {
    if (await _tokenStore.readMfaPending()) {
      throw const MemberAccountException(
        '请先完成双重验证',
        statusCode: 401,
        code: 'mfa_required',
      );
    }
    final refreshToken = await _tokenStore.readRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      throw const MemberAccountException('请先登录', statusCode: 401);
    }
    try {
      return await _sessionRequest('$authRoot/refresh', {
        'refresh_token': refreshToken,
      });
    } catch (_) {
      await _tokenStore.clear();
      rethrow;
    }
  }

  Future<MemberSession> _sessionRequest(
    String path,
    Map<String, dynamic> data, {
    bool authenticated = false,
    String? accessToken,
    bool retryAuthentication = true,
  }) async {
    final json = await _jsonRequest(
      'POST',
      path,
      data: data,
      authenticated: authenticated,
      accessToken: accessToken,
      retryAuthentication: retryAuthentication,
    );
    final session = MemberSession.fromJson(json, baseUri: baseUri);
    try {
      await _tokenStore.saveTokens(
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
        mfaPending: session.mfaRequired,
      );
    } catch (_) {
      throw const MemberAccountException('无法安全保存登录状态，请检查系统安全存储设置');
    }
    return session;
  }

  Future<Map<String, dynamic>> _jsonRequest(
    String method,
    String path, {
    Object? data,
    bool authenticated = true,
    String? accessToken,
    bool retryAuthentication = true,
  }) async {
    final response = await _request(
      method,
      path,
      data: data,
      authenticated: authenticated,
      accessToken: accessToken,
      retryAuthentication: retryAuthentication,
    );
    if (response.data is! Map) {
      throw const MemberAccountException('服务器返回了无法识别的数据');
    }
    return (response.data as Map).cast<String, dynamic>();
  }

  Future<void> _emptyRequest(String method, String path, {Object? data}) async {
    await _request(method, path, data: data);
  }

  Future<Response<dynamic>> _request(
    String method,
    String path, {
    Object? data,
    bool authenticated = true,
    String? accessToken,
    bool retryAuthentication = true,
  }) async {
    var token = accessToken;
    if (authenticated && token == null) {
      token = await _tokenStore.readAccessToken();
      if (token == null || token.isEmpty) {
        throw const MemberAccountException('请先登录', statusCode: 401);
      }
    }
    try {
      return await _dio.request<dynamic>(
        baseUri.resolve(path).toString(),
        data: data,
        options: Options(
          method: method,
          headers: token == null ? null : {'Authorization': 'Bearer $token'},
        ),
      );
    } on DioException catch (error) {
      if (authenticated &&
          retryAuthentication &&
          error.response?.statusCode == 401) {
        final refreshed = await refreshSession();
        return _request(
          method,
          path,
          data: data,
          accessToken: refreshed.accessToken,
          retryAuthentication: false,
        );
      }
      throw _friendlyError(error);
    }
  }
}

MemberAccountException _friendlyError(DioException error) {
  final statusCode = error.response?.statusCode;
  final data = error.response?.data;
  final json = data is Map
      ? data.cast<String, dynamic>()
      : const <String, dynamic>{};
  final detail = json['detail'];
  final code =
      json['error'] as String? ??
      json['code'] as String? ??
      (detail is Map ? detail['code'] as String? : null);
  final retryAfter =
      json['retry_after'] as int? ??
      int.tryParse(error.response?.headers.value('retry-after') ?? '');
  final serverMessage = switch (detail) {
    final String value when value.trim().isNotEmpty => value.trim(),
    final Map value => value['message'] as String?,
    _ => json['message'] as String?,
  };
  final validationMessage = _validationErrorMessage(detail);
  final message =
      serverMessage ??
      validationMessage ??
      switch (code) {
        'authorization_pending' => '等待在浏览器中完成授权',
        'slow_down' => '授权查询过于频繁，请稍后重试',
        'expired_token' => '授权请求已过期，请重新开始',
        _ => null,
      } ??
      switch (statusCode) {
        400 => '提交的信息有误，请检查后重试',
        401 => '登录状态已失效，请重新登录',
        403 => '当前账号无权执行此操作',
        404 => '请求的账号功能暂不可用',
        409 => '该邮箱或用户名已被使用',
        413 => '上传的文件过大',
        415 => '不支持该文件格式',
        422 => '提交的信息不符合要求，请检查后重试',
        429 => '操作过于频繁，请稍后再试',
        final code when code != null && code >= 500 && code <= 599 =>
          '账号服务暂时不可用，请稍后再试',
        _
            when error.type == DioExceptionType.connectionTimeout ||
                error.type == DioExceptionType.receiveTimeout ||
                error.type == DioExceptionType.sendTimeout =>
          '连接账号服务超时，请检查网络后重试',
        _ => '无法连接账号服务，请检查网络后重试',
      };
  return MemberAccountException(
    message,
    statusCode: statusCode,
    code: code,
    retryAfter: retryAfter,
  );
}

String? _validationErrorMessage(Object? detail) {
  if (detail is! List) return null;
  for (final violation in detail) {
    if (violation is! Map) continue;
    final location = violation['loc'];
    if (location is! List) continue;
    final field = location.whereType<String>().lastOrNull;
    switch (field) {
      case 'email':
        return '邮箱格式不正确，请检查后重试';
      case 'username':
        return '用户名不符合要求，请使用 3-30 位小写字母、数字或下划线';
      case 'password':
        return '密码不符合要求，请使用 12-128 位字符';
      case 'code':
      case 'challenge_id':
        return '验证码无效或已过期，请重新获取';
    }
  }
  return null;
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : const {};

String? _optionalText(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
