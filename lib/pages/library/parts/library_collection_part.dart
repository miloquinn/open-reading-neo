// 文件说明：书库封面网格、卡片列表与封面选择。
// 技术要点：LibraryPage 私有视图拆分，状态所有权仍保留在主页面。

part of '../library_page.dart';

extension _LibraryPageCollection on _LibraryPageState {
  Widget _buildCoverOnlyGrid(
    List<Book> books, {
    required double topPadding,
    required int mobileColumns,
    required bool showDetails,
  }) {
    final useRail =
        LayoutHelper.getNavigationType(context) == NavigationType.rail;
    final spacing = useRail ? 14.0 : 10.0;
    final horizontalPadding = useRail ? 16.0 : 12.0;
    final bottomPadding = useRail
        ? MediaQuery.viewPaddingOf(context).bottom +
              (_selection.isActive ? 104 : 24)
        : HomeMobileChromeScope.of(context).pageBottomPadding;

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = LayoutHelper.coverOnlyGridColumnsForWidth(
          constraints.maxWidth,
          mobileColumns: mobileColumns,
        );
        final itemWidth =
            (constraints.maxWidth -
                horizontalPadding * 2 -
                spacing * (crossAxisCount - 1)) /
            crossAxisCount;
        final itemHeight =
            itemWidth * 3 / 2 +
            (showDetails ? LibraryGridBookDetails.height : 0);
        return GridView.builder(
          key: const ValueKey('library-cover-grid'),
          scrollCacheExtent: const ScrollCacheExtent.pixels(720),
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            topPadding,
            horizontalPadding,
            bottomPadding,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing + 2,
            childAspectRatio: itemWidth / itemHeight,
          ),
          itemCount: books.length,
          itemBuilder: (context, index) {
            final book = books[index];
            final coverKey = _coverKeyFor(book);
            return RepaintBoundary(
              child: Semantics(
                button: true,
                label: showDetails
                    ? '${book.title}，${context.l10n.libraryProgressContinue(_bookProgressPercent(book))}'
                    : book.title,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () async {
                      await _handleBookTap(
                        book,
                        openBook: () => _openBookWithSelectedAnimation(
                          book,
                          coverKey: coverKey,
                          radius: BorderRadius.circular(10),
                          coverBuilder: (context) =>
                              _gridCoverArt(context, book),
                        ),
                      );
                    },
                    onLongPress: _selection.isActive
                        ? () => _toggleBookSelection(book)
                        : () => _showBookOptions(book),
                    child: Stack(
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: SizedBox.expand(
                                key: coverKey,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .shadow
                                            .withValues(alpha: 0.14),
                                        blurRadius: 7,
                                        offset: const Offset(0, 3),
                                      ),
                                    ],
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: _gridCoverArt(context, book),
                                  ),
                                ),
                              ),
                            ),
                            if (showDetails) LibraryGridBookDetails(book: book),
                          ],
                        ),
                        if (_selection.isActive)
                          Positioned(
                            top: 6,
                            left: 6,
                            child: _BookSelectionIndicator(
                              selected: _isBookSelected(book),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  int _bookProgressPercent(Book book) {
    return (book.progress * 100).round();
  }

  Widget _buildBooksGrid(List<Book> books, {required double topPadding}) {
    final useRail =
        LayoutHelper.getNavigationType(context) == NavigationType.rail;
    if (!useRail) {
      return _buildBooksList(books, topPadding: topPadding);
    }

    final spacing = LayoutHelper.isDesktop(context) ? 16.0 : 14.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 列数由可用宽度和目标封面宽度推导：旋转屏幕时封面大小基本不变，
        // 只是列数重排，不再按断点写死列数。
        const double horizontalPadding = 32.0;
        final crossAxisCount = LayoutHelper.bookGridColumnsForWidth(
          constraints.maxWidth,
        );
        final totalSpacing = spacing * (crossAxisCount - 1);
        final availableWidth = math.max(
          0.0,
          constraints.maxWidth - horizontalPadding - totalSpacing,
        );
        final itemWidth = availableWidth / crossAxisCount;
        // 网格高度为 2:3 封面 + 文本区域预留高度（更接近常见书封比例）
        final itemHeight =
            (itemWidth * 3 / 2) +
            _BookCoverItem.textHeight +
            _BookCoverItem.gap;
        final childAspectRatio = itemWidth > 0 ? itemWidth / itemHeight : 0.75;

        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.0, 0.3, 0.7, 1.0],
              colors: [
                Theme.of(context).colorScheme.surface.withValues(alpha: 0.0),
                Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: 0.03),
                Theme.of(
                  context,
                ).colorScheme.secondaryContainer.withValues(alpha: 0.03),
                Theme.of(context).colorScheme.surface.withValues(alpha: 0.0),
              ],
            ),
          ),
          child: GridView.builder(
            scrollCacheExtent: const ScrollCacheExtent.pixels(720),
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              MediaQuery.viewPaddingOf(context).bottom +
                  (_selection.isActive ? 104 : 24),
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: spacing,
              mainAxisSpacing: spacing + 8,
              childAspectRatio: childAspectRatio,
            ),
            itemCount: books.length,
            itemBuilder: (context, index) {
              final book = books[index];
              final coverKey = _coverKeyFor(book);
              return RepaintBoundary(
                child: _BookCoverItem(
                  book: book,
                  coverKey: coverKey,
                  selectionActive: _selection.isActive,
                  selected: _isBookSelected(book),
                  onTap: () async {
                    await _handleBookTap(
                      book,
                      openBook: () => _openBookWithSelectedAnimation(
                        book,
                        coverKey: coverKey,
                        radius: BorderRadius.circular(12),
                        coverBuilder: (context) => _gridCoverArt(context, book),
                      ),
                    );
                  },
                  onLongPress: _selection.isActive
                      ? () => _toggleBookSelection(book)
                      : () => _showBookOptions(book),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildBooksList(List<Book> books, {required double topPadding}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView.builder(
      scrollCacheExtent: const ScrollCacheExtent.pixels(720),
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        topPadding,
        16,
        HomeMobileChromeScope.of(context).pageBottomPadding,
      ),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        final coverKey = _coverKeyFor(book);
        final progress = book.progress;
        final progressText = context.l10n.libraryProgressContinue(
          (progress * 100).round(),
        );

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: _isMaterial3Style
                ? scheme.surfaceContainerLow
                : scheme.surface.withValues(alpha: 0.86),
            surfaceTintColor: Colors.transparent,
            elevation: _isMaterial3Style ? 1 : 0,
            shadowColor: scheme.shadow.withValues(
              alpha: _isMaterial3Style ? 0.07 : 0.0,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: scheme.outline.withValues(
                  alpha: _isMaterial3Style ? 0.2 : 0.12,
                ),
                width: 0.8,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () async {
                await _handleBookTap(
                  book,
                  openBook: () => _openBookWithSelectedAnimation(
                    book,
                    coverKey: coverKey,
                    radius: BorderRadius.circular(11),
                    coverBuilder: (context) => _buildListCover(context, book),
                  ),
                );
              },
              onLongPress: _selection.isActive
                  ? () => _toggleBookSelection(book)
                  : () => _showBookOptions(book),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    SizedBox(
                      key: coverKey,
                      width: 64,
                      height: 92,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(11),
                        child: _buildListCover(context, book),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  book.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if (book.isOnline) ...[
                                const SizedBox(width: 8),
                                _onlineBadge(context),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            progressText,
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.58),
                            ),
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 5,
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.12),
                              valueColor: AlwaysStoppedAnimation(
                                Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_selection.isActive)
                      _BookSelectionIndicator(selected: _isBookSelected(book))
                    else
                      Icon(
                        Icons.chevron_right_rounded,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.35),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildListCover(BuildContext context, Book book) {
    if (!kIsWeb &&
        book.coverImagePath != null &&
        book.coverImagePath!.isNotEmpty) {
      // 列表封面显示宽度固定 64，按屏幕像素密度限制解码尺寸即可
      return Image.file(
        File(book.coverImagePath!),
        fit: LayoutHelper.bookCoverFit,
        cacheWidth: (64 * MediaQuery.of(context).devicePixelRatio).round(),
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) =>
            _buildListDefaultCover(context, book),
      );
    }
    final sourceCover = _sourceCoverUrl(book);
    if (sourceCover != null) {
      return SourceCoverImage(
        url: sourceCover,
        headers: _sourceCoverHeaders(book),
        fit: LayoutHelper.bookCoverFit,
        cacheWidth: (64 * MediaQuery.of(context).devicePixelRatio).round(),
        fallback: _buildListDefaultCover(context, book),
      );
    }
    return _buildListDefaultCover(context, book);
  }

  Widget _buildListDefaultCover(BuildContext context, Book book) {
    return GeneratedBookCover(title: book.title, author: book.author);
  }

  Widget _onlineBadge(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      context.l10n.bookSourceOnlineBadge,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onPrimaryContainer,
        fontSize: 10,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
