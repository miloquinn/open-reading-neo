import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/book_sources/models/sourced_book.dart';
import 'package:xxread/pages/book_sources/sourced_book_details_page.dart';
import 'package:xxread/services/library/download_task_controller.dart';

void main() {
  testWidgets(
    'summary and reading remain available while details load and fail',
    (tester) async {
      final gateway = _Gateway(pending: Completer<BookSourceBook>());
      await tester.pumpWidget(_harness(gateway: gateway));
      expect(find.text('山海之间'), findsWidgets);
      expect(find.byKey(const Key('bookSourceDetailsLoading')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('bookSourceReadButton')))
            .onPressed,
        isNotNull,
      );
      gateway.pending!.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bookSourceDetailsLoading')), findsNothing);
      expect(
        find.byKey(const Key('bookSourceDetailsRetryButton')),
        findsOneWidget,
      );
      expect(find.text(_book.description), findsOneWidget);
      gateway.pending = null;
      await tester.tap(find.byKey(const Key('bookSourceDetailsRetryButton')));
      await tester.pumpAndSettle();
      expect(gateway.calls, 2);
      expect(
        find.byKey(const Key('bookSourceDetailsRetryButton')),
        findsNothing,
      );
    },
  );

  testWidgets('reader returns to details and can be opened again', (
    tester,
  ) async {
    var reads = 0;
    await tester.pumpWidget(
      _harness(
        onRead: (context, book) async {
          reads++;
          expect(book.id, _book.id);
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('Reader')),
                body: const Text('Chapter content'),
              ),
            ),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const Key('bookSourceReadButton')));
      await tester.pumpAndSettle();
      expect(find.text('Chapter content'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bookSourceDetailsPage')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('bookSourceReadButton')))
            .onPressed,
        isNotNull,
      );
    }
    expect(reads, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending shelf add cannot be submitted twice and stays on page', (
    tester,
  ) async {
    final shelf = _Shelf(pending: Completer<Book>());
    await tester.pumpWidget(_harness(shelf: shelf));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bookSourceAddToShelfButton')));
    await tester.pump();
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const Key('bookSourceAddToShelfButton')),
          )
          .onPressed,
      isNull,
    );
    expect(shelf.adds, 1);
    shelf.pending!.complete(_shelfBook);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bookSourceOnShelf')), findsOneWidget);
    expect(find.byKey(const Key('bookSourceDetailsPage')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled download can be dismissed without leaving details', (
    tester,
  ) async {
    final shelf = _Shelf();
    await tester.pumpWidget(_harness(shelf: shelf));
    await tester.pumpAndSettle();
    final option = find.byKey(const Key('bookSourceDownloadLocalOption'));
    await tester.ensureVisible(option);
    await tester.tap(option);
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('bookSourceReadButton')))
          .onPressed,
      isNull,
    );
    final cancel = find.descendant(
      of: find.byKey(const Key('bookSourceDownloadInline')),
      matching: find.byType(TextButton),
    );
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pump();
    shelf.download.complete(_shelfBook);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bookSourceDownloadInline')), findsOneWidget);
    final back = find.descendant(
      of: find.byKey(const Key('bookSourceDownloadInline')),
      matching: find.byType(TextButton),
    );
    await tester.ensureVisible(back);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bookSourceDownloadInline')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('bookSourceReadButton')))
          .onPressed,
      isNotNull,
    );
    expect(find.byKey(const Key('bookSourceDetailsPage')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final variant in [
    (name: 'mobile', size: const Size(390, 844), scale: 1.0, dark: false),
    (name: 'narrow', size: const Size(320, 640), scale: 1.0, dark: false),
    (name: 'dark-large', size: const Size(390, 844), scale: 1.6, dark: true),
    (name: 'tablet', size: const Size(1100, 850), scale: 1.0, dark: false),
  ]) {
    testWidgets('details stay usable at ${variant.name}', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = variant.size;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 20);
      addTearDown(tester.view.reset);
      final previewDir = Platform.environment['DETAILS_PREVIEW_DIR'];
      if (previewDir != null) {
        await tester.runAsync(() async {
          final font = await File(
            '/System/Library/Fonts/Hiragino Sans GB.ttc',
          ).readAsBytes();
          await (FontLoader(
            'DetailsPreview',
          )..addFont(Future.value(ByteData.sublistView(font)))).load();
          await (FontLoader(
            'Ahem',
          )..addFont(Future.value(ByteData.sublistView(font)))).load();
          final root = Platform.resolvedExecutable.split('/bin/cache').first;
          final icons = await File(
            '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes();
          await (FontLoader(
            'MaterialIcons',
          )..addFont(Future.value(ByteData.sublistView(icons)))).load();
        });
      }
      await tester.pumpWidget(
        _harness(scale: variant.scale, dark: variant.dark),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final readRect = tester.getRect(
        find.byKey(const Key('bookSourceReadButton')),
      );
      expect(readRect.bottom, lessThanOrEqualTo(variant.size.height - 20));
      expect(readRect.height, greaterThanOrEqualTo(48));
      if (previewDir != null) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('detailsPreview')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(previewDir).create(recursive: true);
          await File(
            '$previewDir/${variant.name}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.ensureVisible(
        find.byKey(const Key('bookSourceDownloadLocalOption')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('bookSourceDownloadLocalOption')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

Widget _harness({
  _Gateway? gateway,
  _Shelf? shelf,
  double scale = 1,
  bool dark = false,
  Future<void> Function(BuildContext, BookSourceBook)? onRead,
}) => ChangeNotifierProvider(
  create: (_) => DownloadTaskController(),
  child: MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'DetailsPreview',
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF526B62),
        brightness: dark ? Brightness.dark : Brightness.light,
      ),
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: RepaintBoundary(key: const Key('detailsPreview'), child: child!),
    ),
    home: SourcedBookDetailsPage(
      result: SourcedBook(source: _source, book: _book),
      gateway: gateway ?? _Gateway(),
      shelfService: shelf ?? _Shelf(),
      onRead: onRead ?? (_, _) async {},
      onDownloadContinuesInBackground: () {},
    ),
  ),
);

final _source = RegisteredBookSource(
  id: 'source',
  name: '山海书屋',
  description: '',
  manifestUrl: Uri.parse('https://example.org/source.json'),
  apiBaseUrl: Uri.parse('https://example.org/api/'),
  protocolVersion: '1.1',
  languages: const ['zh'],
  capabilities: const {'search'},
  enabled: true,
  addedAt: DateTime.utc(2026),
);
const _book = BookSourceBook(
  id: 'book',
  title: '山海之间',
  author: '林间客',
  description:
      '一封来自故乡的信，让远行多年的游子重新踏上归途。\n\n沿着旧时的山路，他走过晨雾中的村落、海边的灯塔，也慢慢找回那些被岁月遗忘的名字。这是关于相遇、告别与重新出发的故事。',
  categories: ['文学', '旅行'],
  status: '连载中',
  latestChapter: '第二十四章 · 风从海上来',
);
final _shelfBook = Book(
  id: 1,
  title: _book.title,
  author: _book.author,
  filePath: '',
  format: 'source',
  storageType: 'online',
  sourceId: 'source',
  sourceBookId: 'book',
);

class _Gateway extends BookSourceClient {
  _Gateway({this.pending});
  Completer<BookSourceBook>? pending;
  int calls = 0;
  @override
  Future<BookSourceBook> getBook(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async {
    calls++;
    return pending?.future ?? _book;
  }
}

class _Shelf extends BookSourceShelfService {
  _Shelf({this.pending});
  final Completer<Book>? pending;
  bool added = false;
  int adds = 0;
  final download = Completer<Book>();

  @override
  Future<Book> downloadToLocal({
    required RegisteredBookSource source,
    required BookSourceBook book,
    String? bookUid,
    void Function(int completed, int total)? onProgress,
    BookDownloadCancellation? cancellation,
  }) {
    onProgress?.call(1, 3);
    return download.future;
  }

  @override
  Future<Book?> findShelfBook({
    required String sourceId,
    required String sourceBookId,
  }) async => added ? _shelfBook : null;
  @override
  Future<Book> addOnline({
    required RegisteredBookSource source,
    required BookSourceBook book,
  }) async {
    adds++;
    final result = await (pending?.future ?? Future.value(_shelfBook));
    added = true;
    return result;
  }
}
