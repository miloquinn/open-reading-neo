// 文件说明：书库页面结构、筛选搜索、工具栏与空状态。
// 技术要点：LibraryPage 私有视图拆分，状态所有权仍保留在主页面。

part of '../library_page.dart';

extension _LibraryPageChrome on _LibraryPageState {
  Widget _buildContent(
    BuildContext context, {
    required bool useRailNavigation,
  }) {
    final books = _visibleBooks;
    final libraryLayoutMode = context
        .select<AppSettingsNotifier, LibraryLayoutMode>(
          (settings) => settings.libraryLayoutMode,
        );
    final libraryGridColumns = context.select<AppSettingsNotifier, int>(
      (settings) => settings.libraryGridColumns,
    );
    final libraryGridShowDetails = context.select<AppSettingsNotifier, bool>(
      (settings) => settings.libraryGridShowDetails,
    );
    final palette = PageStyleHelper.palette(context);
    final mobileChrome = HomeMobileChromeScope.of(context);
    // 手机模式：内容从屏幕顶端开始、滚动时穿过毛玻璃顶栏，
    // 顶栏的模糊层才有真实内容可以取样；用内边距避开首屏遮挡。
    final mobileTopInset = mobileChrome.pageTopPadding;
    final listTopPadding = useRailNavigation
        ? 8.0
        : (_searchBarVisible ? 10.0 : mobileTopInset);
    final content = Column(
      children: [
        if (useRailNavigation) ...[_buildTopBar(), const SizedBox(height: 10)],
        if (_searchBarVisible) ...[
          if (!useRailNavigation) SizedBox(height: mobileTopInset),
          _buildSearchBar(),
        ],
        Expanded(
          child: _isInitialLoading
              ? const Center(child: CircularProgressIndicator())
              : _loadError != null && _books.isEmpty
              ? _buildLoadError()
              : RefreshIndicator(
                  onRefresh: _loadBooks,
                  strokeWidth: 2.5,
                  displacement: 40,
                  // 与首页/发现页对齐：出场裁剪线贴住毛玻璃顶栏下边缘，
                  // 圆圈看起来从顶栏底下滑出；用 pageTopPadding 会让裁剪线
                  // 悬在顶栏下方 8dp，圆圈在半空被“隐形层”切头。
                  edgeOffset: useRailNavigation || _searchBarVisible
                      ? 0
                      : mobileChrome.topBarHeight,
                  color: Theme.of(context).colorScheme.primary,
                  backgroundColor: palette.cardStrong,
                  child: _books.isEmpty
                      ? _buildRefreshableState(_buildEmptyLibrary())
                      : books.isEmpty
                      ? _buildRefreshableState(_buildNoSearchResult())
                      : libraryLayoutMode == LibraryLayoutMode.grid
                      ? _buildCoverOnlyGrid(
                          books,
                          topPadding: listTopPadding,
                          mobileColumns: libraryGridColumns,
                          showDetails: libraryGridShowDetails,
                        )
                      : _buildBooksGrid(books, topPadding: listTopPadding),
                ),
        ),
      ],
    );
    return Container(
      decoration: BoxDecoration(
        gradient: PageStyleHelper.backgroundGradient(context),
      ),
      child: useRailNavigation
          ? SafeArea(bottom: false, child: content)
          : content,
    );
  }

  Widget _buildLoadError() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.error_outline_rounded,
          size: 42,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 12),
        Text(context.l10n.error),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _retryLoadBooks,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(context.l10n.retry),
        ),
      ],
    ),
  );

  List<Book> get _visibleBooks {
    final query = _searchQuery.trim().toLowerCase();
    if (_visibleBooksCacheRevision == _booksRevision &&
        _visibleBooksCacheFilter == _selectedFilter &&
        _visibleBooksCacheQuery == query) {
      return _visibleBooksCache;
    }
    final filteredByStatus = _books
        .where((book) => _matchesSelectedFilter(book))
        .toList();
    final result = query.isEmpty
        ? filteredByStatus
        : filteredByStatus.where((book) {
            return book.title.toLowerCase().contains(query) ||
                book.author.toLowerCase().contains(query);
          }).toList();
    _visibleBooksCacheRevision = _booksRevision;
    _visibleBooksCacheFilter = _selectedFilter;
    _visibleBooksCacheQuery = query;
    _visibleBooksCache = result;
    return result;
  }

  bool _matchesSelectedFilter(Book book) {
    switch (_selectedFilter) {
      case _LibraryFilter.all:
        return true;
      case _LibraryFilter.reading:
        return _isReadingBook(book);
      case _LibraryFilter.finished:
        return _isFinishedBook(book);
    }
  }

  bool _isFinishedBook(Book book) {
    return book.progress >= 1;
  }

  bool _isReadingBook(Book book) {
    return book.progress > 0 && !_isFinishedBook(book);
  }

  Widget _buildTopBar() {
    final palette = PageStyleHelper.palette(context);
    final scheme = Theme.of(context).colorScheme;
    final webDavSync = context.watch<WebDavSyncController?>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          if (_selection.isActive) ...[
            IconButton(
              tooltip: context.l10n.cancel,
              onPressed: _exitSelectionMode,
              icon: const Icon(Icons.close_rounded),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              _selection.isActive
                  ? context.l10n.librarySelectedBooks(
                      _selection.selectedIds.length,
                    )
                  : context.l10n.library,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _selection.isActive ? 24 : 36,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
                height: 1.05,
              ),
            ),
          ),
          if (_selection.isActive)
            TextButton(
              onPressed: _selectAllVisibleBooks,
              child: Text(context.l10n.librarySelectAll),
            )
          else ...[
            if (webDavSync?.isConfigured ?? false) ...[
              _buildTopBarIcon(
                icon: Icons.cloud_sync_rounded,
                active: webDavSync!.remoteBooks.any(
                  (book) => book.fileAvailable,
                ),
                tooltip: context.l10n.webDavBookFilesTitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const BookFileSyncPage(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            _buildTopBarIcon(
              icon: Icons.downloading_rounded,
              active:
                  context.watch<DownloadTaskController?>()?.hasActiveTasks ??
                  false,
              tooltip: context.l10n.downloadTasksTitle,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DownloadTasksPage(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _buildTopBarIcon(
              icon: Icons.search_rounded,
              active: _searchBarVisible,
              tooltip: context.l10n.bookSourcesSearch,
              onTap: _toggleSearchBar,
            ),
            const SizedBox(width: 8),
            _LibraryFilterButton(
              active: _selectedFilter != _LibraryFilter.all,
              decoration: (active) => _panelDecoration(
                radius: 22,
                stronger: true,
                color: active
                    ? scheme.primaryContainer
                    : (_isMaterial3Style
                          ? scheme.surfaceContainer
                          : palette.card),
              ),
              iconColor: _selectedFilter != _LibraryFilter.all
                  ? scheme.onPrimaryContainer
                  : palette.iconMuted,
              onTapWithRect: _showFilterMenu,
            ),
            const SizedBox(width: 8),
            InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const ImportBookPage(),
                  ),
                );
                if (result == true && mounted) {
                  _loadBooks();
                }
              },
              child: Container(
                width: 44,
                height: 44,
                decoration: _panelDecoration(
                  radius: 22,
                  stronger: true,
                  color: _isMaterial3Style
                      ? scheme.surfaceContainer
                      : palette.card,
                ),
                child: Icon(Icons.add_rounded, color: palette.iconMuted),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRailSelectionBottomBar() {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: 24,
      right: 24,
      bottom: MediaQuery.viewPaddingOf(context).bottom + 18,
      child: SafeArea(
        top: false,
        child: Center(
          child: FilledButton.icon(
            key: const ValueKey('library-delete-selected'),
            onPressed: _selection.selectedIds.isEmpty
                ? null
                : _confirmDeleteSelectedBooks,
            style: FilledButton.styleFrom(
              minimumSize: const Size(260, 52),
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            icon: const Icon(Icons.delete_outline_rounded),
            label: Text(
              context.l10n.libraryDeleteSelected(_selection.selectedIds.length),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBarIcon({
    required IconData icon,
    required bool active,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final palette = PageStyleHelper.palette(context);
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: _panelDecoration(
            radius: 22,
            stronger: true,
            color: active
                ? scheme.primaryContainer
                : (_isMaterial3Style ? scheme.surfaceContainer : palette.card),
          ),
          child: Icon(
            icon,
            color: active ? scheme.onPrimaryContainer : palette.iconMuted,
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    final palette = PageStyleHelper.palette(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: _panelDecoration(
          radius: 14,
          stronger: true,
          color: _isMaterial3Style ? scheme.surfaceContainerLow : palette.card,
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 18, color: palette.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocus,
                onChanged: _onSearchChanged,
                decoration: InputDecoration(
                  hintText: context.l10n.librarySearchHint,
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            if (_searchQuery.isNotEmpty)
              InkWell(
                onTap: () {
                  _searchController.clear();
                  _updateState(() => _searchQuery = '');
                },
                child: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: palette.textMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingActionButton() {
    final isTablet = LayoutHelper.isTablet(context);
    final isDesktop = LayoutHelper.isDesktop(context);
    final useRailNav = isTablet || isDesktop;
    final bottomPadding = MediaQuery.viewPaddingOf(context).bottom;
    final mobileChrome = HomeMobileChromeScope.of(context);
    final scheme = Theme.of(context).colorScheme;

    // 侧边导航栏模式：FAB 在右下角，边距较小
    // 底部导航栏模式：FAB 需要避开导航栏
    final double bottomMargin = useRailNav
        ? bottomPadding +
              16 // 侧边导航：只需避开安全区域
        : mobileChrome.floatingActionBottomMargin; // 底部导航：避开悬浮导航栏

    if (_isMaterial3Style) {
      return Container(
        margin: EdgeInsets.only(bottom: bottomMargin),
        child: FloatingActionButton(
          onPressed: () async {
            final result = await Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const ImportBookPage()),
            );
            if (result == true && mounted) {
              _loadBooks();
            }
          },
          backgroundColor: scheme.primaryContainer,
          foregroundColor: scheme.onPrimaryContainer,
          elevation: 2,
          heroTag: "add_book_fab",
          child: const Icon(Icons.add, size: 28),
        ),
      );
    }

    return Container(
      margin: EdgeInsets.only(bottom: bottomMargin),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
            spreadRadius: 0,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          enabled: !GlassEffectConfig.shouldDisableBlur,
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: FloatingActionButton(
            onPressed: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ImportBookPage()),
              );
              // 导入完成后刷新书籍列表
              if (result == true && mounted) {
                _loadBooks();
              }
            },
            backgroundColor: Theme.of(context).colorScheme.primary.withValues(
              alpha: GlassEffectConfig.effectiveOpacity(0.9),
            ),
            foregroundColor: Colors.white,
            elevation: 0,
            heroTag: "add_book_fab", // 添加唯一标识避免冲突
            child: const Icon(Icons.add, size: 28),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyLibrary() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppBrandIcon(size: 56, borderRadius: 14),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ImportBookPage()),
              );
              _loadBooks();
            },
            icon: const Icon(Icons.add),
            label: Text(context.l10n.importBooks),
          ),
        ],
      ),
    );
  }

  Widget _buildNoSearchResult() {
    final palette = PageStyleHelper.palette(context);
    final hasSearch = _searchQuery.trim().isNotEmpty;
    final message = hasSearch
        ? context.l10n.libraryNoMatchingBooks
        : switch (_selectedFilter) {
            _LibraryFilter.reading => context.l10n.libraryNoReadingBooks,
            _LibraryFilter.finished => context.l10n.libraryNoFinishedBooks,
            _LibraryFilter.all => context.l10n.libraryNoBooks,
          };

    return Center(
      child: Text(
        message,
        style: TextStyle(fontSize: 16, color: palette.textMuted),
      ),
    );
  }

  Widget _buildRefreshableState(Widget state) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          children: [SizedBox(height: constraints.maxHeight, child: state)],
        );
      },
    );
  }
}
