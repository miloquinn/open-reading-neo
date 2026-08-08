// 文件说明：书籍操作面板、信息展示、重命名与封面编辑。
// 技术要点：LibraryPage 私有操作拆分，状态所有权仍保留在主页面。

part of '../library_page.dart';

extension _LibraryPageBookDetails on _LibraryPageState {
  void _showBookOptions(Book book) {
    final scheme = Theme.of(context).colorScheme;
    final isMaterial3Style = _isMaterial3Style;
    final useBlur = !isMaterial3Style && !GlassEffectConfig.shouldDisableBlur;
    showModalBottomSheet(
      context: context,
      backgroundColor: isMaterial3Style
          ? scheme.surfaceContainerHigh
          : Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        final localScheme = Theme.of(context).colorScheme;
        final progress = book.progress;
        final content = Container(
          decoration: BoxDecoration(
            color: isMaterial3Style
                ? localScheme.surfaceContainerHigh
                : GlassEffectConfig.surfaceColor(context, opacity: 0.95),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(
                color: localScheme.outline.withValues(
                  alpha: isMaterial3Style ? 0.24 : 0.2,
                ),
                width: 1,
              ),
            ),
            boxShadow: isMaterial3Style
                ? [
                    BoxShadow(
                      color: localScheme.shadow.withValues(alpha: 0.08),
                      blurRadius: 16,
                      offset: const Offset(0, -2),
                    ),
                  ]
                : null,
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 8),
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: localScheme.onSurface.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Row(
                    children: [
                      Container(
                        width: 50,
                        height: 70,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              localScheme.primary.withValues(alpha: 0.8),
                              localScheme.secondary.withValues(alpha: 0.6),
                            ],
                          ),
                          border: Border.all(
                            color: localScheme.outline.withValues(
                              alpha: isMaterial3Style ? 0.22 : 0.12,
                            ),
                            width: 0.8,
                          ),
                          boxShadow: isMaterial3Style
                              ? null
                              : [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.1),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: _buildListCover(context, book),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              book.title,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              book.author,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: localScheme.onSurface.withValues(
                                      alpha: 0.6,
                                    ),
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(99),
                                    child: LinearProgressIndicator(
                                      value: progress,
                                      minHeight: 5,
                                      backgroundColor: localScheme.primary
                                          .withValues(alpha: 0.14),
                                      color: localScheme.primary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${(progress * 100).toStringAsFixed(1)}%',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: localScheme.primary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: localScheme.outline.withValues(alpha: 0.15),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                  child: Column(
                    children: [
                      _buildOptionItem(
                        context: context,
                        icon: Icons.library_add_check_outlined,
                        iconColor: localScheme.primary,
                        title: context.l10n.librarySelectMultiple,
                        onTap: () {
                          Navigator.pop(context);
                          _enterSelectionMode(book);
                        },
                      ),
                      _buildOptionItem(
                        context: context,
                        icon: Icons.play_circle_outline,
                        iconColor: localScheme.primary,
                        title: context.l10n.continueReading,
                        trailing: book.isOnline
                            ? context.l10n.bookSourceOnlineBadge
                            : book.currentPage > 0
                            ? context.l10n.libraryPageNumber(book.currentPage)
                            : context.l10n.libraryStartFromBeginning,
                        onTap: () async {
                          Navigator.pop(context);
                          final fullBook = await _bookDao.getBookById(book.id!);
                          if (fullBook != null && context.mounted) {
                            final settings = context
                                .read<AppSettingsNotifier>();
                            await _openBook(
                              fullBook,
                              libraryAnimation:
                                  settings.libraryBookOpenAnimation,
                              animationPace:
                                  settings.libraryBookOpenAnimationPace,
                            );
                            _loadBooks();
                          }
                        },
                      ),
                      if (book.isOnline)
                        _buildOptionItem(
                          context: context,
                          icon: Icons.swap_horiz_rounded,
                          iconColor: localScheme.primary,
                          title: context.l10n.bookSourceChangeSourceTitle,
                          trailing: _sourceShelfService.sourceFrom(book).name,
                          onTap: () {
                            Navigator.pop(context);
                            unawaited(_changeOnlineBookSource(book));
                          },
                        ),
                      if (book.isOnline)
                        _buildOptionItem(
                          context: context,
                          icon: Icons.download_for_offline_outlined,
                          iconColor: localScheme.secondary,
                          title: context.l10n.bookSourceDownloadLocal,
                          onTap: () {
                            Navigator.pop(context);
                            unawaited(_downloadOnlineBook(book));
                          },
                        ),
                      _buildOptionItem(
                        context: context,
                        icon: Icons.info_outline,
                        iconColor: localScheme.tertiary,
                        title: context.l10n.libraryBookInfo,
                        trailing: _bookInfoSubtitle(context, book),
                        onTap: () {
                          Navigator.pop(context);
                          _showBookInfo(book);
                        },
                      ),
                      _buildOptionItem(
                        context: context,
                        icon: Icons.edit_outlined,
                        iconColor: localScheme.secondary,
                        title: context.l10n.libraryRenameBook,
                        onTap: () {
                          Navigator.pop(context);
                          _renameBook(book);
                        },
                      ),
                      if (!kIsWeb) ...[
                        _buildOptionItem(
                          context: context,
                          icon: Icons.image_outlined,
                          iconColor: localScheme.secondary,
                          title: context.l10n.libraryCustomCover,
                          onTap: () {
                            Navigator.pop(context);
                            unawaited(_pickCustomCover(book));
                          },
                        ),
                        if (BookCoverEditService.hasCustomCover(book))
                          _buildOptionItem(
                            context: context,
                            icon: Icons.restore,
                            iconColor: localScheme.secondary,
                            title: context.l10n.libraryResetCover,
                            onTap: () {
                              Navigator.pop(context);
                              unawaited(_resetCustomCover(book));
                            },
                          ),
                      ],
                      if (!book.isOnline && book.filePath.isNotEmpty)
                        _buildOptionItem(
                          context: context,
                          icon: Icons.file_upload_outlined,
                          iconColor: localScheme.secondary,
                          title: context.l10n.libraryExportBook,
                          onTap: () {
                            Navigator.pop(context);
                            unawaited(_exportBook(book));
                          },
                        ),
                      if (BookTextExtractionService.supports(book))
                        _buildOptionItem(
                          context: context,
                          icon: Icons.auto_awesome_outlined,
                          iconColor: localScheme.primary,
                          title: context.l10n.libraryAiPreprocess,
                          onTap: () {
                            Navigator.pop(context);
                            unawaited(_confirmAiPreprocess(book));
                          },
                        ),
                      _buildOptionItem(
                        context: context,
                        icon: Icons.delete_outline_rounded,
                        iconColor: localScheme.error,
                        title: context.l10n.deleteBook,
                        destructive: true,
                        onTap: () {
                          Navigator.pop(context);
                          _confirmDeleteBook(book);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );

        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: useBlur
              ? BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                  child: content,
                )
              : content,
        );
      },
    );
  }

  /// 书籍格式与页数/章节数摘要。
  ///
  /// 在线书源书籍的 totalPages 存储的是章节序号换算出的进度单位（见
  /// [BookSourceShelfService.unitsPerChapter]），不是真实页码，大部头小说会
  /// 显示成几十万"页"。因此在线书籍改为展示真实章节数。
  String _bookInfoSubtitle(BuildContext context, Book book) {
    final format = book.format.toUpperCase();
    if (!book.isOnline) {
      return context.l10n.libraryFormatAndPages(format, book.totalPages);
    }
    final unitsPerChapter = BookSourceShelfService.unitsPerChapter;
    if (book.totalPages < unitsPerChapter) return format;
    final chapters = (book.totalPages / unitsPerChapter).round();
    return context.l10n.libraryFormatAndChapters(format, chapters);
  }

  /// 重命名书籍：更新书名，若存在本地文件则同步重命名磁盘文件。
  Future<void> _renameBook(Book book) async {
    final controller = TextEditingController(text: book.title);
    final isMaterial3Style = _isMaterial3Style;
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: isMaterial3Style
            ? scheme.surfaceContainerHigh
            : GlassEffectConfig.surfaceColor(dialogContext, opacity: 0.95),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.libraryRenameBook),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 120,
          decoration: InputDecoration(labelText: l10n.libraryBookTitle),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = newTitle?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == book.title) return;

    final toastContext = context;
    try {
      await BookRenameService().rename(book, trimmed);
      _loadBooks();
      if (!toastContext.mounted) return;
      showSideToast(
        toastContext,
        l10n.libraryRenameBookSuccess,
        kind: SideToastKind.success,
      );
    } catch (_) {
      if (!toastContext.mounted) return;
      showSideToast(
        toastContext,
        l10n.libraryRenameBookFailed,
        kind: SideToastKind.error,
      );
    }
  }

  /// 让用户挑选本地图片替换 [book] 的封面，成功后刷新书库。
  Future<void> _pickCustomCover(Book book) async {
    final l10n = context.l10n;
    final toastContext = context;
    try {
      final applied = await BookCoverEditService().pickAndApplyCover(book);
      if (!applied) return; // 用户取消挑选
      _loadBooks();
      if (!toastContext.mounted) return;
      showSideToast(
        toastContext,
        l10n.libraryCustomCoverSuccess,
        kind: SideToastKind.success,
      );
    } on BookCoverEditException catch (error) {
      if (!toastContext.mounted) return;
      final message = switch (error.code) {
        BookCoverEditError.unsupportedFormat =>
          l10n.libraryCoverUnsupportedFormat,
        BookCoverEditError.fileTooLarge => l10n.libraryCoverFileTooLarge,
        BookCoverEditError.readFailed => l10n.libraryCoverReadFailed,
        BookCoverEditError.storageFailed => l10n.libraryCoverSaveFailed,
      };
      showSideToast(toastContext, message, kind: SideToastKind.error);
    } catch (_) {
      if (!toastContext.mounted) return;
      showSideToast(
        toastContext,
        l10n.libraryCoverSaveFailed,
        kind: SideToastKind.error,
      );
    }
  }

  /// 撤销 [book] 的自定义封面，恢复原封面或回退到书源/生成封面。
  Future<void> _resetCustomCover(Book book) async {
    final l10n = context.l10n;
    final toastContext = context;
    try {
      await BookCoverEditService().resetCover(book);
      _loadBooks();
      if (!toastContext.mounted) return;
      showSideToast(
        toastContext,
        l10n.libraryResetCoverSuccess,
        kind: SideToastKind.success,
      );
    } catch (_) {
      if (!toastContext.mounted) return;
      showSideToast(
        toastContext,
        l10n.libraryCoverSaveFailed,
        kind: SideToastKind.error,
      );
    }
  }

  /// 构建操作选项项
  /// 紧凑操作行：小图标 + 标题 +（可选）右侧摘要，替代旧版大卡片。
  Widget _buildOptionItem({
    required BuildContext context,
    required IconData icon,
    required Color iconColor,
    required String title,
    String? trailing,
    bool destructive = false,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: iconColor, size: 17),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: destructive ? scheme.error : scheme.onSurface,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Text(
                    trailing,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 显示书籍详细信息
  void _showBookInfo(Book book) {
    final scheme = Theme.of(context).colorScheme;
    final isMaterial3Style = _isMaterial3Style;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isMaterial3Style
            ? scheme.surfaceContainerHigh
            : scheme.surface.withValues(alpha: 0.95),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(
              Icons.info_outline,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(context.l10n.libraryBookInfo),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoRow(context.l10n.libraryBookTitle, book.title),
            const SizedBox(height: 12),
            _buildInfoRow(context.l10n.author, book.author),
            const SizedBox(height: 12),
            _buildInfoRow(
              context.l10n.libraryFormat,
              book.format.toUpperCase(),
            ),
            const SizedBox(height: 12),
            if (book.isOnline) ...[
              _buildInfoRow(
                context.l10n.totalChapters,
                context.l10n.libraryChaptersCount(
                  (book.totalPages / BookSourceShelfService.unitsPerChapter)
                      .round(),
                ),
              ),
              const SizedBox(height: 12),
              _buildInfoRow(
                context.l10n.currentChapter,
                context.l10n.libraryChaptersCount(
                  (book.currentPage / BookSourceShelfService.unitsPerChapter)
                      .round(),
                ),
              ),
            ] else ...[
              _buildInfoRow(
                context.l10n.totalPages,
                context.l10n.libraryPagesCount(book.totalPages),
              ),
              const SizedBox(height: 12),
              _buildInfoRow(
                context.l10n.currentPage,
                context.l10n.libraryPagesCount(book.currentPage),
              ),
            ],
            const SizedBox(height: 12),
            _buildInfoRow(
              context.l10n.readingProgress,
              '${(book.progress * 100).toStringAsFixed(1)}%',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.libraryClose),
          ),
        ],
      ),
    );
  }

  /// 构建信息行
  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 70,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.6),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
