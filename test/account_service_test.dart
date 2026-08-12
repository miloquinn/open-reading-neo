import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/services/account/account.dart';

void main() {
  test('account summary cache restores the settings card identity', () async {
    SharedPreferences.setMockInitialValues({});
    const cache = MemberAccountSummaryCache();
    const summary = MemberAccountSummary(
      userId: 'user-1',
      username: 'reader',
      effectiveName: 'Reader',
      avatarUrl: 'https://open.xxread.top/avatar.jpg',
      premium: true,
    );

    await cache.save(summary);
    final restored = await cache.load();

    expect(restored?.userId, 'user-1');
    expect(restored?.effectiveName, 'Reader');
    expect(restored?.premium, isTrue);
  });

  test('invalid account summary cache is ignored safely', () async {
    SharedPreferences.setMockInitialValues({
      MemberAccountSummaryCache.storageKey: '{broken-json',
    });

    expect(await const MemberAccountSummaryCache().load(), isNull);
  });

  test(
    'password login stores the rotated session without exposing secrets',
    () async {
      final storage = _MemoryTokenStore();
      final adapter = _RouteAdapter((options) {
        expect(options.uri.path, '/api/v1/auth/password/login');
        expect(options.data, {
          'email': 'reader@example.com',
          'password': 'secret',
        });
        return _json(_session(access: 'access-1', refresh: 'refresh-1'));
      });
      final client = _client(adapter, storage);

      final session = await client.loginPassword(
        'reader@example.com',
        'secret',
      );

      expect(session.user.username, 'reader');
      expect(storage.accessToken, 'access-1');
      expect(storage.refreshToken, 'refresh-1');
      expect(session.toString(), isNot(contains('access-1')));
    },
  );

  test('registration validation errors explain the invalid field', () async {
    final storage = _MemoryTokenStore();
    final adapter = _RouteAdapter((options) {
      expect(options.uri.path, '/api/v1/auth/password/register');
      return _json({
        'detail': [
          {
            'type': 'value_error',
            'loc': ['body', 'code'],
            'msg': 'invalid verification code',
          },
        ],
      }, status: 422);
    });
    final client = _client(adapter, storage);

    await expectLater(
      client.registerPassword(
        email: 'reader@example.com',
        challengeId: 'challenge-1',
        code: '123456',
        username: 'reader',
        password: 'a secure password',
      ),
      throwsA(
        isA<MemberAccountException>().having(
          (error) => error.message,
          'message',
          '验证码无效或已过期，请重新获取',
        ),
      ),
    );
  });

  test(
    'email validation errors are not reported as connection failures',
    () async {
      final storage = _MemoryTokenStore();
      final adapter = _RouteAdapter((options) {
        expect(options.uri.path, '/api/v1/auth/password/register/code');
        return _json({
          'detail': [
            {
              'type': 'value_error',
              'loc': ['body', 'email'],
              'msg': 'not a valid email address',
            },
          ],
        }, status: 422);
      });
      final client = _client(adapter, storage);

      await expectLater(
        client.requestCode('not-an-email', MemberEmailCodePurpose.registration),
        throwsA(
          isA<MemberAccountException>().having(
            (error) => error.message,
            'message',
            '邮箱格式不正确，请检查后重试',
          ),
        ),
      );
    },
  );

  test(
    'apple login posts the identity token and stores the rotated session',
    () async {
      final storage = _MemoryTokenStore();
      final adapter = _RouteAdapter((options) {
        expect(options.uri.path, '/api/v1/auth/apple/login');
        expect(options.data, {
          'identity_token': 'apple-identity-token',
          'full_name': 'Jamie Reader',
        });
        return _json(
          _session(access: 'access-apple', refresh: 'refresh-apple'),
        );
      });
      final client = _client(adapter, storage);

      final session = await client.loginApple(
        identityToken: 'apple-identity-token',
        fullName: 'Jamie Reader',
      );

      expect(session.user.username, 'reader');
      expect(storage.accessToken, 'access-apple');
      expect(storage.refreshToken, 'refresh-apple');
    },
  );

  test('apple login omits full_name when not provided', () async {
    final storage = _MemoryTokenStore();
    final adapter = _RouteAdapter((options) {
      expect(options.data, {'identity_token': 'apple-identity-token'});
      return _json(_session(access: 'access-apple', refresh: 'refresh-apple'));
    });
    final client = _client(adapter, storage);

    await client.loginApple(identityToken: 'apple-identity-token');
  });

  test(
    '401 refreshes once, rotates tokens, and retries me with new access',
    () async {
      final storage = _MemoryTokenStore(
        accessToken: 'expired-access',
        refreshToken: 'refresh-1',
      );
      var meCalls = 0;
      final adapter = _RouteAdapter((options) {
        if (options.uri.path == '/api/v1/auth/me') {
          meCalls++;
          final token = options.headers['Authorization'];
          if (token == 'Bearer expired-access') {
            return _json({'detail': '登录状态已失效'}, status: 401);
          }
          expect(token, 'Bearer access-2');
          return _json({'user': _user()});
        }
        expect(options.uri.path, '/api/v1/auth/refresh');
        expect(options.data, {'refresh_token': 'refresh-1'});
        expect(options.headers['Authorization'], isNull);
        return _json(_session(access: 'access-2', refresh: 'refresh-2'));
      });
      final client = _client(adapter, storage);

      final user = await client.currentUser();

      expect(user.email, 'reader@example.com');
      expect(meCalls, 2);
      expect(storage.accessToken, 'access-2');
      expect(storage.refreshToken, 'refresh-2');
    },
  );

  test(
    'controller initializes anonymously with provider and support config',
    () async {
      final storage = _MemoryTokenStore();
      final adapter = _RouteAdapter((options) {
        return switch (options.uri.path) {
          '/api/v1/auth/config' => _json({
            'providers': {'google': true, 'github': false, 'passkey': true},
            'username': {'min_length': 3, 'max_length': 30},
            'password': {'min_length': 12, 'max_length': 128},
          }),
          '/api/v1/membership/config' => _json({
            'product': 'premium_lifetime',
            'purchase_url': '/support',
            'features': ['webdav_sync'],
          }),
          _ => throw StateError('Unexpected route ${options.uri.path}'),
        };
      });
      final controller = MemberAccountController(
        api: _client(adapter, storage),
      );

      await controller.initialize();

      expect(controller.initialized, isTrue);
      expect(controller.loading, isFalse);
      expect(controller.isAuthenticated, isFalse);
      expect(controller.providers.google, isTrue);
      expect(controller.providers.passkey, isTrue);
      expect(
        controller.membershipConfig?.purchaseUrl,
        'https://open.xxread.top/support',
      );
      expect(controller.error, isNull);
    },
  );

  test(
    'failed initialization clears cached identity and can retry provider config',
    () async {
      SharedPreferences.setMockInitialValues({});
      const cache = MemberAccountSummaryCache();
      await cache.save(
        const MemberAccountSummary(
          userId: 'stale-user',
          username: 'stale',
          effectiveName: 'Stale Reader',
          premium: true,
        ),
      );
      var online = false;
      final adapter = _RouteAdapter((options) {
        if (!online) throw const SocketException('offline');
        return switch (options.uri.path) {
          '/api/v1/auth/config' => _json({
            'providers': {
              'apple': true,
              'google': true,
              'github': true,
              'passkey': true,
            },
            'username': {'min_length': 3, 'max_length': 30},
            'password': {'min_length': 12, 'max_length': 128},
          }),
          '/api/v1/membership/config' => _json({
            'product': 'premium_lifetime',
            'purchase_url': '/support',
            'features': <String>[],
          }),
          _ => throw StateError('Unexpected route ${options.uri.path}'),
        };
      });
      final controller = MemberAccountController(
        api: _client(adapter, _MemoryTokenStore()),
        summaryCache: cache,
      );

      await expectLater(
        controller.initialize(),
        throwsA(isA<MemberAccountException>()),
      );

      expect(controller.initialized, isFalse);
      expect(controller.summary, isNull);
      expect(await cache.load(), isNull);
      expect(controller.isAuthenticated, isFalse);

      online = true;
      await controller.initialize();

      expect(controller.initialized, isTrue);
      expect(controller.providers.apple, isTrue);
      expect(controller.providers.google, isTrue);
      expect(controller.providers.github, isTrue);
      expect(controller.providers.passkey, isTrue);
      expect(controller.isAuthenticated, isFalse);
    },
  );

  test('referral API loads and binds a single invite code', () async {
    final storage = _MemoryTokenStore(
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
    );
    var bound = false;
    final adapter = _RouteAdapter((options) {
      expect(options.headers['Authorization'], 'Bearer access-1');
      if (options.uri.path == '/api/v1/membership/referral/bind') {
        expect(options.method, 'POST');
        expect(options.data, {'code': 'ORFRIEND1'});
        bound = true;
      }
      return _json({
        'invite_code': 'ORMYCODE1',
        'invite_url': 'https://open.xxread.top/account?invite=ORMYCODE1',
        'inviter': bound
            ? {'code': 'ORFRIEND1', 'name': 'Friend', 'status': 'bound'}
            : null,
        'stats': {'invited': 2, 'rewarded': 1},
        'recent_invites': [
          {
            'name': 'New Reader',
            'status': 'rewarded',
            'bound_at': '2026-08-03T00:00:00Z',
            'rewarded_at': '2026-08-04T00:00:00Z',
          },
        ],
      });
    });
    final client = _client(adapter, storage);

    final before = await client.referral();
    final after = await client.bindReferral('ORFRIEND1');

    expect(before.inviteCode, 'ORMYCODE1');
    expect(before.inviteUrl.host, 'open.xxread.top');
    expect(before.rewardedCount, 1);
    expect(before.recentInvites.single.name, 'New Reader');
    expect(after.inviter?.code, 'ORFRIEND1');
    expect(after.inviter?.status, 'bound');
  });

  test('device authorization reports pending then completes login', () async {
    final storage = _MemoryTokenStore();
    var polls = 0;
    final adapter = _RouteAdapter((options) {
      return switch (options.uri.path) {
        '/api/v1/auth/device/github/begin' => _json({
          'device_code': 'device-secret',
          'user_code': 'ABCD-EFGH',
          'verification_uri': '/activate',
          'verification_uri_complete':
              'https://github.com/login/oauth/authorize?client_id=client-id&state=member_state.ABCD-EFGH',
          'expires_in': 600,
          'interval': 5,
        }),
        '/api/v1/auth/device/token' when polls++ == 0 => _json({
          'error': 'authorization_pending',
        }, status: 400),
        '/api/v1/auth/device/token' => _json(
          _session(access: 'access-2', refresh: 'refresh-2'),
        ),
        '/api/v1/membership' => _json({
          'premium': false,
          'features': <String, bool>{},
          'entitlements': <Object>[],
        }),
        _ => throw StateError('Unexpected route ${options.uri.path}'),
      };
    });
    final controller = MemberAccountController(api: _client(adapter, storage));

    final authorization = await controller.beginExternalLogin(
      MemberExternalAuthMethod.github,
    );
    expect(
      authorization.verificationUri.toString(),
      'https://open.xxread.top/activate',
    );
    expect(
      authorization.verificationUriComplete.toString(),
      'https://github.com/login/oauth/authorize?client_id=client-id&state=member_state.ABCD-EFGH',
    );
    expect(await controller.pollDeviceAuthorization(authorization), isFalse);
    expect(await controller.pollDeviceAuthorization(authorization), isTrue);
    expect(controller.user?.username, 'reader');
    expect(storage.refreshToken, 'refresh-2');
  });

  test('concurrent device authorization polls share one completion', () async {
    final storage = _MemoryTokenStore();
    final responseGate = Completer<void>();
    final requestStarted = Completer<void>();
    var polls = 0;
    final adapter = _AsyncRouteAdapter((options) async {
      return switch (options.uri.path) {
        '/api/v1/auth/device/github/begin' => _json({
          'device_code': 'device-secret',
          'user_code': 'ABCD-EFGH',
          'verification_uri': '/activate',
          'expires_in': 600,
          'interval': 5,
        }),
        '/api/v1/auth/device/token' => () async {
          polls++;
          requestStarted.complete();
          await responseGate.future;
          return _json(_session(access: 'access-2', refresh: 'refresh-2'));
        }(),
        '/api/v1/membership' => _json({
          'premium': false,
          'features': <String, bool>{},
          'entitlements': <Object>[],
        }),
        _ => throw StateError('Unexpected route ${options.uri.path}'),
      };
    });
    final controller = MemberAccountController(api: _client(adapter, storage));
    final authorization = await controller.beginExternalLogin(
      MemberExternalAuthMethod.github,
    );

    final callbackPoll = controller.pollDeviceAuthorization(authorization);
    final pagePoll = controller.pollDeviceAuthorization(authorization);
    await requestStarted.future;

    expect(polls, 1);
    expect(controller.error, isNull);
    await expectLater(
      controller.pollDeviceAuthorization(
        DeviceAuthorization(
          method: MemberExternalAuthMethod.github,
          deviceCode: 'other-device',
          userCode: 'WXYZ-1234',
          verificationUri: Uri.https('open.xxread.top', '/activate'),
          expiresIn: 600,
          interval: 5,
        ),
      ),
      throwsA(
        isA<MemberAccountException>().having(
          (error) => error.message,
          'message',
          '账号操作正在进行，请稍候',
        ),
      ),
    );

    responseGate.complete();
    expect(await Future.wait([callbackPoll, pagePoll]), [isTrue, isTrue]);
    expect(controller.user?.username, 'reader');
    expect(controller.error, isNull);
  });

  test('API detail becomes a user-facing controller error', () async {
    final adapter = _RouteAdapter(
      (_) => _json({'detail': '邮箱或密码错误'}, status: 401),
    );
    final controller = MemberAccountController(
      api: _client(adapter, _MemoryTokenStore()),
    );

    await expectLater(
      controller.loginPassword('reader@example.com', 'wrong'),
      throwsA(
        isA<MemberAccountException>().having(
          (error) => error.message,
          'message',
          '邮箱或密码错误',
        ),
      ),
    );
    expect(controller.error, '邮箱或密码错误');
    expect(controller.loading, isFalse);
  });

  test(
    'device slow-down response preserves the required retry delay',
    () async {
      final adapter = _RouteAdapter(
        (_) => _json({'error': 'slow_down', 'retry_after': 12}, status: 400),
      );
      final client = _client(adapter, _MemoryTokenStore());
      final authorization = DeviceAuthorization(
        method: MemberExternalAuthMethod.google,
        deviceCode: 'device-secret',
        userCode: 'ABCD-EFGH',
        verificationUri: Uri.https('open.xxread.top', '/activate'),
        expiresIn: 600,
        interval: 5,
      );

      await expectLater(
        client.pollDeviceAuthorization(authorization),
        throwsA(
          isA<MemberAccountException>()
              .having((error) => error.code, 'code', 'slow_down')
              .having((error) => error.retryAfter, 'retryAfter', 12),
        ),
      );
    },
  );

  test(
    'MFA-pending login stays in memory until verification rotates tokens',
    () async {
      final storage = _MemoryTokenStore();
      final adapter = _RouteAdapter((options) {
        return switch (options.uri.path) {
          '/api/v1/auth/password/login' => _json(
            _session(
              access: 'pending-access',
              refresh: 'pending-refresh',
              mfaRequired: true,
            ),
          ),
          '/api/v1/auth/mfa/verify' => () {
            expect(options.headers['Authorization'], 'Bearer pending-access');
            expect(options.data, {'code': '123456'});
            return _json(_session(access: 'access-2', refresh: 'refresh-2'));
          }(),
          '/api/v1/membership' => _json({
            'premium': false,
            'features': <String, bool>{},
            'entitlements': <Object>[],
          }),
          _ => throw StateError('Unexpected route ${options.uri.path}'),
        };
      });
      final controller = MemberAccountController(
        api: _client(adapter, storage),
      );

      await controller.loginPassword('reader@example.com', 'secret');

      expect(controller.mfaRequired, isTrue);
      expect(controller.isAuthenticated, isFalse);
      expect(controller.user, isNull);
      expect(controller.pendingUser?.email, 'reader@example.com');
      expect(storage.accessToken, 'pending-access');
      expect(storage.refreshToken, 'pending-refresh');
      expect(storage.mfaPending, isTrue);

      await controller.verifyMfa('123456');

      expect(controller.mfaRequired, isFalse);
      expect(controller.isAuthenticated, isTrue);
      expect(controller.pendingUser, isNull);
      expect(storage.accessToken, 'access-2');
      expect(storage.refreshToken, 'refresh-2');
      expect(storage.mfaPending, isFalse);
    },
  );

  test(
    'controller restores a pending MFA session from me without refreshing',
    () async {
      final storage = _MemoryTokenStore(
        accessToken: 'pending-access',
        refreshToken: 'pending-refresh',
        mfaPending: true,
      );
      final adapter = _RouteAdapter((options) {
        return switch (options.uri.path) {
          '/api/v1/auth/config' => _json({
            'providers': <String, bool>{},
            'username': {'min_length': 3, 'max_length': 30},
            'password': {'min_length': 12, 'max_length': 128},
          }),
          '/api/v1/membership/config' => _json({
            'product': 'premium_lifetime',
            'features': <String>[],
          }),
          '/api/v1/auth/me' => () {
            expect(options.headers['Authorization'], 'Bearer pending-access');
            return _json({'user': _user(), 'mfa_required': true});
          }(),
          _ => throw StateError('Unexpected route ${options.uri.path}'),
        };
      });
      final controller = MemberAccountController(
        api: _client(adapter, storage),
      );

      await controller.initialize();

      expect(controller.initialized, isTrue);
      expect(controller.mfaRequired, isTrue);
      expect(controller.pendingUser?.username, 'reader');
      expect(controller.user, isNull);
      expect(storage.accessToken, 'pending-access');
      expect(storage.refreshToken, 'pending-refresh');
      expect(storage.mfaPending, isTrue);
    },
  );

  test('pending refresh is rejected without clearing its tokens', () async {
    final storage = _MemoryTokenStore(
      accessToken: 'pending-access',
      refreshToken: 'pending-refresh',
      mfaPending: true,
    );
    final client = _client(
      _RouteAdapter(
        (options) => throw StateError('Unexpected route ${options.uri.path}'),
      ),
      storage,
    );

    await expectLater(
      client.refreshSession(),
      throwsA(
        isA<MemberAccountException>().having(
          (error) => error.code,
          'code',
          'mfa_required',
        ),
      ),
    );
    expect(storage.accessToken, 'pending-access');
    expect(storage.refreshToken, 'pending-refresh');
    expect(storage.mfaPending, isTrue);
  });

  test(
    'security endpoints use bearer auth and exact request payloads',
    () async {
      final storage = _MemoryTokenStore(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
      );
      var step = 0;
      final adapter = _RouteAdapter((options) {
        expect(options.headers['Authorization'], 'Bearer access-1');
        step++;
        return switch (options.uri.path) {
          '/api/v1/auth/security/email/code' => () {
            expect(options.data, {'new_email': 'new@example.com'});
            return _json({
              'current': {'challenge_id': 'current-id', 'expires_in': 600},
              'new': {'challenge_id': 'new-id', 'expires_in': 580},
              'message': 'sent',
            });
          }(),
          '/api/v1/auth/security/password/code' => _json({
            'challenge_id': 'password-id',
            'expires_in': 600,
          }),
          '/api/v1/auth/security/mfa/status' => _json({
            'enabled': false,
            'recovery_codes_remaining': 0,
          }),
          '/api/v1/auth/security/mfa/setup/code' => _json({
            'challenge_id': 'mfa-id',
            'expires_in': 600,
          }),
          '/api/v1/auth/security/mfa/setup' => () {
            expect(options.data, {'challenge_id': 'mfa-id', 'code': '111111'});
            return _json({
              'secret': 'BASE32SECRET',
              'otpauth_uri': 'otpauth://totp/OpenReading:test',
            });
          }(),
          '/api/v1/auth/security/mfa/confirm' => () {
            expect(options.data, {'code': '222222'});
            return _json({
              'enabled': true,
              'recovery_codes': ['recovery-one', 'recovery-two'],
            });
          }(),
          '/api/v1/auth/security/mfa/disable' => () {
            expect(options.data, {'code': 'recovery-one'});
            return _json({'enabled': false});
          }(),
          _ => throw StateError('Unexpected route ${options.uri.path}'),
        };
      });
      final client = _client(adapter, storage);

      final email = await client.requestEmailChangeCode(' new@example.com ');
      final password = await client.requestPasswordChangeCode();
      final status = await client.mfaStatus();
      final mfaChallenge = await client.requestMfaSetupCode();
      final setup = await client.setupMfa(
        challengeId: mfaChallenge.id,
        code: '111111',
      );
      final confirmation = await client.confirmMfa('222222');
      await client.disableMfa('recovery-one');

      expect(email.currentChallengeId, 'current-id');
      expect(email.newChallengeId, 'new-id');
      expect(email.expiresIn, 580);
      expect(password.id, 'password-id');
      expect(status.enabled, isFalse);
      expect(setup.secret, 'BASE32SECRET');
      expect(confirmation.recoveryCodes, ['recovery-one', 'recovery-two']);
      expect(step, 7);
    },
  );

  test(
    'email and password changes rotate sessions with exact payloads',
    () async {
      final storage = _MemoryTokenStore(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
      );
      final adapter = _RouteAdapter((options) {
        return switch (options.uri.path) {
          '/api/v1/auth/security/email/change' => () {
            expect(options.headers['Authorization'], 'Bearer access-1');
            expect(options.data, {
              'new_email': 'new@example.com',
              'current_challenge_id': 'current-id',
              'current_code': '111111',
              'new_challenge_id': 'new-id',
              'new_code': '222222',
            });
            return _json(_session(access: 'access-2', refresh: 'refresh-2'));
          }(),
          '/api/v1/auth/security/password/change' => () {
            expect(options.headers['Authorization'], 'Bearer access-2');
            expect(options.data, {
              'challenge_id': 'password-id',
              'code': '333333',
              'password': 'new-secure-password',
            });
            return _json(_session(access: 'access-3', refresh: 'refresh-3'));
          }(),
          _ => throw StateError('Unexpected route ${options.uri.path}'),
        };
      });
      final client = _client(adapter, storage);

      await client.changeEmail(
        newEmail: 'new@example.com',
        currentChallengeId: 'current-id',
        currentCode: '111111',
        newChallengeId: 'new-id',
        newCode: '222222',
      );
      await client.changePassword(
        challengeId: 'password-id',
        code: '333333',
        password: 'new-secure-password',
      );

      expect(storage.accessToken, 'access-3');
      expect(storage.refreshToken, 'refresh-3');
      expect(storage.mfaPending, isFalse);
    },
  );

  test('avatar upload evicts the old URL even when URL is unchanged', () async {
    final storage = _MemoryTokenStore(
      accessToken: 'access-1',
      refreshToken: 'refresh-1',
    );
    final directory = await Directory.systemTemp.createTemp('avatar-evict-');
    addTearDown(() => directory.delete(recursive: true));
    var avatarDownloads = 0;
    final avatarCache = AccountAvatarCache(
      cacheDirectory: directory,
      loader: (_) async => Uint8List.fromList([++avatarDownloads]),
    );
    final avatarUri = Uri.parse(
      'https://open.xxread.top/api/v1/auth/users/6e29be31-ffeb-4699-bf69-8b37afe15504/avatar?v=1',
    );
    final adapter = _RouteAdapter((options) {
      return switch (options.uri.path) {
        '/api/v1/auth/config' => _json({
          'providers': <String, bool>{},
          'username': {'min_length': 3, 'max_length': 30},
          'password': {'min_length': 12, 'max_length': 128},
        }),
        '/api/v1/membership/config' => _json({
          'product': 'premium_lifetime',
          'features': <String>[],
        }),
        '/api/v1/auth/me' => _json({'user': _user()}),
        '/api/v1/membership' => _json({
          'premium': false,
          'features': <String, bool>{},
          'entitlements': <Object>[],
        }),
        '/api/v1/auth/avatar' => _json({'user': _user()}),
        _ => throw StateError('Unexpected route ${options.uri.path}'),
      };
    });
    final controller = MemberAccountController(
      api: _client(adapter, storage),
      avatarCache: avatarCache,
    );
    await controller.initialize();
    expect(await avatarCache.load(avatarUri), [1]);

    await controller.uploadAvatar(
      AvatarUploadData(
        bytes: Uint8List.fromList([1, 2, 3]),
        filename: 'avatar.jpg',
        contentType: 'image/jpeg',
      ),
    );

    expect(await avatarCache.load(avatarUri), [2]);
    expect(avatarDownloads, 2);
  });
}

MemberAccountApiClient _client(
  HttpClientAdapter adapter,
  MemberTokenStore storage,
) {
  final dio = Dio()..httpClientAdapter = adapter;
  return MemberAccountApiClient(dio: dio, tokenStore: storage);
}

Map<String, dynamic> _session({
  required String access,
  required String refresh,
  bool mfaRequired = false,
}) => {
  'token_type': 'bearer',
  'access_token': access,
  'refresh_token': refresh,
  'access_expires_in': 900,
  'refresh_expires_in': 2592000,
  'mfa_required': mfaRequired,
  'user': _user(),
};

Map<String, dynamic> _user() => {
  'id': '6e29be31-ffeb-4699-bf69-8b37afe15504',
  'email': 'reader@example.com',
  'email_verified': true,
  'username': 'reader',
  'display_name': 'Reader',
  'effective_name': 'Reader',
  'avatar_url':
      '/api/v1/auth/users/6e29be31-ffeb-4699-bf69-8b37afe15504/avatar?v=1',
  'auth_methods': ['password'],
  'created_at': '2026-08-03T00:00:00Z',
};

ResponseBody _json(Map<String, dynamic> body, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

class _RouteAdapter implements HttpClientAdapter {
  _RouteAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);
}

class _AsyncRouteAdapter implements HttpClientAdapter {
  _AsyncRouteAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);
}

class _MemoryTokenStore implements MemberTokenStore {
  _MemoryTokenStore({
    this.accessToken,
    this.refreshToken,
    this.mfaPending = false,
  });

  String? accessToken;
  String? refreshToken;
  bool mfaPending;

  @override
  Future<void> clear() async {
    accessToken = null;
    refreshToken = null;
    mfaPending = false;
  }

  @override
  Future<String?> readAccessToken() async => accessToken;

  @override
  Future<String?> readRefreshToken() async => refreshToken;

  @override
  Future<bool> readMfaPending() async => mfaPending;

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    bool mfaPending = false,
  }) async {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    this.mfaPending = mfaPending;
  }
}
