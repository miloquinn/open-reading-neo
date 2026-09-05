import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:xxread/models/book.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/pages/reader/comic/comic_reader_page.dart';
import 'package:xxread/pages/reader/native/native_reader_page.dart';
import 'package:xxread/pages/reader/native/txt_editor_copy.dart';
import 'package:xxread/pages/reader/pdf/pdf_reader_page.dart';
import 'package:xxread/services/books/book_format_support.dart';
import 'package:xxread/services/books/book_storage_repair_service.dart';
import 'package:xxread/services/books/book_dao.dart';
import 'package:xxread/services/books/web_book_file_store.dart';
import 'package:xxread/services/reader/replace_rule_service.dart';
import 'package:xxread/services/sync/reading_progress_sync_service.dart';
import 'package:xxread/services/sync/book_sync_identity.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';
import 'package:xxread/utils/book_open_transition.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_transitions.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/side_toast.dart';

enum _OnlineProgressChoice { keepLocal, later, useRemote }

class BookReaderLauncher {
  BookReaderLauncher._();

  /// Performs a short progress refresh and reloads the business row before
  /// navigation. A slow or unavailable WebDAV server never blocks opening.
  static Future<Book> refreshProgressBeforeOpen(
    BuildContext context,
    Book book, {
    Future<Book?> Function(int bookId)? reloadBook,
    Future<Book> Function(Book book)? applyCandidate,
    Duration timeout = const Duration(seconds: 1),
  }) async {
    if (!context.mounted || book.id == null) return book;
    final sync = Provider.of<WebDavSyncController?>(context, listen: false);
    if (sync?.autoResume != true ||
        sync?.autoSync != true ||
        sync?.scope.progress != true) {
      return book;
    }
    try {
      await sync!.checkProgressBeforeOpen().timeout(timeout);
      final reloaded =
          await (reloadBook ?? BookDao().getBookById)(book.id!) ?? book;
      final resumed =
          await (applyCandidate ??
              ReadingProgressSyncService.instance.applySafeCandidateBeforeOpen)(
            reloaded,
          );
      if (!resumed.isOnline ||
          ReadingProgressSyncService.instance.takeContinuationApplied(
            resumed.id!,
          )) {
        return resumed;
      }
      if (!context.mounted) return book;
      return await chooseOnlineCandidate(context, resumed);
    } catch (error) {
      debugPrint('Progress pre-open refresh deferred: $error');
      return book;
    }
  }

  @visibleForTesting
  static Future<Book> chooseOnlineCandidate(
    BuildContext context,
    Book book, {
    List<ReadingProgressRemoteCandidate>? candidatesOverride,
    Future<void> Function(ReadingProgressRemoteCandidate candidate)? keepLocal,
    Future<void> Function(ReadingProgressRemoteCandidate candidate)? later,
    Future<Book> Function(ReadingProgressRemoteCandidate candidate)? useRemote,
  }) async {
    final candidates =
        candidatesOverride ??
        await ReadingProgressSyncService.instance.candidatesFor(
          book.id!,
          includeSnoozed: false,
        );
    if (candidates.isEmpty || !context.mounted) return book;
    final candidate = candidates.first;
    final copy = TxtEditorCopy.of(context);
    final source = candidate.snapshot.sourceProgress;
    final chapter = source?['chapterId'] as String?;
    final chapterProgress = (source?['chapterProgress'] as num?)?.toDouble();
    final position = chapter != null
        ? copy.chapterProgress(
            chapter,
            ((chapterProgress ?? 0) * 100).round().clamp(0, 100).toInt(),
          )
        : copy.pageProgress(candidate.snapshot.currentPage);
    final choice = await showDialog<_OnlineProgressChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(copy.remoteProgressChoiceTitle),
        content: Text(copy.remoteProgressChoiceBody(position)),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _OnlineProgressChoice.keepLocal),
            child: Text(copy.keepLocalProgress),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _OnlineProgressChoice.later),
            child: Text(copy.later),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _OnlineProgressChoice.useRemote),
            child: Text(copy.useRemoteProgress),
          ),
        ],
      ),
    );
    switch (choice) {
      case _OnlineProgressChoice.useRemote:
        if (useRemote != null) return useRemote(candidate);
        final applied = await ReadingProgressSyncService.instance
            .applyCandidate(book.id!, candidate, currentBook: book);
        if (applied) {
          ReadingProgressSyncService.instance.takeContinuationApplied(book.id!);
        }
        return applied ? (await BookDao().getBookById(book.id!) ?? book) : book;
      case _OnlineProgressChoice.keepLocal:
        await (keepLocal?.call(candidate) ??
            ReadingProgressSyncService.instance.ignoreCandidate(candidate));
        return book;
      case _OnlineProgressChoice.later:
        await (later?.call(candidate) ??
            ReadingProgressSyncService.instance.snoozeCandidate(
              book.id!,
              candidate,
            ));
        return book;
      case null:
        return book;
    }
  }

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
    if (!kIsWeb && repaired.id != null && context.mounted) {
      final sync = Provider.of<WebDavSyncController?>(context, listen: false);
      if (sync?.autoSync == true && sync?.scope.bookFiles == true) {
        try {
          final uid = await stableBookUid(repaired);
          final states = await sync!.mutableTxtService.listStates();
          final enabled = states.any(
            (state) => state.bookUid == uid && state.enabled,
          );
          if (enabled && await sync.mutableTxtService.applyPendingRemote(uid)) {
            repaired = await BookDao().getBookById(repaired.id!) ?? repaired;
          }
        } catch (error) {
          debugPrint('Pending TXT update deferred: $error');
        }
      }
    }
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
              emitSyncEvent: false,
            );
          } catch (error) {
            debugPrint('repair downloaded source progress failed: $error');
          }
        }
        repaired = progressRepaired;
      }
    }
    final progressSync = ReadingProgressSyncService.instance;
    final bookId = repaired.id;
    if (bookId != null) {
      if (!context.mounted) return;
      progressSync.beginOpening(repaired);
      repaired = await refreshProgressBeforeOpen(context, repaired);
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
      if (bookId != null) progressSync.cancelOpening(bookId);
      return;
    }
    final format = repaired.format.toLowerCase();
    final formatSpec = BookFormatRegistry.specForExtension(format);
    final destination = BookFormatRegistry.readerDestinationFor(format);
    if (destination == BookReaderDestination.comic) {
      if (bookId != null) progressSync.cancelOpening(bookId);
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
      if (bookId != null) progressSync.cancelOpening(bookId);
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
      if (bookId != null) progressSync.cancelOpening(bookId);
      if (context.mounted) {
        showSideToast(
          context,
          context.l10n.readerUnsupportedFormat,
          kind: SideToastKind.warning,
        );
      }
      return;
    }
    if (!context.mounted) {
      if (bookId != null) progressSync.cancelOpening(bookId);
      return;
    }
    // Resolve the reader palette before pushing the route so its very first
    // opaque frame already matches the saved reading theme. Letting the reader
    // load it after navigation produces a visible white flash for dark themes.
    final resolvedInitialTheme = await initialThemeFuture;
    if (!context.mounted) {
      if (bookId != null) progressSync.cancelOpening(bookId);
      return;
    }
    if (bookId != null) progressSync.activate(bookId);
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
    var navigation = BookOpenTransition.push<void>(context, route);
    if (bookId != null) {
      navigation = navigation.whenComplete(
        () => progressSync.endSession(bookId),
      );
    }
    if (waitForReaderClose) {
      await navigation;
    } else {
      unawaited(navigation);
    }
  }
}
