// Run one capture per process, for example:
// flutter test tool/preview_book_source_cards.dart --plain-name 'dark 390'

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_management_source_card.dart';
import 'package:xxread/utils/app_themes.dart';

const _previewFont = 'BookSourceCardPreviewChinese';
const _captureKey = Key('bookSourceCardPreviewBoundary');
const _outputDirectory = 'artifacts/source-cards';

void main() {
  testWidgets('capture source cards dark 390', (tester) async {
    await _capture(
      tester,
      width: 390,
      height: 844,
      textScale: 1.2,
      brightness: Brightness.dark,
      fileName: 'book-source-cards-dark-390x844.png',
      sources: _previewSources,
    );
  });

  testWidgets('capture source cards light 320 large text', (tester) async {
    await _capture(
      tester,
      width: 320,
      height: 900,
      textScale: 2,
      brightness: Brightness.light,
      fileName: 'book-source-cards-light-320x900-large-text.png',
      sources: [_previewSources.first, _previewSources.last],
    );
  });
}

Future<void> _capture(
  WidgetTester tester, {
  required double width,
  required double height,
  required double textScale,
  required Brightness brightness,
  required String fileName,
  required List<RegisteredBookSource> sources,
}) async {
  await tester.runAsync(_loadPreviewFonts);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: _previewFont,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppThemes.defaultAccentColor,
          brightness: brightness,
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: RepaintBoundary(key: _captureKey, child: child!),
      ),
      home: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
            children: [
              Text(
                '书源管理',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 18),
              for (final source in sources)
                BookSourceManagementSourceCard(
                  source: source,
                  selectionMode: false,
                  selected: false,
                  additionalProtocolsEnabled: true,
                  onToggleSelection: () {},
                  onEnabledChanged: (_) {},
                  onAction: (_) {},
                ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  await _writePng(tester, fileName);
}

final _previewSources = [
  _source(
    id: 'ecc6',
    name: 'E小说网6',
    description: 'm.ecc6.com',
    groups: const ['源仓库', '整理检验'],
    login: true,
    failed: true,
  ),
  _source(
    id: 'forum',
    name: 'FORUM Group — 一个名字很长的社区书源',
    description: '1、爬梯子，2、保持耐心，3、遇到限流稍后重试',
    groups: const ['有效'],
    failed: true,
  ),
  _source(
    id: 'lofter',
    name: 'Lofter',
    description: '// Error: Timeout while validating the reading chain',
    groups: const ['有效', '整理检验与名称很长仍然不能撑破卡片的分组'],
    login: true,
    failed: true,
  ),
];

RegisteredBookSource _source({
  required String id,
  required String name,
  required String description,
  required List<String> groups,
  bool login = false,
  bool failed = false,
}) => RegisteredBookSource(
  id: id,
  name: name,
  description: description,
  manifestUrl: Uri.parse('https://$id.example/source.json'),
  apiBaseUrl: Uri.parse('https://$id.example'),
  protocolVersion: 'reading-source-1',
  languages: const ['zh'],
  capabilities: const {'search', 'detail', 'catalog', 'content'},
  enabled: true,
  groups: groups,
  addedAt: DateTime.utc(2026, 9, 12),
  sourceProtocol: BookSourceProtocolKind.readingSource,
  sourceConfig: {
    if (login) 'loginUrl': 'https://$id.example/login',
    if (failed)
      '_openReadingHealthCheck': const {
        'checked': ['search', 'info', 'catalog', 'content'],
        'failed': ['content'],
        'checkedAt': '2026-09-12T00:00:00Z',
      },
  },
);

Future<void> _writePng(WidgetTester tester, String fileName) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (data == null) throw StateError('Could not encode preview PNG.');
    final directory = Directory(_outputDirectory)..createSync(recursive: true);
    File('${directory.path}/$fileName').writeAsBytesSync(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
  });
}

Future<void> _loadPreviewFonts() async {
  final fontCandidates = [
    ?Platform.environment['BOOK_SOURCE_PREVIEW_FONT'],
    '/System/Library/Fonts/PingFang.ttc',
    '/System/Library/Fonts/Hiragino Sans GB.ttc',
    '/System/Library/Fonts/STHeiti Medium.ttc',
  ];
  final fontFiles = fontCandidates
      .map(File.new)
      .where((file) => file.existsSync())
      .toList(growable: false);
  if (fontFiles.isEmpty) {
    throw StateError(
      'No readable Chinese preview font found. Set BOOK_SOURCE_PREVIEW_FONT.',
    );
  }
  final bytes = await fontFiles.first.readAsBytes();
  Future<ByteData> fontData() => Future.value(ByteData.sublistView(bytes));
  final executable = Platform.resolvedExecutable;
  final marker = '${Platform.pathSeparator}bin${Platform.pathSeparator}cache';
  final markerIndex = executable.indexOf(marker);
  final inferredRoot = markerIndex < 0
      ? null
      : executable.substring(0, markerIndex);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? inferredRoot;
  if (flutterRoot == null) {
    throw StateError('Set FLUTTER_ROOT to load MaterialIcons.');
  }
  final iconBytes = await File(
    '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytes();
  await Future.wait([
    (FontLoader(_previewFont)..addFont(fontData())).load(),
    (FontLoader(
      'MaterialIcons',
    )..addFont(Future.value(ByteData.sublistView(iconBytes)))).load(),
  ]);
}
