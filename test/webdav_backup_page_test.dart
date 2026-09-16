import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/settings/backup/webdav_backup_page.dart';
import 'package:xxread/pages/settings/sync/webdav_setup_page.dart';
import 'package:xxread/services/backup/webdav_backup_controller.dart';
import 'package:xxread/services/backup/backup_selection.dart';
import 'package:xxread/services/sync/sync_models.dart';

void main() {
  testWidgets('one manual backup action; no sync schedules or scopes', (
    tester,
  ) async {
    final controller = _Controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller, const WebDavBackupPage()));
    await tester.pumpAndSettle();
    expect(controller.backupCalls, 0);
    expect(controller.refreshCalls, 1);
    expect(find.text('自动同步频率'), findsNothing);
    expect(find.text('更多同步内容'), findsNothing);
    await tester.tap(find.text('立即备份'));
    await tester.pumpAndSettle();
    expect(controller.backupCalls, 1);
    expect(find.text('备份已上传'), findsOneWidget);
  });
  testWidgets('choose files by size and categories without starting backup', (
    tester,
  ) async {
    final controller = _Controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller, const WebDavBackupPage()));
    await tester.pumpAndSettle();
    expect(controller.selection.bookIds, isEmpty);
    await tester.tap(find.text('备份内容'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('选择书籍正文'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择书籍正文'));
    await tester.pumpAndSettle();
    expect(find.text('3.00 GB'), findsOneWidget);
    await tester.tap(find.text('Small book'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 本 · 1.0 KB'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(controller.selection.bookIds, {1});
    expect(controller.backupCalls, 0);
    await tester.ensureVisible(find.text('书源'));
    await tester.tap(find.text('书源'));
    await tester.pumpAndSettle();
    expect(controller.selection.sources, isFalse);
  });

  testWidgets('transfer shows stage percentage bytes and speed', (
    tester,
  ) async {
    final controller = _Controller()
      ..busy = true
      ..stage = 'uploading'
      ..progress = .5
      ..completedBytes = 1024
      ..totalBytes = 2048
      ..bytesPerSecond = 1024;
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller, const WebDavBackupPage()));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('正在上传'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.text('50% · 1.0 KB / 2.0 KB'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('1.0 KB/s'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.text('1.0 KB/s'), findsOneWidget);
  });

  testWidgets('restore requires confirmation; cancellation does not write', (
    tester,
  ) async {
    final controller = _Controller();
    addTearDown(controller.dispose);
    controller.backups = [CloudBackup('test.zip', DateTime(2026, 9, 16), 1024)];
    await tester.pumpWidget(_app(controller, const WebDavBackupPage()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('恢复'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();
    expect(find.textContaining('未备份的类别'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.restoreCalls, 0);
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('允许覆盖现有数据'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, '允许覆盖现有数据'),
          )
          .value,
      isFalse,
    );
    await tester.tap(find.text('允许覆盖现有数据'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(SwitchListTile, '阅读统计'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, '阅读统计'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, '恢复'));
    await tester.tap(find.widgetWithText(FilledButton, '恢复'));
    await tester.pumpAndSettle();
    expect(controller.restoreCalls, 1);
    expect(controller.restoreSelection.overwrite, isTrue);
    expect(controller.restoreSelection.statistics, isFalse);
    expect(find.text('恢复完成'), findsOneWidget);
    expect(find.text('重新载入应用'), findsOneWidget);
    expect(find.text('立即备份'), findsNothing);
  });
  testWidgets('busy snapshot disables repeated actions', (tester) async {
    final controller = _Controller()..busy = true;
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller, const WebDavBackupPage()));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '立即备份'))
          .onPressed,
      isNull,
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });
  for (final scale in [1.0, 1.6]) {
    testWidgets('small screen remains readable at text scale $scale', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = _Controller();
      addTearDown(controller.dispose);
      controller.backups = [
        CloudBackup('test.zip', DateTime(2026, 9, 16), 1024),
      ];
      await tester.pumpWidget(
        _app(controller, const WebDavBackupPage(), scale: scale),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -700));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('恢复').hitTestable(), findsOneWidget);
    });
  }
  for (final fails in [false, true]) {
    testWidgets(
      'setup validates and saves once; save errors remain retryable $fails',
      (tester) async {
        final controller = _Controller()..fails = fails;
        controller.pending = Completer<ConnectionTestResult>();
        addTearDown(controller.dispose);
        await tester.pumpWidget(_app(controller, const WebDavSetupPage()));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'WebDAV 地址'),
          'https://dav.test',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, '用户名'),
          'reader',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, '应用密码'),
          'secret',
        );
        final save = find.byKey(const ValueKey('webdav-save-action'));
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pump();
        expect(controller.testCalls, 1);
        expect(tester.widget<FilledButton>(save).onPressed, isNull);
        expect(
          tester
              .widget<TextFormField>(find.byType(TextFormField).first)
              .enabled,
          isFalse,
        );
        controller.pending!.complete(const ConnectionTestResult(success: true));
        await tester.pumpAndSettle();
        expect(controller.configureCalls, 1);
        if (fails) {
          expect(find.byType(WebDavSetupPage), findsOneWidget);
          expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Widget _app(
  WebDavBackupController controller,
  Widget child, {
  double scale = 1,
}) => ChangeNotifierProvider<WebDavBackupController>.value(
  value: controller,
  child: MaterialApp(
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: child,
  ),
);

class _Controller extends WebDavBackupController {
  @override
  Future<void> loadBooks() async {
    books = const [
      BackupBook(1, 'Small book', 1024, true),
      BackupBook(2, 'Large book', 3221225472, true),
    ];
  }

  int backupCalls = 0,
      refreshCalls = 0,
      restoreCalls = 0,
      testCalls = 0,
      configureCalls = 0;
  bool fails = false;
  Completer<ConnectionTestResult>? pending;
  @override
  bool get isConfigured => true;
  @override
  Future<void> refresh() async {
    refreshCalls++;
  }

  @override
  Future<void> backup() async {
    backupCalls++;
  }

  @override
  Future<void> restore(CloudBackup backup) async {
    restoreCalls++;
  }

  @override
  Future<ConnectionTestResult> testConnection(
    WebDavSyncConfigDraft draft,
  ) async {
    testCalls++;
    return pending!.future;
  }

  @override
  Future<void> configure(WebDavSyncConfigDraft draft) async {
    configureCalls++;
    if (fails) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.secureStorage,
        'save failed',
      );
    }
  }
}
