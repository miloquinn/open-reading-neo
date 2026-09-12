import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/pages/reader/book_source/online_reader_factory.dart';
import 'package:xxread/services/reader/replace_rule_service.dart';
import 'package:xxread/utils/book_open_transition.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_transitions.dart';
import 'package:xxread/widgets/side_toast.dart';

import '../models/sourced_book.dart';
import '../sourced_book_details_page.dart';

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
    final page = SourcedBookDetailsPage(
      result: result,
      gateway: client,
      shelfService: shelfService,
      onRead: (pageContext, book) => _openReader(
        pageContext,
        SourcedBook(source: result.source, book: book),
      ),
      onDownloadContinuesInBackground: () {
        if (!context.mounted) return;
        showSideToast(context, context.l10n.downloadRunningInBackground);
      },
    );
    unawaited(
      Navigator.of(context).push<void>(
        MediaQuery.disableAnimationsOf(context)
            ? CustomPageTransitions.createInstantRoute<void>(page)
            : MaterialPageRoute<void>(builder: (_) => page),
      ),
    );
  }

  Future<void> _openReader(BuildContext context, SourcedBook result) async {
    if (!context.mounted) return;
    final reader = buildOnlineReader(
      source: result.source,
      sourceBook: result.book,
      replaceRuleService: context.read<ReplaceRuleService>(),
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
