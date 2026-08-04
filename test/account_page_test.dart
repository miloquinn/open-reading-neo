import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/account/account_page.dart';
import 'package:xxread/services/account/account.dart';
import 'package:xxread/widgets/settings_account_card.dart';

void main() {
  testWidgets('guest account card opens the complete account center', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = MemberAccountController(
      api: MemberAccountApiClient(
        dio: Dio()..httpClientAdapter = _AccountAdapter(),
        tokenStore: _EmptyTokenStore(),
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
          home: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: SettingsAccountCard(),
            ),
          ),
        ),
      ),
    );

    expect(find.text('登录开元阅读'), findsOneWidget);
    expect(find.text('同步账号资料与安全设置'), findsOneWidget);
    final avatar = tester.widget<Container>(
      find.byKey(const ValueKey('settings-account-avatar')),
    );
    expect((avatar.decoration! as BoxDecoration).shape, BoxShape.circle);

    await tester.tap(find.byKey(const ValueKey('settings-account-card')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(AccountPage), findsOneWidget);
    expect(find.text('用户中心'), findsOneWidget);
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('邮箱'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
    expect(find.text('没有账号？注册'), findsOneWidget);
    expect(find.text('忘记密码'), findsOneWidget);
    expect(find.text('使用邮箱验证码登录'), findsNothing);
    expect(find.text('邮箱登录'), findsOneWidget);
    expect(find.text('GitHub 登录'), findsOneWidget);
    expect(find.text('使用 Passkey'), findsNothing);
    expect(find.text('更多登录方式'), findsOneWidget);
    expect(find.text('使用 Google'), findsNothing);
    expect(find.text('支持高级功能'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('account-open-register')));
    await tester.pump();
    expect(find.text('注册'), findsOneWidget);
    expect(find.byKey(const ValueKey('account-change-email')), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'reader@example.com');
    expect(find.text('reader@example.com'), findsOneWidget);
    await tester.tap(find.text('已有账号？返回登录'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('account-change-email')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('account-provider-github')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('account-provider-google')), findsNothing);
    expect(
      find.byKey(const ValueKey('account-provider-passkey')),
      findsNothing,
    );
    final signInCard = find.byKey(const ValueKey('account-sign-in-card'));
    expect(
      find.descendant(
        of: signInCard,
        matching: find.byKey(const ValueKey('account-provider-github')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: signInCard,
        matching: find.byKey(const ValueKey('account-more-providers')),
      ),
      findsOneWidget,
    );

    final emailTopLeft = tester.getTopLeft(find.text('邮箱'));
    final githubTopLeft = tester.getTopLeft(
      find.byKey(const ValueKey('account-provider-github')),
    );
    expect(emailTopLeft.dy, lessThan(githubTopLeft.dy));

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('account-more-providers')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('account-more-providers')));
    await tester.pump();
    expect(find.text('使用 Passkey'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('account-provider-passkey')),
      findsOneWidget,
    );
    expect(find.text('使用 Google'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('account-provider-google')),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField).first, 'reader@example.com');
    await tester.tap(find.byKey(const ValueKey('account-email-continue')));
    await tester.pump();

    expect(find.text('使用密码登录'), findsOneWidget);
    expect(find.text('使用邮箱验证码登录'), findsOneWidget);
    expect(find.text('reader@example.com'), findsOneWidget);
    expect(find.byKey(const ValueKey('account-change-email')), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pump();
    expect(find.text('支持高级功能'), findsNothing);
    expect(find.text('当前所有功能免费'), findsNothing);
  });

  testWidgets('premium member receives the exclusive account card', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = MemberAccountController(
      api: MemberAccountApiClient(
        dio: Dio()..httpClientAdapter = _SignedInAdapter(premium: true),
        tokenStore: _PageTokenStore()..mfaPending = false,
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
          home: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: SettingsAccountCard(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-account-premium-badge')),
      findsOneWidget,
    );
    expect(find.text('支持者'), findsOneWidget);
    expect(find.text('永久高级版已解锁'), findsOneWidget);
    expect(find.text('PREMIUM'), findsOneWidget);
    final avatar = tester.widget<Container>(
      find.byKey(const ValueKey('settings-account-avatar')),
    );
    final decoration = avatar.decoration! as BoxDecoration;
    expect(decoration.border, isNotNull);
    expect(decoration.boxShadow, isNotEmpty);
    expect(
      find.byKey(const ValueKey('settings-account-avatar-clip')),
      findsOneWidget,
    );
    final avatarCenter = tester.getCenter(
      find.byKey(const ValueKey('settings-account-avatar-clip')),
    );
    final fallbackCenter = tester.getCenter(
      find.byKey(const ValueKey('settings-account-avatar-fallback')),
    );
    expect(fallbackCenter.dx, avatarCenter.dx);
    expect(fallbackCenter.dy, avatarCenter.dy);
    expect((decoration.border! as Border).top.width, greaterThan(2));
  });

  testWidgets('pending MFA session shows only the compact verification gate', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = MemberAccountController(
      api: MemberAccountApiClient(
        dio: Dio()..httpClientAdapter = _PendingMfaAdapter(),
        tokenStore: _PageTokenStore(),
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
    await tester.pump();

    expect(find.text('双重验证'), findsOneWidget);
    expect(find.text('验证器动态码'), findsOneWidget);
    expect(find.byKey(const ValueKey('account-mfa-verify')), findsOneWidget);
    expect(find.text('注册'), findsNothing);
    expect(find.text('使用 GitHub'), findsNothing);
    expect(find.text('支持高级功能'), findsNothing);
  });

  testWidgets(
    'signed-in center keeps profile and security details tucked away',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final tokenStore = _PageTokenStore()..mfaPending = false;
      final controller = MemberAccountController(
        api: MemberAccountApiClient(
          dio: Dio()..httpClientAdapter = _SignedInAdapter(),
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

      expect(find.byType(ClipOval), findsOneWidget);
      expect(find.text('邀请好友'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-referral')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-support')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-invite-ticket')), findsNothing);
      expect(
        find.byKey(const ValueKey('account-redemption-code')),
        findsNothing,
      );
      expect(find.text('登录方式'), findsNothing);
      expect(find.text('更换邮箱'), findsNothing);
      expect(find.text('设置或更换密码'), findsNothing);
      expect(find.byKey(const ValueKey('account-mfa-setup')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('account-security')),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('账号安全'), findsOneWidget);
      expect(find.text('编辑资料'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('account-referral')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('account-invite-ticket')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('floating-subpage-back')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('floating-subpage-back')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('account-support')));
      await tester.pumpAndSettle();
      expect(find.text('当前所有功能免费'), findsOneWidget);
      expect(
        find.text(
          '高级版目前仅用于学习并跑通购买流程，暂时没有实际高级功能。购买高级版与捐赠几乎没有区别；如果你愿意，可以购买高级版支持一下项目。',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('account-premium-purchase-notice')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('account-redemption-code')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('floating-subpage-back')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('account-security')));
      await tester.pumpAndSettle();

      expect(find.text('登录方式'), findsOneWidget);
      expect(find.text('更换邮箱'), findsOneWidget);
      expect(find.text('设置或更换密码'), findsOneWidget);
      expect(find.text('双重验证'), findsOneWidget);
      expect(find.textContaining('默认关闭'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-mfa-setup')), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('恢复码已复制'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('account-mfa-setup')));
      await tester.pumpAndSettle();

      expect(find.text('先验证当前邮箱'), findsOneWidget);
      expect(find.textContaining('reader@example.com'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('account-mfa-send-email-submit')),
        findsOneWidget,
      );
      expect(find.text('验证码'), findsNothing);
      expect(find.byType(AppBar), findsNothing);
      expect(
        find.byKey(const ValueKey('floating-subpage-back')),
        findsOneWidget,
      );
      expect(find.textContaining('第 1 步'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('account-mfa-send-email-submit')),
      );
      await tester.pumpAndSettle();

      expect(find.text('输入邮件验证码'), findsOneWidget);
      expect(find.text('验证码'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-mfa-qr-code')), findsNothing);

      await tester.enterText(find.byType(TextField), '111111');
      await tester.tap(
        find.byKey(const ValueKey('account-mfa-email-code-submit')),
      );
      await tester.pumpAndSettle();

      expect(find.text('将开元阅读添加到验证器'), findsOneWidget);
      expect(find.byKey(const ValueKey('account-mfa-qr-code')), findsOneWidget);
      expect(find.text('BASE32SECRET'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account-edit-profile')));
      await tester.pumpAndSettle();

      expect(find.text('编辑资料'), findsOneWidget);
      expect(find.text('个人资料'), findsOneWidget);
      expect(find.text('更换头像'), findsOneWidget);
    },
  );
}

class _AccountAdapter implements HttpClientAdapter {
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
        'providers': {'google': false, 'github': true, 'passkey': true},
        'username': {'min_length': 3, 'max_length': 30},
        'password': {'min_length': 12, 'max_length': 128},
      },
      '/api/v1/membership/config' => {
        'product': 'premium_lifetime',
        'purchase_url': 'https://pay.ldxp.cn/item/m3rfxi',
        'features': ['supporter_badge'],
      },
      _ => throw StateError('Unexpected route ${options.uri.path}'),
    };
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

class _EmptyTokenStore implements MemberTokenStore {
  @override
  Future<void> clear() async {}

  @override
  Future<String?> readAccessToken() async => null;

  @override
  Future<String?> readRefreshToken() async => null;

  @override
  Future<bool> readMfaPending() async => false;

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    bool mfaPending = false,
  }) async {}
}

class _PendingMfaAdapter implements HttpClientAdapter {
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
        'mfa_required': true,
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
      _ => throw StateError('Unexpected route ${options.uri.path}'),
    };
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

class _SignedInAdapter implements HttpClientAdapter {
  _SignedInAdapter({this.premium = false});

  final bool premium;

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
        'stats': {'invited': 3, 'rewarded': 1},
        'inviter': null,
      },
      '/api/v1/auth/security/mfa/status' => {
        'enabled': false,
        'recovery_codes_remaining': 0,
      },
      '/api/v1/auth/security/mfa/setup/code' => {
        'challenge_id': 'mfa-id',
        'expires_in': 600,
      },
      '/api/v1/auth/security/mfa/setup' => () {
        expect(options.data, {'challenge_id': 'mfa-id', 'code': '111111'});
        return {
          'secret': 'BASE32SECRET',
          'otpauth_uri':
              'otpauth://totp/OpenReading:reader?secret=BASE32SECRET&issuer=OpenReading',
        };
      }(),
      _ => throw StateError('Unexpected route ${options.uri.path}'),
    };
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

class _PageTokenStore implements MemberTokenStore {
  String? accessToken = 'pending-access';
  String? refreshToken = 'pending-refresh';
  bool mfaPending = true;

  @override
  Future<void> clear() async {
    accessToken = null;
    refreshToken = null;
    mfaPending = false;
  }

  @override
  Future<String?> readAccessToken() async => accessToken;

  @override
  Future<bool> readMfaPending() async => mfaPending;

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
    this.mfaPending = mfaPending;
  }
}
