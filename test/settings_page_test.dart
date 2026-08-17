import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/settings/settings_page.dart';
import 'package:xxread/reader_core/ai/ai_service.dart';
import 'package:xxread/services/account/account.dart';
import 'package:xxread/services/core/core_services.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';

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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('complete settings page mounts with its provider graph', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 1200);
    addTearDown(tester.view.reset);

    final theme = ThemeNotifier();
    final appSettings = AppSettingsNotifier();
    final webDav = WebDavSyncController();
    final account = MemberAccountController();
    addTearDown(theme.dispose);
    addTearDown(appSettings.dispose);
    addTearDown(webDav.dispose);
    addTearDown(account.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: theme),
          ChangeNotifierProvider.value(value: appSettings),
          ChangeNotifierProvider.value(value: webDav),
          ChangeNotifierProvider.value(value: account),
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
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-account-card')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
