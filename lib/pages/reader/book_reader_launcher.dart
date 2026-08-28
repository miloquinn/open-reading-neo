import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:xxread/models/book.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/pages/reader/comic/comic_reader_page.dart';
import 'package:xxread/pages/reader/native/native_reader_page.dart';
import 'package:xxread/pages/reader/pdf/pdf_reader_page.dart';
import 'package:xxread/services/books/book_format_support.dart';
import 'package:xxread/services/books/book_storage_repair_service.dart';
import 'package:xxread/services/books/book_dao.dart';
import 'package:xxread/services/books/web_book_file_store.dart';
import 'package:xxread/services/reader/replace_rule_service.dart';
import 'package:xxread/utils/book_open_transition.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_transitions.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/side_toast.dart';

class BookReaderLauncher {
  BookReaderLauncher._();

  static Future<void> openBook(
    BuildContext context,
    Book book, {
    BookOpenAnimation? animation,
    LibraryBookOpenAnimation? libraryAnimation,
    LibraryBookOpenAnimationPace animationPace =
        LibraryBookOpenAnimationPace.fast,
    ReaderThemePalette? initialTheme,
    ReaderPageTransitionOrigin origin = ReaderPageTransitionOrigin.standard,
    bool waitForReaderClose = true,
  }) async {
    final initialThemeFuture = initialTheme == null
        ? ReaderThemes.loadSavedPalette()
        : SynchronousFuture(initialTheme);
    var repaired = kIsWeb
        ? book
        : await BookStorageRepairService().repairSingleBookIfNeeded(book);
    if (!kIsWeb) {
      final progressRepaired =
          BookSourceShelfService.repairLegacyDownloadedProgress(repaired);
      if (progressRepaired.currentPage != repaired.currentPage) {
        final bookId = progressRepaired.id;
        if (bookId != null) {
          try {
            await BookDao().updateBookProgress(
              bookId,
              progressRepaired.currentPage,
              readingProgress: progressRepaired.readingProgress,
            );
          } catch (error) {
            debugPrint('repair downloaded source progress failed: $error');
          }
        }
        repaired = progressRepaired;
      }
    }
    final fileExists = kIsWeb
        ? WebBookFileStore.isWebBookPath(repaired.filePath) &&
              await WebBookFileStore().exists(repaired.filePath)
        : await File(repaired.filePath).exists();
    if (!fileExists) {
      if (context.mounted) {
        showSideToast(
          context,
          context.l10n.readerFileMissing,
          kind: SideToastKind.error,
        );
      }
      return;
    }
    final format = repaired.format.toLowerCase();
    final formatSpec = BookFormatRegistry.specForExtension(format);
    final destination = BookFormatRegistry.readerDestinationFor(format);
    if (destination == BookReaderDestination.comic) {
      final resolvedInitialTheme = await initialThemeFuture;
      if (!context.mounted) return;
      await ComicReaderPage.open(
        context,
        repaired,
        initialTheme: resolvedInitialTheme,
        animation: animation,
        libraryAnimation: libraryAnimation,
        animationPace: animationPace,
        waitForReaderClose: waitForReaderClose,
      );
      return;
    }
    if (destination == BookReaderDestination.pdf) {
      if (!context.mounted) return;
      // pdfx 没有 Linux 实现（Android/iOS/macOS/Windows/Web 可用）。
      if (!kIsWeb && Platform.isLinux) {
        showSideToast(
          context,
          context.l10n.readerPdfLinuxUnsupported,
          kind: SideToastKind.warning,
        );
        return;
      }
      final resolvedInitialTheme = await initialThemeFuture;
      if (!context.mounted) return;
      await PdfReaderPage.open(
        context,
        repaired,
        initialTheme: resolvedInitialTheme,
        animation: animation,
        libraryAnimation: libraryAnimation,
        animationPace: animationPace,
        waitForReaderClose: waitForReaderClose,
      );
      return;
    }
    // kindle_unpack depends on dart:io; Web only has the safe parser stub.
    if (destination != BookReaderDestination.text ||
        (kIsWeb && formatSpec?.id == 'kindle')) {
      if (context.mounted) {
        showSideToast(
          context,
          context.l10n.readerUnsupportedFormat,
          kind: SideToastKind.warning,
        );
      }
      return;
    }
    if (!context.mounted) return;
    // Resolve the reader palette before pushing the route so its very first
    // opaque frame already matches the saved reading theme. Letting the reader
    // load it after navigation produces a visible white flash for dark themes.
    final resolvedInitialTheme = await initialThemeFuture;
    if (!context.mounted) return;
    final route = BookOpenTransition.createRoute<void>(
      NativeReaderPage(
        book: repaired,
        replaceRuleService: context.read<ReplaceRuleService>(),
        initialTheme: resolvedInitialTheme,
      ),
      animation: animation,
      libraryAnimation: libraryAnimation,
      animationPace: animationPace,
      readerBackgroundColor: resolvedInitialTheme.background,
      origin: origin,
      waitForReaderReady: true,
    );
    final navigation = BookOpenTransition.push<void>(context, route);
    if (waitForReaderClose) {
      await navigation;
    } else {
      unawaited(navigation);
    }
  }
}
