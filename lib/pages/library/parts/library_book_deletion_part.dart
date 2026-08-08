// 文件说明：单本与批量删除的确认、进度及文件清理流程。
// 技术要点：LibraryPage 私有操作拆分，状态所有权仍保留在主页面。

part of '../library_page.dart';

extension _LibraryPageBookDeletion on _LibraryPageState {
  void _confirmDeleteBook(Book book) {
    final isMaterial3Style = _isMaterial3Style;
    final scheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (context) {
        final dialog = AlertDialog(
          backgroundColor: isMaterial3Style
              ? scheme.surfaceContainerHigh
              : GlassEffectConfig.surfaceColor(context, opacity: 0.95),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(
            context.l10n.libraryConfirmDeleteTitle,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          content: Text(context.l10n.libraryDeleteBookMessage(book.title)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.cancel),
            ),
            TextButton(
              onPressed: () async {
                final navigator = Navigator.of(context);
                final toastContext = this.context;
                navigator.pop();

                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => PopScope(
                    canPop: false,
                    child: AlertDialog(
                      backgroundColor: isMaterial3Style
                          ? scheme.surfaceContainerHigh
                          : Theme.of(
                              context,
                            ).colorScheme.surface.withValues(alpha: 0.95),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      content: Row(
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Text(
                              context.l10n.libraryDeletingBook(book.title),
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );

                try {
                  await _performBookDeletion(book);
                  if (!mounted) return;

                  navigator.pop();
                  _loadBooks();
                  if (!toastContext.mounted) return;
                  showSideToast(
                    toastContext,
                    toastContext.l10n.libraryBookDeletedToast(book.title),
                    kind: SideToastKind.success,
                  );
                } catch (e) {
                  if (!mounted) return;
                  navigator.pop();

                  if (!toastContext.mounted) return;
                  showSideToast(
                    toastContext,
                    toastContext.l10n.libraryDeleteFailed('$e'),
                    kind: SideToastKind.error,
                  );
                }
              },
              child: Text(
                context.l10n.delete,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        );

        if (isMaterial3Style || GlassEffectConfig.shouldDisableBlur) {
          return dialog;
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: dialog,
          ),
        );
      },
    );
  }

  Future<void> _confirmDeleteSelectedBooks() async {
    final selectedIds = _selection.selectedIds;
    if (selectedIds.isEmpty) return;
    final selectedBooks = _books
        .where((book) => book.id != null && selectedIds.contains(book.id))
        .toList(growable: false);
    if (selectedBooks.isEmpty) return;

    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.libraryBatchDeleteTitle),
        content: Text(l10n.libraryBatchDeleteMessage(selectedBooks.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _deleteSelectedBooks(selectedBooks);
  }

  Future<void> _deleteSelectedBooks(List<Book> selectedBooks) async {
    final progress = ValueNotifier<int>(0);
    final l10n = context.l10n;
    final navigator = Navigator.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (context, done, _) => Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(
                  child: Text(
                    l10n.libraryDeletingSelected(done, selectedBooks.length),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final failedIds = <int>{};
    final deletedIds = <int>{};
    for (var index = 0; index < selectedBooks.length; index += 1) {
      final book = selectedBooks[index];
      try {
        await _performBookDeletion(book);
        if (book.id != null) deletedIds.add(book.id!);
      } catch (_) {
        if (book.id != null) failedIds.add(book.id!);
      }
      progress.value = index + 1;
    }

    if (!mounted) {
      progress.dispose();
      return;
    }
    navigator.pop();
    progress.dispose();
    _updateState(() {
      _books.removeWhere((book) => deletedIds.contains(book.id));
      _booksRevision++;
      if (failedIds.isEmpty) {
        _selection.exit();
      } else {
        _selection.retainOnly(failedIds);
      }
    });
    _syncSelection();
    LibraryEventBus().notifyLibraryChanged();

    if (failedIds.isEmpty) {
      showSideToast(
        context,
        l10n.libraryBatchDeleteSuccess(deletedIds.length),
        kind: SideToastKind.success,
      );
    } else {
      showSideToast(
        context,
        l10n.libraryBatchDeletePartial(deletedIds.length, failedIds.length),
        kind: SideToastKind.error,
      );
    }
  }

  /// 执行书籍删除操作（在后台执行）
  ///
  /// 彻底删除书籍及其所有相关文件和缓存：
  /// 1. 删除书籍原文件
  /// 2. 删除封面图片文件
  /// 3. 删除分页缓存文件
  /// 4. 删除数据库记录（会级联删除笔记、书签等）
  ///
  /// 参数 [onProgress] 进度回调，用于更新UI提示信息
  Future<void> _performBookDeletion(
    Book book, {
    void Function(String message)? onProgress,
  }) async {
    final l10n = context.l10n;
    await _bookDeletionService.delete(
      book,
      onProgress: (stage) => onProgress?.call(switch (stage) {
        BookDeletionStage.bookFile => l10n.libraryDeletingBookFile,
        BookDeletionStage.coverImage => l10n.libraryDeletingCoverImage,
        BookDeletionStage.database => l10n.libraryCleaningDatabase,
        BookDeletionStage.complete => l10n.libraryDeleteComplete,
      }),
    );
  }
}
