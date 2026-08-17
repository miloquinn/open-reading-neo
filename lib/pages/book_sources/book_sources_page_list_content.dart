part of 'book_sources_page.dart';

extension _BookSourcesPageListContent on _BookSourcesPageState {
  List<Widget> _buildListLayoutSlivers(
    BookSourcesSectionCache cache,
    double bottomPadding,
  ) {
    final categories = _state.listChannelsBySource.values
        .expand((items) => items)
        .toList(growable: false);
    if (!_state.showListDirectory && categories.isEmpty) {
      return [
        _paddedSectionSliver(
          _state.sourcesFor(BookSourcesSection.categories).isEmpty
              ? _buildUnsupportedMessage('categories')
              : _buildEmptyMessage(),
          bottomPadding: bottomPadding,
        ),
      ];
    }

    if (_state.showListDirectory || _state.selectedCategory == null) {
      final groups = _memoizedListGroups();
      final filteredGroups = _memoizedFilteredListGroups(groups);
      return [
        BookSourceListDirectory(
          searchController: _listSourceSearchController,
          groups: groups,
          filteredGroups: filteredGroups,
          state: _state,
          searchHint: context.l10n.bookSourcesManagementSearchHint,
          clearSearchTooltip: context.l10n.bookSourcesClearSearch,
          noMatchesLabel: context.l10n.bookSourcesNoMatchingSources,
          resetFiltersLabel: context.l10n.bookSourcesResetFilters,
          retryLabel: context.l10n.retry,
          channelCountLabel: context.l10n.bookSourceChannelCount,
          onQueryChanged: _controller.setListSourceQuery,
          onClearQuery: _clearListSourceSearch,
          onToggleSource: (group) =>
              unawaited(_controller.toggleListSource(group)),
          onExpandSource: (group) =>
              unawaited(_controller.expandListSource(group)),
          onSelectCategory: (category) =>
              unawaited(_selectListCategory(category)),
          shouldAnimateSource: _revealedListSourceIds.add,
        ),
      ];
    }

    return [
      _paddedSectionSliver(
        BookSourceListSelectionHeader(
          category: _state.selectedCategory!,
          changeLabel: context.l10n.bookSourceChangeChannel,
          onChange: _returnToListDirectory,
        ),
        bottomPadding: 12,
      ),
      ..._buildCategoriesSlivers(cache, bottomPadding, showChannelStrip: false),
    ];
  }

  void _clearListSourceSearch() {
    _listSourceSearchController.clear();
    _controller.setListSourceQuery('');
  }

  Future<void> _selectListCategory(SourcedBookCategory category) async {
    if (_scrollController.hasClients) {
      _listDirectoryScrollOffset = _scrollController.offset;
      _scrollController.jumpTo(0);
    }
    await _controller.selectListCategory(category);
  }

  void _returnToListDirectory() {
    if (_scrollController.hasClients && _scrollController.offset != 0) {
      _scrollController.jumpTo(0);
    }
    _controller.returnToListDirectory();
    final target = _listDirectoryScrollOffset;
    if (target == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      _scrollController.jumpTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  Widget _buildCategoryChannels(
    List<SourcedBookCategory> categories,
    SourcedBookCategory selectedCategory,
  ) {
    return BookSourceCategoryChannels(
      categories: categories,
      selectedCategory: selectedCategory,
      pickerLabel: context.l10n.discoverCategories,
      onSelected: (category) => unawaited(_controller.selectCategory(category)),
      onOpenPicker: () => unawaited(_openCategoryPicker(categories)),
    );
  }

  List<Widget> _buildLatestSlivers(
    BookSourcesSectionCache cache,
    double bottomPadding,
  ) {
    final books = (cache.books ?? const <SourcedBook>[])
        .where((result) => _state.matchesSelectedSource(result.source))
        .toList(growable: false);
    if (books.isEmpty) {
      return [
        _paddedSectionSliver(
          _state.sourcesFor(BookSourcesSection.latest).isEmpty
              ? _buildUnsupportedMessage('browse')
              : _buildEmptyMessage(),
          bottomPadding: bottomPadding,
        ),
      ];
    }
    return [_bookListSliver(books, bottomPadding: bottomPadding)];
  }

  Widget _bookListSliver(
    List<SourcedBook> books, {
    required double bottomPadding,
  }) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomPadding),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, childIndex) {
            if (childIndex.isOdd) return const SizedBox(height: 10);
            final index = childIndex ~/ 2;
            final result = books[index];
            return BookSourceListReveal(
              key: Key(
                'bookSourceBookReveal-${result.source.id}-${result.book.id}',
              ),
              animate: _shouldAnimateBook(result),
              order: index,
              child: _centerSectionChild(
                SourcedBookListTile(
                  result: result,
                  onTap: () => _actions.showBookDetails(result),
                ),
              ),
            );
          },
          childCount: books.isEmpty ? 0 : (books.length * 2) - 1,
          addAutomaticKeepAlives: false,
        ),
      ),
    );
  }

  bool _shouldAnimateBook(SourcedBook result) {
    final category = _state.selectedCategory;
    final scope = category == null
        ? '${_state.section.name}\u0000${_state.selectedSourceId ?? ''}'
        : '${category.source.id}\u0000${category.id}';
    if (_bookRevealScope != scope) {
      _bookRevealScope = scope;
      _revealedBookIds.clear();
    }
    return _revealedBookIds.add('${result.source.id}\u0000${result.book.id}');
  }

  Widget _paddedSectionSliver(
    Widget child, {
    double topPadding = 8,
    required double bottomPadding,
  }) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(16, topPadding, 16, bottomPadding),
      sliver: SliverToBoxAdapter(child: _centerSectionChild(child)),
    );
  }

  Widget _centerSectionChild(Widget child) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1048),
      child: child,
    ),
  );

  Widget _buildUnsupportedMessage(String capability) {
    final hasEnabledSources = _state.sources.any((source) => source.enabled);
    return BookSourceMessageCard(
      icon: hasEnabledSources
          ? Icons.extension_off_outlined
          : Icons.travel_explore_outlined,
      title: hasEnabledSources
          ? context.l10n.discoverUnsupportedTitle
          : context.l10n.bookSourcesNoSourcesTitle,
      message: hasEnabledSources
          ? context.l10n.discoverUnsupportedMessage(capability)
          : context.l10n.bookSourcesNoSourcesDescription,
      actionLabel: context.l10n.bookSourceManagementTitle,
      onAction: _openSourceManagement,
    );
  }

  Widget _buildEmptyMessage() {
    return BookSourceMessageCard(
      icon: Icons.inbox_outlined,
      title: context.l10n.discoverEmptyTitle,
      message: context.l10n.discoverEmptyMessage,
    );
  }
}
