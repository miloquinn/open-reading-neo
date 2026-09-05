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
          sourceActionsBuilder: _sourceActions,
        ),
      ];
    }

    return [
      _paddedSectionSliver(
        BookSourceListSelectionHeader(
          category: _state.selectedCategory!,
          changeLabel: context.l10n.bookSourceChangeChannel,
          onChange: _returnToListDirectory,
          actions: _sourceActions(_state.selectedCategory!.source),
        ),
        topPadding: 0,
        bottomPadding: 8,
      ),
      ..._buildCategoriesSlivers(cache, bottomPadding, showChannelStrip: false),
    ];
  }

  List<Widget> _buildCategoriesSlivers(
    BookSourcesSectionCache cache,
    double bottomPadding, {
    bool showChannelStrip = true,
  }) {
    final categories = (cache.categories ?? const <SourcedBookCategory>[])
        .where((category) => _state.matchesSelectedSource(category.source))
        .toList(growable: false);
    if (categories.isEmpty) {
      return [
        _paddedSectionSliver(
          _state.sourcesFor(BookSourcesSection.categories).isEmpty
              ? _buildUnsupportedMessage('categories')
              : _buildEmptyMessage(),
          bottomPadding: bottomPadding,
        ),
      ];
    }
    final selectedCategory = _state.selectedCategory ?? categories.first;
    final slivers = <Widget>[];
    if (showChannelStrip) {
      slivers.add(
        _paddedSectionSliver(
          _buildCategoryChannels(categories, selectedCategory),
          bottomPadding: 18,
        ),
      );
    }
    if (_state.loadingCategoryBooks) {
      slivers.add(
        _paddedSectionSliver(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 36),
            child: Center(child: CircularProgressIndicator()),
          ),
          topPadding: 0,
          bottomPadding: bottomPadding,
        ),
      );
    } else if (_state.categoryLoadError != null) {
      slivers.add(
        _paddedSectionSliver(
          BookSourceMessageCard(
            icon: Icons.cloud_off_outlined,
            title: context.l10n.bookSourceChannelLoadFailed,
            message: context.l10n.bookSourceChannelLoadFailedMessage(
              _categoryErrorMessage(_state.categoryLoadError!),
            ),
            actionLabel: context.l10n.retry,
            onAction: () => _controller.selectCategory(selectedCategory),
          ),
          topPadding: 0,
          bottomPadding: bottomPadding,
        ),
      );
    } else if (_state.categoryBooks.isEmpty) {
      slivers.add(
        _paddedSectionSliver(
          BookSourceMessageCard(
            icon: Icons.menu_book_outlined,
            title: context.l10n.bookSourcesNoResults,
            message: context.l10n.discoverCategoryEmpty,
          ),
          topPadding: 0,
          bottomPadding: bottomPadding,
        ),
      );
    } else {
      slivers.add(
        _bookListSliver(
          _state.categoryBooks,
          bottomPadding:
              _state.categoryHasMore ||
                  _state.loadingMoreCategoryBooks ||
                  _state.categoryLoadMoreFailed
              ? 12
              : bottomPadding,
        ),
      );
      if (_state.categoryHasMore ||
          _state.loadingMoreCategoryBooks ||
          _state.categoryLoadMoreFailed) {
        slivers.add(
          _paddedSectionSliver(
            Center(
              child: _state.loadingMoreCategoryBooks
                  ? const CircularProgressIndicator()
                  : OutlinedButton.icon(
                      key: const Key('bookSourceCategoryLoadMore'),
                      onPressed: _controller.loadMoreCategory,
                      icon: Icon(
                        _state.categoryLoadMoreFailed
                            ? Icons.refresh_rounded
                            : Icons.expand_more_rounded,
                      ),
                      label: Text(
                        _state.categoryLoadMoreFailed
                            ? context.l10n.retry
                            : context.l10n.bookSourcesLoadMore,
                      ),
                    ),
            ),
            topPadding: 0,
            bottomPadding: bottomPadding,
          ),
        );
      }
    }
    // Category controls remain live while only the book results transition.
    // Loading, error and empty states use the same lazy content boundary.
    final channelSliver = showChannelStrip ? slivers.removeAt(0) : null;
    final phase = _state.loadingCategoryBooks
        ? 'loading'
        : _state.categoryLoadError != null
        ? 'error'
        : _state.categoryBooks.isEmpty
        ? 'empty'
        : 'books';
    return [
      ?channelSliver,
      if (showChannelStrip)
        _paddedSectionSliver(
          Row(
            children: [
              Expanded(
                child: Text(
                  selectedCategory.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 16),
              Flexible(
                child: Text(
                  selectedCategory.source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (_state.selectedSourceId == null)
                _sourceActions(selectedCategory.source),
            ],
          ),
          topPadding: 0,
          bottomPadding: 0,
        ),
      BookSourceSliverTransition(
        key: const Key('bookSourceCategoryTransition'),
        identity: (selectedCategory.source.id, selectedCategory.id, phase),
        slivers: slivers,
      ),
    ];
  }

  void _clearListSourceSearch() {
    _listSourceSearchController.clear();
    _controller.setListSourceQuery('');
  }

  Future<void> _selectListCategory(SourcedBookCategory category) async {
    if (_scrollController.hasClients) {
      _listDirectoryScrollOffset = _scrollController.offset;
    }
    _pendingScrollOffset = 0;
    await _controller.selectListCategory(category);
  }

  void _returnToListDirectory() {
    _revealedListSourceIds.clear();
    _pendingScrollOffset = _listDirectoryScrollOffset ?? 0;
    _controller.returnToListDirectory();
  }

  Widget _buildCategoryChannels(
    List<SourcedBookCategory> categories,
    SourcedBookCategory selectedCategory,
  ) {
    return BookSourceCategoryChannels(
      categories: categories,
      selectedCategory: selectedCategory,
      pickerLabel: context.l10n.statsRangeAll,
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
    Widget buildBook(BuildContext context, int index) {
      final result = books[index];
      return BookSourceListReveal(
        key: Key('bookSourceBookReveal-${result.source.id}-${result.book.id}'),
        animate: _shouldAnimateBook(result),
        order: index,
        child: _centerSectionChild(
          SourcedBookListTile(
            result: result,
            editorial: true,
            onTap: () => _actions.showBookDetails(result),
            onSourceTap:
                _state.section == BookSourcesSection.latest &&
                    _state.selectedSourceId == null
                ? () => _showSourceActions(result.source)
                : null,
          ),
        ),
      );
    }

    final tabletGrid =
        LayoutHelper.usesTabletLayout(context) &&
        _layoutController.layout.value == BookSourceDiscoverLayout.standard;
    if (!tabletGrid) {
      final horizontalPadding = LayoutHelper.usesTabletLayout(context)
          ? LayoutHelper.tabletPagePadding
          : 16.0;
      return SliverPadding(
        padding: EdgeInsets.fromLTRB(
          horizontalPadding,
          0,
          horizontalPadding,
          bottomPadding,
        ),
        sliver: SliverList.separated(
          itemCount: books.length,
          itemBuilder: buildBook,
          separatorBuilder: (_, _) => const SizedBox(height: 4),
        ),
      );
    }

    return SliverLayoutBuilder(
      builder: (context, constraints) {
        const horizontalPadding = LayoutHelper.tabletPagePadding;
        final usableWidth = math.max(
          0.0,
          constraints.crossAxisExtent - horizontalPadding * 2,
        );
        final columns = ((usableWidth + 20) / (340 + 20))
            .floor()
            .clamp(2, 3)
            .toInt();
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            0,
            horizontalPadding,
            bottomPadding,
          ),
          sliver: SliverGrid(
            key: const Key('bookSourceTabletBookGrid'),
            delegate: SliverChildBuilderDelegate(
              buildBook,
              childCount: books.length,
              addAutomaticKeepAlives: false,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 20,
              mainAxisSpacing: 4,
              mainAxisExtent: 160,
            ),
          ),
        );
      },
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
    final horizontalPadding = LayoutHelper.usesTabletLayout(context)
        ? LayoutHelper.tabletPagePadding
        : 16.0;
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        topPadding,
        horizontalPadding,
        bottomPadding,
      ),
      sliver: SliverToBoxAdapter(child: _centerSectionChild(child)),
    );
  }

  Widget _centerSectionChild(Widget child) {
    if (LayoutHelper.usesTabletLayout(context)) return child;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1048),
        child: child,
      ),
    );
  }

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
