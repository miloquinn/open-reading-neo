import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/settings/about/open_source_licenses_page.dart';
import 'package:xxread/pages/settings/settings_page.dart';
import 'package:xxread/pages/settings/cloud_tts_settings_page.dart';
import 'package:xxread/services/reader_aloud_service.dart';
import 'package:xxread/reader_core/ai/ai_service.dart';
import 'package:xxread/services/account/account.dart';
import 'package:xxread/services/core/core_services.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';

class _SettingsAloudService extends ChangeNotifier
    implements ReaderAloudService {
  @override
  ReaderAloudCloudSettings get cloudSettings =>
      const ReaderAloudCloudSettings();
  @override
  bool get hasCloudApiKey => false;
  @override
  Future<void> initialize() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCacheManager extends AppCacheManager {
  @override
  Future<AppCacheUsage> usage() async => AppCacheUsage({
    for (final category in AppCacheCategory.values) category: 0,
  });
}

class _FakePreferencesStore implements SettingsPagePreferencesStore {
  SettingsPagePreferences settings = const SettingsPagePreferences();

  @override
  Future<SettingsPagePreferences> load() async => settings;

  @override
  Future<void> save(SettingsPagePreferences preferences) async {
    settings = preferences;
  }
}

Future<ValueNotifier<double>> _pumpSettingsPage(
  WidgetTester tester, {
  required Locale locale,
  double textScaleFactor = 1,
  ReaderAloudService? aloudService,
  Size surfaceSize = const Size(390, 1200),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = surfaceSize;
  addTearDown(tester.view.reset);

  final theme = ThemeNotifier();
  final appSettings = AppSettingsNotifier();
  final webDav = WebDavSyncController();
  final account = MemberAccountController();
  addTearDown(theme.dispose);
  addTearDown(appSettings.dispose);
  addTearDown(webDav.dispose);
  addTearDown(account.dispose);
  final textScale = ValueNotifier(textScaleFactor);
  addTearDown(textScale.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: theme),
        ChangeNotifierProvider.value(value: appSettings),
        ChangeNotifierProvider.value(value: webDav),
        ChangeNotifierProvider.value(value: account),
        if (aloudService != null)
          ChangeNotifierProvider<ReaderAloudService>.value(value: aloudService),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => ValueListenableBuilder<double>(
          valueListenable: textScale,
          builder: (context, scale, _) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: SettingsPage(
          cacheManager: _FakeCacheManager(),
          preferencesStore: _FakePreferencesStore(),
          aiService: MockAIService(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return textScale;
}

Future<void> _disposeSettingsPage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _scrollToAboutCard(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(const ValueKey('settings-about-card')),
    500,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

void _expectSameRow(WidgetTester tester, List<String> keys) {
  final rects = keys
      .map((key) => tester.getRect(find.byKey(ValueKey(key))))
      .toList();
  final centers = rects.map((rect) => rect.center).toList();
  for (final center in centers.skip(1)) {
    expect(
      center.dy,
      moreOrLessEquals(centers.first.dy, epsilon: 1),
      reason: 'Expected one row for $keys, but laid out as $rects.',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.niki.xxread/app_update');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Open Reading',
      packageName: 'com.niki.xxread',
      version: '2.6.7',
      buildNumber: '260908001',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => '260907001');
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('cloud TTS settings entry uses the shared playback service', (
    tester,
  ) async {
    final aloud = _SettingsAloudService();
    addTearDown(aloud.dispose);
    await _pumpSettingsPage(
      tester,
      locale: const Locale('zh'),
      aloudService: aloud,
    );
    await tester.scrollUntilVisible(
      find.text('云端 TTS'),
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('云端 TTS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('云端 TTS'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CloudTtsSettingsPage>(find.byType(CloudTtsSettingsPage))
          .service,
      same(aloud),
    );
    expect(
      find.byKey(const ValueKey('cloud-tts-save')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _disposeSettingsPage(tester);
  });

  testWidgets(
    'complete settings page mounts with its provider graph',
    (tester) async {
      await _pumpSettingsPage(
        tester,
        locale: const Locale('en'),
        surfaceSize: const Size(430, 1200),
      );

      expect(find.byType(SettingsPage), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-account-card')),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-changelog-link')),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(find.text('2.6.7 (260907001)'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _disposeSettingsPage(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'places the three Chinese community links on one row at 390 pixels',
    (tester) async {
      await _pumpSettingsPage(tester, locale: const Locale('zh'));
      await _scrollToAboutCard(tester);

      _expectSameRow(tester, const [
        'settings-qq-group-link',
        'settings-qq-channel-link',
        'settings-telegram-link',
      ]);
      expect(tester.takeException(), isNull);
      await _disposeSettingsPage(tester);
    },
  );

  testWidgets(
    'keeps GitHub and website links compact on one Chinese 390-pixel row',
    (tester) async {
      await _pumpSettingsPage(tester, locale: const Locale('zh'));
      await _scrollToAboutCard(tester);

      const keys = ['settings-github-link', 'settings-website-link'];
      _expectSameRow(tester, keys);
      for (final key in keys) {
        expect(
          tester.getSize(find.byKey(ValueKey(key))).height,
          lessThanOrEqualTo(56),
        );
      }
      expect(tester.takeException(), isNull);
      await _disposeSettingsPage(tester);
    },
  );

  for (final testCase in const [
    (label: 'English', locale: Locale('en'), textScaleFactor: 1.0),
    (label: 'Japanese', locale: Locale('ja'), textScaleFactor: 1.0),
    (label: 'large English text', locale: Locale('en'), textScaleFactor: 1.6),
    (
      label: 'maximum Chinese app text',
      locale: Locale('zh'),
      textScaleFactor: 1.3,
    ),
    (
      label: 'maximum English app text',
      locale: Locale('en'),
      textScaleFactor: 1.3,
    ),
    (
      label: 'maximum Japanese app text',
      locale: Locale('ja'),
      textScaleFactor: 1.3,
    ),
  ]) {
    testWidgets(
      'keeps wrapped about links within the card at 320 pixels in ${testCase.label}',
      (tester) async {
        await _pumpSettingsPage(
          tester,
          locale: testCase.locale,
          textScaleFactor: testCase.textScaleFactor,
          surfaceSize: const Size(320, 1200),
        );
        await _scrollToAboutCard(tester);

        final cardRect = tester.getRect(
          find.byKey(const ValueKey('settings-about-card')),
        );
        for (final key in const [
          'settings-qq-group-link',
          'settings-qq-channel-link',
          'settings-telegram-link',
          'settings-github-link',
          'settings-website-link',
        ]) {
          final linkRect = tester.getRect(find.byKey(ValueKey(key)));
          expect(linkRect.left, greaterThanOrEqualTo(cardRect.left));
          expect(linkRect.right, lessThanOrEqualTo(cardRect.right));
        }
        expect(tester.takeException(), isNull);
        await _disposeSettingsPage(tester);
      },
    );
  }

  testWidgets('offers five app text sizes and persists every selection', (
    tester,
  ) async {
    await _pumpSettingsPage(tester, locale: const Locale('zh'));
    final settingsContext = tester.element(find.byType(SettingsPage));
    final settings = Provider.of<AppSettingsNotifier>(
      settingsContext,
      listen: false,
    );
    final l10n = AppLocalizations.of(settingsContext);

    await tester.scrollUntilVisible(
      find.text(l10n.appTextSize),
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.appTextSize));
    await tester.pumpAndSettle();

    for (var level = 0; level < 5; level++) {
      final option = find.byKey(ValueKey('app-text-size-$level'));
      expect(option, findsOneWidget);
      await tester.tap(option);
      await tester.pump();

      expect(settings.appTextScaleLevel, level);
      expect(
        settings.appTextScaleFactor,
        AppSettingsNotifier.appTextScaleFactors[level],
      );
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getInt('app_text_scale_level_v1'), level);
    }
    expect(tester.takeException(), isNull);
    await _disposeSettingsPage(tester);
  });

  testWidgets('reveals localized open-source details only after tapping info', (
    tester,
  ) async {
    await _pumpSettingsPage(tester, locale: const Locale('zh'));
    final l10n = AppLocalizations.of(tester.element(find.byType(SettingsPage)));
    await _scrollToAboutCard(tester);

    expect(find.text(l10n.settingsOpenSourceDetails), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-open-source-info')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.settingsOpenSourceDetails), findsOneWidget);
    await _disposeSettingsPage(tester);
  });

  testWidgets('keeps navigation to third-party licenses available', (
    tester,
  ) async {
    await _pumpSettingsPage(tester, locale: const Locale('zh'));
    await _scrollToAboutCard(tester);

    await tester.tap(
      find.byKey(const ValueKey('settings-open-source-licenses-link')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(OpenSourceLicensesPage), findsOneWidget);
    await _disposeSettingsPage(tester);
  });
}
