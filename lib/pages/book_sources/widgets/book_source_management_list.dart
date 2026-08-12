import 'package:flutter/material.dart';

import '../../../book_sources/models/registered_book_source.dart';
import '../../../utils/localization_extension.dart';
import '../../../widgets/floating_subpage_scaffold.dart';
import '../controllers/book_source_management_controller.dart';
import 'book_source_management_source_card.dart';

class BookSourceManagementList extends StatelessWidget {
  const BookSourceManagementList({
    super.key,
    required this.state,
    required this.visibleSources,
    required this.availableGroups,
    required this.searchController,
    required this.scrollController,
    required this.additionalProtocolsEnabled,
    required this.onQueryChanged,
    required this.onClearQuery,
    required this.onFilterChanged,
    required this.onChooseGroup,
    required this.onResetFilters,
    required this.onToggleSelectAll,
    required this.onEnableSelected,
    required this.onDisableSelected,
    required this.onCheckSelected,
    required this.onRemoveSelected,
    required this.onToggleSourceSelection,
    required this.onSourceEnabledChanged,
    required this.onSourceAction,
  });

  final BookSourceManagementState state;
  final List<RegisteredBookSource> visibleSources;
  final List<String> availableGroups;
  final TextEditingController searchController;
  final ScrollController scrollController;
  final bool additionalProtocolsEnabled;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClearQuery;
  final ValueChanged<BookSourceManagementFilter> onFilterChanged;
  final VoidCallback onChooseGroup;
  final VoidCallback onResetFilters;
  final VoidCallback onToggleSelectAll;
  final VoidCallback onEnableSelected;
  final VoidCallback onDisableSelected;
  final VoidCallback onCheckSelected;
  final VoidCallback onRemoveSelected;
  final ValueChanged<RegisteredBookSource> onToggleSourceSelection;
  final void Function(RegisteredBookSource source, bool enabled)
  onSourceEnabledChanged;
  final void Function(
    RegisteredBookSource source,
    BookSourceManagementSourceAction action,
  )
  onSourceAction;

  @override
  Widget build(BuildContext context) {
    final visible = visibleSources;
    final allOrsp = visible
        .where((source) => source.sourceProtocol == BookSourceProtocolKind.orsp)
        .toList(growable: false);
    final allAdditional = visible
        .where((source) => source.sourceProtocol != BookSourceProtocolKind.orsp)
        .toList(growable: false);
    final orsp = allOrsp.take(state.displayLimit).toList(growable: false);
    final remaining = state.displayLimit - orsp.length;
    final additional = allAdditional
        .take(remaining > 0 ? remaining : 0)
        .toList(growable: false);
    final displayedCount = orsp.length + additional.length;

    return Scrollbar(
      key: const Key('bookSourceManagementScrollbar'),
      controller: scrollController,
      thumbVisibility: true,
      interactive: true,
      child: CustomScrollView(
        key: const Key('bookSourceManagementList'),
        controller: scrollController,
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(
              height: FloatingSubpageScaffold.headerExtentOf(context),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            sliver: SliverToBoxAdapter(
              child: _HeaderAndFilters(
                state: state,
                visibleSources: visible,
                availableGroups: availableGroups,
                visibleCount: visible.length,
                searchController: searchController,
                onQueryChanged: onQueryChanged,
                onClearQuery: onClearQuery,
                onFilterChanged: onFilterChanged,
                onChooseGroup: onChooseGroup,
                onToggleSelectAll: onToggleSelectAll,
                onEnableSelected: onEnableSelected,
                onDisableSelected: onDisableSelected,
                onCheckSelected: onCheckSelected,
                onRemoveSelected: onRemoveSelected,
              ),
            ),
          ),
          if (state.loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (state.sources.isEmpty)
            _paddedSliver(const BookSourceManagementEmptyCard())
          else if (visible.isEmpty)
            _paddedSliver(
              BookSourceManagementNoMatchesCard(onReset: onResetFilters),
            )
          else ...[
            if (orsp.isNotEmpty)
              ..._sourceGroupSlivers(
                context,
                title: context.l10n.bookSourcesProtocolGroupOrsp,
                sources: orsp,
                totalCount: allOrsp.length,
              ),
            if (additional.isNotEmpty)
              ..._sourceGroupSlivers(
                context,
                title: context.l10n.bookSourcesProtocolGroupAdditional,
                sources: additional,
                totalCount: allAdditional.length,
              ),
            if (displayedCount < visible.length)
              const SliverPadding(
                key: Key('bookSourceManagementLoadingMore'),
                padding: EdgeInsets.symmetric(vertical: 12),
                sliver: SliverToBoxAdapter(
                  child: Center(
                    child: SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  ),
                ),
              ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 36)),
        ],
      ),
    );
  }

  SliverPadding _paddedSliver(Widget child) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      sliver: SliverToBoxAdapter(child: child),
    );
  }

  List<Widget> _sourceGroupSlivers(
    BuildContext context, {
    required String title,
    required List<RegisteredBookSource> sources,
    required int totalCount,
  }) {
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
        sliver: SliverToBoxAdapter(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '$totalCount',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final source = sources[index];
            return BookSourceManagementSourceCard(
              source: source,
              selectionMode: state.selectionMode,
              selected: state.selectedSourceIds.contains(source.id),
              additionalProtocolsEnabled: additionalProtocolsEnabled,
              onToggleSelection: () => onToggleSourceSelection(source),
              onEnabledChanged: (enabled) =>
                  onSourceEnabledChanged(source, enabled),
              onAction: (action) => onSourceAction(source, action),
            );
          }, childCount: sources.length),
        ),
      ),
    ];
  }
}

class _HeaderAndFilters extends StatelessWidget {
  const _HeaderAndFilters({
    required this.state,
    required this.visibleSources,
    required this.availableGroups,
    required this.visibleCount,
    required this.searchController,
    required this.onQueryChanged,
    required this.onClearQuery,
    required this.onFilterChanged,
    required this.onChooseGroup,
    required this.onToggleSelectAll,
    required this.onEnableSelected,
    required this.onDisableSelected,
    required this.onCheckSelected,
    required this.onRemoveSelected,
  });

  final BookSourceManagementState state;
  final List<RegisteredBookSource> visibleSources;
  final List<String> availableGroups;
  final int visibleCount;
  final TextEditingController searchController;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClearQuery;
  final ValueChanged<BookSourceManagementFilter> onFilterChanged;
  final VoidCallback onChooseGroup;
  final VoidCallback onToggleSelectAll;
  final VoidCallback onEnableSelected;
  final VoidCallback onDisableSelected;
  final VoidCallback onCheckSelected;
  final VoidCallback onRemoveSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('bookSourceManagementSearchField'),
          controller: searchController,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: context.l10n.bookSourcesManagementSearchHint,
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: state.query.isEmpty
                ? null
                : IconButton(
                    tooltip: context.l10n.bookSourcesClearSearch,
                    onPressed: onClearQuery,
                    icon: const Icon(Icons.close_rounded),
                  ),
            filled: true,
            fillColor: scheme.surfaceContainerLow,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
          ),
          onChanged: onQueryChanged,
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final filter in BookSourceManagementFilter.values) ...[
                ChoiceChip(
                  key: Key('bookSourceFilter-${filter.name}'),
                  selected: state.filter == filter,
                  avatar: filter == BookSourceManagementFilter.requiresLogin
                      ? const Icon(Icons.key_rounded, size: 18)
                      : null,
                  label: Text(_filterLabel(context, filter)),
                  onSelected: (_) => onFilterChanged(filter),
                ),
                const SizedBox(width: 8),
              ],
              if (availableGroups.isNotEmpty)
                ActionChip(
                  key: const Key('bookSourceGroupFilter'),
                  avatar: const Icon(Icons.folder_outlined, size: 18),
                  label: Text(
                    state.selectedGroup ?? context.l10n.bookSourcesAllGroups,
                  ),
                  onPressed: onChooseGroup,
                ),
            ],
          ),
        ),
        if (state.selectionMode) ...[
          const SizedBox(height: 12),
          _BulkActions(
            state: state,
            allVisibleSelected: _allSelected(),
            onToggleSelectAll: onToggleSelectAll,
            onEnableSelected: onEnableSelected,
            onDisableSelected: onDisableSelected,
            onCheckSelected: onCheckSelected,
            onRemoveSelected: onRemoveSelected,
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            context.l10n.bookSourcesVisibleCount(
              visibleCount,
              state.sources.length,
            ),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  bool _allSelected() {
    final ids = visibleSources.map((source) => source.id).toSet();
    return ids.isNotEmpty && state.selectedSourceIds.containsAll(ids);
  }

  String _filterLabel(
    BuildContext context,
    BookSourceManagementFilter filter,
  ) => switch (filter) {
    BookSourceManagementFilter.all => context.l10n.statsRangeAll,
    BookSourceManagementFilter.enabled => context.l10n.bookSourcesEnabled,
    BookSourceManagementFilter.disabled => context.l10n.bookSourcesDisabled,
    BookSourceManagementFilter.runnable => context.l10n.bookSourcesRunnable,
    BookSourceManagementFilter.pending =>
      context.l10n.bookSourcesPendingCompatibility,
    BookSourceManagementFilter.requiresLogin =>
      context.l10n.bookSourcesRequiresLogin,
  };
}

class _BulkActions extends StatelessWidget {
  const _BulkActions({
    required this.state,
    required this.allVisibleSelected,
    required this.onToggleSelectAll,
    required this.onEnableSelected,
    required this.onDisableSelected,
    required this.onCheckSelected,
    required this.onRemoveSelected,
  });

  final BookSourceManagementState state;
  final bool allVisibleSelected;
  final VoidCallback onToggleSelectAll;
  final VoidCallback onEnableSelected;
  final VoidCallback onDisableSelected;
  final VoidCallback onCheckSelected;
  final VoidCallback onRemoveSelected;

  @override
  Widget build(BuildContext context) {
    final selected = state.selectedSourceIds.isNotEmpty;
    final progress = state.healthProgress;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: onToggleSelectAll,
          icon: Icon(
            allVisibleSelected
                ? Icons.deselect_rounded
                : Icons.select_all_rounded,
          ),
          label: Text(
            allVisibleSelected
                ? context.l10n.bookSourcesClearSelection
                : context.l10n.bookSourcesSelectAll,
          ),
        ),
        FilledButton.tonalIcon(
          onPressed: selected ? onEnableSelected : null,
          icon: const Icon(Icons.toggle_on_outlined),
          label: Text(context.l10n.bookSourcesEnableSelected),
        ),
        OutlinedButton.icon(
          onPressed: selected ? onDisableSelected : null,
          icon: const Icon(Icons.toggle_off_outlined),
          label: Text(context.l10n.bookSourcesDisableSelected),
        ),
        OutlinedButton.icon(
          onPressed: !selected || progress != null ? null : onCheckSelected,
          icon: progress == null
              ? const Icon(Icons.health_and_safety_outlined)
              : const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
          label: Text(
            progress == null
                ? context.l10n.bookSourcesCheckSelected
                : '${progress.completed}/${progress.total}',
          ),
        ),
        TextButton.icon(
          onPressed: selected ? onRemoveSelected : null,
          icon: const Icon(Icons.delete_outline_rounded),
          label: Text(context.l10n.bookSourcesDeleteSelected),
        ),
      ],
    );
  }
}
