import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/settings/about/changelog_page.dart';
import 'package:xxread/services/core/changelog_service.dart';

void main() {
  const channel = MethodChannel('com.niki.xxread/app_update');

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Origo',
      packageName: 'com.niki.xxread',
      version: '2.3.0',
      buildNumber: '1102',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getReleaseBuildNumber');
          return '102';
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'changelog page marks the installed version and build as current',
    (tester) async {
      const locale = Locale('zh');
      const entries = [
        ChangelogEntry(version: '2.3.0', buildNumber: '103', items: ['更新构建']),
        ChangelogEntry(
          version: '2.3.0',
          buildNumber: '102',
          items: ['支持 ColorOS 流体云实时展示下载进度'],
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ChangelogPage(service: _StaticChangelogService(entries)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(entries, isNotEmpty);
      expect(find.text('版本更新记录'), findsOneWidget);
      expect(find.text('当前版本'), findsOneWidget);
      final installedEntry = find.byKey(
        const ValueKey('changelog-entry-2.3.0+102'),
      );
      final newerEntry = find.byKey(
        const ValueKey('changelog-entry-2.3.0+103'),
      );
      expect(installedEntry, findsOneWidget);
      expect(
        find.descendant(of: installedEntry, matching: find.text('当前版本')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: newerEntry, matching: find.text('当前版本')),
        findsNothing,
      );
      expect(find.text('v2.3.0 (103)'), findsOneWidget);
      expect(find.text('v2.3.0 (102)'), findsOneWidget);
      expect(find.text(entries.last.items.first), findsOneWidget);
    },
  );

  testWidgets('historical entries without a build number still render', (
    tester,
  ) async {
    const entries = [
      ChangelogEntry(version: '2.3.0', items: ['Historical release']),
    ];

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChangelogPage(service: _StaticChangelogService(entries)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('v2.3.0'), findsOneWidget);
    expect(find.text('Current version'), findsOneWidget);
  });

  testWidgets('changelog page exposes a retry state when loading fails', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChangelogPage(service: _FailingChangelogService()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Could not load release history'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}

class _FailingChangelogService extends ChangelogService {
  @override
  Future<List<ChangelogEntry>> load(Locale locale) {
    return Future.error(const FormatException('invalid test catalog'));
  }
}

class _StaticChangelogService extends ChangelogService {
  _StaticChangelogService(this.entries);

  final List<ChangelogEntry> entries;

  @override
  Future<List<ChangelogEntry>> load(Locale locale) async => entries;
}
