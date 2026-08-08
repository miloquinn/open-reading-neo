// 文件说明：书库下载、换源、AI 预处理与文件导出命令。
// 技术要点：LibraryPage 私有操作拆分，状态所有权仍保留在主页面。

part of '../library_page.dart';

extension _LibraryPageBookCommands on _LibraryPageState {
  Future<void> _downloadOnlineBook(Book book) async {
    final source = _sourceShelfService.sourceFrom(book);
    final sourceBook = _sourceShelfService.sourceBookFrom(book);
    final taskId = context.read<DownloadTaskController>().enqueueBookDownload(
      source: source,
      book: sourceBook,
      shelfService: _sourceShelfService,
    );
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BookDownloadTaskDialog(taskId: taskId),
    );
    if (!mounted) return;
    showSideToast(context, context.l10n.downloadRunningInBackground);
  }

  Future<void> _changeOnlineBookSource(Book book) async {
    final source = _sourceShelfService.sourceFrom(book);
    final sourceBook = _sourceShelfService.sourceBookFrom(book);
    final result = await Navigator.of(context).push<BookSourceChangeResult>(
      MaterialPageRoute(
        builder: (_) => BookSourceChangePage(
          sourcesFuture: BookSourceRegistry().loadRunnableInBackground(),
          currentSource: source,
          currentBook: sourceBook,
          shelfBook: book,
          service: BookSourceChangeService(shelfService: _sourceShelfService),
        ),
      ),
    );
    if (!mounted || result == null) return;
    await _loadBooks();
    if (!mounted) return;
    showSideToast(
      context,
      context.l10n.bookSourceChangeSuccess(result.source.name),
    );
  }

  /// 手动 AI 预处理：校验模型可用并确认 token 消耗后加入后台队列，
  /// 进度到"下载任务"页的 AI 预处理 Tab 查看。
  Future<void> _confirmAiPreprocess(Book book) async {
    final l10n = context.l10n;
    final settings = await ReaderHttpAIService().loadSettings();
    if (!mounted) return;
    if (!settings.isConfigured) {
      showSideToast(
        context,
        l10n.settingsAiPreprocessNeedModel,
        kind: SideToastKind.error,
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.libraryAiPreprocess),
        content: Text(l10n.libraryAiPreprocessConfirm(book.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // 列表查询不含 textEncoding 等全量字段，入队前取完整记录。
    final fullBook = book.id == null
        ? null
        : await _bookDao.getBookById(book.id!);
    if (!mounted) return;
    AiPreprocessTaskController().enqueue(fullBook ?? book);
    showSideToast(
      context,
      l10n.libraryAiPreprocessQueued,
      kind: SideToastKind.success,
    );
  }

  Future<void> _exportBook(Book book) async {
    if (!_exportingBookPaths.add(book.filePath)) return;
    showSideToast(context, context.l10n.bookExportInProgress);
    try {
      final result = await BookExportService().export(book);
      if (!mounted) return;
      switch (result.status) {
        case BookExportStatus.success:
          final location = result.location ?? result.displayName ?? book.title;
          showSideToast(
            context,
            context.l10n.bookExportSuccess(location),
            kind: SideToastKind.success,
          );
        case BookExportStatus.cancelled:
          break;
        case BookExportStatus.sourceMissing:
        case BookExportStatus.notDownloaded:
          showSideToast(
            context,
            context.l10n.bookExportSourceMissing,
            kind: SideToastKind.warning,
          );
        case BookExportStatus.unsupported:
          showSideToast(
            context,
            context.l10n.bookExportUnsupported,
            kind: SideToastKind.warning,
          );
        case BookExportStatus.failure:
          showSideToast(
            context,
            context.l10n.bookExportFailed,
            kind: SideToastKind.error,
          );
      }
    } finally {
      _exportingBookPaths.remove(book.filePath);
    }
  }
}
