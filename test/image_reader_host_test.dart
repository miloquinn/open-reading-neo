import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/reader/comic/image_reader_host.dart';
import 'package:xxread/pages/reader/comic/image_reader_source.dart';
import 'package:xxread/pages/reader/comic/online_comic_kind.dart';
import 'package:xxread/pages/reader/image/paged_image_reader.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/utils/reader_themes.dart';

/// 1x1 transparent PNG that Image.memory can decode.
final Uint8List _tinyPng = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _FakeImageSource extends ImageReaderSource {
  _FakeImageSource({
    required this.chapters,
    required this.pagesByChapter,
    this.initialChapterIndex = 0,
    this.initialPageIndex = 0,
    this.failingChapters = const {},
  });

  final List<ImageReaderChapter> chapters;
  final Map<int, int> pagesByChapter;
  final int initialChapterIndex;
  final int initialPageIndex;
  final Set<int> failingChapters;

  final List<({int chapterIndex, int pageIndex, int pageCount})> saved = [];
  final List<int> invalidated = [];
  int pageCountLoads = 0;

  @override
  String get bookTitle => 'Host book';

  @override
  ReaderThemePalette get theme => ReaderThemes.day;

  @override
  Future<ImageReaderDocument> loadDocument() async {
    return ImageReaderDocument(
      chapters: chapters,
      initialChapterIndex: initialChapterIndex,
      initialPageIndex: initialPageIndex,
    );
  }

  @override
  Future<int> loadChapterPageCount(int chapterIndex) async {
    pageCountLoads++;
    if (failingChapters.contains(chapterIndex)) {
      throw StateError('chapter $chapterIndex failed');
    }
    return pagesByChapter[chapterIndex] ?? 0;
  }

  @override
  Future<Uint8List> loadPage(int chapterIndex, int pageIndex) async => _tinyPng;

  @override
  Future<void> saveProgress({
    required int chapterIndex,
    required int pageIndex,
    required int pageCount,
  }) async {
    saved.add((
      chapterIndex: chapterIndex,
      pageIndex: pageIndex,
      pageCount: pageCount,
    ));
  }

  @override
  void invalidateChapter(int chapterIndex) => invalidated.add(chapterIndex);

  @override
  String emptyPagesMessage(AppLocalizations l10n) => l10n.readerComicNoPages;

  @override
  String describeError(Object error, AppLocalizations l10n) =>
      l10n.readerOpenFailed(error.toString());
}

Future<void> _pumpHost(WidgetTester tester, ImageReaderSource source) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ImageReaderHost(source: source),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  const fullscreenChannel = MethodChannel('com.niki.xxread/fullscreen');
  const readerKeysChannel = MethodChannel('com.niki.xxread/reader_keys');

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fullscreenChannel, (_) async => null);
    messenger.setMockMethodCallHandler(readerKeysChannel, (_) async => null);
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fullscreenChannel, null);
    messenger.setMockMethodCallHandler(readerKeysChannel, null);
  });

  test('image sources are classified by source type or book type', () {
    final imageSource = RegisteredBookSource(
      id: 'src',
      name: 'Images',
      description: '',
      manifestUrl: Uri.parse('https://example.test/'),
      apiBaseUrl: Uri.parse('https://example.test/'),
      protocolVersion: 'reading-source-1',
      languages: const [],
      capabilities: const {'search', 'detail', 'catalog', 'content'},
      enabled: true,
      addedAt: DateTime.utc(2026, 1, 1),
      sourceProtocol: BookSourceProtocolKind.readingSource,
      sourceConfig: const {'bookSourceType': 2},
    );
    const imageBook = BookSourceBook(
      id: 'book',
      title: 'Comic',
      author: '',
      description: '',
      categories: [],
      type: 64,
    );
    const textBook = BookSourceBook(
      id: 'book',
      title: 'Novel',
      author: '',
      description: '',
      categories: [],
    );

    expect(isOnlineComicSource(imageSource, textBook), isTrue);
    expect(
      isOnlineComicSource(imageSource.copyWith(sourceConfig: {}), imageBook),
      isTrue,
    );
    expect(
      isOnlineComicSource(imageSource.copyWith(sourceConfig: {}), textBook),
      isFalse,
    );
  });

  testWidgets('host restores the saved chapter and page on one reading line', (
    tester,
  ) async {
    final source = _FakeImageSource(
      chapters: const [
        ImageReaderChapter(id: 'c1', title: 'One'),
        ImageReaderChapter(id: 'c2', title: 'Two'),
      ],
      pagesByChapter: const {0: 2, 1: 4},
      initialChapterIndex: 1,
      initialPageIndex: 2,
    );

    await _pumpHost(tester, source);

    expect(find.byType(PagedImageReader), findsOneWidget);
    expect(find.text('Host book · Two'), findsOneWidget);
    expect(find.text('3 / 4'), findsOneWidget);
    expect(source.pageCountLoads, 1);
    await _unmount(tester);
  });

  testWidgets(
    'crossing the last page opens the next chapter on the same host',
    (tester) async {
      final source = _FakeImageSource(
        chapters: const [
          ImageReaderChapter(id: 'c1', title: 'One'),
          ImageReaderChapter(id: 'c2', title: 'Two'),
        ],
        pagesByChapter: const {0: 1, 1: 2},
      );

      await _pumpHost(tester, source);
      expect(find.text('Host book · One'), findsOneWidget);

      await tester.tapAt(const Offset(700, 400));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('Host book · Two'), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      await _unmount(tester);
    },
  );

  testWidgets('retry invalidates the failed chapter and reloads it', (
    tester,
  ) async {
    final source = _FakeImageSource(
      chapters: const [ImageReaderChapter(id: 'c1', title: 'One')],
      pagesByChapter: const {0: 2},
      failingChapters: {0},
    );

    await _pumpHost(tester, source);
    expect(find.textContaining('Failed to open'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(source.invalidated, [0]);
    expect(source.pageCountLoads, 2);
    await _unmount(tester);
  });
}
