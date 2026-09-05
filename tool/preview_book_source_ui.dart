// Run explicitly, one state per process, for example:
// flutter test tool/preview_book_source_ui.dart --plain-name 'capture recommended'

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/caching/source_cover_cache.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/book_sources_page.dart';
import 'package:xxread/pages/book_sources/widgets/sourced_book_cards.dart';
import 'package:xxread/pages/home/home_shell_page.dart';
import 'package:xxread/services/core/app_settings_service.dart';
import 'package:xxread/utils/app_themes.dart';
import 'package:xxread/utils/glass_config.dart';
import 'package:xxread/utils/ui_style.dart';
import 'package:xxread/widgets/generated_book_cover.dart';

const _captureKey = Key('bookSourcePreviewBoundary');
const _outputDirectory = '.omx/book-source-ui-previews';
const _previewFont = 'BookSourcePreviewChinese';

void main() {
  testWidgets('capture spacious source directory light', (tester) async {
    await _capture(
      tester,
      fileName: 'spacious-source-directory-light-390x844.png',
      listLayout: true,
      longSourceNames: true,
      style: AppUiStyle.glass,
    );
  });
  testWidgets('capture spacious source directory dark', (tester) async {
    await _capture(
      tester,
      fileName: 'spacious-source-directory-dark-390x844.png',
      listLayout: true,
      longSourceNames: true,
      style: AppUiStyle.glass,
      brightness: Brightness.dark,
      textScale: 1.3,
    );
  });

  testWidgets('capture organization editor', (tester) async {
    await _capture(
      tester,
      fileName: 'organization-editor-light-390x844.png',
      organizationView: 'editor',
    );
  });
  testWidgets('capture organization directory dark', (tester) async {
    await _capture(
      tester,
      fileName: 'organization-directory-dark-390x844.png',
      listLayout: true,
      brightness: Brightness.dark,
      textScale: 1.3,
      style: AppUiStyle.glass,
    );
  });
  testWidgets('capture organization manager', (tester) async {
    await _capture(
      tester,
      fileName: 'organization-manager-light-390x844.png',
      organizationView: 'manager',
    );
  });

  testWidgets('capture recommended', (tester) async {
    await _capture(tester, fileName: 'recommended-light-390x844.png');
  });

  testWidgets('capture categories', (tester) async {
    await _capture(
      tester,
      fileName: 'categories-light-390x844.png',
      openCategories: true,
    );
  });

  testWidgets('capture reading channels', (tester) async {
    await _capture(
      tester,
      fileName: 'reading-channels-light-390x844.png',
      readingChannels: true,
    );
  });

  testWidgets('capture glass reading channels light', (tester) async {
    await _capture(
      tester,
      fileName: 'glass-reading-channels-light-390x844.png',
      readingChannels: true,
      style: AppUiStyle.glass,
    );
  });

  testWidgets('capture glass reading channels dark', (tester) async {
    await _capture(
      tester,
      fileName: 'glass-reading-channels-dark-390x844.png',
      brightness: Brightness.dark,
      textScale: 1.3,
      readingChannels: true,
      style: AppUiStyle.glass,
    );
  });

  testWidgets('capture glass ORSP categories light', (tester) async {
    await _capture(
      tester,
      fileName: 'glass-orsp-categories-light-390x844.png',
      openCategories: true,
      style: AppUiStyle.glass,
    );
  });

  testWidgets('capture glass directory many channels', (tester) async {
    await _capture(
      tester,
      fileName: 'glass-directory-30-channels-light-390x844.png',
      listLayout: true,
      directoryChannelCount: 30,
      style: AppUiStyle.glass,
    );
  });

  testWidgets('capture glass directory selected channel', (tester) async {
    await _capture(
      tester,
      fileName: 'glass-directory-selected-channel-light-390x844.png',
      listLayout: true,
      directoryChannelCount: 30,
      selectDirectoryChannel: true,
      style: AppUiStyle.glass,
    );
  });

  testWidgets('capture directory', (tester) async {
    await _capture(
      tester,
      fileName: 'directory-light-390x844.png',
      listLayout: true,
    );
  });

  testWidgets('capture dark large text', (tester) async {
    await _capture(
      tester,
      fileName: 'categories-dark-large-text-390x844.png',
      brightness: Brightness.dark,
      textScale: 1.3,
      openCategories: true,
    );
  });
}

Future<void> _capture(
  WidgetTester tester, {
  required String fileName,
  Brightness brightness = Brightness.light,
  double textScale = 1,
  bool openCategories = false,
  String? organizationView,
  bool listLayout = false,
  bool longSourceNames = false,
  bool readingChannels = false,
  int directoryChannelCount = 4,
  bool selectDirectoryChannel = false,
  AppUiStyle style = AppUiStyle.material3,
}) async {
  await tester.runAsync(_loadPreviewFonts);
  GlassEffectConfig.setDisableAllGlassEffects(style == AppUiStyle.material3);
  addTearDown(() => GlassEffectConfig.setDisableAllGlassEffects(false));
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 20);
  addTearDown(tester.view.reset);

  final sources = [
    _source(
      'reading-source',
      longSourceNames ? '126小说网 · 精品小说与备用线路' : '阅读书源',
      protocol: BookSourceProtocolKind.readingSource,
    ),
    _source(
      'literature-library',
      longSourceNames ? '文学书库 · 精品小说合集' : '文学书库',
    ).copyWith(
      isFavorite: organizationView != null,
      groups: organizationView != null ? ['常用', '备用'] : null,
    ),
  ];
  if (longSourceNames) {
    sources.addAll([
      _source('backup', '365小说 · 夜间备用线路'),
      _source('short-source', '2#bybk.cc'),
      _source('classic', '经典文学与人文历史资料书库'),
    ]);
  }
  // This explicit preview harness keeps registry state in memory.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({
    'open_reading_book_sources_v1': jsonEncode(
      sources.map((source) => source.toJson()).toList(growable: false),
    ),
    additionalSourceProtocolsPreferenceKey: true,
    if (listLayout) BookSourcesPageController.preferenceKey: 'list',
  });

  final scheme = ColorScheme.fromSeed(
    seedColor: AppThemes.defaultAccentColor,
    brightness: brightness,
  );
  final client = _PreviewClient(readingChannelCount: directoryChannelCount);
  addTearDown(client.close);
  final cacheRoot = Directory.systemTemp.createTempSync(
    'book-source-ui-preview-',
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => cacheRoot.path,
      );
  addTearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (cacheRoot.existsSync()) await cacheRoot.delete(recursive: true);
  });
  await tester.runAsync(() => _seedPreviewCovers(cacheRoot));
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        useMaterial3: true,
        brightness: brightness,
        colorScheme: scheme,
        scaffoldBackgroundColor: scheme.surface,
        fontFamily: _previewFont,
        dividerTheme: DividerThemeData(
          color: scheme.outline.withValues(alpha: 0.32),
          thickness: 0.7,
        ),
        extensions: [UiStyleThemeExtension(style: style)],
      ),
      builder: (context, child) => RepaintBoundary(
        key: _captureKey,
        child: MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
      home: RepaintBoundary(
        key: const Key('bookSourcePreviewHome'),
        child: Scaffold(
          body: NavigationContext(
            useRailNavigation: true,
            child: BookSourcesPage(client: client),
          ),
        ),
      ),
    ),
  );
  await _pumpUntil(
    tester,
    listLayout ? '目录' : '文学拾光',
    target: listLayout
        ? find.byKey(const Key('bookSourceListLayoutDirectory'))
        : null,
  );

  if (openCategories) {
    await tester.tap(
      find.byKey(const Key('bookSourceDiscoverScope-literature-library')),
    );
    await _settlePageAnimations(tester);
    await tester.tap(find.text('分类'));
    await _pumpUntil(
      tester,
      'category book rows',
      target: find.byType(SourcedBookListTile),
    );
    await _settleSliverTransitions(tester);
  }
  if (readingChannels) {
    await tester.tap(
      find.byKey(const Key('bookSourceDiscoverScope-reading-source')),
    );
    await _pumpUntil(
      tester,
      '阅读书源频道',
      target: find.byKey(
        const Key(
          'bookSourceDiscoveryChannel-reading-source-reading-source-fantasy',
        ),
      ),
    );
    await _settleSliverTransitions(tester);
    expect(find.text('分类'), findsNothing);
    expect(find.text('最新'), findsNothing);
    expect(find.text('长风入夜'), findsOneWidget);
    expect(find.byType(SourcedBookListTile), findsWidgets);
  }
  if (listLayout && !longSourceNames) {
    await tester.tap(
      find.byKey(const Key('bookSourceListSourceToggle-reading-source')),
    );
    await _pumpUntil(
      tester,
      '玄幻',
      target: find.byKey(
        const Key(
          'bookSourceListChannel-reading-source-reading-source-fantasy',
        ),
      ),
    );
    if (directoryChannelCount > 4) {
      expect(find.text('$directoryChannelCount 个频道'), findsOneWidget);
      expect(
        find.byKey(const Key('bookSourceListLazyChannels')),
        findsOneWidget,
      );
    }
    if (selectDirectoryChannel) {
      await tester.tap(
        find.byKey(
          const Key(
            'bookSourceListChannel-reading-source-reading-source-fantasy',
          ),
        ),
      );
      await _pumpUntil(
        tester,
        'selected directory channel',
        target: find.byKey(const Key('bookSourceListSelectionHeader')),
      );
      await _settleSliverTransitions(tester);
      expect(find.text('长风入夜'), findsOneWidget);
    }
  }

  if (organizationView == 'editor') {
    await tester.tap(
      find.byKey(
        const ValueKey('bookSourceOrganizationMore-literature-library'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入分组'));
    await tester.pumpAndSettle();
  }
  if (organizationView == 'manager') {
    await tester.tap(find.byKey(const Key('bookSourceOrganizationGroups')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bookSourceGroupPickerManage')));
    await tester.pumpAndSettle();
  }

  if ((!listLayout || selectDirectoryChannel) &&
      Platform.environment.containsKey('BOOK_SOURCE_PREVIEW_COVER_PATH')) {
    await _pumpUntilRealCovers(tester);
  }
  await _settlePageAnimations(tester);
  expect(find.text('发现'), findsOneWidget);
  expect(find.byType(CircularProgressIndicator), findsNothing);
  expect(tester.takeException(), isNull);
  await _writePng(tester, fileName);
}

Future<void> _pumpUntilRealCovers(WidgetTester tester) async {
  for (var frame = 0; frame < 40; frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    final renderImages = tester
        .renderObjectList<RenderImage>(find.byType(RawImage))
        .toList(growable: false);
    if (renderImages.isNotEmpty &&
        renderImages.every((renderImage) => renderImage.image != null) &&
        find.byType(GeneratedBookCover).evaluate().isEmpty) {
      return;
    }
  }
  fail('Preview cover images did not replace generated fallbacks.');
}

Future<void> _settlePageAnimations(WidgetTester tester) async {
  for (var frame = 0; frame < 40; frame++) {
    await tester.pump(const Duration(milliseconds: 80));
    if (!tester.hasRunningAnimations) return;
  }
  fail('Book-source preview still had running animations before capture.');
}

Future<void> _settleSliverTransitions(WidgetTester tester) async {
  for (var frame = 0; frame < 40; frame++) {
    await tester.pump(const Duration(milliseconds: 80));
    final transitions = tester
        .widgetList<SliverFadeTransition>(find.byType(SliverFadeTransition))
        .toList(growable: false);
    if (!tester.hasRunningAnimations &&
        transitions.every((transition) => transition.opacity.value >= 0.999)) {
      expect(find.byType(SourcedBookListTile), findsWidgets);
      return;
    }
  }
  fail('Book-source sliver transitions did not settle at full opacity.');
}

Future<void> _pumpUntil(
  WidgetTester tester,
  String label, {
  Finder? target,
}) async {
  final finder = target ?? find.text(label);
  for (var frame = 0; frame < 40; frame++) {
    await tester.pump(const Duration(milliseconds: 80));
    if (finder.evaluate().isNotEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 240));
      return;
    }
  }
  expect(finder, findsWidgets, reason: '$label did not become visible');
}

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
  final fontFile = fontFiles.first;
  final bytes = await fontFile.readAsBytes();
  Future<ByteData> fontData() => Future.value(
    ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
  );
  await Future.wait([
    (FontLoader(_previewFont)..addFont(fontData())).load(),
    _loadMaterialIcons(),
  ]);
}

Future<void> _loadMaterialIcons() async {
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
  final bytes = await File(
    '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytes();
  await (FontLoader('MaterialIcons')..addFont(
        Future.value(
          ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes),
        ),
      ))
      .load();
}

class _PreviewClient extends BookSourceClient {
  final int readingChannelCount;

  _PreviewClient({this.readingChannelCount = 4});

  @override
  Future<BookSourceDiscoveryPage> getDiscovery(
    RegisteredBookSource source,
  ) async {
    if (source.sourceProtocol == BookSourceProtocolKind.readingSource) {
      throw StateError('Reading sources must not request ORSP discovery.');
    }
    return BookSourceDiscoveryPage(
      sections: [
        BookSourceDiscoverySection(
          id: '${source.id}-featured',
          title: '文学拾光',
          items: [
            _book('grass', '人间草木', '汪曾祺', '在寻常草木与四季烟火里，读见生活的温度。'),
            _book('river', '山河故人', '余秋雨', '沿山河旧迹，重访时间留下的人与故事。'),
            _book('slow-walk', '慢慢走过', '丰子恺', '用清淡笔触记下日常里的诗意与从容。'),
          ],
        ),
      ],
    );
  }

  @override
  Future<List<BookSourceCategory>> getCategories(
    RegisteredBookSource source,
  ) async {
    if (source.sourceProtocol == BookSourceProtocolKind.readingSource) {
      return List.generate(readingChannelCount, (index) {
        final id = index == 0 ? 'fantasy' : 'channel-$index';
        return BookSourceCategory(
          id: '${source.id}-$id',
          name: _readingChannelNames[index % _readingChannelNames.length],
        );
      }, growable: false);
    }
    return [
      BookSourceCategory(id: '${source.id}-literature', name: '文学'),
      BookSourceCategory(id: '${source.id}-prose', name: '散文'),
      BookSourceCategory(id: '${source.id}-history', name: '历史'),
      BookSourceCategory(id: '${source.id}-biography', name: '传记'),
    ];
  }

  @override
  Future<BookSourceSearchPage> browse(
    RegisteredBookSource source, {
    String? category,
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) async {
    final books = [
      _book('night-wind', '长风入夜', '林舟', '少年踏入山海之间，在风起之处寻找失落已久的答案。'),
      _book('mountain-letter', '山海来信', '江南', '一封来自山间的信，开启了一段穿越山海的奇妙旅程。'),
      _book('immortal-road', '万里仙途', '陆青', '自小城启程，历经万千山河，走出属于自己的修行之路。'),
      _book('old-city', '故城灯火', '顾南', '灯火深处，旧城往事在夜色里缓缓苏醒。'),
    ];
    return BookSourceSearchPage(
      items: books,
      page: 1,
      pageSize: books.length,
      total: books.length,
      hasMore: false,
    );
  }
}

const _readingChannelNames = [
  '玄幻',
  '都市',
  '仙侠',
  '武侠',
  '科幻',
  '悬疑',
  '历史',
  '军事',
  '游戏',
  '竞技',
  '轻小说',
  '奇幻',
  '灵异',
  '现言',
  '古言',
  '青春',
  '校园',
  '豪门',
  '职场',
  '婚恋',
  '甜宠',
  '虐恋',
  '穿越',
  '重生',
  '系统',
  '末世',
  '完本',
  '连载',
  '新书',
  '排行',
];

RegisteredBookSource _source(
  String id,
  String name, {
  BookSourceProtocolKind protocol = BookSourceProtocolKind.orsp,
}) => RegisteredBookSource(
  id: id,
  name: name,
  description: '',
  manifestUrl: Uri.parse('https://preview.invalid/$id/source.json'),
  apiBaseUrl: Uri.parse('https://preview.invalid/$id/api/'),
  protocolVersion: '1.1',
  languages: const ['zh-CN'],
  capabilities: const {'search', 'discover', 'categories', 'browse'},
  sourceProtocol: protocol,
  sourceConfig: protocol == BookSourceProtocolKind.readingSource
      ? {
          'bookSourceName': name,
          'bookSourceUrl': 'https://preview.invalid/$id/',
          'exploreUrl': '小说::https://preview.invalid/$id/fiction',
          'ruleExplore': {'bookList': 'class.book'},
        }
      : null,
  enabled: true,
  addedAt: DateTime.utc(2026, 9, 5),
);

BookSourceBook _book(
  String id,
  String title,
  String author,
  String description,
) => BookSourceBook(
  id: id,
  title: title,
  author: author,
  description: description,
  coverUrl: Platform.environment.containsKey('BOOK_SOURCE_PREVIEW_COVER_PATH')
      ? Uri.parse('https://preview.invalid/covers/$id.png')
      : null,
  categories: const [],
  updatedAt: DateTime.utc(2026, 9, 5),
);

Future<void> _seedPreviewCovers(Directory cacheRoot) async {
  final coverPath = Platform.environment['BOOK_SOURCE_PREVIEW_COVER_PATH'];
  if (coverPath == null) return;
  final bytes = await File(coverPath).readAsBytes();
  final books = [
    _book('night-wind', '长风入夜', '林舟', ''),
    _book('mountain-letter', '山海来信', '江南', ''),
    _book('star-shore', '群星彼岸', '沈舟', ''),
    _book('grass', '人间草木', '汪曾祺', ''),
    _book('river', '山河故人', '余秋雨', ''),
    _book('slow-walk', '慢慢走过', '丰子恺', ''),
    _book('immortal-road', '万里仙途', '陆青', ''),
    _book('old-city', '故城灯火', '顾南', ''),
  ];
  final cacheDirectory = Directory(
    '${cacheRoot.path}/${SourceCoverCache.directoryName}',
  )..createSync(recursive: true);
  for (final book in books) {
    final url = book.coverUrl!;
    final rawKey = sha256
        .convert(utf8.encode('${url.toString()}\u0000'))
        .toString();
    await File(
      '${cacheDirectory.path}/default:$rawKey.img',
    ).writeAsBytes(bytes, flush: true);
  }
  SourceCoverCache.instance.clearMemory();
}
