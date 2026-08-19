import 'package:flutter/material.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_reading_progress.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/book_sources/caching/source_cover_cache.dart';
import 'package:xxread/pages/reader/comic/image_reader_host.dart';
import 'package:xxread/pages/reader/comic/online_comic_source.dart';
import 'package:xxread/utils/reader_themes.dart';

export 'package:xxread/pages/reader/comic/online_comic_kind.dart'
    show isOnlineComicSource;

/// Online image-source entry. The reading session lives in [ImageReaderHost].
class OnlineComicReaderPage extends StatelessWidget {
  const OnlineComicReaderPage({
    super.key,
    required this.source,
    required this.book,
    this.client,
    this.progressStore = const BookSourceReadingProgressStore(),
    this.shelfService,
    this.initialTheme,
    this.remoteImageCache,
  });

  final RegisteredBookSource source;
  final BookSourceBook book;
  final BookSourceClient? client;
  final BookSourceReadingProgressStore progressStore;
  final BookSourceShelfService? shelfService;
  final ReaderThemePalette? initialTheme;
  final SourceCoverCache? remoteImageCache;

  @override
  Widget build(BuildContext context) {
    return ImageReaderHost(
      source: OnlineComicSource(
        source: source,
        book: book,
        client: client,
        progressStore: progressStore,
        imageCache: remoteImageCache,
        theme: initialTheme,
      ),
    );
  }
}
