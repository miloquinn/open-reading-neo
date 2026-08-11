import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/pages/reader/book_source/book_source_reader_page.dart';
import 'package:xxread/pages/reader/book_source/online_comic_reader_page.dart';
import 'package:xxread/utils/book_open_transition.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_transitions.dart';
import 'package:xxread/widgets/side_toast.dart';

import '../models/sourced_book.dart';
import 'sourced_book_details_sheet.dart';

/// Context-owned UI orchestration for sourced-book details and navigation.
class SourcedBookActions {
  const SourcedBookActions({
    required this.context,
    required this.client,
    required this.shelfService,
  });

  final BuildContext context;
  final BookSourceClient client;
  final BookSourceShelfService shelfService;

  void showBookDetails(SourcedBook result) {
    final media = MediaQuery.of(context);
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        useSafeArea: true,
        constraints: BoxConstraints(
          maxWidth: math.min(media.size.width, 640),
          maxHeight: math.min(
            media.size.height * 0.9,
            media.size.height - media.padding.top - 16,
          ),
        ),
        builder: (_) => SourcedBookDetailsLoader(
          result: result,
          gateway: client,
          shelfService: shelfService,
          onRead: (book) =>
              _openReader(SourcedBook(source: result.source, book: book)),
          onDownloadContinuesInBackground: () {
            if (!context.mounted) return;
            showSideToast(context, context.l10n.downloadRunningInBackground);
          },
        ),
      ),
    );
  }

  Future<void> _openReader(SourcedBook result) async {
    if (!context.mounted) return;
    final reader = isOnlineComicSource(result.source, result.book)
        ? OnlineComicReaderPage(
            source: result.source,
            book: result.book,
            client: client,
            shelfService: shelfService,
          )
        : BookSourceReaderPage(
            source: result.source,
            book: result.book,
            client: client,
            shelfService: shelfService,
          );
    final route = BookOpenTransition.createRoute<void>(
      reader,
      origin: ReaderPageTransitionOrigin.discoverSheet,
      waitForReaderReady: true,
    );
    await BookOpenTransition.push<void>(context, route);
  }
}
