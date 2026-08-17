part of 'source_search_page.dart';

extension _SourceSearchPageUi on _SourceSearchPageState {
  Widget _buildSourceLimitBanner(int enabledCount) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('bookSourceSearchLimitBanner'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 15,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              context.l10n.bookSourcesSearchSourceLimitWarning(
                enabledCount,
                _settings.sourceLimit,
              ),
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                height: 1.35,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQueryField(List<RegisteredBookSource> enabledSources) {
    final canSearch = enabledSources.isNotEmpty;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Container(
        padding: const EdgeInsets.only(right: 12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(
            color: scheme.outline.withValues(alpha: 0.22),
            width: 0.9,
          ),
        ),
        child: TextField(
          key: const Key('bookSourceQueryControl'),
          controller: _queryController,
          focusNode: _queryFocus,
          enabled: canSearch,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          style: const TextStyle(fontSize: 16),
          decoration: InputDecoration(
            hintText: context.l10n.bookSourcesSearchHint,
            border: InputBorder.none,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 16),
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 48,
              minHeight: 0,
            ),
            suffixIcon: _queryController.text.isEmpty
                ? null
                : IconButton(
                    key: const Key('bookSourceSearchClearButton'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).deleteButtonTooltip,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: _clearSearch,
                  ),
          ),
          onChanged: (_) => _mutate(() {}),
        ),
      ),
    );
  }

  Widget _buildScopeChips(List<RegisteredBookSource> enabledSources) {
    return SizedBox(
      key: const Key('bookSourceScopeControl'),
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: enabledSources.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index == 0) {
            return ChoiceChip(
              selected: _selectedSourceId == null,
              label: Text(context.l10n.statsRangeAll),
              onSelected: (_) => _changeScope(null),
            );
          }
          final source = enabledSources[index - 1];
          return ChoiceChip(
            selected: _selectedSourceId == source.id,
            label: Text(source.name),
            onSelected: (_) => _changeScope(source.id),
          );
        },
      ),
    );
  }

  void _changeScope(String? sourceId) {
    if (_selectedSourceId == sourceId) return;
    _searchGeneration++;
    _cancelActiveSearches();
    _mutate(() {
      _selectedSourceId = sourceId;
      if (_hasSearched) {
        _searching = false;
        _results.clear();
        _resultKeys.clear();
        _resultArrivalOrder.clear();
        _nextResultArrivalOrder = 0;
        _pageStates.clear();
      }
    });
    if (_hasSearched && _activeQuery.isNotEmpty) {
      _queryController.text = _activeQuery;
      unawaited(_search());
    }
  }

  Widget _buildBody(List<RegisteredBookSource> enabledSources) {
    final scheme = Theme.of(context).colorScheme;
    if (_preparingSources) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_sourcesError != null) {
      return _buildSourcesErrorMessage();
    }
    if (enabledSources.isEmpty) {
      return _buildMessage(
        icon: Icons.travel_explore_outlined,
        title: context.l10n.bookSourcesNoSourcesTitle,
        message: context.l10n.bookSourcesNoSourcesDescription,
      );
    }
    if (!_hasSearched) {
      return _buildMessage(
        icon: Icons.manage_search_rounded,
        title: context.l10n.bookSourcesSearch,
        message: context.l10n.bookSourcesSearchHint,
      );
    }
    if (_results.isEmpty) {
      if (_searching) {
        return _buildSearchingMessage();
      }
      return _buildMessage(
        icon: Icons.search_off_rounded,
        title: context.l10n.bookSourcesNoResults,
        message: _failedSourceCount > 0
            ? context.l10n.bookSourcesFailedCount(_failedSourceCount)
            : '',
      );
    }
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${context.l10n.bookSourcesSearch}'
                    ' · ${_scopeLabel()} · ${_results.length}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (_searching) ...[
                  Text('$_completedSourceCount/$_totalSourceCount'),
                  const SizedBox(width: 10),
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_failedSourceCount > 0)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Text(
                context.l10n.bookSourcesFailedCount(_failedSourceCount),
                style: TextStyle(color: scheme.error, fontSize: 12),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          sliver: SliverList.separated(
            itemCount: _results.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final result = _results[index];
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1048),
                  child: SourcedBookListTile(
                    result: result,
                    onTap: () => _actions.showBookDetails(result),
                  ),
                ),
              );
            },
          ),
        ),
        if (_hasMore || _loadingMore || _loadMoreFailed)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverToBoxAdapter(
              child: Center(
                child: _loadingMore
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : OutlinedButton.icon(
                        key: const Key('bookSourceLoadMoreButton'),
                        onPressed: _loadMore,
                        icon: Icon(
                          _loadMoreFailed
                              ? Icons.refresh_rounded
                              : Icons.expand_more_rounded,
                        ),
                        label: Text(
                          _loadMoreFailed
                              ? context.l10n.retry
                              : context.l10n.bookSourcesLoadMore,
                        ),
                      ),
              ),
            ),
          ),
      ],
    );
  }

  String _scopeLabel() {
    for (final source in _sources) {
      if (source.id == _selectedSourceId) return source.name;
    }
    return context.l10n.statsRangeAll;
  }

  Widget _buildSearchingMessage() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 14),
          Text(
            '${context.l10n.bookSourcesSearch} '
            '$_completedSourceCount/$_totalSourceCount',
          ),
        ],
      ),
    );
  }

  Widget _buildMessage({
    required IconData icon,
    required String title,
    required String message,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 42,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (message.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSourcesErrorMessage() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 42,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.error,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _retryLoadSources,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(context.l10n.retry),
            ),
          ],
        ),
      ),
    );
  }
}
