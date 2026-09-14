import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/account/premium_membership_page.dart';
import 'package:xxread/pages/account/premium_policy_page.dart';
import 'package:xxread/services/account/account.dart';
import 'package:xxread/services/core/app_distribution.dart';
import 'package:xxread/widgets/app_brand_icon.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final screenshotDirectory = Platform.environment['PREMIUM_SCREENSHOT_DIR'];

  setUp(AppDistribution.debugReset);
  tearDown(() {
    AppDistribution.debugReset();
    _resetPlatform();
  });

  setUpAll(() async {
    if (screenshotDirectory == null) return;
    final fontPath = Platform.environment['PREMIUM_PREVIEW_FONT'];
    if (fontPath != null) {
      final text = FontLoader('PremiumPreview');
      text.addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
      await text.load();
    }
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  for (final source in ['admin', 'card', 'apple']) {
    testWidgets('existing $source member sees channel and retains restore', (
      tester,
    ) async {
      _usePlatform(TargetPlatform.iOS);
      final store = _FakeAppleStore();
      final account = _TestAccount(store: store, premium: true, source: source);
      addTearDown(account.dispose);
      addTearDown(store.close);
      await _pumpPage(tester, account: account);
      await tester.pumpAndSettle();
      expect(
        find.text(switch (source) {
          'admin' => '你已获赠高级会员，无需重复购买。',
          'card' => '你已通过其他渠道开通高级会员，无需重复购买。',
          _ => '你已通过 App Store 开通高级会员，无需重复购买。',
        }),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('account-apple-purchase')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('account-apple-restore')),
        findsOneWidget,
      );
      _resetPlatform();
    });
  }

  testWidgets(
    'shows localized App Store price and the real premium benefits on iOS',
    (tester) async {
      _usePlatform(TargetPlatform.iOS);
      final store = _FakeAppleStore();
      final account = _TestAccount(store: store);
      addTearDown(account.dispose);
      addTearDown(store.close);

      await _pumpPage(tester, account: account);
      await tester.pumpAndSettle();

      expect(find.text('¥28.00'), findsOneWidget);
      expect(find.text('更多书源协议'), findsOneWidget);
      expect(find.text('允许内网书源'), findsOneWidget);
      expect(find.text('会员不提供书籍内容或书源地址，第三方服务可能另行收费。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('account-apple-restore')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('account-redemption-code')),
        findsNothing,
      );
      _resetPlatform();
    },
  );

  testWidgets(
    'keeps restore but removes refund actions for an active iOS member',
    (tester) async {
      _usePlatform(TargetPlatform.iOS);
      final store = _FakeAppleStore();
      final account = _TestAccount(store: store, premium: true);
      addTearDown(account.dispose);
      addTearDown(store.close);

      await _pumpPage(tester, account: account);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('premium-active')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('account-apple-restore')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('premium-refund')), findsNothing);
      expect(find.byKey(const ValueKey('premium-apple-support')), findsNothing);
      expect(find.text('申请退款'), findsNothing);
      expect(
        find.byKey(const ValueKey('account-apple-purchase')),
        findsNothing,
      );
      _resetPlatform();
    },
  );

  testWidgets(
    'macOS website builds keep redemption instead of App Store purchase',
    (tester) async {
      _usePlatform(TargetPlatform.macOS);
      AppDistribution.debugOverride(usesAppleBilling: false);
      final store = _FakeAppleStore();
      final account = _TestAccount(store: store);
      addTearDown(account.dispose);
      addTearDown(store.close);
      await _pumpPage(tester, account: account);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('account-redemption-code')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('account-redeem-premium')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('account-apple-purchase')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('account-apple-restore')), findsNothing);
      expect(find.byKey(const ValueKey('premium-eula-link')), findsNothing);
      _resetPlatform();
    },
  );

  testWidgets(
    'macOS App Store builds keep store actions without refund entry points',
    (tester) async {
      _usePlatform(TargetPlatform.macOS);
      AppDistribution.debugOverride(usesAppleBilling: true);
      final store = _FakeAppleStore();
      final account = _TestAccount(store: store);
      addTearDown(account.dispose);
      addTearDown(store.close);
      await _pumpPage(tester, account: account);
      await tester.pumpAndSettle();
      expect(find.text('¥28.00'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('account-apple-purchase')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('account-apple-restore')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('premium-refund')), findsNothing);
      expect(find.byKey(const ValueKey('premium-apple-support')), findsNothing);
      expect(find.byKey(const ValueKey('premium-eula-link')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('account-redemption-code')),
        findsNothing,
      );
      _resetPlatform();
    },
  );

  testWidgets(
    'keeps restore available when the App Store product query fails',
    (tester) async {
      _usePlatform(TargetPlatform.iOS);
      final store = _FakeAppleStore(productAvailable: false);
      final account = _TestAccount(store: store);
      addTearDown(account.dispose);
      addTearDown(store.close);

      await _pumpPage(tester, account: account);
      await tester.pumpAndSettle();

      expect(find.text('App Store 商品尚未配置或不可用'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('account-apple-restore')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('account-apple-purchase')),
        findsOneWidget,
      );
      _resetPlatform();
    },
  );

  testWidgets('opens complete membership terms without a network request', (
    tester,
  ) async {
    _usePlatform(TargetPlatform.iOS);
    final store = _FakeAppleStore();
    final account = _TestAccount(store: store);
    addTearDown(account.dispose);
    addTearDown(store.close);
    await _pumpPage(tester, account: account);
    await tester.pumpAndSettle();

    await _tapVisible(tester, const ValueKey('premium-terms-link'));

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is PremiumPolicyPage && widget.policy == PremiumPolicy.terms,
      ),
      findsOneWidget,
    );
    expect(find.text('账号与权益'), findsOneWidget);
    expect(find.text('申请退款'), findsOneWidget);
    _resetPlatform();
  });

  testWidgets('opens complete privacy disclosures without a network request', (
    tester,
  ) async {
    _usePlatform(TargetPlatform.iOS);
    final store = _FakeAppleStore();
    final account = _TestAccount(store: store);
    addTearDown(account.dispose);
    addTearDown(store.close);
    await _pumpPage(tester, account: account);
    await tester.pumpAndSettle();

    await _tapVisible(tester, const ValueKey('premium-privacy-link'));

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is PremiumPolicyPage &&
            widget.policy == PremiumPolicy.privacy,
      ),
      findsOneWidget,
    );
    expect(find.text('账号服务'), findsOneWidget);
    expect(find.text('购买与验证数据'), findsOneWidget);
    _resetPlatform();
  });

  testWidgets('preserves redemption-code access on Android', (tester) async {
    _usePlatform(TargetPlatform.android);
    final store = _FakeAppleStore();
    final account = _TestAccount(store: store);
    addTearDown(account.dispose);
    addTearDown(store.close);

    await _pumpPage(tester, account: account);

    expect(
      find.byKey(const ValueKey('account-redemption-code')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('account-redeem-premium')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('account-apple-restore')), findsNothing);
    expect(find.byKey(const ValueKey('premium-eula-link')), findsNothing);
    _resetPlatform();
  });

  testWidgets('active Android membership has no empty purchase panel', (
    tester,
  ) async {
    _usePlatform(TargetPlatform.android);
    final store = _FakeAppleStore();
    final account = _TestAccount(store: store, premium: true);
    addTearDown(account.dispose);
    addTearDown(store.close);
    await _pumpPage(tester, account: account);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('premium-active')), findsOneWidget);
    expect(find.text('购买说明'), findsNothing);
    expect(find.byKey(const ValueKey('account-redemption-code')), findsNothing);
    expect(find.byKey(const ValueKey('premium-privacy-link')), findsOneWidget);
    _resetPlatform();
  });

  testWidgets('reports an Apple purchase that is waiting for approval', (
    tester,
  ) async {
    _usePlatform(TargetPlatform.iOS);
    final store = _FakeAppleStore();
    final account = _TestAccount(store: store);
    addTearDown(account.dispose);
    addTearDown(store.close);
    await _pumpPage(tester, account: account);
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      store.emit(PurchaseStatus.pending);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();

    expect(find.text('正在等待 Apple 批准。批准并验证后会自动解锁。'), findsOneWidget);
    _resetPlatform();
  });

  testWidgets('lays out narrow large-text dark mode without overflow', (
    tester,
  ) async {
    _usePlatform(TargetPlatform.iOS);
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _FakeAppleStore();
    final account = _TestAccount(store: store);
    addTearDown(account.dispose);
    addTearDown(store.close);

    await _pumpPage(
      tester,
      account: account,
      themeMode: ThemeMode.dark,
      textScaler: const TextScaler.linear(1.5),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -1800));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('premium-terms-link')), findsOneWidget);
    _resetPlatform();
  });

  testWidgets(
    'exports the phone light membership review image when requested',
    (tester) async {
      _usePlatform(TargetPlatform.iOS);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = _FakeAppleStore();
      final account = _TestAccount(store: store);
      addTearDown(account.dispose);
      addTearDown(store.close);
      final previewKey = GlobalKey();

      await _pumpPage(
        tester,
        account: account,
        previewKey: previewKey,
        previewFont: true,
      );
      await tester.pumpAndSettle();
      await _loadBrandIcon(tester);
      await _capture(
        tester,
        previewKey,
        '$screenshotDirectory/premium-membership-phone-light.png',
      );
      await _scrollVisible(tester, const ValueKey('premium-terms-link'));
      await _capture(
        tester,
        previewKey,
        '$screenshotDirectory/premium-membership-phone-purchase-light.png',
      );
      _resetPlatform();
    },
    skip: screenshotDirectory == null,
  );

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('exports active phone membership in ${mode.name}', (
      tester,
    ) async {
      _usePlatform(TargetPlatform.iOS);
      addTearDown(_resetPlatform);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = _FakeAppleStore();
      final account = _TestAccount(store: store, premium: true);
      addTearDown(account.dispose);
      addTearDown(store.close);
      final previewKey = GlobalKey();
      await _pumpPage(
        tester,
        account: account,
        previewKey: previewKey,
        previewFont: true,
        themeMode: mode,
      );
      await tester.pumpAndSettle();
      await _loadBrandIcon(tester);
      expect(tester.takeException(), isNull);
      await _capture(
        tester,
        previewKey,
        '$screenshotDirectory/premium-active-phone-${mode.name}.png',
      );
      _resetPlatform();
    }, skip: screenshotDirectory == null);
  }

  testWidgets(
    'exports the tablet dark membership review image when requested',
    (tester) async {
      _usePlatform(TargetPlatform.iOS);
      tester.view.physicalSize = const Size(1180, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = _FakeAppleStore();
      final account = _TestAccount(store: store, premium: true);
      addTearDown(account.dispose);
      addTearDown(store.close);
      final previewKey = GlobalKey();

      await _pumpPage(
        tester,
        account: account,
        themeMode: ThemeMode.dark,
        previewKey: previewKey,
        previewFont: true,
      );
      await tester.pumpAndSettle();
      await _loadBrandIcon(tester);
      await _capture(
        tester,
        previewKey,
        '$screenshotDirectory/premium-membership-tablet-dark.png',
      );
      _resetPlatform();
    },
    skip: screenshotDirectory == null,
  );
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required MemberAccountController account,
  ThemeMode themeMode = ThemeMode.light,
  TextScaler textScaler = TextScaler.noScaling,
  GlobalKey? previewKey,
  bool previewFont = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: _theme(Brightness.light, previewFont: previewFont),
      darkTheme: _theme(Brightness.dark, previewFont: previewFont),
      themeMode: themeMode,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: RepaintBoundary(
        key: previewKey,
        child: PremiumMembershipPage(account: account),
      ),
    ),
  );
}

Future<void> _tapVisible(WidgetTester tester, ValueKey<String> key) async {
  await _scrollVisible(tester, key);
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

Future<void> _scrollVisible(WidgetTester tester, ValueKey<String> key) async {
  final target = find.byKey(key);
  final viewportHeight =
      tester.view.physicalSize.height / tester.view.devicePixelRatio;
  while (tester.getCenter(target).dy > viewportHeight - 60) {
    await tester.drag(find.byType(ListView), const Offset(0, -350));
    await tester.pump();
  }
}

void _usePlatform(TargetPlatform platform) {
  debugDefaultTargetPlatformOverride = platform;
}

void _resetPlatform() => debugDefaultTargetPlatformOverride = null;

ThemeData _theme(Brightness brightness, {required bool previewFont}) {
  final theme = ThemeData(brightness: brightness);
  if (!previewFont) return theme;
  const previewStyle = TextStyle(fontFamily: 'PremiumPreview');
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: 'PremiumPreview'),
    cupertinoOverrideTheme: const CupertinoThemeData(
      textTheme: CupertinoTextThemeData(
        textStyle: previewStyle,
        actionTextStyle: previewStyle,
        navActionTextStyle: previewStyle,
        navTitleTextStyle: previewStyle,
      ),
    ),
  );
}

Future<void> _loadBrandIcon(WidgetTester tester) async {
  await tester.runAsync(
    () => precacheImage(
      const AssetImage(kAppBrandIconAsset),
      tester.element(find.byType(PremiumMembershipPage)),
    ),
  );
  await tester.pump();
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String path) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(path).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

class _TestAccount extends MemberAccountController {
  _TestAccount({
    required ApplePurchaseStore store,
    this.premium = false,
    this.source,
  }) : super(appleStore: store);

  final bool premium;
  final String? source;

  @override
  MemberMembership get membership => MemberMembership(
    premium: premium,
    features: const {},
    entitlements: [
      if (source != null)
        MemberEntitlement(
          featureKey: 'premium',
          source: source!,
          status: 'active',
          grantedAt: _createdAt,
        ),
    ],
  );

  @override
  bool get isAuthenticated => true;

  @override
  bool get hasPremiumAccess => premium;

  @override
  MemberUser get user => MemberUser(
    id: 'reader-1',
    email: 'reader@example.com',
    emailVerified: true,
    username: 'reader',
    effectiveName: '阅读者',
    authMethods: ['apple'],
    createdAt: _createdAt,
  );

  static final _createdAt = DateTime.utc(2026, 1, 1);
}

class _FakeAppleStore implements ApplePurchaseStore {
  _FakeAppleStore({this.productAvailable = true});

  final bool productAvailable;
  final _purchases = StreamController<List<PurchaseDetails>>.broadcast();

  void emit(PurchaseStatus status) {
    _purchases.add([
      PurchaseDetails(
        purchaseID: 'transaction-1',
        productID: MemberAccountController.appleProductId,
        verificationData: PurchaseVerificationData(
          localVerificationData: '{}',
          serverVerificationData: 'signed-jws',
          source: 'app_store',
        ),
        transactionDate: '1767225600000',
        status: status,
      ),
    ]);
  }

  Future<void> close() => _purchases.close();

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _purchases.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<ProductDetailsResponse> queryProductDetails(
    Set<String> identifiers,
  ) async => ProductDetailsResponse(
    productDetails: productAvailable
        ? [
            ProductDetails(
              id: MemberAccountController.appleProductId,
              title: '永久高级会员',
              description: '一次购买，永久解锁',
              price: '¥28.00',
              rawPrice: 28,
              currencyCode: 'CNY',
              currencySymbol: '¥',
            ),
          ]
        : const [],
    notFoundIDs: productAvailable
        ? const []
        : const [MemberAccountController.appleProductId],
  );

  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async =>
      true;

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {}

  @override
  Future<Set<String>?> restorePurchases({String? applicationUserName}) async =>
      const {};
}
