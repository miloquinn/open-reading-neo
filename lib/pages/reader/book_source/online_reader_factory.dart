import 'package:flutter/widgets.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/reader/book_source/book_source_reader_page.dart';
import 'package:xxread/pages/reader/book_source/online_comic_reader_page.dart';
import 'package:xxread/services/reader/replace_rule_service.dart';
import 'package:xxread/utils/reader_themes.dart';

/// Builds the correct online reader while callers retain resource ownership.
Widget buildOnlineReader({
  Book? shelfBook,
  RegisteredBookSource? source,
  BookSourceBook? sourceBook,
  required ReplaceRuleService replaceRuleService,
  BookSourceClient? client,
  BookSourceShelfService? shelfService,
  ReaderThemePalette? initialTheme,
}) {
  final hasExplicitBinding = source != null || sourceBook != null;
  if (shelfBook != null && hasExplicitBinding) {
    throw ArgumentError(
      'Provide either a shelf book or an explicit source/book pair, not both.',
    );
  }
  if (shelfBook == null && (source == null || sourceBook == null)) {
    throw ArgumentError(
      'Provide a shelf book or a complete explicit source/book pair.',
    );
  }
  if (shelfBook != null && shelfService == null) {
    throw ArgumentError('A shelf service is required to resolve a shelf book.');
  }
  late final RegisteredBookSource resolvedSource;
  late final BookSourceBook resolvedBook;
  if (shelfBook != null) {
    final binding = shelfService!.bindingFrom(shelfBook);
    resolvedSource = binding.source;
    resolvedBook = binding.book;
  } else {
    resolvedSource = source!;
    resolvedBook = sourceBook!;
  }
  if (isOnlineComicSource(resolvedSource, resolvedBook)) {
    return OnlineComicReaderPage(
      source: resolvedSource,
      book: resolvedBook,
      client: client,
      shelfService: shelfService,
      initialTheme: initialTheme,
    );
  }
  return BookSourceReaderPage(
    source: resolvedSource,
    book: resolvedBook,
    replaceRuleService: replaceRuleService,
    client: client,
    shelfService: shelfService,
    initialTheme: initialTheme,
  );
}
