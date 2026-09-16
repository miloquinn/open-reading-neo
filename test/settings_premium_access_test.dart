import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/settings/settings_page.dart';
import 'package:xxread/reader_core/ai/ai_service.dart';
import 'package:xxread/services/account/account.dart';
import 'package:xxread/services/core/core_services.dart';
import 'package:xxread/services/backup/webdav_backup_controller.dart';

import 'support/premium_account.dart';

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

  for (final width in [430.0, 1280.0]) {
    testWidgets(
      'advanced section unlocks and disappears live at width $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 5000);
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues({
          additionalSourceProtocolsPreferenceKey: true,
          privateBookSourceNetworkPreferenceKey: true,
        });
        final account = PremiumTestAccount(premium: false);
        final appSettings = (await tester.runAsync(() async {
          final settings = AppSettingsNotifier(account: account);
          final loaded = Completer<void>();
          void onLoaded() {
            if (settings.isInitialized && !loaded.isCompleted) {
              loaded.complete();
            }
          }

          settings.addListener(onLoaded);
          onLoaded();
          await loaded.future.timeout(const Duration(seconds: 10));
          settings.removeListener(onLoaded);
          return settings;
        }))!;
        final theme = ThemeNotifier();
        final webDav = WebDavBackupController();
        addTearDown(account.dispose);
        addTearDown(appSettings.dispose);
        addTearDown(theme.dispose);
        addTearDown(webDav.dispose);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: theme),
              ChangeNotifierProvider.value(value: appSettings),
              ChangeNotifierProvider.value(value: webDav),
              ChangeNotifierProvider<MemberAccountController>.value(
                value: account,
              ),
            ],
            child: MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: SettingsPage(
                cacheManager: _FakeCacheManager(),
                preferencesStore: _FakePreferencesStore(),
                aiService: MockAIService(),
              ),
            ),
          ),
        );
        await tester.pump();
        for (var i = 0; i < 40 && !appSettings.isInitialized; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(appSettings.isInitialized, isTrue);
        final l10n = AppLocalizations.of(
          tester.element(find.byType(SettingsPage)),
        );
        void expectSection(bool visible) {
          final matcher = visible ? findsOneWidget : findsNothing;
          expect(find.text(l10n.settingsSectionAdvancedFeatures), matcher);
          expect(
            find.text(l10n.settingsAdditionalSourceProtocolsTitle),
            matcher,
          );
          expect(
            find.text(l10n.settingsPrivateBookSourceNetworkTitle),
            matcher,
          );
        }

        expectSection(false);
        expect(find.text('WebDAV backups'), findsOneWidget);
        expect(find.text(l10n.bookSourceManagementTitle), findsOneWidget);
        account.setPremium(true);
        await tester.pump();
        expectSection(true);
        expect(appSettings.additionalSourceProtocolsEnabled, isTrue);
        account.setPremium(false);
        await tester.pump();
        expectSection(false);
        expect(appSettings.additionalSourceProtocolsEnabled, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
}
