import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/account/account_page.dart';
import 'package:xxread/services/account/account.dart';

Future<MemberAccountController> _openDeletionFlow(
  WidgetTester tester,
  _DeletionAdapter adapter,
  _DeletionTokenStore tokenStore,
) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = MemberAccountController(
    api: MemberAccountApiClient(
      dio: Dio()..httpClientAdapter = adapter,
      tokenStore: tokenStore,
    ),
  );
  await tester.runAsync(controller.initialize);

  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const AccountPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('account-security')),
    500,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.byKey(const ValueKey('account-security')));
  await tester.pumpAndSettle();

  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('account-delete-entry')),
    500,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.byKey(const ValueKey('account-delete-entry')));
  await tester.pumpAndSettle();
  return controller;
}

/// Deleting spans a request, a token wipe, a cache wipe and a dialog. Pump a few
/// frames so each hop lands before settling.
Future<void> _settleRequest(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

Future<void> _acceptTermsAndSendCode(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('account-delete-consent')),
    500,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.byKey(const ValueKey('account-delete-consent')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('account-delete-continue')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('account-delete-send-code')));
  await tester.pumpAndSettle();
}

void main() {
  // The controller clears its summary cache while deleting. Without an in-memory
  // backend that platform channel never answers under the test's fake clock.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('deletion opens on the terms and states every consequence', (
    tester,
  ) async {
    final adapter = _DeletionAdapter(applePurchase: true, premium: true);
    await _openDeletionFlow(tester, adapter, _DeletionTokenStore());

    expect(find.text('注销后会发生什么'), findsOneWidget);
    expect(find.text('注销条款'), findsOneWidget);
    expect(find.textContaining('账号注销不可撤销、不可恢复'), findsOneWidget);
    expect(find.textContaining('高级版权益会被删除'), findsOneWidget);
    // A member who paid on the App Store must be told the purchase survives.
    expect(find.textContaining('恢复购买'), findsOneWidget);
    expect(find.textContaining('本来就只保存在你的设备里'), findsOneWidget);
    expect(find.text('高级版已解锁（将被移除）'), findsOneWidget);
    expect(find.textContaining('2 个已登录设备'), findsOneWidget);
    expect(adapter.deletions, isEmpty);
  });

  testWidgets('the terms step will not advance until consent is given', (
    tester,
  ) async {
    await _openDeletionFlow(tester, _DeletionAdapter(), _DeletionTokenStore());

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('account-delete-continue')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    final blocked = tester.widget<FilledButton>(
      find.byKey(const ValueKey('account-delete-continue')),
    );
    expect(blocked.onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('account-delete-consent')));
    await tester.pumpAndSettle();
    final allowed = tester.widget<FilledButton>(
      find.byKey(const ValueKey('account-delete-continue')),
    );
    expect(allowed.onPressed, isNotNull);
  });

  testWidgets('a mistyped address never reaches the deletion endpoint', (
    tester,
  ) async {
    final adapter = _DeletionAdapter();
    await _openDeletionFlow(tester, adapter, _DeletionTokenStore());
    await _acceptTermsAndSendCode(tester);

    expect(find.text('最后一步'), findsOneWidget);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '123456');
    await tester.enterText(fields.at(1), 'someone-else@example.com');
    await tester.tap(find.byKey(const ValueKey('account-delete-submit')));
    await _settleRequest(tester);

    expect(adapter.deletions, isEmpty);
    expect(find.textContaining('不一致'), findsOneWidget);
  });

  testWidgets('the third step deletes the account and clears local tokens', (
    tester,
  ) async {
    final adapter = _DeletionAdapter();
    final tokenStore = _DeletionTokenStore();
    await _openDeletionFlow(tester, adapter, tokenStore);
    await _acceptTermsAndSendCode(tester);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '123456');
    await tester.enterText(fields.at(1), 'reader@example.com');
    await tester.tap(find.byKey(const ValueKey('account-delete-submit')));
    await _settleRequest(tester);

    expect(adapter.deletions, hasLength(1));
    expect(adapter.deletions.single, {
      'challenge_id': 'deletion-challenge',
      'code': '123456',
      'confirmation': 'reader@example.com',
      'acknowledged': true,
    });
    expect(find.byKey(const ValueKey('account-delete-done')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('account-delete-apple-manual-revocation')),
      findsNothing,
    );
    expect(tokenStore.accessToken, isNull);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    // Every account screen read a member that no longer exists.
    expect(find.byKey(const ValueKey('account-delete-submit')), findsNothing);
  });

  testWidgets(
    'remote deletion remains successful when secure token cleanup fails',
    (tester) async {
      final adapter = _DeletionAdapter();
      final tokenStore = _DeletionTokenStore(failClear: true);
      final controller = await _openDeletionFlow(tester, adapter, tokenStore);
      await _acceptTermsAndSendCode(tester);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '123456');
      await tester.enterText(fields.at(1), 'reader@example.com');
      await tester.tap(find.byKey(const ValueKey('account-delete-submit')));
      await _settleRequest(tester);

      expect(adapter.deletions, hasLength(1));
      expect(controller.isAuthenticated, isFalse);
      expect(find.byKey(const ValueKey('account-delete-done')), findsOneWidget);
      expect(controller.error, contains('本地登录信息清理失败'));
      expect(tokenStore.accessToken, 'access-token');

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本地登录信息清理失败'), findsOneWidget);
    },
  );

  testWidgets('failed remote deletion preserves the signed-in session', (
    tester,
  ) async {
    final adapter = _DeletionAdapter(deletionStatus: 400);
    final tokenStore = _DeletionTokenStore();
    final controller = await _openDeletionFlow(tester, adapter, tokenStore);
    await _acceptTermsAndSendCode(tester);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '000000');
    await tester.enterText(fields.at(1), 'reader@example.com');
    await tester.tap(find.byKey(const ValueKey('account-delete-submit')));
    await _settleRequest(tester);

    expect(adapter.deletions, hasLength(1));
    expect(controller.isAuthenticated, isTrue);
    expect(tokenStore.accessToken, 'access-token');
    expect(find.byKey(const ValueKey('account-delete-done')), findsNothing);
    expect(find.byKey(const ValueKey('account-delete-submit')), findsOneWidget);
  });

  testWidgets('legacy Apple deletion asks for Apple sign-in before retry', (
    tester,
  ) async {
    final adapter = _DeletionAdapter(
      deletionStatus: 409,
      deletionErrorCode: 'appleReauthenticationRequired',
    );
    final controller = await _openDeletionFlow(
      tester,
      adapter,
      _DeletionTokenStore(),
    );
    await _acceptTermsAndSendCode(tester);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '123456');
    await tester.enterText(fields.at(1), 'reader@example.com');
    await tester.tap(find.byKey(const ValueKey('account-delete-submit')));
    await _settleRequest(tester);

    expect(controller.isAuthenticated, isTrue);
    expect(find.textContaining('重新使用 Apple 登录'), findsOneWidget);
    expect(find.byKey(const ValueKey('account-delete-done')), findsNothing);
  });

  testWidgets('legacy Apple deletion shows manual authorization removal', (
    tester,
  ) async {
    final adapter = _DeletionAdapter(appleManualRevocationRequired: true);
    final controller = await _openDeletionFlow(
      tester,
      adapter,
      _DeletionTokenStore(),
    );
    await _acceptTermsAndSendCode(tester);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '123456');
    await tester.enterText(fields.at(1), 'reader@example.com');
    await tester.tap(find.byKey(const ValueKey('account-delete-submit')));
    await _settleRequest(tester);

    expect(controller.isAuthenticated, isFalse);
    expect(find.byKey(const ValueKey('account-delete-done')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('account-delete-apple-manual-revocation')),
      findsOneWidget,
    );
    expect(find.textContaining('停止使用 Apple 登录'), findsOneWidget);
  });

  testWidgets('an admin owner is told to hand over ownership instead', (
    tester,
  ) async {
    final adapter = _DeletionAdapter(deletable: false);
    await _openDeletionFlow(tester, adapter, _DeletionTokenStore());

    expect(find.text('这个账号暂时不能注销'), findsOneWidget);
    expect(find.textContaining('移交给其他人'), findsOneWidget);
    expect(find.byKey(const ValueKey('account-delete-consent')), findsNothing);
    expect(find.byKey(const ValueKey('account-delete-continue')), findsNothing);
  });

  testWidgets('an account with two-factor on asks for the second code too', (
    tester,
  ) async {
    final adapter = _DeletionAdapter(mfaRequired: true);
    await _openDeletionFlow(tester, adapter, _DeletionTokenStore());
    await _acceptTermsAndSendCode(tester);

    expect(find.textContaining('已开启双重验证'), findsOneWidget);
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), '123456');
    await tester.enterText(fields.at(1), '654321');
    await tester.enterText(fields.at(2), 'reader@example.com');
    await tester.tap(find.byKey(const ValueKey('account-delete-submit')));
    await _settleRequest(tester);

    expect(adapter.deletions.single['mfa_code'], '654321');
  });
}

class _DeletionAdapter implements HttpClientAdapter {
  _DeletionAdapter({
    this.deletable = true,
    this.premium = false,
    this.applePurchase = false,
    this.mfaRequired = false,
    this.deletionStatus = 200,
    this.deletionErrorCode,
    this.appleManualRevocationRequired = false,
  });

  final bool deletable;
  final bool premium;
  final bool applePurchase;
  final bool mfaRequired;
  final int deletionStatus;
  final String? deletionErrorCode;
  final bool appleManualRevocationRequired;
  final List<Map<String, dynamic>> deletions = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = switch (options.uri.path) {
      '/api/v1/auth/config' => {
        'providers': <String, bool>{},
        'username': {'min_length': 3, 'max_length': 30},
        'password': {'min_length': 12, 'max_length': 128},
      },
      '/api/v1/membership/config' => {
        'product': 'premium_lifetime',
        'features': <String>[],
      },
      '/api/v1/auth/me' => {
        'mfa_required': false,
        'user': {
          'id': '6e29be31-ffeb-4699-bf69-8b37afe15504',
          'email': 'reader@example.com',
          'email_verified': true,
          'username': 'reader',
          'display_name': 'Reader',
          'effective_name': 'Reader',
          'avatar_url': null,
          'auth_methods': ['password'],
          'created_at': '2026-08-03T00:00:00Z',
        },
      },
      '/api/v1/membership' => {
        'premium': premium,
        'features': <String, bool>{},
        'entitlements': <Object>[],
      },
      '/api/v1/membership/referral' => {
        'invite_code': 'OR-MY-CODE',
        'invite_url': 'https://open.xxread.top/account?invite=OR-MY-CODE',
        'stats': {'invited': 0, 'rewarded': 0},
        'inviter': null,
      },
      '/api/v1/auth/security/mfa/status' => {
        'enabled': mfaRequired,
        'recovery_codes_remaining': 0,
      },
      '/api/v1/auth/security/deletion/preview' => {
        'email': 'reader@example.com',
        'username': 'reader',
        'created_at': '2026-08-03T00:00:00Z',
        'confirmation_phrase': 'reader@example.com',
        'deletable': deletable,
        'blocked_reason': deletable ? null : 'owner',
        'premium': premium,
        'premium_sources': premium ? ['apple'] : <String>[],
        'apple_purchase': applePurchase,
        'mfa_required': mfaRequired,
        'counts': {
          'sessions': 2,
          'passkeys': 0,
          'oauth_identities': 0,
          'entitlements': premium ? 1 : 0,
          'redemptions': 0,
          'invited_members': 0,
          'apple_purchases': applePurchase ? 1 : 0,
        },
      },
      '/api/v1/auth/security/deletion/code' => {
        'challenge_id': 'deletion-challenge',
        'expires_in': 600,
      },
      '/api/v1/auth/security/deletion' => () {
        deletions.add(Map<String, dynamic>.from(options.data as Map));
        return deletionErrorCode == null
            ? {
                'deleted': true,
                'premium_removed': premium,
                'apple_manual_revocation_required':
                    appleManualRevocationRequired,
              }
            : {
                'detail': {'code': deletionErrorCode},
              };
      }(),
      _ => throw StateError('Unexpected route ${options.uri.path}'),
    };
    return ResponseBody.fromString(
      jsonEncode(body),
      options.uri.path == '/api/v1/auth/security/deletion'
          ? deletionStatus
          : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

class _DeletionTokenStore implements MemberTokenStore {
  _DeletionTokenStore({this.failClear = false});

  final bool failClear;
  String? accessToken = 'access-token';
  String? refreshToken = 'refresh-token';

  @override
  Future<void> clear() async {
    if (failClear) throw StateError('secure storage unavailable');
    accessToken = null;
    refreshToken = null;
  }

  @override
  Future<String?> readAccessToken() async => accessToken;

  @override
  Future<bool> readMfaPending() async => false;

  @override
  Future<String?> readRefreshToken() async => refreshToken;

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    bool mfaPending = false,
  }) async {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
  }
}
