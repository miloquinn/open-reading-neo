import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/settings/font_selection_sheet.dart';
import 'package:xxread/services/core/app_settings_service.dart';
import 'package:xxread/services/core/online_font_service.dart';
import 'package:xxread/utils/font_catalog_helper.dart';

class _DeferredOnlineFontService extends OnlineFontService {
  final Completer<OnlineFontRecord> completion = Completer<OnlineFontRecord>();
  OnlineFontDownloadProgress? currentProgress;
  bool started = false;
  bool downloaded = false;

  @override
  Future<void> initialize() async {}

  @override
  bool get isSupported => true;

  @override
  bool isDownloaded(String fontId) => downloaded;

  @override
  OnlineFontDownloadProgress? progressFor(String fontId) =>
      currentProgress?.fontId == fontId ? currentProgress : null;

  @override
  Future<OnlineFontRecord> download({
    required String fontId,
    required String family,
    required List<OnlineFontFile> files,
    OnlineFontProgressCallback? onProgress,
    CancelToken? cancelToken,
  }) async {
    started = true;
    currentProgress = OnlineFontDownloadProgress(
      fontId: fontId,
      status: OnlineFontDownloadStatus.downloading,
      downloadedBytes: 1,
      totalBytes: 2,
      totalFiles: files.length,
    );
    onProgress?.call(currentProgress!);
    final record = await completion.future;
    downloaded = true;
    currentProgress = OnlineFontDownloadProgress(
      fontId: fontId,
      status: OnlineFontDownloadStatus.completed,
      downloadedBytes: 2,
      totalBytes: 2,
      downloadedFiles: files.length,
      totalFiles: files.length,
    );
    onProgress?.call(currentProgress!);
    return record;
  }
}

Future<AppSettingsNotifier> _loadNotifier({
  OnlineFontService? onlineFontService,
}) async {
  final notifier = AppSettingsNotifier(onlineFontService: onlineFontService);
  if (notifier.isInitialized) return notifier;
  final initialized = Completer<void>();
  void listener() {
    if (notifier.isInitialized && !initialized.isCompleted) {
      initialized.complete();
    }
  }

  notifier.addListener(listener);
  listener();
  await initialized.future;
  notifier.removeListener(listener);
  return notifier;
}

Widget _testApp(AppSettingsNotifier settings) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: FontSelectionSheet(
      settings: settings,
      domain: FontDomain.app,
      title: 'App font',
      description: 'Choose the interface font.',
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('selecting an available font applies it and closes the sheet', (
    tester,
  ) async {
    final settings = (await tester.runAsync(_loadNotifier))!;
    addTearDown(settings.dispose);
    var popped = false;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                await showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => FontSelectionSheet(
                    settings: settings,
                    domain: FontDomain.app,
                    title: 'App font',
                    description: 'Choose the interface font.',
                  ),
                );
                popped = true;
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('font-option-system')));
    await tester.pumpAndSettle();

    expect(settings.appFontId, FontCatalog.systemId);
    expect(popped, isTrue);
    expect(find.byType(FontSelectionSheet), findsNothing);
  });

  testWidgets('online font download keeps the sheet open while in progress', (
    tester,
  ) async {
    final onlineService = _DeferredOnlineFontService();
    final settings = (await tester.runAsync(
      () => _loadNotifier(onlineFontService: onlineService),
    ))!;
    addTearDown(settings.dispose);
    await tester.pumpWidget(_testApp(settings));

    final instrumentSans = find.byKey(
      const ValueKey('font-option-instrument_sans'),
    );
    await tester.ensureVisible(instrumentSans);
    await tester.pumpAndSettle();
    await tester.tap(instrumentSans);
    await tester.pump(const Duration(milliseconds: 120));

    expect(onlineService.started, isTrue);
    expect(find.byType(FontSelectionSheet), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('50%'), findsOneWidget);

    onlineService.completion.complete(
      OnlineFontRecord(
        id: FontCatalog.instrumentSansId,
        files: const <OnlineFontFileRecord>[],
        downloadedAt: DateTime.utc(2026),
      ),
    );
    await tester.pumpAndSettle();

    expect(settings.appFontId, FontCatalog.instrumentSansId);
    expect(find.byType(FontSelectionSheet), findsOneWidget);
  });
}
